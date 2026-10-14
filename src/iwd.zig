// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! iwd client over D-Bus — the Wi‑Fi backend for systems without NetworkManager.
//! Same API as nm.zig, which forwards here when only iwd is running.
//!
//! Passwords: during Network.Connect iwd asks our agent (net.connman.iwd.Agent.RequestPassphrase).
//! The agent answers only iwd's own unique bus name, and the password is wiped right after the reply.
//! iwd stores the network itself (a "known network") once the connection succeeds.
//! 802.1X: iwd takes enterprise settings only from /var/lib/iwd/<SSID>.8021x, which root writes —
//! the menu says so instead of trying.

const std = @import("std");
const sys = @import("sys.zig");
const dbus = @import("dbus.zig");
const nm = @import("nm.zig");

pub const NAME = "net.connman.iwd";
const OM = "org.freedesktop.DBus.ObjectManager";
const PROPS = "org.freedesktop.DBus.Properties";
const STATION = "net.connman.iwd.Station";
const DEVICE = "net.connman.iwd.Device";
const NETWORK = "net.connman.iwd.Network";
const KNOWN = "net.connman.iwd.KnownNetwork";
const ADAPTER = "net.connman.iwd.Adapter";
const AGENT_MGR = "net.connman.iwd.AgentManager";
const AGENT = "net.connman.iwd.Agent";
const AGENT_PATH = "/org/netline/zwifi";

/// The device object: the Device interface, and Station while it is powered (same path).
var station: nm.Path = .{};
/// Its adapter: Adapter.Powered is the rfkill soft block.
var adapter: nm.Path = .{};
var body_buf: [4 * 1024]u8 = undefined;
var connect_serial: u32 = 0;
/// The password for the connection in progress: handed to iwd once, on its request.
var pending: [64]u8 = undefined;
var pending_len: usize = 0;
var have_pending = false;

const bus = &nm.bus;

fn call(path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) ?dbus.Reply {
    const r = bus.call(NAME, path, iface, member, sig, body) catch |e| {
        nm.setError(switch (e) {
            error.Timeout => "iwd is not responding",
            else => "error talking to iwd",
        });
        return null;
    };
    if (!r.ok()) {
        nm.setError(r.message());
        return null;
    }
    return r;
}

// ================================================================= initialization

const Scan = struct { found: bool = false, powered: ?bool = null };

/// owner — iwd's unique bus name (from GetNameOwner): signals and agent calls are accepted only from it.
pub fn init(owner: []const u8) bool {
    bus.setPeer(owner);
    var sc = Scan{};
    {
        var serials = [1]u32{bus.sendCall(NAME, "/", OM, "GetManagedObjects", "", "") catch 0};
        bus.collect(&serials, &sc, gotObjects) catch {};
    }
    if (!sc.found) {
        nm.setError("Wi‑Fi adapter not found (iwd)");
        return false;
    }
    if (sc.powered) |p| nm.wifi_enabled = p;
    addMatch("type='signal',sender='" ++ NAME ++ "'");
    bus.on_signal = onSignal;
    bus.on_method = onMethod;
    var w = dbus.W{ .buf = &body_buf };
    w.str(AGENT_PATH);
    _ = call("/net/connman/iwd", AGENT_MGR, "RegisterAgent", "o", w.bytes()) orelse return false;
    return true;
}

/// The first device in station mode — that's the one the menu works with. It is found by its Device
/// interface: a powered-off device has no Station interface, and the menu must still be able to turn it on.
fn gotObjects(sc: *Scan, _: usize, rep: dbus.Reply) void {
    if (!rep.ok()) return;
    const eql = std.mem.eql;
    var r = rep.reader();
    const end = r.arrayEnd(8);
    while (r.p < end and !r.bad and !sc.found) {
        r.alignTo(8);
        const path = r.str();
        var is_dev = false;
        var is_station = true; // Mode: "station" (the default), "ap" or "ad-hoc"
        var powered: ?bool = null;
        var adp: []const u8 = "";
        const iend = r.arrayEnd(8);
        while (r.p < iend and !r.bad) {
            r.alignTo(8);
            const iface = r.str();
            const dev = eql(u8, iface, DEVICE);
            if (dev) is_dev = true;
            const pend = r.arrayEnd(8);
            while (r.p < pend and !r.bad) {
                r.alignTo(8);
                const key = r.str();
                const vs = r.sig();
                if (dev and eql(u8, key, "Powered") and eql(u8, vs, "b")) {
                    powered = r.boolean();
                } else if (dev and eql(u8, key, "Mode") and eql(u8, vs, "s")) {
                    is_station = eql(u8, r.str(), "station");
                } else if (dev and eql(u8, key, "Adapter") and eql(u8, vs, "o")) {
                    adp = r.str();
                } else r.skip(vs);
            }
            r.p = @max(r.p, pend);
        }
        r.p = @max(r.p, iend);
        if (is_dev and is_station and !r.bad) {
            station.set(path);
            adapter.set(adp);
            sc.found = true;
            sc.powered = powered;
        }
    }
}

