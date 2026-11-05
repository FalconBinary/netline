// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Volume and mute of the default output over the PulseAudio native protocol, which
//! pipewire-pulse speaks too. No libpulse and no pactl/wpctl processes: one socket, and the server
//! tells us about changes, so nothing is polled.
//!
//! The server's data is parsed with bounds checks, and only the start of a packet is kept:
//! the fields used here come first, the long property lists after them are dropped unread.
//! Tests: zig build test

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");

pub const NORM: u32 = 0x10000; // PA_VOLUME_NORM: 100 %
const MAX_VOLUME: u32 = NORM; // the slider and the steps stop at 100 %: no software amplification
const SINK = "@DEFAULT_SINK@";
const NO_INDEX: u32 = 0xffffffff;
const VERSION: u32 = 32;
const MAX_CHANNELS = 32;

// pa_command_t
const CMD_ERROR: u32 = 0;
const CMD_REPLY: u32 = 2;
const CMD_AUTH: u32 = 8;
const CMD_SET_CLIENT_NAME: u32 = 9;
const CMD_GET_SINK_INFO: u32 = 21;
const CMD_SUBSCRIBE: u32 = 35;
const CMD_SET_SINK_VOLUME: u32 = 36;
const CMD_SET_SINK_MUTE: u32 = 39;
const CMD_SUBSCRIBE_EVENT: u32 = 66;

const MASK_SINK: u32 = 0x01; // PA_SUBSCRIPTION_MASK_SINK
const MASK_SERVER: u32 = 0x80; // the default sink changes with the server's settings
const FACILITY_MASK: u32 = 0x0f;
const FACILITY_SINK: u32 = 0;
const FACILITY_SERVER: u32 = 7;

const TAG_AUTH: u32 = 1;
const TAG_NAME: u32 = 2;
const TAG_SUBSCRIBE: u32 = 3;
const TAG_SET: u32 = 4; // changes: their replies say nothing, the event that follows does
const TAG_INFO: u32 = 5; // this and everything above: GET_SINK_INFO replies carry a fresh number

pub const Sink = struct {
    /// whether there is a default output at all
    present: bool = false,
    /// the loudest channel, 0..100 (a balance setting survives volume changes)
    percent: u8 = 0,
    muted: bool = false,
    channels: u8 = 0,
    volumes: [MAX_CHANNELS]u32 = @as([MAX_CHANNELS]u32, @splat(0)),
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,

    pub fn name(s: *const Sink) []const u8 {
        return s.name_buf[0..s.name_len];
    }
};

// ================================================================= writing

const Out = struct {
    buf: [512]u8 = undefined,
    n: usize = 20, // room for the packet descriptor

    fn raw(o: *Out, bytes: []const u8) void {
        if (o.n + bytes.len > o.buf.len) return;
        @memcpy(o.buf[o.n..][0..bytes.len], bytes);
        o.n += bytes.len;
    }
    fn be32(o: *Out, v: u32) void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        o.raw(&b);
    }
    fn u32_(o: *Out, v: u32) void {
        o.raw("L");
        o.be32(v);
    }
    fn str(o: *Out, s: []const u8) void {
        o.raw("t");
        o.raw(s);
        o.raw(&[_]u8{0});
    }
    fn boolean(o: *Out, v: bool) void {
        o.raw(if (v) "1" else "0");
    }
    fn arbitrary(o: *Out, bytes: []const u8) void {
        o.raw("x");
        o.be32(@intCast(bytes.len));
        o.raw(bytes);
    }
    /// The descriptor: payload length, channel -1 (a command), offset 0, no flags.
    fn packet(o: *Out) []const u8 {
        std.mem.writeInt(u32, o.buf[0..4], @intCast(o.n - 20), .big);
        std.mem.writeInt(u32, o.buf[4..8], 0xffffffff, .big);
        @memset(o.buf[8..20], 0);
        return o.buf[0..o.n];
    }
};

fn command(cmd: u32, tag: u32) Out {
    var o = Out{};
    o.u32_(cmd);
    o.u32_(tag);
    return o;
}

