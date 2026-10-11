// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Состояние Wi‑Fi и Bluetooth — напрямую из ядра (sysfs/procfs/ioctl), без NetworkManager/BlueZ/D-Bus.
//! Обновления приходят событиями netlink, поэтому панель не опрашивает систему впустую.

const std = @import("std");
const sys = @import("sys.zig");

pub const WifiState = enum(u8) { none, off, disconnected, connected };
pub const Wifi = struct { state: WifiState = .none, level: u8 = 0 }; // level 1..3

pub const Bt = enum(u8) { none, off, on, connected };

/// Сокеты событий (или -1): изменения сетевых интерфейсов и uevent'ы устройств.
pub var route_fd: i32 = -1;
pub var uevent_fd: i32 = -1;
var hci_sock: i32 = -1;

/// Открыть всё нужное заранее — после включения песочницы создавать сокеты нельзя.
pub fn init() void {
    route_fd = sys.netlink(0, 1) catch -1; // NETLINK_ROUTE, RTMGRP_LINK
    uevent_fd = sys.netlink(15, 1) catch -1; // NETLINK_KOBJECT_UEVENT, события ядра
    hci_sock = sys.socket(31, 3, 1) catch -1; // AF_BLUETOOTH, SOCK_RAW, BTPROTO_HCI
}

pub const Changed = struct { wifi: bool = false, bt: bool = false };

/// Вычитать все события из готовых сокетов и сказать, что нужно перечитать.
pub fn drainEvents(route_ready: bool, uevent_ready: bool) Changed {
    var ch = Changed{};
    var buf: [8192]u8 align(4) = undefined;
    if (route_ready) {
        while (true) {
            const n = sys.read(route_fd, &buf) catch |e| {
                if (e == error.WouldBlock) break;
                ch.wifi = true; // ENOBUFS и т.п. — на всякий случай перечитаем
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
            // "ACTION@DEVPATH\0KEY=VALUE\0..." — нужна только подсистема
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

/// true/false — заблокирован ли rfkill данного типа ("wlan", "bluetooth"); null — устройств нет.
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

    // IFF_UP в /sys/class/net/<if>/flags
    const flags_s = sys.readFile(sys.joinZ(&path, &.{ "/sys/class/net/", iface(), "/flags" }), &buf) orelse return .{ .state = .off };
    const flags_t = trim(flags_s);
    const flags = std.fmt.parseInt(u32, if (std.mem.startsWith(u8, flags_t, "0x")) flags_t[2..] else flags_t, 16) catch 0;
    if (flags & 1 == 0) return .{ .state = .off };

    const oper = sys.readFile(sys.joinZ(&path, &.{ "/sys/class/net/", iface(), "/operstate" }), &buf) orelse return .{ .state = .disconnected };
    if (!std.mem.eql(u8, trim(oper), "up")) return .{ .state = .disconnected };

    return .{ .state = .connected, .level = signalLevel() };
}

/// Уровень сигнала 1..3 по link quality из /proc/net/wireless (обычно из 70).
fn signalLevel() u8 {
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
            conns += 1; // hciN:<handle> — активное соединение
        } else if (dev == null) {
            dev = std.fmt.parseInt(u16, name[3..], 10) catch null;
        }
    }
    const id = dev orelse return .none;
    const powered = hciUp(id) orelse !(rfkillBlocked("bluetooth") orelse false);
    if (!powered) return .off;
    return if (conns > 0) .connected else .on;
}

/// Флаг HCI_UP через ioctl(HCIGETDEVINFO) — права root не нужны.
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
