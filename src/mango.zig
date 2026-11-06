// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! MangoWM IPC (≥ 0.14): `watch` streams as JSON lines.
//! - `watch all-tags` — the tags of every monitor;
//! - `watch all-clients` — every window; the panel takes only which monitors show a fullscreen one.
//! The broker opens the sockets and hands them over — the panel itself cannot connect anywhere.
//! JSON is parsed by a tiny bounds-checked tokenizer.
//!
//! The second stream costs no wakeup. mango sends both lines from one handler, the tags line first
//! (ipc.c handle_print_status), and every change that sends one sends the other. So once the windows
//! stream is running, the event loop watches only it, and the tags line of the same change is read
//! along with it: it is already in its socket. If lines ever come otherwise, the tags stream is
//! watched on its own again.

const std = @import("std");
const sys = @import("sys.zig");
const broker = @import("broker.zig");

pub const MAX_TAGS = 16;
pub const MAX_MONS = 8;

pub const Tag = struct { active: bool = false, urgent: bool = false, clients: u16 = 0 };

pub const Mon = struct {
    used: bool = false,
    seen: bool = false, // present in the snapshot being parsed
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    tags: [MAX_TAGS]Tag = @as([MAX_TAGS]Tag, @splat(.{})),
    ntags: u8 = 0,

    pub fn name(self: *const Mon) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub var fd: i32 = -1; // watch all-tags
pub var wfd: i32 = -1; // watch all-clients; -1 — not asked for, or this mango doesn't have it
pub var mons: [MAX_MONS]Mon = @as([MAX_MONS]Mon, @splat(.{}));

var tag_buf: [64 * 1024]u8 = undefined;
var win_buf: [64 * 1024]u8 = undefined; // a window is ~0.6 KiB of JSON: room for about a hundred
var tags: Stream = .{ .buf = &tag_buf };
var wins: Stream = .{ .buf = &win_buf };
var wins_ok = false; // the windows stream has sent a snapshot
var in_order = true; // so far, every windows line came after the tags line of its change

const Name = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn get(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Name, s: []const u8) void {
        self.len = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..self.len], s[0..self.len]);
    }
};

/// Monitors that show a fullscreen window.
var full: [MAX_MONS]Name = @as([MAX_MONS]Name, @splat(.{}));
var nfull: usize = 0;

/// A stream of JSON lines. Every line is a full snapshot, so of a burst only the last one counts.
const Stream = struct {
    buf: []u8,
    len: usize = 0,
    lines: u64 = 0, // complete lines received
    skip: bool = false, // the rest of a line too long for the buffer is on its way

    /// Read what has arrived. false — the other end is gone.
    fn fill(s: *Stream, from: i32) bool {
        if (s.len == s.buf.len) { // the line did not fit — drop it, up to its end
            s.len = 0;
            s.skip = true;
        }
        const n = sys.read(from, s.buf[s.len..]) catch 0;
        if (n == 0) return false;
        s.add(n);
        return true;
    }

    /// `n` new bytes are at the end of the buffer.
    fn add(s: *Stream, n: usize) void {
        const new = s.buf[s.len..][0..n];
        s.lines += std.mem.count(u8, new, "\n");
        s.len += n;
        if (!s.skip) return;
        const nl = std.mem.indexOfScalar(u8, new, '\n') orelse {
            s.len = 0;
            return;
        };
        s.skip = false;
        const end = s.len - n + nl + 1;
        std.mem.copyForwards(u8, s.buf[0 .. s.len - end], s.buf[end..s.len]);
        s.len -= end;
    }

    /// The last complete line. `drop` forgets it once it is parsed.
    fn last(s: *const Stream) ?[]const u8 {
        const nl = std.mem.lastIndexOfScalar(u8, s.buf[0..s.len], '\n') orelse return null;
        const start = if (std.mem.lastIndexOfScalar(u8, s.buf[0..nl], '\n')) |p| p + 1 else 0;
        return s.buf[start..nl];
    }

    /// Forget the complete lines, keep the start of the next one.
    fn drop(s: *Stream) void {
        const nl = std.mem.lastIndexOfScalar(u8, s.buf[0..s.len], '\n') orelse return;
        const rest = s.len - (nl + 1);
        std.mem.copyForwards(u8, s.buf[0..rest], s.buf[nl + 1 .. s.len]);
        s.len = rest;
    }
};

