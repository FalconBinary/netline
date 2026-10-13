// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Theme: default colors from config.zig, overridden by the file $XDG_CONFIG_HOME/netline/theme.
//! The file is reread when saved (inotify on its folder), without restarting the panel.
//!
//! An editor's save is several events: vim renames the file to a backup, creates a new one and
//! writes it. So the file is reread once, SETTLE_MS after the last event (the event loop sleeps
//! in poll with timeout()), and a redraw happens only if the colors actually changed —
//! no flash of default colors in between and no extra frames.

const std = @import("std");
const sys = @import("sys.zig");
const cfg = @import("config.zig");
const color = @import("color.zig");

pub var t: cfg.Theme = cfg.theme;
pub var inotify_fd: i32 = -1;

var path_buf: [512]u8 = undefined;
var path: [:0]const u8 = "";
var dir_buf: [512]u8 = undefined;
pub var dir: [:0]const u8 = "";

const file_name = blk: {
    const i = std.mem.lastIndexOfScalar(u8, cfg.theme_file, '/');
    break :blk if (i) |k| cfg.theme_file[k + 1 ..] else cfg.theme_file;
};

pub fn init() void {
    const base = sys.getenv("XDG_CONFIG_HOME") orelse blk: {
        const home = sys.getenv("HOME") orelse return;
        break :blk sys.joinZ(&dir_buf, &.{ home, "/.config" });
    };
    var tmp: [512]u8 = undefined;
    const base_copy = sys.joinZ(&tmp, &.{base});
    path = sys.joinZ(&path_buf, &.{ base_copy, "/", cfg.theme_file });
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    dir = sys.joinZ(&dir_buf, &.{path[0..slash]});
    _ = load();
    // IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE | IN_MOVED_FROM
    inotify_fd = sys.inotifyInit() catch -1;
    if (inotify_fd >= 0) {
        sys.inotifyWatch(inotify_fd, dir, 0x8 | 0x80 | 0x100 | 0x200 | 0x40) catch {
            sys.close(inotify_fd);
            inotify_fd = -1;
        };
    }
}

/// Read the theme file. A missing file means default colors. true — the colors changed.
pub fn load() bool {
    var next: cfg.Theme = cfg.theme;
    var buf: [16 * 1024]u8 = undefined;
    if (path.len > 0) {
        if (sys.readFile(path, &buf)) |data| {
            var lines = std.mem.splitScalar(u8, data, '\n');
            var ln: usize = 0;
            while (lines.next()) |raw| {
                ln += 1;
                applyLine(&next, raw, ln);
            }
        }
    }
    // compared as bytes (memcmp): a field-by-field comparison came out kilobytes larger
    const changed = !std.mem.eql(u8, std.mem.asBytes(&next), std.mem.asBytes(&t));
    t = next;
    return changed;
}

fn applyLine(th: *cfg.Theme, raw: []const u8, ln: usize) void {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#' or line[0] == ';') return;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
        sys.log("theme, line {d}: expected `name = #color`", .{ln});
        return;
    };
    const key = std.mem.trim(u8, line[0..eq], " \t");
    // the value is the first word after '=', a comment may follow
    var words = std.mem.tokenizeAny(u8, line[eq + 1 ..], " \t");
    const val = words.next() orelse "";
    const c = color.parse(val) orelse {
        sys.log("theme, line {d}: invalid color", .{ln});
        return;
    };
    inline for (@typeInfo(cfg.Theme).@"struct".fields) |f| {
        if (std.mem.eql(u8, key, f.name)) {
            @field(th, f.name) = c;
            return;
        }
    }
    sys.log("theme, line {d}: unknown name", .{ln});
}

/// Monotonic time (ms) of the last change of the theme file not yet reread; 0 — none.
var pending_at: u64 = 0;
const SETTLE_MS = 80;

/// Handle inotify events: a change of our file is remembered, the reread comes in settle().
pub fn onInotify() void {
    var buf: [4096]u8 align(4) = undefined;
    while (true) {
        const n = sys.read(inotify_fd, &buf) catch break;
        if (n == 0) break;
        // struct inotify_event { i32 wd; u32 mask; u32 cookie; u32 len; char name[len]; }
        var off: usize = 0;
        while (off + 16 <= n) {
            const mask = std.mem.readInt(u32, buf[off + 4 ..][0..4], .little);
            const len = std.mem.readInt(u32, buf[off + 12 ..][0..4], .little);
            if (off + 16 + len > n) break;
            const name_raw = buf[off + 16 .. off + 16 + len];
            const name = name_raw[0 .. std.mem.indexOfScalar(u8, name_raw, 0) orelse name_raw.len];
            if (std.mem.eql(u8, name, file_name)) pending_at = @max(1, sys.monoMs());
            if (mask & 0x8000 != 0) { // IN_IGNORED: the folder was removed
                sys.close(inotify_fd);
                inotify_fd = -1;
                return;
            }
            off += 16 + len;
        }
    }
}

/// Timeout for the event loop's poll: -1 (sleep until an event) or what is left of the pause before the reread.
pub fn timeout() i32 {
    if (pending_at == 0) return -1;
    const passed = sys.monoMs() -% pending_at;
    return if (passed >= SETTLE_MS) 0 else @intCast(SETTLE_MS - passed);
}

/// Called after every poll: rereads the file once the pause has passed. true — the colors changed.
pub fn settle() bool {
    if (pending_at == 0 or sys.monoMs() -% pending_at < SETTLE_MS) return false;
    pending_at = 0;
    return load();
}

/// Whether a background color is fully opaque (then the compositor needn't draw what's under it).
pub fn solid(c: u32) bool {
    return c >> 24 == 0xff;
}