// ================================================================= reading

/// A tagged-field reader. Any bad field makes it `bad`, and from then on it returns zeros.
const In = struct {
    d: []const u8,
    p: usize = 0,
    bad: bool = false,

    fn tag(r: *In, t: u8) bool {
        if (r.bad or r.p >= r.d.len or r.d[r.p] != t) {
            r.bad = true;
            return false;
        }
        r.p += 1;
        return true;
    }
    fn be32(r: *In) u32 {
        if (r.bad or r.d.len - r.p < 4) {
            r.bad = true;
            return 0;
        }
        const v = std.mem.readInt(u32, r.d[r.p..][0..4], .big);
        r.p += 4;
        return v;
    }
    fn u32_(r: *In) u32 {
        return if (r.tag('L')) r.be32() else 0;
    }
    fn u8Field(r: *In) u8 {
        if (r.bad or r.p >= r.d.len) {
            r.bad = true;
            return 0;
        }
        const v = r.d[r.p];
        r.p += 1;
        return v;
    }
    fn str(r: *In) []const u8 {
        if (r.bad or r.p >= r.d.len) {
            r.bad = true;
            return "";
        }
        const t = r.d[r.p];
        r.p += 1;
        if (t == 'N') return ""; // a NULL string
        if (t != 't') {
            r.bad = true;
            return "";
        }
        const end = std.mem.indexOfScalarPos(u8, r.d, r.p, 0) orelse {
            r.bad = true;
            return "";
        };
        const s = r.d[r.p..end];
        r.p = end + 1;
        return s;
    }
    fn boolean(r: *In) bool {
        if (r.bad or r.p >= r.d.len) {
            r.bad = true;
            return false;
        }
        const t = r.d[r.p];
        r.p += 1;
        if (t != '0' and t != '1') r.bad = true;
        return t == '1';
    }
    fn skip(r: *In, n: usize) void {
        if (r.bad or r.d.len - r.p < n) {
            r.bad = true;
            return;
        }
        r.p += n;
    }
};

/// The start of a sink_info reply, after the command and tag fields.
pub fn parseSink(d: []const u8) ?Sink {
    var r = In{ .d = d };
    var s = Sink{ .present = true };
    _ = r.u32_(); // index
    _ = r.str(); // name
    const desc = r.str();
    if (r.tag('a')) r.skip(6); // sample spec: format, channels, rate
    if (r.tag('m')) r.skip(r.u8Field()); // channel map
    _ = r.u32_(); // owner module
    if (r.tag('v')) {
        const n = r.u8Field();
        if (n == 0 or n > MAX_CHANNELS) return null;
        s.channels = n;
        var top: u32 = 0;
        for (s.volumes[0..n]) |*v| {
            v.* = r.be32();
            top = @max(top, v.*);
        }
        s.percent = percentOf(top);
    }
    s.muted = r.boolean();
    if (r.bad) return null;
    s.name_len = @intCast(fitUtf8(desc, s.name_buf.len));
    @memcpy(s.name_buf[0..s.name_len], desc[0..s.name_len]);
    return s;
}

/// How many bytes of `s` fit in `max` without cutting a UTF-8 character in half.
fn fitUtf8(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var n = max;
    while (n > 0 and s[n] & 0xc0 == 0x80) n -= 1;
    return n;
}

fn percentOf(v: u32) u8 {
    const p = (@as(u64, v) * 100 + NORM / 2) / NORM;
    return @intCast(@min(p, 100));
}

/// New channel volumes for a percent: the loudest channel gets it, the others keep their ratio to it.
pub fn scaled(s: *const Sink, percent: u8, out: *[MAX_CHANNELS]u32) void {
    const target: u64 = @min(percent, 100) * @as(u64, MAX_VOLUME) / 100;
    var top: u32 = 0;
    for (s.volumes[0..s.channels]) |v| top = @max(top, v);
    for (s.volumes[0..s.channels], out[0..s.channels]) |v, *o| {
        o.* = if (top == 0) @intCast(target) else @intCast(target * v / top);
    }
}

