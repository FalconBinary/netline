// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Минимальный клиент D-Bus на чистом Zig: аутентификация EXTERNAL, маршалинг сообщений
//! (little-endian), синхронные вызовы методов. Все чтения проверяют границы.

const std = @import("std");
const sys = @import("sys.zig");

pub const Error = error{ Connect, Auth, Io, Timeout, Protocol, TooBig, Remote };

// ================================================================= запись

pub const W = struct {
    buf: []u8,
    n: usize = 0,
    overflow: bool = false,

    fn put(w: *W, data: []const u8) void {
        if (w.n + data.len > w.buf.len) {
            w.overflow = true;
            return;
        }
        @memcpy(w.buf[w.n..][0..data.len], data);
        w.n += data.len;
    }
    pub fn pad(w: *W, a: usize) void {
        while (w.n % a != 0 and !w.overflow) w.put(&.{0});
    }
    pub fn byte(w: *W, v: u8) void {
        w.put(&.{v});
    }
    pub fn u32_(w: *W, v: u32) void {
        w.pad(4);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        w.put(&b);
    }
    pub fn boolean(w: *W, v: bool) void {
        w.u32_(@intFromBool(v));
    }
    pub fn str(w: *W, s: []const u8) void {
        w.u32_(@intCast(s.len));
        w.put(s);
        w.put(&.{0});
    }
    pub fn sig(w: *W, s: []const u8) void {
        w.byte(@intCast(s.len));
        w.put(s);
        w.put(&.{0});
    }

    pub const Arr = struct { len_pos: usize, start: usize };
    pub fn arrayBegin(w: *W, elem_align: usize) Arr {
        w.u32_(0);
        const len_pos = w.n - 4;
        w.pad(elem_align);
        return .{ .len_pos = len_pos, .start = w.n };
    }
    pub fn arrayEnd(w: *W, a: Arr) void {
        if (w.overflow) return;
        std.mem.writeInt(u32, w.buf[a.len_pos..][0..4], @intCast(w.n - a.start), .little);
    }

    // ---- элементы словаря a{sv}
    pub fn kvStr(w: *W, key: []const u8, val: []const u8) void {
        w.pad(8);
        w.str(key);
        w.sig("s");
        w.str(val);
    }
    pub fn kvBool(w: *W, key: []const u8, val: bool) void {
        w.pad(8);
        w.str(key);
        w.sig("b");
        w.boolean(val);
    }
    pub fn kvBytes(w: *W, key: []const u8, val: []const u8) void {
        w.pad(8);
        w.str(key);
        w.sig("ay");
        const a = w.arrayBegin(1);
        w.put(val);
        w.arrayEnd(a);
    }
    pub fn kvStrArray(w: *W, key: []const u8, items: []const []const u8) void {
        w.pad(8);
        w.str(key);
        w.sig("as");
        const a = w.arrayBegin(4);
        for (items) |it| w.str(it);
        w.arrayEnd(a);
    }
    /// Начать элемент a{sa{sv}}: имя группы и вложенный словарь.
    pub fn groupBegin(w: *W, name: []const u8) Arr {
        w.pad(8);
        w.str(name);
        return w.arrayBegin(8);
    }

    pub fn bytes(w: *const W) []const u8 {
        return w.buf[0..w.n];
    }
};

// ================================================================= чтение

pub fn alignOf(c: u8) usize {
    return switch (c) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 's', 'o', 'a', 'h' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => 1,
    };
}

/// Индекс сразу после одного полного типа, начинающегося в sig[i].
pub fn typeEnd(sig: []const u8, i: usize) usize {
    if (i >= sig.len) return sig.len;
    switch (sig[i]) {
        'a' => return typeEnd(sig, i + 1),
        '(', '{' => {
            const close: u8 = if (sig[i] == '(') ')' else '}';
            var j = i + 1;
            while (j < sig.len and sig[j] != close) j = typeEnd(sig, j);
            return @min(j + 1, sig.len);
        },
        else => return i + 1,
    }
}

