// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Wi‑Fi, Bluetooth, battery and backlight state straight from the kernel (sysfs/procfs/ioctl), without
//! NetworkManager/BlueZ/D-Bus/UPower. Updates arrive as netlink events, so the panel does not poll the system for nothing.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const cfg = @import("config.zig");

/// Empty in a normal build: a -Dtest_root=DIR build reads the battery and backlight below DIR.
pub const root: [:0]const u8 = @import("build_options").test_root;
pub const power_dir = root ++ "/sys/class/power_supply";
pub const light_dir = root ++ "/sys/class/backlight";

pub const WifiState = enum(u8) { none, off, disconnected, connected };
pub const Wifi = struct { state: WifiState = .none, level: u8 = 0 }; // level 1..3

pub const Bt = enum(u8) { none, off, on, connected };

/// Event sockets (or -1): network interface changes, device uevents
/// and Bluetooth management events (adapter power on/off).
pub var route_fd: i32 = -1;
pub var uevent_fd: i32 = -1;
pub var mgmt_fd: i32 = -1;
var hci_sock: i32 = -1;

/// Open everything needed up front — sockets cannot be created once the sandbox is on.
/// BPF filters are attached to the sockets: the kernel wakes the panel only for events that change
/// the icons, not for every percent of battery charge, USB device or Wi‑Fi scan.
pub fn init() void {
    route_fd = sys.netlink(0, 1) catch -1; // NETLINK_ROUTE, RTMGRP_LINK
    if (route_fd >= 0) sys.attachFilter(route_fd, &route_filter) catch {};
    uevent_fd = openUevents();
    hci_sock = sys.socket(31, 3, 1) catch -1; // AF_BLUETOOTH, SOCK_RAW, BTPROTO_HCI
    mgmt_fd = openMgmt();
    if (comptime cfg.hasItem(.wifi)) openNl80211();
}

// ---------------------------------------------------------------- filters

const LD_W_ABS: u16 = 0x20;
const LD_B_ABS: u16 = 0x30;
const LD_B_IND: u16 = 0x50;
const LD_LEN: u16 = 0x80;
const ADD: u16 = 0x04;
const SUB: u16 = 0x14;
const AND: u16 = 0x54;
const TAX: u16 = 0x07;
const TXA: u16 = 0x87;
const JEQ: u16 = 0x15;
const JGE_X: u16 = 0x3d;
const RET: u16 = 0x06;
const KEEP: u32 = 0xffffffff;

// Numbers in netlink are in CPU byte order: where the low and high bytes of a u16 are.
const lo: u32 = if (builtin.cpu.arch.endian() == .little) 0 else 1;
const hi: u32 = 1 - lo;

/// RTM_NEWLINK with the IFLA_WIRELESS attribute — wireless events (end of a scan etc.,
/// NetworkManager scans every few minutes). They don't change the icon: connecting and
/// disconnecting arrive as a separate RTM_NEWLINK about the interface state.
/// Such an event has the attributes IFLA_IFNAME followed directly by IFLA_WIRELESS; the filter checks the type
/// of the second attribute. (The in-kernel attribute lookup, SKF_AD_NLATTR, doesn't work on rtnetlink broadcasts.)
/// Short messages are left alone: reading past the end in BPF means "drop".
const route_filter = [_]sys.SockFilter{
    .{ .code = LD_B_ABS, .k = 32 + hi }, // 0: high byte of the first attribute's length (IFNAME is shorter than 256)
    .{ .code = JEQ, .k = 0, .jt = 0, .jf = 15 }, // 1: otherwise — pass
    .{ .code = LD_B_ABS, .k = 32 + lo }, // 2: length of the first attribute
    .{ .code = ADD, .k = 3 }, // 3–4: aligned to 4
    .{ .code = AND, .k = 0xfc },
    .{ .code = ADD, .k = 32 + 4 }, // 5: end of the second attribute's header
    .{ .code = TAX, .k = 0 }, // 6
    .{ .code = LD_LEN, .k = 0 }, // 7
    .{ .code = JGE_X, .k = 0, .jt = 0, .jf = 8 }, // 8: message is shorter — pass
    .{ .code = TXA, .k = 0 }, // 9
    .{ .code = SUB, .k = 4 }, // 10
    .{ .code = TAX, .k = 0 }, // 11: X — start of the second attribute
    .{ .code = LD_B_IND, .k = 2 + lo }, // 12: type, low byte
    .{ .code = JEQ, .k = 11, .jt = 0, .jf = 3 }, // 13: IFLA_WIRELESS?
    .{ .code = LD_B_IND, .k = 2 + hi }, // 14: high byte (without NLA_F_* flags)
    .{ .code = AND, .k = 0x3f },
    .{ .code = JEQ, .k = 0, .jt = 1, .jf = 0 }, // 16: yes — drop
    .{ .code = RET, .k = KEEP }, // 17
    .{ .code = RET, .k = 0 }, // 18
};

