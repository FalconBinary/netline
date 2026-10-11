// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Тема: цвета по умолчанию из config.zig, поверх — файл $XDG_CONFIG_HOME/zpanel/theme.
//! Файл перечитывается при сохранении (inotify на папку), без перезапуска панели.

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
    load();
    // IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE | IN_MOVED_FROM
    inotify_fd = sys.inotifyInit() catch -1;
    if (inotify_fd >= 0) {
        sys.inotifyWatch(inotify_fd, dir, 0x8 | 0x80 | 0x100 | 0x200 | 0x40) catch {
            sys.close(inotify_fd);
            inotify_fd = -1;
        };
    }
}

/// Прочитать файл темы. Отсутствующий файл — цвета по умолчанию.
pub fn load() void {
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
    t = next;
}

fn applyLine(th: *cfg.Theme, raw: []const u8, ln: usize) void {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#' or line[0] == ';') return;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
        sys.log("тема, строка {d}: ожидается `имя = #цвет`", .{ln});
        return;
    };
    const key = std.mem.trim(u8, line[0..eq], " \t");
    // значение — первое слово после '=', дальше может идти комментарий
    var words = std.mem.tokenizeAny(u8, line[eq + 1 ..], " \t");
    const val = words.next() orelse "";
    const c = color.parse(val) orelse {
        sys.log("тема, строка {d}: неверный цвет", .{ln});
        return;
    };
    inline for (@typeInfo(cfg.Theme).@"struct".fields) |f| {
        if (std.mem.eql(u8, key, f.name)) {
            @field(th, f.name) = c;
            return;
        }
    }
    sys.log("тема, строка {d}: неизвестное имя", .{ln});
}

/// Обработать события inotify. true — тема перечитана.
pub fn onInotify() bool {
    var buf: [4096]u8 align(4) = undefined;
    var changed = false;
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
            if (std.mem.eql(u8, name, file_name)) changed = true;
            if (mask & 0x8000 != 0) { // IN_IGNORED: папку удалили
                sys.close(inotify_fd);
                inotify_fd = -1;
                return changed;
            }
            off += 16 + len;
        }
    }
    if (changed) load();
    return changed;
}