/// `windows`: also watch the windows, for `fullscreen`.
pub fn connect(windows: bool) bool {
    const got = broker.requestWatch(windows);
    fd = got[0];
    wfd = got[1];
    tags = .{ .buf = &tag_buf };
    wins = .{ .buf = &win_buf };
    wins_ok = false;
    in_order = true;
    return fd >= 0;
}

pub fn disconnect() void {
    sys.close(fd);
    fd = -1;
    dropWindows();
}

/// Without the windows stream nothing is known about fullscreen windows: there are none.
fn dropWindows() void {
    if (wfd >= 0) sys.close(wfd);
    wfd = -1;
    wins_ok = false;
    nfull = 0;
}

/// The tags socket for the event loop: -1 while the windows stream wakes the panel for both.
pub fn tagsFd() i32 {
    const paired = wfd >= 0 and wins_ok and in_order and tags.lines >= wins.lines;
    return if (paired) -1 else fd;
}

/// Call when the tags socket is readable. true — a new tag state arrived.
/// Every `watch all-tags` line is a full snapshot of all monitors (mango ipc_notify_all_tags →
/// build_all_tags_response), so of a burst of lines only the last complete one is parsed.
pub fn onReadable() bool {
    if (!tags.fill(fd)) {
        disconnect();
        return false;
    }
    const line = tags.last() orelse return false;
    parse(line);
    tags.drop();
    return true;
}

pub const Changed = struct { tags: bool = false, fullscreen: bool = false };

/// Call when the windows socket is readable.
pub fn onWindowsReadable() Changed {
    var ch = Changed{};
    if (!wins.fill(wfd)) {
        ch.fullscreen = nfull > 0;
        dropWindows();
        return ch;
    }
    if (wins.last()) |line| {
        var found: [MAX_MONS]Name = undefined;
        const got = parseWindows(line, &found);
        wins.drop();
        if (got) |n| {
            wins_ok = true;
            ch.fullscreen = setFull(found[0..n]);
        } else if (!wins_ok) {
            // not what was asked for: a mango without this watch answers with an error
            dropWindows();
            return ch;
        }
    }
    // the tags line of the same change came first: it is in its socket already
    var pfd = [1]sys.PollFd{.{ .fd = fd, .events = sys.POLLIN }};
    const ready = sys.poll(&pfd, 0) catch 0;
    if (ready > 0) ch.tags = onReadable();
    if (tags.lines < wins.lines) in_order = false;
    return ch;
}

/// Whether the monitor shows a fullscreen window.
pub fn fullscreen(name: []const u8) bool {
    if (name.len == 0) return false;
    for (full[0..nfull]) |*f| {
        if (std.mem.eql(u8, f.get(), name)) return true;
    }
    return false;
}

/// true — the set changed.
fn setFull(found: []const Name) bool {
    var same = found.len == nfull;
    if (same) {
        for (found) |*f| same = same and fullscreen(f.get());
    }
    for (found, 0..) |*f, i| full[i].set(f.get());
    nfull = found.len;
    return !same;
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
        if (m.used and std.mem.eql(u8, m.name(), name)) {
            m.seen = true;
            return m;
        }
    }
    for (&mons) |*m| {
        if (!m.used) {
            const k = @min(name.len, m.name_buf.len);
            m.* = .{ .used = true, .seen = true, .name_len = k };
            @memcpy(m.name_buf[0..k], name[0..k]);
            return m;
        }
    }
    return null;
}

// ---------------------------------------------------------------- JSON
// Tags: {"all_tags":[{"monitor":"eDP-1","tags":[{"index":1,"is_active":true,
//        "is_urgent":false,"layout":"T","client_count":2}, ...]}, ...]}
// Windows: {"clients":[{"id":3,"title":"…","monitor":"eDP-1","tags":[1],"is_visible":true,
//        "is_fullscreen":false, …}, ...]}

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