/// MurmurHash2 — udevd signs the subsystem in the broadcast header with it (as in libudev).
fn murmur2(comptime s: []const u8) u32 {
    const m: u32 = 0x5bd1e995;
    var h: u32 = @as(u32, s.len);
    var i: usize = 0;
    while (s.len - i >= 4) : (i += 4) {
        var k = std.mem.readInt(u32, s[i..][0..4], builtin.cpu.arch.endian());
        k *%= m;
        k ^= k >> 24;
        k *%= m;
        h *%= m;
        h ^= k;
    }
    const rest = s.len - i;
    if (rest == 3) h ^= @as(u32, s[i + 2]) << 16;
    if (rest >= 2) h ^= @as(u32, s[i + 1]) << 8;
    if (rest >= 1) {
        h ^= s[i];
        h *%= m;
    }
    h ^= h >> 13;
    h *%= m;
    h ^= h >> 15;
    return h;
}

/// The subsystems whose events change something on the panel: with no battery item in the
/// config, power_supply events don't wake it at all.
const watched = blk: {
    var w: []const []const u8 = &.{ "rfkill", "bluetooth" };
    if (cfg.hasItem(.battery)) w = w ++ &[_][]const u8{"power_supply"};
    if (cfg.hasItem(.brightness)) w = w ++ &[_][]const u8{"backlight"};
    break :blk w;
};

/// A udevd broadcast: "libudev\0", magic 0xfeedcafe (offset 8), subsystem hash (24) —
/// all in network byte order, which is how BPF reads it. Only the watched subsystems pass.
const udev_filter = blk: {
    const n = watched.len;
    var f: [n + 5]sys.SockFilter = undefined;
    f[0] = .{ .code = LD_W_ABS, .k = 8 };
    f[1] = .{ .code = JEQ, .k = 0xfeedcafe, .jt = 0, .jf = n + 1 };
    f[2] = .{ .code = LD_W_ABS, .k = 24 };
    for (watched, 0..) |s, i| f[3 + i] = .{ .code = JEQ, .k = murmur2(s), .jt = n - i, .jf = 0 };
    f[3 + n] = .{ .code = RET, .k = 0 };
    f[4 + n] = .{ .code = RET, .k = KEEP };
    break :blk f;
};

/// Device events. If udevd is running — its broadcast (group 2) filtered by
/// subsystem right in the kernel. Without udevd — all kernel events (group 1), parsed by drainEvents.
fn openUevents() i32 {
    if (sys.pathExists("/run/udev/control")) {
        if (sys.netlink(15, 2)) |fd| {
            if (sys.attachFilter(fd, &udev_filter)) |_| return fd else |_| sys.close(fd);
        } else |_| {}
    }
    return sys.netlink(15, 1) catch -1; // NETLINK_KOBJECT_UEVENT, kernel events
}

/// Bluetooth management channel (mgmt): a New Settings event arrives when the adapter is
/// powered on and off — without it this would have to be polled. No root needed:
/// an unprivileged socket receives settings events but cannot change anything.
fn openMgmt() i32 {
    const fd = sys.socket(31, 3 | sys.O_NONBLOCK, 1) catch return -1; // AF_BLUETOOTH, SOCK_RAW, BTPROTO_HCI
    // struct sockaddr_hci { u16 family; u16 dev = HCI_DEV_NONE; u16 channel = HCI_CHANNEL_CONTROL; }
    const addr = [6]u8{ 31, 0, 0xff, 0xff, 3, 0 };
    sys.bindRaw(fd, &addr) catch {
        sys.close(fd);
        return -1;
    };
    return fd;
}

/// Whether Bluetooth power events are available (otherwise adapter power is learned by polling).
pub fn btEvents() bool {
    return mgmt_fd >= 0;
}

/// Whether interface and rfkill changes arrive as events (otherwise the whole state is polled).
pub fn events() bool {
    return route_fd >= 0 and uevent_fd >= 0;
}

/// Drain mgmt events. true — something changed with the adapters (power, added, removed)
/// or the channel is gone (then power is learned by polling again).
pub fn drainMgmt() bool {
    var buf: [512]u8 = undefined;
    var any = false;
    while (true) {
        const n = sys.read(mgmt_fd, &buf) catch |e| {
            if (e == error.WouldBlock) return any;
            break;
        };
        if (n == 0) break;
        any = true;
    }
    // error or end of stream: close it, otherwise poll would wake the panel endlessly
    sys.close(mgmt_fd);
    mgmt_fd = -1;
    return true;
}

pub const Changed = struct { wifi: bool = false, bt: bool = false, power: bool = false, light: bool = false };

/// Drain all events from the ready sockets and report what needs rereading.
pub fn drainEvents(route_ready: bool, uevent_ready: bool) Changed {
    var ch = Changed{};
    var buf: [8192]u8 align(4) = undefined;
    if (route_ready) {
        while (true) {
            const n = sys.read(route_fd, &buf) catch |e| {
                if (e == error.WouldBlock) break;
                ch.wifi = true; // ENOBUFS and the like — reread just in case
                break;
            };
            if (n == 0) break;
            ch.wifi = true;
        }
    }
    if (uevent_ready) {
        while (true) {
            const n = sys.read(uevent_fd, &buf) catch |e| {
                if (e != error.WouldBlock) {
                    ch.wifi = true;
                    ch.bt = true;
                    ch.power = true;
                    ch.light = true;
                }
                break;
            };
            if (n == 0) break;
            // "ACTION@DEVPATH\0KEY=VALUE\0..." — only the subsystem is needed
            var it = std.mem.splitScalar(u8, buf[0..n], 0);
            while (it.next()) |kv| {
                if (std.mem.eql(u8, kv, "SUBSYSTEM=bluetooth")) ch.bt = true;
                if (std.mem.eql(u8, kv, "SUBSYSTEM=power_supply")) ch.power = true;
                if (std.mem.eql(u8, kv, "SUBSYSTEM=backlight")) ch.light = true;
                if (std.mem.eql(u8, kv, "SUBSYSTEM=rfkill")) {
                    ch.bt = true;
                    ch.wifi = true;
                }
            }
        }
    }
    return ch;
}