fn addMatch(rule: []const u8) void {
    var w = dbus.W{ .buf = &body_buf };
    w.str(rule);
    bus.callNoReply("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", w.bytes());
}

fn onSignal(path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) void {
    const eql = std.mem.eql;
    if (eql(u8, iface, OM)) {
        // a network appeared or vanished after a scan
        if (eql(u8, member, "InterfacesAdded") or eql(u8, member, "InterfacesRemoved")) nm.nets_changed = true;
        return;
    }
    if (!eql(u8, member, "PropertiesChanged") or !eql(u8, sig, "sa{sv}as")) return;
    var r = dbus.R{ .d = body };
    const which = r.str();
    if (eql(u8, which, NETWORK)) {
        nm.nets_changed = true; // Connected flipped
        return;
    }
    if (!eql(u8, path, station.get())) return;
    const end = r.arrayEnd(8);
    while (r.p < end and !r.bad) {
        r.alignTo(8);
        const key = r.str();
        const vs = r.sig();
        if (eql(u8, which, DEVICE) and eql(u8, key, "Powered") and eql(u8, vs, "b")) {
            const on = r.boolean();
            if (!r.bad and on != nm.wifi_enabled) {
                nm.wifi_enabled = on;
                nm.nets_changed = true;
            }
        } else if (eql(u8, which, STATION) and eql(u8, key, "State")) {
            nm.state_changed = true;
            nm.nets_changed = true;
            r.skip(vs);
        } else if (eql(u8, which, STATION) and eql(u8, key, "Scanning") and eql(u8, vs, "b")) {
            if (!r.boolean()) nm.nets_changed = true; // scan finished: fresh list
        } else r.skip(vs);
    }
}

// ================================================================= agent

fn onMethod(c: *dbus.Conn, m: *const dbus.Incoming) void {
    const eql = std.mem.eql;
    if (!eql(u8, m.path, AGENT_PATH) or !eql(u8, m.iface, AGENT)) {
        return c.replyError(m, "org.freedesktop.DBus.Error.UnknownObject", "no such object");
    }
    // only iwd itself may ask for the password — not another process on the bus
    if (!eql(u8, m.sender, c.peer())) {
        return c.replyError(m, "org.freedesktop.DBus.Error.AccessDenied", "access denied");
    }
    if (eql(u8, m.member, "Release") or eql(u8, m.member, "Cancel")) {
        wipePending();
        return c.reply(m, "", "");
    }
    if (eql(u8, m.member, "RequestPassphrase") and have_pending) {
        var b: [128]u8 = undefined;
        var w = dbus.W{ .buf = &b };
        w.str(pending[0..pending_len]);
        c.reply(m, "s", w.bytes());
        sys.secureZero(&b);
        sys.secureZero(c.out);
        wipePending();
        return;
    }
    // no password to give (a saved one stopped working, or 802.1X) — the menu asks the user again
    c.replyError(m, "net.connman.iwd.Agent.Error.Canceled", "canceled");
}

fn wipePending() void {
    sys.secureZero(&pending);
    pending_len = 0;
    have_pending = false;
}

// ================================================================= radio and scanning

pub fn setEnabled(on: bool) bool {
    if (!setPowered(station.get(), DEVICE, on)) {
        // the adapter itself is off (rfkill soft block, e.g. the airplane key): Adapter.Powered lifts it,
        // then the device comes up within a moment
        if (!on or adapter.len == 0 or !setPowered(adapter.get(), ADAPTER, true)) return false;
        var attempt: u32 = 0;
        while (!setPowered(station.get(), DEVICE, true)) : (attempt += 1) {
            if (attempt == 20) return false;
            var none = [0]sys.PollFd{};
            _ = sys.poll(&none, 50) catch {};
        }
    }
    nm.wifi_enabled = on;
    return true;
}