pub const R = struct {
    d: []const u8,
    p: usize = 0,
    bad: bool = false,

    pub fn alignTo(r: *R, a: usize) void {
        r.p = (r.p + a - 1) & ~(a - 1);
        if (r.p > r.d.len) {
            r.p = r.d.len;
            r.bad = true;
        }
    }
    fn take(r: *R, n: usize) []const u8 {
        if (r.d.len - r.p < n) {
            r.bad = true;
            r.p = r.d.len;
            return &.{};
        }
        const s = r.d[r.p .. r.p + n];
        r.p += n;
        return s;
    }
    pub fn byte(r: *R) u8 {
        const s = r.take(1);
        return if (s.len == 1) s[0] else 0;
    }
    pub fn u32_(r: *R) u32 {
        r.alignTo(4);
        const s = r.take(4);
        return if (s.len == 4) std.mem.readInt(u32, s[0..4], .little) else 0;
    }
    pub fn u64_(r: *R) u64 {
        r.alignTo(8);
        const s = r.take(8);
        return if (s.len == 8) std.mem.readInt(u64, s[0..8], .little) else 0;
    }
    pub fn boolean(r: *R) bool {
        return r.u32_() != 0;
    }
    pub fn str(r: *R) []const u8 {
        const len = r.u32_();
        const s = r.take(len);
        _ = r.take(1);
        return s;
    }
    pub fn sig(r: *R) []const u8 {
        const len = r.byte();
        const s = r.take(len);
        _ = r.take(1);
        return s;
    }
    /// Начало массива: возвращает позицию конца его данных.
    pub fn arrayEnd(r: *R, elem_align: usize) usize {
        const len = r.u32_();
        r.alignTo(elem_align);
        if (len > r.d.len - r.p) {
            r.bad = true;
            return r.d.len;
        }
        return r.p + len;
    }
    /// Пропустить одно значение типа `t` (один полный тип).
    pub fn skip(r: *R, t: []const u8) void {
        r.skipDepth(t, 0);
    }
    fn skipDepth(r: *R, t: []const u8, depth: u32) void {
        if (t.len == 0 or r.bad or depth > 32) {
            r.bad = r.bad or depth > 32;
            return;
        }
        switch (t[0]) {
            'y' => _ = r.take(1),
            'n', 'q' => {
                r.alignTo(2);
                _ = r.take(2);
            },
            'b', 'i', 'u', 'h' => _ = r.u32_(),
            'x', 't', 'd' => _ = r.u64_(),
            's', 'o' => _ = r.str(),
            'g' => _ = r.sig(),
            'v' => {
                const s = r.sig();
                r.skipDepth(s, depth + 1);
            },
            'a' => {
                const elem = t[1..typeEnd(t, 0)];
                const end = r.arrayEnd(alignOf(if (elem.len > 0) elem[0] else 'y'));
                r.p = end;
            },
            '(', '{' => {
                r.alignTo(8);
                var j: usize = 1;
                const close = typeEnd(t, 0) - 1;
                while (j < close and !r.bad) {
                    const e = typeEnd(t, j);
                    r.skipDepth(t[j..e], depth + 1);
                    j = e;
                }
            },
            else => r.bad = true,
        }
    }
};

// ================================================================= соединение

pub const Reply = struct {
    sig: []const u8,
    body: []const u8,
    err_name: []const u8 = "",

    pub fn ok(self: Reply) bool {
        return self.err_name.len == 0;
    }
    pub fn reader(self: Reply) R {
        return .{ .d = self.body };
    }
    /// Текст ошибки (первый аргумент-строка ошибки D-Bus).
    pub fn message(self: Reply) []const u8 {
        if (self.sig.len == 0 or self.sig[0] != 's') return self.err_name;
        var r = self.reader();
        return r.str();
    }
};

/// Обработчик сигналов, пришедших вперемешку с ответами.
pub const SignalFn = *const fn (iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) void;