var iface_buf: [32]u8 = undefined;
var iface_len: usize = 0;

fn iface() []const u8 {
    return iface_buf[0..iface_len];
}

fn findWireless() bool {
    var path: [256]u8 = undefined;
    if (iface_len > 0 and sys.exists(sys.joinZ(&path, &.{ "/sys/class/net/", iface(), "/phy80211" }))) return true;
    iface_len = 0;
    var dir = sys.Dir.open("/sys/class/net") orelse return false;
    defer dir.deinit();
    while (dir.next()) |name| {
        if (name.len > iface_buf.len) continue;
        if (sys.exists(sys.joinZ(&path, &.{ "/sys/class/net/", name, "/phy80211" })) or
            sys.exists(sys.joinZ(&path, &.{ "/sys/class/net/", name, "/wireless" })))
        {
            @memcpy(iface_buf[0..name.len], name);
            iface_len = name.len;
            return true;
        }
    }
    return false;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// true/false — whether rfkill of this type ("wlan", "bluetooth") is blocked; null — no devices.
fn rfkillBlocked(kind: []const u8) ?bool {
    var dir = sys.Dir.open("/sys/class/rfkill") orelse return null;
    defer dir.deinit();
    var path: [256]u8 = undefined;
    var buf: [32]u8 = undefined;
    var found = false;
    while (dir.next()) |name| {
        const t = sys.readFile(sys.joinZ(&path, &.{ "/sys/class/rfkill/", name, "/type" }), &buf) orelse continue;
        if (!std.mem.eql(u8, trim(t), kind)) continue;
        found = true;
        const soft = sys.readFile(sys.joinZ(&path, &.{ "/sys/class/rfkill/", name, "/soft" }), &buf) orelse continue;
        if (std.mem.eql(u8, trim(soft), "1")) return true;
        const hard = sys.readFile(sys.joinZ(&path, &.{ "/sys/class/rfkill/", name, "/hard" }), &buf) orelse continue;
        if (std.mem.eql(u8, trim(hard), "1")) return true;
    }
    return if (found) false else null;
}

pub fn wifi() Wifi {
    if (!findWireless()) return .{};
    var path: [256]u8 = undefined;
    var buf: [64]u8 = undefined;

    if (rfkillBlocked("wlan") orelse false) return .{ .state = .off };

    // IFF_UP in /sys/class/net/<if>/flags
    const flags_s = sys.readFile(sys.joinZ(&path, &.{ "/sys/class/net/", iface(), "/flags" }), &buf) orelse return .{ .state = .off };
    const flags_t = trim(flags_s);
    const flags = std.fmt.parseInt(u32, if (std.mem.startsWith(u8, flags_t, "0x")) flags_t[2..] else flags_t, 16) catch 0;
    if (flags & 1 == 0) return .{ .state = .off };

    const oper = sys.readFile(sys.joinZ(&path, &.{ "/sys/class/net/", iface(), "/operstate" }), &buf) orelse return .{ .state = .disconnected };
    if (!std.mem.eql(u8, trim(oper), "up")) return .{ .state = .disconnected };

    return .{ .state = .connected, .level = signalLevel() };
}

/// Signal level 1..3: from nl80211, or where that is missing from link quality in
/// /proc/net/wireless (usually out of 70).
pub fn signalLevel() u8 {
    if (nl80211Signal()) |dbm| return levelOf(dbm);
    var buf: [2048]u8 = undefined;
    const d = sys.readFile("/proc/net/wireless", &buf) orelse return 3;
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |line| {
        const l = trim(line);
        if (l.len <= iface_len or !std.mem.startsWith(u8, l, iface()) or l[iface_len] != ':') continue;
        var it = std.mem.tokenizeAny(u8, l[iface_len + 1 ..], " \t");
        _ = it.next(); // status
        const q = it.next() orelse return 3;
        const qn = std.fmt.parseInt(u32, std.mem.trim(u8, q, "."), 10) catch return 3;
        const pct = @as(u64, qn) * 100 / 70;
        return if (pct >= 60) 3 else if (pct >= 30) 2 else 1;
    }
    return 3;
}

/// Link quality as /proc/net/wireless shows it, from the signal in dBm (cfg80211: dBm + 110,
/// out of 70), so either way the bars mean the same.
fn levelOf(dbm: i8) u8 {
    const quality: u64 = @intCast(std.math.clamp(@as(i32, dbm) + 110, 0, 70));
    const pct = quality * 100 / 70;
    return if (pct >= 60) 3 else if (pct >= 30) 2 else 1;
}

// ---------------------------------------------------------------- nl80211

// The signal of the access point, asked of nl80211 over generic netlink once a minute, when
// the clock wakes the panel anyway. /proc/net/wireless goes through wireless extensions,
// which the kernel warns about in its log ("uses wireless extensions which will stop working
// for Wi-Fi 7 hardware") and which new drivers no longer have.

var genl_fd: i32 = -1;
var nl80211_id: u16 = 0;
var genl_seq: u32 = 0;

const NLMSG_ERROR = 2;
const NLMSG_DONE = 3;
const NLM_F_REQUEST = 1;
const NLM_F_DUMP = 0x300;
const GENL_ID_CTRL = 0x10;
const CTRL_CMD_GETFAMILY = 3;
const CTRL_ATTR_FAMILY_ID = 1;
const CTRL_ATTR_FAMILY_NAME = 2;
const NL80211_CMD_GET_STATION = 17;
const NL80211_ATTR_IFINDEX = 3;
const NL80211_ATTR_STA_INFO = 21;
const NL80211_STA_INFO_SIGNAL = 7;
const NL80211_STA_INFO_SIGNAL_AVG = 13;

/// The socket and nl80211's family number, before the sandbox: it allows no new sockets.
fn openNl80211() void {
    const fd = sys.netlink(16, 0) catch return; // NETLINK_GENERIC
    var msg: [32]u8 = undefined;
    genl_seq +%= 1;
    var reply: [4096]u8 = undefined;
    const n = ask(fd, familyRequest(&msg, genl_seq), &reply) orelse {
        sys.close(fd);
        return;
    };
    nl80211_id = familyId(reply[0..n]) orelse {
        sys.close(fd);
        return;
    };
    genl_fd = fd;
}

/// One request and its answer. The kernel answers before send returns, so the socket stays
/// non-blocking; what is left of a dump is read away, so the next answer starts clean.
fn ask(fd: i32, request: []const u8, reply: []u8) ?usize {
    drain(fd);
    sys.sendAll(fd, request) catch return null;
    const n = sys.read(fd, reply) catch return null;
    drain(fd);
    return n;
}

fn drain(fd: i32) void {
    var spare: [4096]u8 = undefined;
    while (sys.read(fd, &spare)) |got| {
        if (got == 0) break;
    } else |_| {}
}

fn nl80211Signal() ?i8 {
    if (genl_fd < 0 or iface_len == 0) return null;
    var path: [96]u8 = undefined;
    var buf: [16]u8 = undefined;
    const text = sys.readFile(sys.joinZ(&path, &.{ "/sys/class/net/", iface(), "/ifindex" }), &buf) orelse return null;
    const ifindex = std.fmt.parseInt(u32, trim(text), 10) catch return null;
    var msg: [32]u8 = undefined;
    var reply: [4096]u8 = undefined;
    genl_seq +%= 1;
    const n = ask(genl_fd, stationRequest(&msg, nl80211_id, genl_seq, ifindex), &reply) orelse return null;
    return stationSignal(reply[0..n]);
}

fn put16(b: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], v, .little);
}