fn setPowered(path: []const u8, iface: []const u8, on: bool) bool {
    var w = dbus.W{ .buf = &body_buf };
    w.str(iface);
    w.str("Powered");
    w.sig("b");
    w.boolean(on);
    _ = call(path, PROPS, "Set", "ssv", w.bytes()) orelse return false;
    return true;
}

/// Ask iwd to scan. "Already scanning" is harmless, so the reply isn't awaited.
pub fn scan() void {
    bus.callNoReply(NAME, station.get(), STATION, "Scan", "", "");
}

// ================================================================= network list

const MAXN = 96;
const Seen = struct { path: nm.Path = .{}, dbm: i16 = -10000 };
const Head = struct { seen: [MAXN]Seen = undefined, n: usize = 0, out: []nm.Net, count: usize = 0, ok: bool = false };

/// Networks in iwd's rank order (one per SSID — iwd already merges access points).
pub fn networks(out: []nm.Net) usize {
    nm.nets_changed = false;
    var h = Head{ .out = out };
    var serials = [2]u32{
        bus.sendCall(NAME, station.get(), STATION, "GetOrderedNetworks", "", "") catch 0,
        bus.sendCall(NAME, "/", OM, "GetManagedObjects", "", "") catch 0,
    };
    if (serials[0] == 0 or serials[1] == 0) {
        nm.setError("error talking to iwd");
        return 0;
    }
    bus.collect(&serials, &h, gotList) catch {
        nm.setError("error talking to iwd");
        return 0;
    };
    // connected on top, then iwd's rank (it already accounts for band and signal)
    std.mem.sort(nm.Net, out[0..h.count], {}, struct {
        fn lt(_: void, a: nm.Net, b: nm.Net) bool {
            if (a.active != b.active) return a.active;
            return a.strength > b.strength;
        }
    }.lt);
    return h.count;
}

fn gotList(h: *Head, i: usize, rep: dbus.Reply) void {
    if (!rep.ok()) {
        nm.setError(rep.message());
        return;
    }
    var r = rep.reader();
    if (i == 0) {
        // a(on): network path and signal in 100 * dBm
        const end = r.arrayEnd(8);
        while (r.p < end and !r.bad and h.n < MAXN) {
            r.alignTo(8);
            h.seen[h.n].path.set(r.str());
            h.seen[h.n].dbm = @bitCast(r.u16_());
            h.n += 1;
        }
        h.ok = !r.bad;
        return;
    }
    // GetManagedObjects arrives after GetOrderedNetworks: the bus keeps a connection's order
    const end = r.arrayEnd(8);
    while (r.p < end and !r.bad) {
        r.alignTo(8);
        const path = r.str();
        var net = nm.Net{};
        var is_net = false;
        var on_station = false;
        const iend = r.arrayEnd(8);
        while (r.p < iend and !r.bad) {
            r.alignTo(8);
            const iface = r.str();
            const mine = std.mem.eql(u8, iface, NETWORK);
            if (mine) is_net = true;
            const pend = r.arrayEnd(8);
            while (r.p < pend and !r.bad) {
                r.alignTo(8);
                const key = r.str();
                const vs = r.sig();
                const eql = std.mem.eql;
                if (!mine) {
                    r.skip(vs);
                } else if (eql(u8, key, "Name") and eql(u8, vs, "s")) {
                    const s = r.str();
                    const k = @min(s.len, net.ssid_buf.len);
                    @memcpy(net.ssid_buf[0..k], s[0..k]);
                    net.ssid_len = @intCast(k);
                } else if (eql(u8, key, "Connected") and eql(u8, vs, "b")) {
                    net.active = r.boolean();
                } else if (eql(u8, key, "Type") and eql(u8, vs, "s")) {
                    const t = r.str();
                    net.sec = if (eql(u8, t, "psk")) .psk else if (eql(u8, t, "8021x")) .eap else if (eql(u8, t, "wep")) .wep else .open;
                } else if (eql(u8, key, "KnownNetwork") and eql(u8, vs, "o")) {
                    net.conn.set(r.str());
                    net.known = true;
                } else if (eql(u8, key, "Device") and eql(u8, vs, "o")) {
                    on_station = eql(u8, r.str(), station.get());
                } else r.skip(vs);
            }
            r.p = @max(r.p, pend);
        }
        r.p = @max(r.p, iend);
        if (!is_net or !on_station or net.ssid_len == 0 or h.count == h.out.len) continue;
        net.ap.set(path);
        net.strength = 0; // not in range right now — iwd still keeps the object for a while
        var visible = false;
        for (h.seen[0..h.n]) |s| {
            if (!std.mem.eql(u8, s.path.get(), path)) continue;
            visible = true;
            // −90 dBm and below → 0 %, −30 dBm and above → 100 %
            const dbm = @divTrunc(@as(i32, s.dbm), 100);
            net.strength = @intCast(std.math.clamp(@divTrunc((dbm + 90) * 100, 60), 0, 100));
        }
        if (!visible and !net.active) continue;
        h.out[h.count] = net;
        h.count += 1;
    }
}

