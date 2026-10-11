// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Минимальная реализация wire-протокола Wayland поверх unix-сокета.
//! Никакого libwayland: сами сериализуем запросы и разбираем события.

const std = @import("std");
const sys = @import("sys.zig");

pub const MAX_IDS = 1024;

/// Аргумент-дескриптор (передаётся через SCM_RIGHTS).
pub const Fd = struct { fd: i32 };
/// Строковый аргумент (null — пустая/NULL строка).
pub const Str = struct { s: ?[]const u8 };
pub fn str(s: []const u8) Str {
    return .{ .s = s };
}

pub const Event = struct {
    obj: u32,
    op: u16,
    args: Args,
};

/// Последовательное чтение аргументов события.
pub const Args = struct {
    d: []const u8,
    p: usize = 0,

    pub fn uint(self: *Args) u32 {
        if (self.p + 4 > self.d.len) return 0;
        const v = std.mem.readInt(u32, self.d[self.p..][0..4], .little);
        self.p += 4;
        return v;
    }
    pub fn int(self: *Args) i32 {
        return @bitCast(self.uint());
    }
    /// fixed 24.8 -> f32
    pub fn fixed(self: *Args) f32 {
        return @as(f32, @floatFromInt(self.int())) / 256.0;
    }
    pub fn string(self: *Args) []const u8 {
        const len: usize = self.uint();
        if (len == 0) return "";
        // считаем в usize и сравниваем с остатком — без переполнений на «злых» длинах
        const rest = self.d.len - self.p;
        if (len > rest) {
            self.p = self.d.len;
            return "";
        }
        const padded = @min((len + 3) & ~@as(usize, 3), rest);
        const s = self.d[self.p .. self.p + len - 1]; // без завершающего нуля
        self.p += padded;
        return s;
    }
};

pub const Conn = struct {
    fd: i32 = -1,
    out: [16384]u8 = undefined,
    olen: usize = 0,
    ofds: [8]i32 = undefined,
    nofds: usize = 0,
    in: [65536]u8 = undefined,
    ilen: usize = 0,
    ipos: usize = 0,
    next_id: u32 = 2, // 1 — wl_display
    free_ids: [MAX_IDS]u32 = undefined,
    nfree: usize = 0,

    pub fn connect(self: *Conn) !void {
        const disp = sys.getenv("WAYLAND_DISPLAY") orelse "wayland-0";
        var buf: [256]u8 = undefined;
        const path = if (disp.len > 0 and disp[0] == '/')
            disp
        else blk: {
            const rt = sys.getenv("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
            break :blk sys.joinZ(&buf, &.{ rt, "/", disp });
        };
        self.fd = try sys.connectUnix(path);
    }

    pub fn newId(self: *Conn) u32 {
        if (self.nfree > 0) {
            // берём наименьший освобождённый id
            var best: usize = 0;
            for (self.free_ids[0..self.nfree], 0..) |id, i| {
                if (id < self.free_ids[best]) best = i;
            }
            const id = self.free_ids[best];
            self.free_ids[best] = self.free_ids[self.nfree - 1];
            self.nfree -= 1;
            return id;
        }
        if (self.next_id >= MAX_IDS) {
            sys.log("закончились id объектов", .{});
            sys.exit(1);
        }
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Вызывается на wl_display.delete_id — id можно переиспользовать.
    pub fn releaseId(self: *Conn, id: u32) void {
        if (id == 0 or id >= MAX_IDS or self.nfree >= MAX_IDS) return;
        self.free_ids[self.nfree] = id;
        self.nfree += 1;
    }

    /// Сериализует запрос. Аргументы — кортеж из u32 / i32 / Str / Fd
    /// (целочисленные литералы считаются u32).
    pub fn send(self: *Conn, obj: u32, op: u16, args: anytype) void {
        if (self.out.len - self.olen < 1024) self.flush() catch fatal();
        const start = self.olen;
        self.olen += 8;
        inline for (args) |a| {
            const T = @TypeOf(a);
            if (T == u32) {
                self.put32(a);
            } else if (T == i32) {
                self.put32(@bitCast(a));
            } else if (T == comptime_int) {
                self.put32(@as(u32, a));
            } else if (T == Str) {
                self.putStr(a.s);
            } else if (T == Fd) {
                if (self.nofds >= self.ofds.len) self.flush() catch fatal();
                self.ofds[self.nofds] = a.fd;
                self.nofds += 1;
            } else {
                @compileError("неподдерживаемый тип аргумента: " ++ @typeName(T));
            }
        }
        const size: u32 = @intCast(self.olen - start);
        std.mem.writeInt(u32, self.out[start..][0..4], obj, .little);
        std.mem.writeInt(u32, self.out[start + 4 ..][0..4], (size << 16) | op, .little);
    }

    fn put32(self: *Conn, v: u32) void {
        std.mem.writeInt(u32, self.out[self.olen..][0..4], v, .little);
        self.olen += 4;
    }

    fn putStr(self: *Conn, s: ?[]const u8) void {
        const v = s orelse {
            self.put32(0);
            return;
        };
        const len: u32 = @intCast(v.len + 1);
        self.put32(len);
        @memcpy(self.out[self.olen..][0..v.len], v);
        const padded = (len + 3) & ~@as(u32, 3);
        @memset(self.out[self.olen + v.len .. self.olen + padded], 0);
        self.olen += padded;
    }

    pub fn flush(self: *Conn) !void {
        var off: usize = 0;
        while (off < self.olen) {
            const n = try sys.sendmsgFds(self.fd, self.out[off..self.olen], self.ofds[0..self.nofds]);
            self.nofds = 0; // дескрипторы ушли с первой порцией
            off += n;
        }
        self.olen = 0;
    }

    /// Дочитать данные из сокета. false — соединение закрыто.
    pub fn fill(self: *Conn) !bool {
        if (self.ipos > 0) {
            const rest = self.ilen - self.ipos;
            std.mem.copyForwards(u8, self.in[0..rest], self.in[self.ipos..self.ilen]);
            self.ilen = rest;
            self.ipos = 0;
        }
        if (self.ilen == self.in.len) return error.BufferFull;
        const n = try sys.read(self.fd, self.in[self.ilen..]);
        if (n == 0) return false;
        self.ilen += n;
        return true;
    }

    /// Следующее полностью прочитанное событие (или null).
    pub fn next(self: *Conn) ?Event {
        const avail = self.ilen - self.ipos;
        if (avail < 8) return null;
        const p = self.in[self.ipos..];
        const obj = std.mem.readInt(u32, p[0..4], .little);
        const hdr = std.mem.readInt(u32, p[4..8], .little);
        const size = hdr >> 16;
        if (size < 8) {
            sys.log("битое сообщение от композитора", .{});
            sys.exit(1);
        }
        if (avail < size) return null;
        self.ipos += size;
        return .{ .obj = obj, .op = @truncate(hdr), .args = .{ .d = p[8..size] } };
    }

    fn fatal() noreturn {
        sys.log("ошибка записи в сокет Wayland", .{});
        sys.exit(1);
    }
};
