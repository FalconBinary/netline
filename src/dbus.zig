// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Minimal D-Bus client in pure Zig: EXTERNAL authentication, message marshalling
//! (little-endian), synchronous method calls. Every read is bounds-checked.

const std = @import("std");
const sys = @import("sys.zig");

pub const Error = error{ Connect, Auth, Io, Timeout, Protocol, TooBig, Remote };

// ================================================================= writing

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

    // ---- a{sv} dictionary entries
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
    /// Start an a{sa{sv}} entry: the group name and a nested dictionary.
    pub fn groupBegin(w: *W, name: []const u8) Arr {
        w.pad(8);
        w.str(name);
        return w.arrayBegin(8);
    }

    pub fn bytes(w: *const W) []const u8 {
        return w.buf[0..w.n];
    }
};

// ================================================================= reading

pub fn alignOf(c: u8) usize {
    return switch (c) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 's', 'o', 'a', 'h' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => 1,
    };
}

/// Index right after one complete type starting at sig[i].
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
    pub fn u16_(r: *R) u16 {
        r.alignTo(2);
        const s = r.take(2);
        return if (s.len == 2) std.mem.readInt(u16, s[0..2], .little) else 0;
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
    /// Start of an array: returns the position where its data ends.
    pub fn arrayEnd(r: *R, elem_align: usize) usize {
        const len = r.u32_();
        r.alignTo(elem_align);
        if (len > r.d.len - r.p) {
            r.bad = true;
            return r.d.len;
        }
        return r.p + len;
    }
    /// Skip one value of type `t` (one complete type).
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

// ================================================================= connection

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
    /// Error text (the first string argument of a D-Bus error).
    pub fn message(self: Reply) []const u8 {
        if (self.sig.len == 0 or self.sig[0] != 's') return self.err_name;
        var r = self.reader();
        return r.str();
    }
};

/// An incoming method call (e.g. from BlueZ to our pairing agent).
pub const Incoming = struct {
    serial: u32,
    flags: u8,
    sender: []const u8,
    path: []const u8,
    iface: []const u8,
    member: []const u8,
    sig: []const u8,
    body: []const u8,

    pub fn reader(m: *const Incoming) R {
        return .{ .d = m.body };
    }
};

/// Result of an async call: success or error text.
pub const Done = struct {
    serial: u32 = 0,
    ok: bool = false,
    name_buf: [96]u8 = undefined,
    name_len: usize = 0,
    msg_buf: [200]u8 = undefined,
    msg_len: usize = 0,

    pub fn errName(d: *const Done) []const u8 {
        return d.name_buf[0..d.name_len];
    }
    pub fn message(d: *const Done) []const u8 {
        return d.msg_buf[0..d.msg_len];
    }
};

/// Handler for signals that arrive interleaved with replies. It must not call the bus.
pub const SignalFn = *const fn (path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) void;
/// Handler for incoming calls. Must reply (reply/replyError) right away or later.
/// No synchronous calls from handlers.
pub const MethodFn = *const fn (c: *Conn, m: *const Incoming) void;

const Msg = struct {
    kind: u8,
    flags: u8,
    reply_serial: u32 = 0,
    err_name: []const u8 = "",
    sig: []const u8 = "",
    path: []const u8 = "",
    iface: []const u8 = "",
    member: []const u8 = "",
    sender: []const u8 = "",
    serial: u32,
    body: []const u8,
};

const MAX_ASYNC = 8;

// Buffers are separate global arrays (in .bss rather than 1.1 MB in .data of every binary).
// There is one D-Bus connection per process.
var in_buf: [1024 * 1024]u8 = undefined;
var out_buf: [64 * 1024]u8 = undefined;