pub const Conn = struct {
    fd: i32 = -1,
    on_signal: ?SignalFn = null,
    serial: u32 = 0,
    in: [256 * 1024]u8 = undefined,
    ilen: usize = 0,
    consumed: usize = 0, // длина последнего отданного ответа в начале буфера
    out: [64 * 1024]u8 = undefined,

    /// Подключиться к системной шине (или к адресу из DBUS_SYSTEM_BUS_ADDRESS).
    pub fn connectSystem(c: *Conn) Error!void {
        var path: []const u8 = "/run/dbus/system_bus_socket";
        if (sys.getenv("DBUS_SYSTEM_BUS_ADDRESS")) |addr| {
            if (std.mem.indexOf(u8, addr, "unix:path=")) |i| {
                const rest = addr[i + 10 ..];
                path = rest[0 .. std.mem.indexOfAny(u8, rest, ",;") orelse rest.len];
            }
        }
        c.fd = sys.connectUnix(path) catch return error.Connect;
        errdefer {
            sys.close(c.fd);
            c.fd = -1;
        }
        try c.auth();
        const r = try c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "", "");
        if (!r.ok()) return error.Auth;
    }

    fn auth(c: *Conn) Error!void {
        // AUTH EXTERNAL <uid в виде шестнадцатеричной записи десятичной строки>
        var uidbuf: [16]u8 = undefined;
        const uid = std.fmt.bufPrint(&uidbuf, "{d}", .{sys.getuid()}) catch return error.Auth;
        var line: [96]u8 = undefined;
        var n: usize = 0;
        const head = "\x00AUTH EXTERNAL ";
        @memcpy(line[0..head.len], head);
        n = head.len;
        const hexd = "0123456789abcdef";
        for (uid) |ch| {
            line[n] = hexd[ch >> 4];
            line[n + 1] = hexd[ch & 15];
            n += 2;
        }
        line[n] = '\r';
        line[n + 1] = '\n';
        n += 2;
        sys.sendAll(c.fd, line[0..n]) catch return error.Io;
        // ждём строку "OK <guid>\r\n"
        var got: usize = 0;
        while (true) {
            try c.waitReadable(5000);
            const k = sys.read(c.fd, c.in[got..256]) catch return error.Io;
            if (k == 0) return error.Auth;
            got += k;
            if (std.mem.indexOf(u8, c.in[0..got], "\r\n")) |_| break;
            if (got >= 256) return error.Auth;
        }
        if (!std.mem.startsWith(u8, c.in[0..got], "OK ")) return error.Auth;
        sys.sendAll(c.fd, "BEGIN\r\n") catch return error.Io;
        c.ilen = 0;
        c.consumed = 0;
    }

    fn waitReadable(c: *Conn, timeout_ms: i32) Error!void {
        var pfd = [1]sys.PollFd{.{ .fd = c.fd, .events = sys.POLLIN }};
        const n = sys.poll(&pfd, timeout_ms) catch return error.Io;
        if (n == 0) return error.Timeout;
    }

    /// Синхронный вызов метода. Ответ ссылается на внутренний буфер — до следующего вызова.
    pub fn call(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) Error!Reply {
        c.serial +%= 1;
        if (c.serial == 0) c.serial = 1;
        const serial = c.serial;
        var w = W{ .buf = &c.out };
        w.byte('l');
        w.byte(1); // METHOD_CALL
        w.byte(0);
        w.byte(1); // версия протокола
        w.u32_(@intCast(body.len));
        w.u32_(serial);
        const fields = w.arrayBegin(8);
        field(&w, 1, "o", path);
        field(&w, 2, "s", iface);
        field(&w, 3, "s", member);
        field(&w, 6, "s", dest);
        if (sig.len > 0) {
            w.pad(8);
            w.byte(8);
            w.sig("g");
            w.sig(sig);
        }
        w.arrayEnd(fields);
        w.pad(8);
        if (w.overflow or w.n + body.len > w.buf.len) return error.TooBig;
        @memcpy(w.buf[w.n..][0..body.len], body);
        w.n += body.len;
        sys.sendAll(c.fd, w.bytes()) catch return error.Io;
        return c.waitReply(serial);
    }

    fn field(w: *W, code: u8, t: []const u8, val: []const u8) void {
        w.pad(8);
        w.byte(code);
        w.sig(t);
        w.str(val);
    }

    fn drop(c: *Conn, n: usize) void {
        std.mem.copyForwards(u8, c.in[0 .. c.ilen - n], c.in[n..c.ilen]);
        c.ilen -= n;
    }

    fn waitReply(c: *Conn, serial: u32) Error!Reply {
        // предыдущий ответ уже обработан — убираем его, остальное (если пришло) сохраняем
        if (c.consumed > 0) {
            c.drop(c.consumed);
            c.consumed = 0;
        }
        while (true) {
            // целое сообщение уже в буфере?
            while (c.ilen >= 16) {
                if (c.in[0] != 'l') return error.Protocol; // big-endian не поддерживаем
                const body_len = std.mem.readInt(u32, c.in[4..8], .little);
                const flen = std.mem.readInt(u32, c.in[12..16], .little);
                const hdr = (16 + @as(usize, flen) + 7) & ~@as(usize, 7);
                const total = hdr + @as(usize, body_len);
                if (total > c.in.len) return error.TooBig;
                if (c.ilen < total) break;
                const msg = c.in[0..total];
                const kind = msg[1];
                var reply_serial: u32 = 0;
                var err_name: []const u8 = "";
                var msig: []const u8 = "";
                var iface: []const u8 = "";
                var member: []const u8 = "";
                var r = R{ .d = msg[0 .. 16 + flen], .p = 16 };
                while (r.p < r.d.len and !r.bad) {
                    r.alignTo(8);
                    if (r.p >= r.d.len) break;
                    const code = r.byte();
                    const t = r.sig();
                    const eql = std.mem.eql;
                    if (code == 5 and eql(u8, t, "u")) {
                        reply_serial = r.u32_();
                    } else if (code == 4 and eql(u8, t, "s")) {
                        err_name = r.str();
                    } else if (code == 8 and eql(u8, t, "g")) {
                        msig = r.sig();
                    } else if (code == 2 and eql(u8, t, "s")) {
                        iface = r.str();
                    } else if (code == 3 and eql(u8, t, "s")) {
                        member = r.str();
                    } else r.skip(t);
                }
                if (r.bad) return error.Protocol;
                if ((kind == 2 or kind == 3) and reply_serial == serial) {
                    c.consumed = total;
                    return .{ .sig = msig, .body = msg[hdr..total], .err_name = if (kind == 3) (if (err_name.len > 0) err_name else "error") else "" };
                }
                if (kind == 4) {
                    if (c.on_signal) |cb| cb(iface, member, msig, msg[hdr..total]);
                }
                // чужое сообщение обработано — выбрасываем
                c.drop(total);
            }
            try c.waitReadable(10000);
            const k = sys.read(c.fd, c.in[c.ilen..]) catch return error.Io;
            if (k == 0) return error.Io;
            c.ilen += k;
        }
    }
};