fn put32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

/// A netlink header, a generic netlink header and one attribute.
fn genlRequest(buf: []u8, family: u16, flags: u16, seq: u32, cmd: u8, version: u8, attr: u16, value: []const u8) []const u8 {
    const attr_len = 4 + value.len;
    const total = 20 + ((attr_len + 3) & ~@as(usize, 3));
    @memset(buf[0..total], 0);
    put32(buf, 0, @intCast(total));
    put16(buf, 4, family);
    put16(buf, 6, flags);
    put32(buf, 8, seq);
    buf[16] = cmd;
    buf[17] = version;
    put16(buf, 20, @intCast(attr_len));
    put16(buf, 22, attr);
    @memcpy(buf[24..][0..value.len], value);
    return buf[0..total];
}

fn familyRequest(buf: []u8, seq: u32) []const u8 {
    return genlRequest(buf, GENL_ID_CTRL, NLM_F_REQUEST, seq, CTRL_CMD_GETFAMILY, 1, CTRL_ATTR_FAMILY_NAME, "nl80211\x00");
}

/// The stations of one interface: on a client, the access point it is connected to.
fn stationRequest(buf: []u8, family: u16, seq: u32, ifindex: u32) []const u8 {
    var index: [4]u8 = undefined;
    std.mem.writeInt(u32, &index, ifindex, .little);
    return genlRequest(buf, family, NLM_F_REQUEST | NLM_F_DUMP, seq, NL80211_CMD_GET_STATION, 0, NL80211_ATTR_IFINDEX, &index);
}

const Attr = struct { kind: u16, value: []const u8 };

/// netlink attributes, one after the other, each padded to four bytes.
const Attrs = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *Attrs) ?Attr {
        if (self.pos + 4 > self.data.len) return null;
        const len = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        const kind = std.mem.readInt(u16, self.data[self.pos + 2 ..][0..2], .little) & 0x3fff;
        if (len < 4 or self.pos + len > self.data.len) return null;
        const value = self.data[self.pos + 4 .. self.pos + len];
        self.pos += (len + 3) & ~@as(usize, 3);
        return .{ .kind = kind, .value = value };
    }
};