// ================================================================= connection

// Separate global arrays, like the Wayland connection's: inside the struct they would make its
// default value kilobytes of the file. There is one connection per process.
var hdr_buf: [20]u8 = undefined;
var body_buf: [2048]u8 = undefined;

/// Everything after the handshake is one state machine fed by `onReadable`.
pub const Client = struct {
    fd: i32 = -1,
    sink: Sink = .{},
    /// a volume or mute change arrived since the first report (for the on-screen level)
    moved: bool = false,

    hdr: *[20]u8 = &hdr_buf,
    hdr_n: usize = 0,
    body: *[2048]u8 = &body_buf,
    body_n: usize = 0,
    body_len: usize = 0, // the whole payload, may be longer than `body`
    body_seen: usize = 0,
    next_tag: u32 = TAG_INFO,
    info_tag: u32 = 0, // the reply being waited for; 0 — none
    info_again: bool = false, // a change arrived during the wait: ask once more
    first_report: bool = true,

    /// Starts talking on a connected socket. The rest of the handshake follows the replies, one step
    /// at a time: pipewire-pulse fills in its view of the devices while it answers the client's name,
    /// and a question that overtakes that answer hears there are none.
    pub fn start(c: *Client, fd: i32) bool {
        c.* = .{ .fd = fd };
        var auth = command(CMD_AUTH, TAG_AUTH);
        auth.u32_(VERSION);
        // the socket's owner is what counts; pipewire-pulse ignores the cookie, PulseAudio checks the uid
        auth.arbitrary(&(@as([256]u8, @splat(0))));
        return c.send(auth.packet());
    }

    fn sendName(c: *Client) bool {
        var cn = command(CMD_SET_CLIENT_NAME, TAG_NAME);
        cn.raw("P"); // a property list of one: application.name, then the NULL string that ends it
        cn.str("application.name");
        cn.u32_(8);
        cn.arbitrary("netline\x00");
        cn.raw("N");
        return c.send(cn.packet());
    }

    fn subscribe(c: *Client) bool {
        var sub = command(CMD_SUBSCRIBE, TAG_SUBSCRIBE);
        sub.u32_(MASK_SINK | MASK_SERVER);
        return c.send(sub.packet()) and c.askInfo();
    }

    pub fn close(c: *Client) void {
        if (c.fd >= 0) sys.close(c.fd);
        c.* = .{};
    }

    /// Never blocks: if the server has stopped reading, the panel must not stop with it.
    fn send(c: *Client, data: []const u8) bool {
        sys.sendNoWait(c.fd, data) catch return false;
        return true;
    }

    fn askInfo(c: *Client) bool {
        c.next_tag +%= 1;
        if (c.next_tag < TAG_INFO) c.next_tag = TAG_INFO;
        c.info_tag = c.next_tag;
        c.info_again = false;
        var o = command(CMD_GET_SINK_INFO, c.info_tag);
        o.u32_(NO_INDEX);
        o.str(SINK);
        return c.send(o.packet());
    }

    pub fn setPercent(c: *Client, percent: u8) bool {
        if (c.sink.channels == 0) return false;
        var v: [MAX_CHANNELS]u32 = undefined;
        scaled(&c.sink, percent, &v);
        var o = command(CMD_SET_SINK_VOLUME, TAG_SET);
        o.u32_(NO_INDEX);
        o.str(SINK);
        o.raw("v");
        o.raw(&[_]u8{c.sink.channels});
        for (v[0..c.sink.channels]) |x| o.be32(x);
        return c.send(o.packet());
    }

    pub fn setMuted(c: *Client, muted: bool) bool {
        var o = command(CMD_SET_SINK_MUTE, TAG_SET);
        o.u32_(NO_INDEX);
        o.str(SINK);
        o.boolean(muted);
        return c.send(o.packet());
    }

    /// Read what has arrived. true — the sink's state changed; if the connection is gone, `fd` is -1.
    pub fn onReadable(c: *Client) bool {
        var buf: [4096]u8 = undefined;
        const n = sys.read(c.fd, &buf) catch |e| {
            if (e == error.WouldBlock or e == error.Interrupted) return false;
            return c.lost();
        };
        if (n == 0) return c.lost();
        return c.feed(buf[0..n]);
    }

    fn lost(c: *Client) bool {
        const had = c.sink.present;
        c.close();
        return had;
    }

    /// Splits the stream into packets. Separate from the socket to be testable.
    pub fn feed(c: *Client, bytes: []const u8) bool {
        var changed = false;
        var d = bytes;
        while (d.len > 0) {
            if (c.hdr_n < c.hdr.len) {
                const k = @min(c.hdr.len - c.hdr_n, d.len);
                @memcpy(c.hdr[c.hdr_n..][0..k], d[0..k]);
                c.hdr_n += k;
                d = d[k..];
                if (c.hdr_n < c.hdr.len) break;
                c.body_len = std.mem.readInt(u32, c.hdr[0..4], .big);
                c.body_n = 0;
                c.body_seen = 0;
                // a command is never this long: this is not the protocol we expect
                if (c.body_len > 16 * 1024 * 1024) return c.lost();
            }
            const k = @min(c.body_len - c.body_seen, d.len);
            const keep = @min(c.body.len - c.body_n, k);
            @memcpy(c.body[c.body_n..][0..keep], d[0..keep]);
            c.body_n += keep;
            c.body_seen += k;
            d = d[k..];
            if (c.body_seen == c.body_len) {
                c.hdr_n = 0;
                // audio streams and memory blocks have a channel; this client opens none
                if (std.mem.readInt(u32, c.hdr[4..8], .big) == 0xffffffff) {
                    if (c.onPacket(c.body[0..c.body_n])) changed = true;
                    if (c.fd == -1) return true;
                }
            }
        }
        return changed;
    }

    fn onPacket(c: *Client, p: []const u8) bool {
        var r = In{ .d = p };
        const cmd = r.u32_();
        const tag = r.u32_();
        if (r.bad) return false;
        switch (cmd) {
            CMD_REPLY, CMD_ERROR => {
                if (tag == TAG_AUTH or tag == TAG_NAME) {
                    const ok = cmd == CMD_REPLY and (if (tag == TAG_AUTH) c.sendName() else c.subscribe());
                    return if (ok) false else c.lost();
                }
                if (tag == 0 or tag != c.info_tag) return false;
                c.info_tag = 0;
                var changed = false;
                if (cmd == CMD_REPLY) {
                    if (parseSink(p[r.p..])) |s| changed = c.apply(s);
                } else changed = c.apply(.{}); // no default output right now
                if (c.info_again and !c.askInfo()) return c.lost();
                return changed;
            },
            CMD_SUBSCRIBE_EVENT => {
                const facility = r.u32_() & FACILITY_MASK;
                if (r.bad or (facility != FACILITY_SINK and facility != FACILITY_SERVER)) return false;
                // a burst of events (a slider being dragged) makes one request at a time
                if (c.info_tag != 0) c.info_again = true else if (!c.askInfo()) return c.lost();
                return false;
            },
            else => return false,
        }
    }

    fn apply(c: *Client, s: Sink) bool {
        const old = &c.sink;
        const same = s.present == old.present and s.percent == old.percent and s.muted == old.muted;
        if (!same and !c.first_report and s.present and old.present) c.moved = true;
        c.first_report = false;
        const name_same = std.mem.eql(u8, s.name(), old.name());
        c.sink = s;
        return !same or !name_same;
    }

    /// One volume-related request from the command line: waits for the state, up to `ms` in all.
    pub fn waitInfo(c: *Client, ms: u32) bool {
        const deadline = sys.monoMs() + ms;
        while (c.first_report) {
            if (c.fd < 0) return false;
            const now = sys.monoMs();
            if (now >= deadline) return false;
            var pfd = [1]sys.PollFd{.{ .fd = c.fd, .events = sys.POLLIN }};
            _ = sys.poll(&pfd, @intCast(deadline - now)) catch continue;
            if (pfd[0].revents != 0) _ = c.onReadable();
        }
        return c.sink.present;
    }
};

