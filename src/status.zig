// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Wi‑Fi and Bluetooth state straight from the kernel (sysfs/procfs/ioctl), without NetworkManager/BlueZ/D-Bus.
//! Updates arrive as netlink events, so the panel does not poll the system for nothing.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");

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

/// A udevd broadcast: "libudev\0", magic 0xfeedcafe (offset 8), subsystem hash (24) —
/// all in network byte order, which is how BPF reads it. Only rfkill and bluetooth pass.
const udev_filter = [_]sys.SockFilter{
    .{ .code = LD_W_ABS, .k = 8 },
    .{ .code = JEQ, .k = 0xfeedcafe, .jt = 0, .jf = 4 },
    .{ .code = LD_W_ABS, .k = 24 },
    .{ .code = JEQ, .k = murmur2("rfkill"), .jt = 1, .jf = 0 },
    .{ .code = JEQ, .k = murmur2("bluetooth"), .jt = 0, .jf = 1 },
    .{ .code = RET, .k = KEEP },
    .{ .code = RET, .k = 0 },
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

pub const Changed = struct { wifi: bool = false, bt: bool = false };

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
                }
                break;
            };
            if (n == 0) break;
            // "ACTION@DEVPATH\0KEY=VALUE\0..." — only the subsystem is needed
            var it = std.mem.splitScalar(u8, buf[0..n], 0);
            while (it.next()) |kv| {
                if (std.mem.eql(u8, kv, "SUBSYSTEM=bluetooth")) ch.bt = true;
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

/// Signal level 1..3 from link quality in /proc/net/wireless (usually out of 70).
pub fn signalLevel() u8 {
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
    var info: [128]u8 align(8) = [_]u8{0} ** 128;
    std.mem.writeInt(u16, info[0..2], id, .little);
    _ = sys.ioctl(hci_sock, HCIGETDEVINFO, @intFromPtr(&info)) catch return null;
    const flags = std.mem.readInt(u32, info[16..20], .little);
    return flags & 1 != 0; // HCI_UP
}

pub const HCIGETDEVINFO: u32 = 0x800448d3; // _IOR('H', 211, int)