/// The messages of a reply: the type of each and its attributes, after the generic netlink header.
const Messages = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *Messages) ?struct { kind: u16, attrs: Attrs } {
        if (self.pos + 20 > self.data.len) return null;
        const len = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        const kind = std.mem.readInt(u16, self.data[self.pos + 4 ..][0..2], .little);
        if (len < 16 or self.pos + len > self.data.len) return null;
        const body = self.data[self.pos + @min(len, 20) .. self.pos + len];
        self.pos += (len + 3) & ~@as(u32, 3);
        return .{ .kind = kind, .attrs = .{ .data = body } };
    }
};

fn familyId(reply: []const u8) ?u16 {
    var msgs = Messages{ .data = reply };
    while (msgs.next()) |m| {
        if (m.kind == NLMSG_ERROR or m.kind == NLMSG_DONE) return null;
        var attrs = m.attrs;
        while (attrs.next()) |a| {
            if (a.kind == CTRL_ATTR_FAMILY_ID and a.value.len >= 2) return std.mem.readInt(u16, a.value[0..2], .little);
        }
    }
    return null;
}

/// The signal in dBm, the driver's average where it keeps one.
fn stationSignal(reply: []const u8) ?i8 {
    var msgs = Messages{ .data = reply };
    while (msgs.next()) |m| {
        if (m.kind == NLMSG_ERROR or m.kind == NLMSG_DONE) return null;
        var attrs = m.attrs;
        while (attrs.next()) |a| {
            if (a.kind != NL80211_ATTR_STA_INFO) continue;
            var info = Attrs{ .data = a.value };
            var signal: ?i8 = null;
            while (info.next()) |i| {
                if (i.value.len < 1) continue;
                if (i.kind == NL80211_STA_INFO_SIGNAL_AVG) return @bitCast(i.value[0]);
                if (i.kind == NL80211_STA_INFO_SIGNAL) signal = @bitCast(i.value[0]);
            }
            if (signal) |dbm| return dbm;
        }
    }
    return null;
}

pub fn bluetooth() Bt {
    var dir = sys.Dir.open("/sys/class/bluetooth") orelse return .none;
    defer dir.deinit();
    var dev: ?u16 = null;
    var conns: u32 = 0;
    while (dir.next()) |name| {
        if (!std.mem.startsWith(u8, name, "hci")) continue;
        if (std.mem.indexOfScalar(u8, name, ':')) |_| {
            conns += 1; // hciN:<handle> — an active connection
        } else if (dev == null) {
            dev = std.fmt.parseInt(u16, name[3..], 10) catch null;
        }
    }
    const id = dev orelse return .none;
    const powered = hciUp(id) orelse !(rfkillBlocked("bluetooth") orelse false);
    if (!powered) return .off;
    return if (conns > 0) .connected else .on;
}

/// The HCI_UP flag via ioctl(HCIGETDEVINFO) — no root needed.
fn hciUp(id: u16) ?bool {
    if (hci_sock < 0) return null;
    // struct hci_dev_info: u16 dev_id; char name[8]; bdaddr[6]; u32 flags; ...
    var info: [128]u8 align(8) = @as([128]u8, @splat(0));
    std.mem.writeInt(u16, info[0..2], id, .little);
    _ = sys.ioctl(hci_sock, HCIGETDEVINFO, @intFromPtr(&info)) catch return null;
    const flags = std.mem.readInt(u32, info[16..20], .little);
    return flags & 1 != 0; // HCI_UP
}

pub const HCIGETDEVINFO: u32 = 0x800448d3; // _IOR('H', 211, int)

// ---------------------------------------------------------------- battery

pub const BatState = enum(u8) { none, discharging, charging, full, idle };

pub const Battery = struct {
    state: BatState = .none,
    percent: u8 = 0,
    /// to empty or to full; 0 — unknown
    minutes: u32 = 0,
    /// power in tenths of a watt; 0 — unknown
    tenth_watts: u32 = 0,
};

fn readU64(path: [:0]const u8) ?u64 {
    var buf: [32]u8 = undefined;
    const d = sys.readFile(path, &buf) orelse return null;
    return std.fmt.parseInt(u64, trim(d), 10) catch null;
}

/// One attribute of a device in `dir`, as text or as a number.
noinline fn attrPath(path: []u8, dir: []const u8, name: []const u8, attr: []const u8) [:0]const u8 {
    return sys.joinZ(path, &.{ dir, "/", name, "/", attr });
}

fn attrNum(dir: []const u8, name: []const u8, attr: []const u8) ?u64 {
    var path: [256]u8 = undefined;
    return readU64(attrPath(&path, dir, name, attr));
}

fn attrIs(dir: []const u8, name: []const u8, attr: []const u8, value: []const u8) ?bool {
    var path: [256]u8 = undefined;
    var buf: [32]u8 = undefined;
    const d = sys.readFile(attrPath(&path, dir, name, attr), &buf) orelse return null;
    return std.mem.eql(u8, trim(d), value);
}

