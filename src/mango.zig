// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! MangoWM IPC (≥ 0.14): the `watch all-tags` stream as JSON lines.
//! The broker opens the socket and hands it over — the panel itself cannot connect anywhere.
//! JSON is parsed by a tiny bounds-checked tokenizer.

const std = @import("std");
const sys = @import("sys.zig");
const broker = @import("broker.zig");

pub const MAX_TAGS = 16;
pub const MAX_MONS = 8;

pub const Tag = struct { active: bool = false, urgent: bool = false, clients: u16 = 0 };

pub const Mon = struct {
    used: bool = false,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    tags: [MAX_TAGS]Tag = [_]Tag{.{}} ** MAX_TAGS,
    ntags: u8 = 0,

    pub fn name(self: *const Mon) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub var fd: i32 = -1;
pub var mons: [MAX_MONS]Mon = [_]Mon{.{}} ** MAX_MONS;

var buf: [64 * 1024]u8 = undefined;
var len: usize = 0;

pub fn connect() bool {
    fd = broker.requestWatch();
    len = 0;
    return fd >= 0;
}

pub fn disconnect() void {
    sys.close(fd);
    fd = -1;
}

/// Call when the socket is readable. true — the tag state changed.
pub fn onReadable() bool {
    if (len == buf.len) len = 0; // the line did not fit — drop it
    const n = sys.read(fd, buf[len..]) catch 0;
    if (n == 0) {
        disconnect();
        return false;
    }
    len += n;
    var changed = false;
    while (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| {
        parse(buf[0..nl]);
        changed = true;
        const rest = len - (nl + 1);
        std.mem.copyForwards(u8, buf[0..rest], buf[nl + 1 .. len]);
        len = rest;
    }
    return changed;
}

pub fn find(name: []const u8) ?*const Mon {
    if (name.len == 0) return null;
    for (&mons) |*m| {
        if (m.used and std.mem.eql(u8, m.name(), name)) return m;
    }
    return null;
}

fn slotFor(name: []const u8) ?*Mon {
    for (&mons) |*m| {
        if (m.used and std.mem.eql(u8, m.name(), name)) return m;
    }
    for (&mons) |*m| {
        if (!m.used) {
            const k = @min(name.len, m.name_buf.len);
            m.* = .{ .used = true, .name_len = k };
            @memcpy(m.name_buf[0..k], name[0..k]);
            return m;
        }
    }
    return null;
}

// ---------------------------------------------------------------- JSON
// Reply: {"all_tags":[{"monitor":"eDP-1","tags":[{"index":1,"is_active":true,
//         "is_urgent":false,"layout":"T","client_count":2}, ...]}, ...]}

const TokKind = enum { lbrace, rbrace, lbrack, rbrack, colon, comma, str, num, tru, fals, nul };
const Tok = struct { kind: TokKind, s: []const u8 = "", n: i64 = 0 };

fn nextTok(s: []const u8, p: *usize) ?Tok {
    var i = p.*;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r' or s[i] == '\n')) i += 1;
    if (i >= s.len) return null;
    const c = s[i];
    p.* = i + 1;
    switch (c) {
        '{' => return .{ .kind = .lbrace },
        '}' => return .{ .kind = .rbrace },
        '[' => return .{ .kind = .lbrack },
        ']' => return .{ .kind = .rbrack },
        ':' => return .{ .kind = .colon },
        ',' => return .{ .kind = .comma },
        '"' => {
            var j = i + 1;
            while (j < s.len and s[j] != '"') : (j += 1) {
                if (s[j] == '\\') j += 1;
            }
            const end = @min(j, s.len);
            p.* = @min(j + 1, s.len);
            return .{ .kind = .str, .s = s[i + 1 .. end] };
        },
        't' => {
            p.* = @min(i + 4, s.len);
            return .{ .kind = .tru };
        },
        'f' => {
            p.* = @min(i + 5, s.len);
            return .{ .kind = .fals };
        },
        'n' => {
            p.* = @min(i + 4, s.len);
            return .{ .kind = .nul };
        },
        else => {
            var j = i;
            var neg = false;
            if (s[j] == '-') {
                neg = true;
                j += 1;
            }
            var v: i64 = 0;
            // saturating arithmetic: a long number cannot overflow
            while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) v = (v *| 10) +| (s[j] - '0');
            while (j < s.len and (std.ascii.isDigit(s[j]) or s[j] == '.' or s[j] == 'e' or s[j] == 'E' or s[j] == '+' or s[j] == '-')) j += 1;
            p.* = @max(j, i + 1);
            return .{ .kind = .num, .n = if (neg) -v else v };
        },
    }
}

fn parse(line: []const u8) void {
    var p: usize = 0;
    var key: []const u8 = "";
    var mon: ?*Mon = null;
    var cur = Tag{};
    var cur_index: i64 = -1;
    while (nextTok(line, &p)) |tok| {
        switch (tok.kind) {
            .str => {
                // a string before a colon is a key
                var q = p;
                while (q < line.len and line[q] == ' ') q += 1;
                if (q < line.len and line[q] == ':') {
                    key = tok.s;
                    p = q + 1;
                    continue;
                }
                if (std.mem.eql(u8, key, "monitor")) {
                    mon = slotFor(tok.s);
                    if (mon) |m| m.ntags = 0;
                }
            },
            .num => {
                if (std.mem.eql(u8, key, "index")) {
                    cur_index = tok.n;
                } else if (std.mem.eql(u8, key, "client_count")) {
                    cur.clients = @intCast(std.math.clamp(tok.n, 0, 65535));
                }
            },
            .tru, .fals => {
                const v = tok.kind == .tru;
                if (std.mem.eql(u8, key, "is_active")) cur.active = v;
                if (std.mem.eql(u8, key, "is_urgent")) cur.urgent = v;
            },
            .lbrace => {
                cur = .{};
                cur_index = -1;
            },
            .rbrace => {
                if (cur_index >= 1 and cur_index <= MAX_TAGS) {
                    if (mon) |m| {
                        const i: usize = @intCast(cur_index - 1);
                        m.tags[i] = cur;
                        m.ntags = @max(m.ntags, @as(u8, @intCast(cur_index)));
                    }
                }
                cur_index = -1;
            },
            else => {},
        }
    }
}