pub const Conn = struct {
    fd: i32 = -1,
    on_signal: ?SignalFn = null,
    on_method: ?MethodFn = null,
    serial: u32 = 0,
    in: *[1024 * 1024]u8 = &in_buf,
    head: usize = 0, // start of the unhandled data (handled messages aren't shifted out one by one)
    ilen: usize = 0,
    consumed: usize = 0, // length of the last returned reply at `head`
    out: *[64 * 1024]u8 = &out_buf,
    waiting: [MAX_ASYNC]u32 = [_]u32{0} ** MAX_ASYNC,
    done: [MAX_ASYNC]Done = [_]Done{.{}} ** MAX_ASYNC,
    /// The unique bus name (":1.23") of the service we talk to. Signals are accepted only from it:
    /// match rules filter broadcasts, but any local process may send a signal straight to us
    /// (a fake network or device in the list, or a flood that keeps the menu busy).
    peer_buf: [64]u8 = undefined,
    peer_len: usize = 0,

    /// Take signals only from this sender (the GetNameOwner reply).
    pub fn setPeer(c: *Conn, name: []const u8) void {
        c.peer_len = @min(name.len, c.peer_buf.len);
        @memcpy(c.peer_buf[0..c.peer_len], name[0..c.peer_len]);
    }

    pub fn peer(c: *const Conn) []const u8 {
        return c.peer_buf[0..c.peer_len];
    }

    /// Connect to the system bus (or to the address in DBUS_SYSTEM_BUS_ADDRESS).
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
        // AUTH, BEGIN and Hello go out in one round trip without waiting for "OK" (sd-bus does this too):
        // one wait for a reply instead of two
        try c.auth();
        const serial = try c.send(.{ .kind = 1, .path = "/org/freedesktop/DBus", .iface = "org.freedesktop.DBus", .member = "Hello", .dest = "org.freedesktop.DBus" }, "");
        try c.authReply();
        const r = try c.waitReply(serial);
        if (!r.ok()) return error.Auth;
    }

    fn auth(c: *Conn) Error!void {
        // AUTH EXTERNAL <uid as the hex encoding of its decimal string>
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
        const tail = "\r\nBEGIN\r\n";
        @memcpy(line[n..][0..tail.len], tail);
        n += tail.len;
        sys.sendAll(c.fd, line[0..n]) catch return error.Io;
    }

    /// The "OK <guid>\r\n" line from the server. Everything after it is already messages (the Hello reply).
    fn authReply(c: *Conn) Error!void {
        var got: usize = 0;
        const end = while (true) {
            if (std.mem.indexOf(u8, c.in[0..got], "\r\n")) |e| break e;
            if (got >= 256) return error.Auth;
            try c.waitReadable(5000);
            const k = sys.read(c.fd, c.in[got..]) catch return error.Io;
            if (k == 0) return error.Auth; // REJECTED and close — no access
            got += k;
        };
        if (!std.mem.startsWith(u8, c.in[0..end], "OK ")) return error.Auth;
        c.head = end + 2;
        c.ilen = got;
        c.consumed = 0;
        if (c.head == c.ilen) {
            c.head = 0;
            c.ilen = 0;
        }
    }

    fn waitReadable(c: *Conn, timeout_ms: i32) Error!void {
        var pfd = [1]sys.PollFd{.{ .fd = c.fd, .events = sys.POLLIN }};
        const n = sys.poll(&pfd, timeout_ms) catch return error.Io;
        if (n == 0) return error.Timeout;
    }

    const Out = struct {
        kind: u8,
        flags: u8 = 0,
        path: []const u8 = "",
        iface: []const u8 = "",
        member: []const u8 = "",
        err_name: []const u8 = "",
        reply_serial: u32 = 0,
        dest: []const u8 = "",
        sig: []const u8 = "",
    };

    /// Build and send a message. Returns its serial.
    fn send(c: *Conn, o: Out, body: []const u8) Error!u32 {
        c.serial +%= 1;
        if (c.serial == 0) c.serial = 1;
        const serial = c.serial;
        var w = W{ .buf = c.out };
        w.byte('l');
        w.byte(o.kind);
        w.byte(o.flags);
        w.byte(1); // protocol version
        w.u32_(@intCast(body.len));
        w.u32_(serial);
        const fields = w.arrayBegin(8);
        if (o.path.len > 0) field(&w, 1, "o", o.path);
        if (o.iface.len > 0) field(&w, 2, "s", o.iface);
        if (o.member.len > 0) field(&w, 3, "s", o.member);
        if (o.err_name.len > 0) field(&w, 4, "s", o.err_name);
        if (o.reply_serial != 0) {
            w.pad(8);
            w.byte(5);
            w.sig("u");
            w.u32_(o.reply_serial);
        }
        if (o.dest.len > 0) field(&w, 6, "s", o.dest);
        if (o.sig.len > 0) {
            w.pad(8);
            w.byte(8);
            w.sig("g");
            w.sig(o.sig);
        }
        w.arrayEnd(fields);
        w.pad(8);
        if (w.overflow or w.n + body.len > w.buf.len) return error.TooBig;
        @memcpy(w.buf[w.n..][0..body.len], body);
        w.n += body.len;
        sys.sendAll(c.fd, w.bytes()) catch return error.Io;
        return serial;
    }

    /// Synchronous method call. The reply points into the internal buffer — until the next call.
    pub fn call(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) Error!Reply {
        const serial = try c.send(.{ .kind = 1, .path = path, .iface = iface, .member = member, .dest = dest, .sig = sig }, body);
        return c.waitReply(serial);
    }

    /// Send a call without waiting for the reply: replies to a batch of such calls are taken by collect.
    pub fn sendCall(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) Error!u32 {
        return c.send(.{ .kind = 1, .path = path, .iface = iface, .member = member, .dest = dest, .sig = sig }, body);
    }

    /// Wait for replies to the calls `serials` (0 — skip) in any order: for each one —
    /// got(ctx, index, reply). The reply lives only inside got; got must not call the bus.
    /// A batch instead of a chain of synchronous calls — one wait instead of N.
    /// Don't send more than 64 calls at once: the system bus limits pending replies.
    pub fn collect(c: *Conn, serials: []u32, ctx: anytype, comptime got: fn (@TypeOf(ctx), usize, Reply) void) Error!void {
        if (c.consumed > 0) {
            c.drop(c.consumed);
            c.consumed = 0;
        }
        var left: usize = 0;
        for (serials) |s| left += @intFromBool(s != 0);
        while (left > 0) {
            while (try c.complete()) |total| {
                const m = try c.parse(total);
                var mine = false;
                if (m.kind == 2 or m.kind == 3) {
                    for (serials, 0..) |*s, i| {
                        if (s.* == 0 or s.* != m.reply_serial) continue;
                        s.* = 0;
                        left -= 1;
                        mine = true;
                        got(ctx, i, .{ .sig = m.sig, .body = m.body, .err_name = if (m.kind == 3) (if (m.err_name.len > 0) m.err_name else "error") else "" });
                        break;
                    }
                }
                if (!mine) c.handle(&m);
                c.drop(total);
            }
            if (left == 0) break;
            try c.waitReadable(10000);
            try c.readMore();
        }
    }

    /// Call without a reply (NO_REPLY_EXPECTED flag): the bus won't reply, nothing to wait for.
    pub fn callNoReply(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) void {
        _ = c.send(.{ .kind = 1, .flags = 1, .path = path, .iface = iface, .member = member, .dest = dest, .sig = sig }, body) catch {};
    }

    /// Async call: the reply comes later and is taken via result(serial).
    pub fn callAsync(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) Error!u32 {
        var slot: ?usize = null;
        for (c.waiting, 0..) |s, i| {
            if (s == 0 and c.done[i].serial == 0) slot = i;
        }
        const i = slot orelse return error.TooBig;
        const serial = try c.send(.{ .kind = 1, .path = path, .iface = iface, .member = member, .dest = dest, .sig = sig }, body);
        c.waiting[i] = serial;
        return serial;
    }

    /// Take the result of an async call (null — not here yet).
    pub fn result(c: *Conn, serial: u32) ?Done {
        for (&c.done) |*d| {
            if (d.serial == serial and serial != 0) {
                const r = d.*;
                d.* = .{};
                return r;
            }
        }
        return null;
    }

    /// Reply to an incoming call.
    pub fn reply(c: *Conn, m: *const Incoming, sig: []const u8, body: []const u8) void {
        if (m.flags & 1 != 0) return; // NO_REPLY_EXPECTED
        _ = c.send(.{ .kind = 2, .reply_serial = m.serial, .dest = m.sender, .sig = sig }, body) catch {};
    }

    pub fn replyError(c: *Conn, m: *const Incoming, name: []const u8, text: []const u8) void {
        if (m.flags & 1 != 0) return;
        var b: [256]u8 = undefined;
        var w = W{ .buf = &b };
        w.str(text);
        if (w.overflow) return;
        _ = c.send(.{ .kind = 3, .err_name = name, .reply_serial = m.serial, .dest = m.sender, .sig = "s" }, w.bytes()) catch {};
    }

    fn field(w: *W, code: u8, t: []const u8, val: []const u8) void {
        w.pad(8);
        w.byte(code);
        w.sig(t);
        w.str(val);
    }

    /// A handled message is just stepped over: a burst of signals is no longer shifted
    /// through the buffer once per message.
    fn drop(c: *Conn, n: usize) void {
        c.head += n;
        if (c.head == c.ilen) {
            c.head = 0;
            c.ilen = 0;
        }
    }

    /// Read what has arrived after the unhandled tail. The tail (an incomplete message, usually
    /// short or nothing) moves to the start of the buffer only now. Replies handed out earlier
    /// are already invalid by this point (see `consumed`).
    fn readMore(c: *Conn) Error!void {
        if (c.head > 0) {
            std.mem.copyForwards(u8, c.in[0 .. c.ilen - c.head], c.in[c.head..c.ilen]);
            c.ilen -= c.head;
            c.head = 0;
        }
        if (c.ilen == c.in.len) return error.TooBig;
        const k = sys.read(c.fd, c.in[c.ilen..]) catch return error.Io;
        if (k == 0) return error.Io;
        c.ilen += k;
    }

    /// Size of the first unhandled message (null — it hasn't fully arrived yet).
    fn complete(c: *Conn) Error!?usize {
        const d = c.in[c.head..c.ilen];
        if (d.len < 16) return null;
        if (d[0] != 'l') return error.Protocol; // big-endian is not supported
        const body_len = std.mem.readInt(u32, d[4..8], .little);
        const flen = std.mem.readInt(u32, d[12..16], .little);
        const hdr = (16 + @as(usize, flen) + 7) & ~@as(usize, 7);
        const total = hdr + @as(usize, body_len);
        if (total > c.in.len) return error.TooBig;
        if (d.len < total) return null;
        return total;
    }

    fn parse(c: *Conn, total: usize) Error!Msg {
        const msg = c.in[c.head..][0..total];
        const flen = std.mem.readInt(u32, msg[12..16], .little);
        const hdr = (16 + @as(usize, flen) + 7) & ~@as(usize, 7);
        var m = Msg{ .kind = msg[1], .flags = msg[2], .serial = std.mem.readInt(u32, msg[8..12], .little), .body = msg[hdr..total] };
        var r = R{ .d = msg[0 .. 16 + flen], .p = 16 };
        const eql = std.mem.eql;
        while (r.p < r.d.len and !r.bad) {
            r.alignTo(8);
            if (r.p >= r.d.len) break;
            const code = r.byte();
            const t = r.sig();
            if (code == 5 and eql(u8, t, "u")) {
                m.reply_serial = r.u32_();
            } else if (code == 4 and eql(u8, t, "s")) {
                m.err_name = r.str();
            } else if (code == 8 and eql(u8, t, "g")) {
                m.sig = r.sig();
            } else if (code == 1 and eql(u8, t, "o")) {
                m.path = r.str();
            } else if (code == 2 and eql(u8, t, "s")) {
                m.iface = r.str();
            } else if (code == 3 and eql(u8, t, "s")) {
                m.member = r.str();
            } else if (code == 7 and eql(u8, t, "s")) {
                m.sender = r.str();
            } else r.skip(t);
        }
        if (r.bad) return error.Protocol;
        return m;
    }

    /// Handle a message that isn't the reply to the current synchronous call.
    fn handle(c: *Conn, m: *const Msg) void {
        switch (m.kind) {
            2, 3 => {
                for (&c.waiting, 0..) |*s, i| {
                    if (s.* == 0 or s.* != m.reply_serial) continue;
                    var d = Done{ .serial = s.*, .ok = m.kind == 2 };
                    if (m.kind == 3) {
                        const name = if (m.err_name.len > 0) m.err_name else "error";
                        d.name_len = @min(name.len, d.name_buf.len);
                        @memcpy(d.name_buf[0..d.name_len], name[0..d.name_len]);
                        var text: []const u8 = name;
                        if (m.sig.len > 0 and m.sig[0] == 's') {
                            var r = R{ .d = m.body };
                            const t = r.str();
                            if (!r.bad) text = t;
                        }
                        d.msg_len = @min(text.len, d.msg_buf.len);
                        @memcpy(d.msg_buf[0..d.msg_len], text[0..d.msg_len]);
                    }
                    c.done[i] = d;
                    s.* = 0;
                    return;
                }
            },
            4 => if (c.on_signal) |cb| {
                if (c.peer_len > 0 and !std.mem.eql(u8, m.sender, c.peer())) return;
                cb(m.path, m.iface, m.member, m.sig, m.body);
            },
            1 => {
                const in = Incoming{ .serial = m.serial, .flags = m.flags, .sender = m.sender, .path = m.path, .iface = m.iface, .member = m.member, .sig = m.sig, .body = m.body };
                if (c.on_method) |cb| cb(c, &in) else c.replyError(&in, "org.freedesktop.DBus.Error.UnknownMethod", "no such method");
            },
            else => {},
        }
    }

    fn waitReply(c: *Conn, serial: u32) Error!Reply {
        // the previous reply is already handled — drop it, keep the rest (if any arrived)
        if (c.consumed > 0) {
            c.drop(c.consumed);
            c.consumed = 0;
        }
        while (true) {
            while (try c.complete()) |total| {
                const m = try c.parse(total);
                if ((m.kind == 2 or m.kind == 3) and m.reply_serial == serial) {
                    c.consumed = total;
                    return .{ .sig = m.sig, .body = m.body, .err_name = if (m.kind == 3) (if (m.err_name.len > 0) m.err_name else "error") else "" };
                }
                c.handle(&m);
                c.drop(total); // a foreign message is handled — drop it
            }
            try c.waitReadable(10000);
            try c.readMore();
        }
    }

    /// Read what has arrived (the socket is readable) and handle all complete messages:
    /// replies to async calls, signals, incoming calls.
    pub fn pump(c: *Conn) Error!void {
        if (c.consumed > 0) {
            c.drop(c.consumed);
            c.consumed = 0;
        }
        var pfd = [1]sys.PollFd{.{ .fd = c.fd, .events = sys.POLLIN }};
        if ((sys.poll(&pfd, 0) catch 0) > 0) try c.readMore();
        while (try c.complete()) |total| {
            const m = try c.parse(total);
            c.handle(&m);
            c.drop(total);
        }
    }
};