/// What one battery reports, in common units.
const Cell = struct { now_uwh: u64 = 0, full_uwh: u64 = 0, power_uw: u64 = 0, percent: ?u8 = null, state: BatState = .idle };

/// Laptop batteries only: a wireless mouse or headset is also a power_supply, of scope Device.
fn readCell(name: []const u8) ?Cell {
    const dir: []const u8 = power_dir;
    if (attrIs(dir, name, "type", "Battery") != true) return null;
    if (attrIs(dir, name, "scope", "Device") == true) return null;
    if (attrNum(dir, name, "present") == 0) return null;
    var c = Cell{};
    var path: [256]u8 = undefined;
    var buf: [32]u8 = undefined;
    if (sys.readFile(attrPath(&path, dir, name, "status"), &buf)) |s| c.state = parseState(trim(s));
    if (attrNum(dir, name, "capacity")) |p| c.percent = @intCast(@min(p, 100));
    if (attrNum(dir, name, "energy_now")) |now| {
        c.now_uwh = now;
        c.full_uwh = attrNum(dir, name, "energy_full") orelse 0;
        c.power_uw = attrNum(dir, name, "power_now") orelse 0;
    } else if (attrNum(dir, name, "charge_now")) |now| {
        // reports µAh and µA: the voltage turns them into energy and power
        const uv = attrNum(dir, name, "voltage_now") orelse 0;
        c.now_uwh = now *| uv / 1_000_000;
        c.full_uwh = (attrNum(dir, name, "charge_full") orelse 0) *| uv / 1_000_000;
        c.power_uw = (attrNum(dir, name, "current_now") orelse 0) *| uv / 1_000_000;
    }
    return c;
}

fn parseState(s: []const u8) BatState {
    if (std.mem.eql(u8, s, "Discharging")) return .discharging;
    if (std.mem.eql(u8, s, "Charging")) return .charging;
    if (std.mem.eql(u8, s, "Full")) return .full;
    return .idle; // "Not charging" (a charge limit), "Unknown"
}

/// One or more batteries as one. Any charging battery means charging: a laptop with two
/// batteries charges them in turn while the other reports "Not charging" or "Full".
fn combine(cells: []const Cell) Battery {
    if (cells.len == 0) return .{};
    var now: u64 = 0;
    var full: u64 = 0;
    var power: u64 = 0;
    var charging = false;
    var discharging = false;
    var all_full = true;
    for (cells) |c| {
        now +|= c.now_uwh;
        full +|= c.full_uwh;
        power +|= c.power_uw;
        charging = charging or c.state == .charging;
        discharging = discharging or c.state == .discharging;
        all_full = all_full and c.state == .full;
    }
    var b = Battery{};
    b.state = if (charging) .charging else if (discharging) .discharging else if (all_full) .full else .idle;
    if (cells.len == 1 and cells[0].percent != null) {
        b.percent = cells[0].percent.?;
    } else if (full > 0) {
        b.percent = @intCast(@min(now *| 100 / full, 100));
    } else if (cells[0].percent) |p| {
        b.percent = p;
    } else {
        return .{}; // nothing to show
    }
    b.tenth_watts = @intCast(@min(power / 100_000, 100_000));
    if (power > 0) {
        const left: u64 = switch (b.state) {
            .discharging => now,
            .charging => full -| now,
            else => 0,
        };
        // a nonsense estimate (a battery that momentarily reports almost no load) is not shown
        const m = left *| 60 / power;
        if (m < 60 * 48) b.minutes = @intCast(m);
    }
    return b;
}

pub fn battery() Battery {
    var dir = sys.Dir.open(power_dir) orelse return .{};
    defer dir.deinit();
    var cells: [4]Cell = undefined;
    var n: usize = 0;
    while (dir.next()) |name| {
        if (n == cells.len or name.len > 64) continue;
        if (readCell(name)) |c| {
            cells[n] = c;
            n += 1;
        }
    }
    return combine(cells[0..n]);
}

// ---------------------------------------------------------------- backlight

pub const Backlight = struct {
    present: bool = false,
    percent: u8 = 0,
    raw: u32 = 0,
    max: u32 = 0,
    name_buf: [48]u8 = undefined,
    name_len: u8 = 0,

    pub fn name(b: *const Backlight) []const u8 {
        return b.name_buf[0..b.name_len];
    }
};

/// The device that really controls the panel: firmware over platform over raw, as logind and
/// systemd choose. (`raw` often exists next to a firmware one and does nothing.)
pub fn backlight() Backlight {
    var dir = sys.Dir.open(light_dir) orelse return .{};
    defer dir.deinit();
    const base: []const u8 = light_dir;
    var best = Backlight{};
    var best_rank: u8 = 0;
    while (dir.next()) |name| {
        if (name.len > best.name_buf.len) continue;
        const rank: u8 = if (attrIs(base, name, "type", "firmware") == true) 3 else if (attrIs(base, name, "type", "platform") == true) 2 else 1;
        if (rank <= best_rank) continue;
        const max = attrNum(base, name, "max_brightness") orelse continue;
        const raw = attrNum(base, name, "brightness") orelse continue;
        if (max == 0 or max > std.math.maxInt(u32)) continue;
        best_rank = rank;
        best.present = true;
        best.max = @intCast(max);
        best.raw = @intCast(@min(raw, max));
        best.percent = lightPercent(best.raw, best.max);
        best.name_len = @intCast(name.len);
        @memcpy(best.name_buf[0..name.len], name);
    }
    return best;
}