// ================================================================= actions

pub fn activateSaved(_: []const u8, ap: []const u8) bool {
    if (ap.len == 0) {
        nm.setError("The network is not in range");
        return false;
    }
    wipePending(); // a saved network: iwd has the key; if it asks, the menu offers to re-enter
    return connectAsync(ap, NETWORK, "Connect", "", "");
}

pub fn addAndActivate(spec: nm.Spec, ap: []const u8) bool {
    switch (spec.sec) {
        .eap => {
            nm.setError("802.1X with iwd: the administrator creates /var/lib/iwd/<SSID>.8021x");
            return false;
        },
        .wep => {
            nm.setError("WEP is outdated and insecure — not supported");
            return false;
        },
        else => {},
    }
    wipePending();
    if (spec.sec == .psk or spec.sec == .sae) {
        if (spec.psk.len == 0 or spec.psk.len > pending.len) {
            nm.setError("A WPA password is 8 to 63 characters");
            return false;
        }
        @memcpy(pending[0..spec.psk.len], spec.psk);
        pending_len = spec.psk.len;
        have_pending = true;
    }
    if (spec.hidden) {
        var w = dbus.W{ .buf = &body_buf };
        w.str(spec.ssid);
        return connectAsync(station.get(), STATION, "ConnectHiddenNetwork", "s", w.bytes());
    }
    if (ap.len == 0) {
        nm.setError("The network is not in range");
        return false;
    }
    return connectAsync(ap, NETWORK, "Connect", "", "");
}

/// Connect returns only when iwd is done (connected or failed); meanwhile it may ask the agent
/// for the password. So the call is async: progress() picks up the result.
fn connectAsync(path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) bool {
    nm.activating.set(path);
    connect_serial = bus.callAsync(NAME, path, iface, member, sig, body) catch {
        nm.setError("error talking to iwd");
        wipePending();
        return false;
    };
    return true;
}

pub fn progress() nm.Progress {
    if (connect_serial == 0) return .failed;
    const d = bus.result(connect_serial) orelse return .working;
    connect_serial = 0;
    wipePending();
    if (d.ok) return .done;
    const eql = std.mem.eql;
    const name = d.errName();
    if (eql(u8, name, "net.connman.iwd.AlreadyConnected")) return .done;
    nm.setError(if (eql(u8, name, "net.connman.iwd.Failed"))
        "Could not connect — check the password"
    else if (eql(u8, name, "net.connman.iwd.Aborted") or eql(u8, name, "net.connman.iwd.Agent.Error.Canceled"))
        "Password required"
    else if (eql(u8, name, "net.connman.iwd.InvalidFormat"))
        "Wrong password format"
    else if (eql(u8, name, "net.connman.iwd.NotSupported"))
        "This network type is not supported"
    else if (eql(u8, name, "net.connman.iwd.NotFound") or eql(u8, name, "net.connman.iwd.NotAvailable"))
        "Network not found"
    else if (eql(u8, name, "net.connman.iwd.InProgress"))
        "Another connection is in progress"
    else
        d.message());
    return .failed;
}

pub fn disconnect() bool {
    if (connect_serial != 0) connect_serial = 0; // the late reply will just be dropped
    wipePending();
    _ = call(station.get(), STATION, "Disconnect", "", "") orelse return false;
    return true;
}

pub fn forget(conn: []const u8) bool {
    _ = call(conn, KNOWN, "Forget", "", "") orelse return false;
    return true;
}