/// A string before a colon is a key: then true, and `p` is past the colon.
fn isKey(line: []const u8, p: *usize) bool {
    var q = p.*;
    while (q < line.len and line[q] == ' ') q += 1;
    if (q >= line.len or line[q] != ':') return false;
    p.* = q + 1;
    return true;
}

fn parse(line: []const u8) void {
    var p: usize = 0;
    var key: []const u8 = "";
    var mon: ?*Mon = null;
    var cur = Tag{};
    var cur_index: i64 = -1;
    var snapshot = false;
    for (&mons) |*m| m.seen = false;
    // monitors missing from a full snapshot are gone (unplugged): free their slots,
    // otherwise after a few replugs under new names there would be no room left
    defer if (snapshot) {
        for (&mons) |*m| {
            if (m.used and !m.seen) m.* = .{};
        }
    };
    while (nextTok(line, &p)) |tok| {
        switch (tok.kind) {
            .str => {
                if (isKey(line, &p)) {
                    key = tok.s;
                    if (std.mem.eql(u8, key, "all_tags")) snapshot = true;
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

/// The monitors with a visible fullscreen window go to `out`: their number, or null if the line is
/// not a windows snapshot. A window on a tag that isn't shown, or minimized, is not visible.
fn parseWindows(line: []const u8, out: *[MAX_MONS]Name) ?usize {
    var p: usize = 0;
    var key: []const u8 = "";
    var snapshot = false;
    var n: usize = 0;
    var mon: []const u8 = "";
    var visible = false;
    var fs = false;
    while (nextTok(line, &p)) |tok| {
        switch (tok.kind) {
            .str => {
                if (isKey(line, &p)) {
                    key = tok.s;
                    if (std.mem.eql(u8, key, "clients")) snapshot = true;
                    continue;
                }
                if (std.mem.eql(u8, key, "monitor")) mon = tok.s;
            },
            .tru, .fals => {
                const v = tok.kind == .tru;
                if (std.mem.eql(u8, key, "is_visible")) visible = v;
                if (std.mem.eql(u8, key, "is_fullscreen")) fs = v;
            },
            .lbrace, .rbrace => {
                // a window's object ends; it holds no objects of its own
                if (tok.kind == .rbrace and visible and fs and mon.len > 0 and n < out.len) {
                    var known = false;
                    for (out[0..n]) |*f| known = known or std.mem.eql(u8, f.get(), mon);
                    if (!known) {
                        out[n] = .{};
                        out[n].set(mon);
                        n += 1;
                    }
                }
                mon = "";
                visible = false;
                fs = false;
            },
            else => {},
        }
    }
    return if (snapshot) n else null;
}

// ---------------------------------------------------------------- tests

fn windowsOf(line: []const u8) ?[]const Name {
    const S = struct {
        var out: [MAX_MONS]Name = undefined;
    };
    const n = parseWindows(line, &S.out) orelse return null;
    return S.out[0..n];
}

test "a visible fullscreen window marks its monitor" {
    // as mango 0.18 sends it, with fields in its order
    const line =
        \\{"clients":[{"id":1,"pid":10,"foreign_toplevel_id":"a1","title":"foot","appid":"foot","monitor":"eDP-1","tags":[1],"is_xwayland":false,"is_visible":true,"is_focused":false,"is_fullscreen":false,"is_floating":false,"x":0,"y":0,"width":960,"height":1080,"scroller_proportion":0.9},
        \\{"id":2,"pid":11,"foreign_toplevel_id":"b2","title":"a \"game\": {x}","appid":"game","monitor":"HDMI-A-1","tags":[2,3],"is_visible":true,"is_fullscreen":true,"is_fakefullscreen":false,"x":1920,"y":0,"width":1920,"height":1080,"scroller_proportion":1.0}]}
    ;
    const w = windowsOf(line).?;
    try std.testing.expectEqual(@as(usize, 1), w.len);
    try std.testing.expectEqualStrings("HDMI-A-1", w[0].get());
}

test "a fullscreen window on a hidden tag, or a fake one, doesn't count" {
    const line =
        \\{"clients":[{"id":1,"monitor":"eDP-1","is_visible":false,"is_fullscreen":true},{"id":2,"monitor":"eDP-1","is_visible":true,"is_fullscreen":false,"is_fakefullscreen":true}]}
    ;
    try std.testing.expectEqual(@as(usize, 0), windowsOf(line).?.len);
    try std.testing.expectEqual(@as(usize, 0), windowsOf("{\"clients\":[]}").?.len);
}

test "two fullscreen windows on one monitor count once" {
    const line =
        \\{"clients":[{"monitor":"DP-2","is_fullscreen":true,"is_visible":true},{"is_visible":true,"monitor":"DP-2","is_fullscreen":true},{"monitor":"DP-1","is_fullscreen":true,"is_visible":true}]}
    ;
    const w = windowsOf(line).?;
    try std.testing.expectEqual(@as(usize, 2), w.len);
    try std.testing.expectEqualStrings("DP-2", w[0].get());
    try std.testing.expectEqualStrings("DP-1", w[1].get());
}

test "an error reply is not a windows snapshot" {
    try std.testing.expect(windowsOf("{\"error\":\"unknown command\"}") == null);
    try std.testing.expect(windowsOf("{\"all_tags\":[]}") == null);
    // cut short: no crash, the window that didn't end isn't counted
    try std.testing.expectEqual(@as(usize, 0), windowsOf("{\"clients\":[{\"monitor\":\"eDP-1\",\"is_visible\":true,\"is_fullscreen\":tr").?.len);
}

test "the fullscreen set reports only changes" {
    var a: [MAX_MONS]Name = undefined;
    a[0] = .{};
    a[0].set("eDP-1");
    a[1] = .{};
    a[1].set("DP-1");
    nfull = 0;
    try std.testing.expect(setFull(a[0..1]));
    try std.testing.expect(fullscreen("eDP-1"));
    try std.testing.expect(!fullscreen("DP-1"));
    try std.testing.expect(!setFull(a[0..1]));
    try std.testing.expect(setFull(a[1..2]));
    try std.testing.expect(!fullscreen("eDP-1"));
    try std.testing.expect(setFull(&.{}));
    try std.testing.expect(!fullscreen("DP-1"));
    try std.testing.expect(!fullscreen(""));
}

test "a stream gives the last complete line and keeps the start of the next" {
    var b: [64]u8 = undefined;
    var s = Stream{ .buf = &b };
    const feed = struct {
        fn f(st: *Stream, text: []const u8) void {
            @memcpy(st.buf[st.len..][0..text.len], text);
            st.add(text.len);
        }
    }.f;
    feed(&s, "{\"a\":1}\n{\"a\":2}\n{\"a\"");
    try std.testing.expectEqual(@as(u64, 2), s.lines);
    try std.testing.expectEqualStrings("{\"a\":2}", s.last().?);
    s.drop();
    try std.testing.expect(s.last() == null);
    feed(&s, ":3}\n");
    try std.testing.expectEqualStrings("{\"a\":3}", s.last().?);
    s.drop();
    try std.testing.expectEqual(@as(u64, 3), s.lines);
    try std.testing.expectEqual(@as(usize, 0), s.len);
}

test "a line too long for the buffer is skipped to its end, and still counted" {
    var b: [16]u8 = undefined;
    var s = Stream{ .buf = &b };
    @memcpy(s.buf[0..16], "{\"x\":\"aaaaaaaaaa");
    s.add(16);
    // what fill does once the buffer is full
    s.len = 0;
    s.skip = true;
    const tail = "aaa\"}\n{\"y\":1}\n";
    @memcpy(s.buf[0..tail.len], tail);
    s.add(tail.len);
    try std.testing.expectEqual(@as(u64, 2), s.lines);
    try std.testing.expectEqualStrings("{\"y\":1}", s.last().?);
}