/// With many hardware levels, equal slider steps should look equal: the eye sees the
/// square root of the light. With few levels every level counts, so they map one to one.
const CURVE_MIN_LEVELS: u32 = 256;

pub fn lightPercent(raw: u32, max: u32) u8 {
    if (max == 0) return 0;
    const f = @as(f32, @floatFromInt(raw)) / @as(f32, @floatFromInt(max));
    const p = if (max >= CURVE_MIN_LEVELS) @sqrt(f) * 100 else f * 100;
    return @intFromFloat(std.math.clamp(@round(p), 0, 100));
}

/// The hardware value for a percent. Never 0: on many panels that switches the backlight off
/// altogether, and a black screen is no way to find the slider again.
pub fn lightRaw(percent: u8, max: u32) u32 {
    if (max == 0) return 0;
    const f = @as(f32, @floatFromInt(@min(percent, 100))) / 100;
    const v = @as(f32, @floatFromInt(max)) * (if (max >= CURVE_MIN_LEVELS) f * f else f);
    return std.math.clamp(@as(u32, @intFromFloat(@round(v))), 1, max);
}

/// The value after one step. A step always moves, even where the curve is flat.
pub fn lightStep(raw: u32, max: u32, step: i32) u32 {
    const p: i32 = @as(i32, lightPercent(raw, max)) + step;
    const next = lightRaw(@intCast(std.math.clamp(p, 0, 100)), max);
    if (next == raw) {
        if (step > 0 and raw < max) return raw + 1;
        if (step < 0 and raw > 1) return raw - 1;
    }
    return next;
}

// ---------------------------------------------------------------- tests

const T = std.testing;

test "one battery reports its own percent" {
    const b = combine(&.{.{ .now_uwh = 30_000_000, .full_uwh = 60_000_000, .power_uw = 10_000_000, .percent = 51, .state = .discharging }});
    try T.expectEqual(BatState.discharging, b.state);
    try T.expectEqual(@as(u8, 51), b.percent);
    try T.expectEqual(@as(u32, 180), b.minutes);
    try T.expectEqual(@as(u32, 100), b.tenth_watts);
}

test "two batteries combine by energy, charging wins" {
    const b = combine(&.{
        .{ .now_uwh = 10_000_000, .full_uwh = 20_000_000, .percent = 50, .state = .idle },
        .{ .now_uwh = 30_000_000, .full_uwh = 80_000_000, .power_uw = 25_000_000, .percent = 37, .state = .charging },
    });
    try T.expectEqual(BatState.charging, b.state);
    try T.expectEqual(@as(u8, 40), b.percent);
    try T.expectEqual(@as(u32, 144), b.minutes);
}

test "no energy figures: capacity alone is enough, without time" {
    const b = combine(&.{.{ .percent = 80, .state = .full }});
    try T.expectEqual(BatState.full, b.state);
    try T.expectEqual(@as(u8, 80), b.percent);
    try T.expectEqual(@as(u32, 0), b.minutes);
}

test "no battery, or one without any figures: nothing to show" {
    try T.expectEqual(BatState.none, combine(&.{}).state);
    try T.expectEqual(BatState.none, combine(&.{.{ .state = .discharging }}).state);
}

test "absurd figures don't overflow or show nonsense" {
    const huge = std.math.maxInt(u64);
    const b = combine(&.{.{ .now_uwh = huge, .full_uwh = huge, .power_uw = huge, .state = .discharging }});
    try T.expect(b.percent <= 100);
    const tiny = combine(&.{.{ .now_uwh = 50_000_000, .full_uwh = 60_000_000, .power_uw = 1, .percent = 80, .state = .discharging }});
    try T.expectEqual(@as(u32, 0), tiny.minutes);
}

test "a charge above full stays at 100 and 0 minutes to full" {
    const b = combine(&.{.{ .now_uwh = 70, .full_uwh = 60, .power_uw = 5, .state = .charging }});
    try T.expectEqual(@as(u8, 100), b.percent);
    try T.expectEqual(@as(u32, 0), b.minutes);
}

test "status words" {
    try T.expectEqual(BatState.idle, parseState("Not charging"));
    try T.expectEqual(BatState.idle, parseState("Unknown"));
    try T.expectEqual(BatState.full, parseState("Full"));
}

test "brightness never reaches zero and stays in range" {
    for ([_]u32{ 1, 7, 15, 100, 255, 256, 937, 4882, 120000 }) |max| {
        for (0..101) |p| {
            const raw = lightRaw(@intCast(p), max);
            try T.expect(raw >= 1 and raw <= max);
            try T.expect(lightPercent(raw, max) <= 100);
        }
        try T.expectEqual(max, lightRaw(100, max));
        try T.expectEqual(@as(u8, 100), lightPercent(max, max));
    }
}