/// $XDG_RUNTIME_DIR/pulse/native — pipewire-pulse and PulseAudio alike.
pub fn socketPath(buf: []u8) ?[]const u8 {
    const rt = sys.getenv("XDG_RUNTIME_DIR") orelse return null;
    return sys.joinZ(buf, &.{ rt, "/pulse/native" });
}

// ================================================================= tests

const T = std.testing;

fn sinkInfo(buf: []u8, vols: []const u32, muted: bool, desc: []const u8) []const u8 {
    var o = Out{};
    o.u32_(3); // index
    o.str("alsa_output.pci");
    o.str(desc);
    o.raw("a");
    o.raw(&[_]u8{ 3, @intCast(vols.len), 0, 0, 0xbb, 0x80 });
    o.raw("m");
    o.raw(&[_]u8{@intCast(vols.len)});
    for (vols) |_| o.raw(&[_]u8{1});
    o.u32_(NO_INDEX);
    o.raw("v");
    o.raw(&[_]u8{@intCast(vols.len)});
    for (vols) |v| o.be32(v);
    o.boolean(muted);
    o.u32_(NO_INDEX); // what follows is ignored
    o.str("alsa_output.pci.monitor");
    const n = o.n - 20;
    @memcpy(buf[0..n], o.buf[20..o.n]);
    return buf[0..n];
}

test "parses the fields of a sink" {
    var b: [512]u8 = undefined;
    const s = parseSink(sinkInfo(&b, &.{ NORM / 2, NORM / 4 }, true, "Built-in Audio")).?;
    try T.expect(s.present and s.muted);
    try T.expectEqual(@as(u8, 50), s.percent);
    try T.expectEqual(@as(u8, 2), s.channels);
    try T.expectEqualStrings("Built-in Audio", s.name());
}

test "a NULL description is an empty name" {
    var o = Out{};
    o.u32_(3);
    o.str("x");
    o.raw("N");
    o.raw("a");
    o.raw(&[_]u8{ 3, 1, 0, 0, 0xbb, 0x80 });
    o.raw("m");
    o.raw(&[_]u8{ 1, 1 });
    o.u32_(0);
    o.raw("v");
    o.raw(&[_]u8{1});
    o.be32(NORM);
    o.boolean(false);
    const s = parseSink(o.buf[20..o.n]).?;
    try T.expectEqual(@as(u8, 100), s.percent);
    try T.expectEqualStrings("", s.name());
}

test "a long UTF-8 name is cut between characters" {
    var long: [200]u8 = undefined;
    var i: usize = 0;
    while (i + 1 < long.len) : (i += 2) {
        long[i] = 0xd0;
        long[i + 1] = 0xb7;
    }
    try T.expectEqual(@as(usize, 64), fitUtf8(&long, 64));
    try T.expectEqual(@as(usize, 62), fitUtf8(&long, 63));
}

test "volume above 100 percent shows as 100" {
    var b: [512]u8 = undefined;
    const s = parseSink(sinkInfo(&b, &.{NORM * 2}, false, "x")).?;
    try T.expectEqual(@as(u8, 100), s.percent);
}

test "scaling keeps the balance between channels" {
    var s = Sink{ .channels = 2 };
    s.volumes[0] = NORM;
    s.volumes[1] = NORM / 2;
    var out: [MAX_CHANNELS]u32 = undefined;
    scaled(&s, 50, &out);
    try T.expectEqual(NORM / 2, out[0]);
    try T.expectEqual(NORM / 4, out[1]);
    scaled(&s, 200, &out); // never amplifies
    try T.expectEqual(NORM, out[0]);
}

test "scaling up from silence does not divide by zero" {
    const s = Sink{ .channels = 2 };
    var out: [MAX_CHANNELS]u32 = undefined;
    scaled(&s, 30, &out);
    try T.expectEqual(@as(u32, 30 * @as(u64, NORM) / 100), out[0]);
    try T.expectEqual(out[0], out[1]);
}