test "brightness percent survives the round trip" {
    for ([_]u32{ 937, 4882, 120000 }) |max| {
        var p: u8 = 10;
        while (p <= 100) : (p += 5) {
            const back = lightPercent(lightRaw(p, max), max);
            try T.expect(@abs(@as(i32, back) - p) <= 1);
        }
    }
    // few levels: one to one
    try T.expectEqual(@as(u32, 8), lightRaw(53, 15));
    try T.expectEqual(@as(u8, 53), lightPercent(8, 15));
}

test "a step always moves until the end of the range" {
    for ([_]u32{ 7, 15, 100, 937, 4882, 120000 }) |max| {
        var raw: u32 = 1;
        var guard: u32 = 0;
        while (raw < max) : (guard += 1) {
            const n = lightStep(raw, max, 5);
            try T.expect(n > raw);
            raw = n;
            try T.expect(guard < 200);
        }
        try T.expectEqual(max, lightStep(max, max, 5));
        guard = 0;
        while (raw > 1) : (guard += 1) {
            const n = lightStep(raw, max, -5);
            try T.expect(n < raw and n >= 1);
            raw = n;
            try T.expect(guard < 200);
        }
        try T.expectEqual(@as(u32, 1), lightStep(1, max, -5));
    }
}

test "the event filter's jumps land on its two exits" {
    const n = watched.len;
    try T.expectEqual(@as(usize, n + 5), udev_filter.len);
    try T.expectEqual(@as(usize, n + 3), 2 + @as(usize, udev_filter[1].jf));
    for (udev_filter[3 .. 3 + n], 0..) |f, i| {
        try T.expectEqual(@as(usize, n + 4), 3 + i + 1 + @as(usize, f.jt));
        try T.expectEqual(JEQ, f.code);
    }
    try T.expectEqual(@as(u32, 0), udev_filter[n + 3].k);
    try T.expectEqual(KEEP, udev_filter[n + 4].k);
}

test "nl80211: the family is asked for by name, and its number read from the answer" {
    var buf: [32]u8 = undefined;
    const req = familyRequest(&buf, 7);
    try std.testing.expectEqual(@as(usize, 32), req.len);
    try std.testing.expectEqual(@as(u16, GENL_ID_CTRL), std.mem.readInt(u16, req[4..6], .little));
    try std.testing.expectEqualStrings("nl80211\x00", req[24..32]);
    // the answer: a header, the generic header, the name again and the number, 0x1c
    var reply: [44]u8 = @splat(0);
    put32(&reply, 0, 44);
    put16(&reply, 4, GENL_ID_CTRL);
    put16(&reply, 20, 12);
    put16(&reply, 22, CTRL_ATTR_FAMILY_NAME);
    @memcpy(reply[24..32], "nl80211\x00");
    put16(&reply, 32, 6);
    put16(&reply, 34, CTRL_ATTR_FAMILY_ID);
    put16(&reply, 36, 0x1c);
    try std.testing.expectEqual(@as(u16, 0x1c), familyId(&reply).?);
    put16(&reply, 4, NLMSG_ERROR);
    try std.testing.expect(familyId(&reply) == null);
}

test "nl80211: the station's signal, its average first, and the bars it makes" {
    var buf: [32]u8 = undefined;
    const req = stationRequest(&buf, 0x1c, 9, 3);
    try std.testing.expectEqual(@as(usize, 28), req.len);
    try std.testing.expectEqual(@as(u16, NLM_F_REQUEST | NLM_F_DUMP), std.mem.readInt(u16, req[6..8], .little));
    try std.testing.expectEqual(@as(u8, NL80211_CMD_GET_STATION), req[16]);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, req[24..28], .little));
    // STA_INFO holding SIGNAL -70 and SIGNAL_AVG -55, then the end of the dump
    var reply: [60]u8 = @splat(0);
    put32(&reply, 0, 40);
    put16(&reply, 4, 0x1c);
    put16(&reply, 20, 20); // STA_INFO, nested
    put16(&reply, 22, NL80211_ATTR_STA_INFO | 0x8000);
    put16(&reply, 24, 5);
    put16(&reply, 26, NL80211_STA_INFO_SIGNAL);
    reply[28] = @bitCast(@as(i8, -70));
    put16(&reply, 32, 5);
    put16(&reply, 34, NL80211_STA_INFO_SIGNAL_AVG);
    reply[36] = @bitCast(@as(i8, -55));
    put32(&reply, 40, 20);
    put16(&reply, 44, NLMSG_DONE);
    try std.testing.expectEqual(@as(i8, -55), stationSignal(&reply).?);
    // without the average, the signal itself
    put16(&reply, 34, 99);
    try std.testing.expectEqual(@as(i8, -70), stationSignal(&reply).?);
    // not connected: only the end of the dump
    try std.testing.expect(stationSignal(reply[40..60]) == null);
    // the same bars as /proc/net/wireless gave: quality dBm + 110, out of 70
    try std.testing.expectEqual(@as(u8, 3), levelOf(-55));
    try std.testing.expectEqual(@as(u8, 2), levelOf(-80));
    try std.testing.expectEqual(@as(u8, 1), levelOf(-95));
    try std.testing.expectEqual(@as(u8, 1), levelOf(-128));
    try std.testing.expectEqual(@as(u8, 3), levelOf(-10));
}