test "broken and truncated packets are refused, never read past the end" {
    var b: [512]u8 = undefined;
    const good = sinkInfo(&b, &.{ NORM, NORM }, false, "Name");
    var n: usize = 0;
    while (n < good.len) : (n += 1) {
        const s = parseSink(good[0..n]);
        // a cut in the ignored tail still has every needed field
        if (s != null) try T.expect(n >= good.len - 30);
    }
    var bad: [512]u8 = undefined;
    @memcpy(bad[0..good.len], good);
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();
    for (0..20000) |_| {
        const pos = random.uintLessThan(usize, good.len);
        const saved = bad[pos];
        bad[pos] = random.int(u8);
        if (parseSink(bad[0..good.len])) |s| {
            try T.expect(s.percent <= 100 and s.channels <= MAX_CHANNELS and s.name_len <= s.name_buf.len);
        }
        bad[pos] = saved;
    }
}

fn fakePacket(buf: []u8, o: *Out, channel: u32) []const u8 {
    const p = o.packet();
    @memcpy(buf[0..p.len], p);
    std.mem.writeInt(u32, buf[4..8], channel, .big);
    return buf[0..p.len];
}

fn reply(buf: []u8, tag: u32, payload: []const u8) []const u8 {
    var o = command(CMD_REPLY, tag);
    o.raw(payload);
    return fakePacket(buf, &o, 0xffffffff);
}

test "a stream split at any byte gives the same result" {
    var b: [512]u8 = undefined;
    const info = sinkInfo(&b, &.{NORM / 2}, false, "Speakers");
    var pb: [600]u8 = undefined;
    const pkt = reply(&pb, 7, info);
    var cut: usize = 1;
    while (cut < pkt.len) : (cut += 1) {
        var c = Client{};
        c.info_tag = 7;
        c.fd = -2; // not -1: the connection counts as open and nothing is written while parsing
        _ = c.feed(pkt[0..cut]);
        try T.expect(!c.sink.present);
        try T.expect(c.feed(pkt[cut..]));
        try T.expectEqual(@as(u8, 50), c.sink.percent);
        try T.expectEqualStrings("Speakers", c.sink.name());
    }
}

test "only the first bytes of a long packet are kept, the rest is skipped" {
    var b: [512]u8 = undefined;
    const info = sinkInfo(&b, &.{NORM}, false, "Speakers");
    var c = Client{};
    c.info_tag = 5;
    c.fd = -2;
    var head: [64]u8 = undefined;
    var o = command(CMD_REPLY, 5);
    const prefix = o.buf[20..o.n];
    const total = prefix.len + info.len + 100000;
    std.mem.writeInt(u32, head[0..4], @intCast(total), .big);
    std.mem.writeInt(u32, head[4..8], 0xffffffff, .big);
    @memset(head[8..20], 0);
    _ = c.feed(head[0..20]);
    _ = c.feed(prefix);
    _ = c.feed(info);
    const junk = @as([4096]u8, @splat(0xaa));
    var left: usize = 100000;
    while (left > 0) {
        const k = @min(left, junk.len);
        _ = c.feed(junk[0..k]);
        left -= k;
    }
    try T.expect(c.sink.present);
    try T.expectEqual(@as(u8, 100), c.sink.percent);
    // the stream stays in step: the next packet is read normally
    c.info_tag = 6;
    var pb: [600]u8 = undefined;
    var b2: [512]u8 = undefined;
    _ = c.feed(reply(&pb, 6, sinkInfo(&b2, &.{NORM / 4}, true, "Speakers")));
    try T.expectEqual(@as(u8, 25), c.sink.percent);
}

test "an absurd packet length drops the connection" {
    var head = @as([20]u8, @splat(0));
    std.mem.writeInt(u32, head[0..4], 0x7fffffff, .big);
    var c = Client{};
    c.fd = -1; // close() does nothing with -1
    _ = c.feed(&head);
    try T.expectEqual(@as(i32, -1), c.fd);
    try T.expectEqual(@as(usize, 0), c.hdr_n);
}

test "only a real change after the first report counts as moved" {
    var b: [512]u8 = undefined;
    var c = Client{};
    c.fd = -2;
    var pb: [600]u8 = undefined;
    c.info_tag = 5;
    _ = c.feed(reply(&pb, 5, sinkInfo(&b, &.{NORM / 2}, false, "S")));
    try T.expect(!c.moved);
    c.info_tag = 6;
    _ = c.feed(reply(&pb, 6, sinkInfo(&b, &.{NORM / 2}, false, "S")));
    try T.expect(!c.moved);
    c.info_tag = 7;
    _ = c.feed(reply(&pb, 7, sinkInfo(&b, &.{NORM / 2}, true, "S")));
    try T.expect(c.moved);
}

test "the reply to a different request is ignored" {
    var b: [512]u8 = undefined;
    var c = Client{};
    c.fd = -2;
    c.info_tag = 9;
    var pb: [600]u8 = undefined;
    try T.expect(!c.feed(reply(&pb, TAG_SET, sinkInfo(&b, &.{NORM}, false, "S"))));
    try T.expect(!c.sink.present);
}

test "an error reply means no output" {
    var c = Client{};
    c.fd = -2;
    c.sink.present = true;
    c.first_report = false;
    c.info_tag = 4;
    var o = command(CMD_ERROR, 4);
    o.u32_(5);
    var pb: [64]u8 = undefined;
    try T.expect(c.feed(fakePacket(&pb, &o, 0xffffffff)));
    try T.expect(!c.sink.present);
}

test "each step of the handshake waits for the previous reply" {
    const pair = try sys.socketpair();
    defer sys.close(pair[1]);
    var c = Client{};
    try T.expect(c.start(pair[0]));
    defer c.close();

    const sent = struct {
        fn cmd(fd: i32) !?u32 {
            var pfd = [1]sys.PollFd{.{ .fd = fd, .events = sys.POLLIN }};
            if (try sys.poll(&pfd, 0) == 0) return null;
            var b: [600]u8 = undefined;
            const n = try sys.read(fd, &b);
            var r = In{ .d = b[20..n] };
            return r.u32_();
        }
    }.cmd;

    try T.expectEqual(@as(?u32, CMD_AUTH), try sent(pair[1]));
    try T.expectEqual(@as(?u32, null), try sent(pair[1]));

    var pb: [64]u8 = undefined;
    var version: [5]u8 = .{ 'L', 0, 0, 0, 35 };
    _ = c.feed(reply(&pb, TAG_AUTH, &version));
    try T.expectEqual(@as(?u32, CMD_SET_CLIENT_NAME), try sent(pair[1]));
    try T.expectEqual(@as(?u32, null), try sent(pair[1]));

    _ = c.feed(reply(&pb, TAG_NAME, &version));
    try T.expectEqual(@as(?u32, CMD_SUBSCRIBE), try sent(pair[1]));
    try T.expectEqual(@as(?u32, CMD_GET_SINK_INFO), try sent(pair[1]));
}

test "a refused handshake ends the connection" {
    const pair = try sys.socketpair();
    defer sys.close(pair[1]);
    var c = Client{};
    try T.expect(c.start(pair[0]));
    var o = command(CMD_ERROR, TAG_AUTH);
    o.u32_(1);
    var pb: [64]u8 = undefined;
    _ = c.feed(fakePacket(&pb, &o, 0xffffffff));
    try T.expectEqual(@as(i32, -1), c.fd);
}

test "a packet on a data channel is not treated as a command" {
    var b: [512]u8 = undefined;
    var c = Client{};
    c.fd = -2;
    c.info_tag = 5;
    var pb: [600]u8 = undefined;
    const p = reply(&pb, 5, sinkInfo(&b, &.{NORM}, false, "S"));
    std.mem.writeInt(u32, pb[4..8], 3, .big);
    try T.expect(!c.feed(p));
    try T.expect(!c.sink.present);
}
