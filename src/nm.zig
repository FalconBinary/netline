// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! NetworkManager client over D-Bus: network list, connecting (open, WPA/WPA2/WPA3
//! Personal, OWE, 802.1X: PEAP, TTLS, EAP-TLS), disconnecting, "forget network", radio on/off.
//! Authentication and encryption are done by the system daemon — passwords go to it over D-Bus.
//! Without NetworkManager the same calls go to iwd (iwd.zig) if it is running.

const std = @import("std");
const sys = @import("sys.zig");
const dbus = @import("dbus.zig");
const iwd = @import("iwd.zig");

const NM = "org.freedesktop.NetworkManager";
const NM_PATH = "/org/freedesktop/NetworkManager";
const PROPS = "org.freedesktop.DBus.Properties";
const DEV = "org.freedesktop.NetworkManager.Device";
const WIFI = "org.freedesktop.NetworkManager.Device.Wireless";
const AP = "org.freedesktop.NetworkManager.AccessPoint";
const SETTINGS = "org.freedesktop.NetworkManager.Settings";
const CONN = "org.freedesktop.NetworkManager.Settings.Connection";
const ACTIVE = "org.freedesktop.NetworkManager.Connection.Active";

pub const Security = enum(u8) { open, wep, psk, sae, owe, eap };

pub const Path = struct {
    buf: [128]u8 = undefined,
    len: u8 = 0,

    pub fn set(p: *Path, s: []const u8) void {
        const k = @min(s.len, p.buf.len);
        std.mem.copyForwards(u8, p.buf[0..k], s[0..k]); // the source may be this same buffer
        p.len = @intCast(k);
    }
    pub fn get(p: *const Path) []const u8 {
        return p.buf[0..p.len];
    }
};

pub const Net = struct {
    ssid_buf: [32]u8 = undefined,
    ssid_len: u8 = 0,
    ap: Path = .{},
    conn: Path = .{}, // the saved connection (if known)
    strength: u8 = 0,
    sec: Security = .open,
    active: bool = false,
    known: bool = false,

    pub fn ssid(n: *const Net) []const u8 {
        return n.ssid_buf[0..n.ssid_len];
    }
};

pub const Eap = enum(u8) { peap, ttls, tls };

/// What a new connection needs.
pub const Spec = struct {
    ssid: []const u8,
    hidden: bool = false,
    sec: Security,
    psk: []const u8 = "",
    eap: Eap = .peap,
    phase2: []const u8 = "mschapv2",
    identity: []const u8 = "",
    anon_identity: []const u8 = "",
    password: []const u8 = "",
    ca_cert: []const u8 = "",
    domain: []const u8 = "",
    client_cert: []const u8 = "",
    private_key: []const u8 = "",
    key_password: []const u8 = "",
};

pub var bus: dbus.Conn = .{};
/// Which daemon manages Wi‑Fi: NetworkManager if it is running, otherwise iwd.
pub const Backend = enum { nm, iwd };
pub var backend: Backend = .nm;
pub var device: Path = .{};
pub var wifi_enabled: bool = true;
/// Text of the last error (to show to the user).
pub var err_buf: [200]u8 = undefined;
pub var err_len: usize = 0;

var body_buf: [16 * 1024]u8 = undefined;

pub fn lastError() []const u8 {
    return err_buf[0..err_len];
}

pub fn setError(msg: []const u8) void {
    err_len = @min(msg.len, err_buf.len);
    @memcpy(err_buf[0..err_len], msg[0..err_len]);
}

fn call(path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) ?dbus.Reply {
    const r = bus.call(NM, path, iface, member, sig, body) catch |e| {
        setError(switch (e) {
            error.Timeout => "NetworkManager is not responding",
            else => "error talking to NetworkManager",
        });
        return null;
    };
    if (!r.ok()) {
        setError(r.message());
        return null;
    }
    return r;
}

/// Read a property: returns a reader positioned at the value, and its signature.
fn getProp(path: []const u8, iface: []const u8, name: []const u8) ?struct { r: dbus.R, sig: []const u8 } {
    var w = dbus.W{ .buf = &body_buf };
    w.str(iface);
    w.str(name);
    const rep = call(path, PROPS, "Get", "ss", w.bytes()) orelse return null;
    var r = rep.reader();
    const s = r.sig();
    return .{ .r = r, .sig = s };
}

// ================================================================= initialization

const Devices = struct { paths: [32]Path = undefined, n: usize = 0, types: [32]u32 = @as([32]u32, @splat(0)), ok: bool = false, enabled: ?bool = null, iwd_owner: Path = .{} };

pub fn init() bool {
    bus.connectSystem() catch {
        setError("no access to the D-Bus system bus");
        return false;
    };
    // who owns the NetworkManager name (signals are accepted only from it), the device list
    // and whether iwd is there instead — one wait
    var devs = Devices{};
    {
        var w = dbus.W{ .buf = &body_buf };
        w.str(NM);
        var w2 = dbus.W{ .buf = body_buf[256..] };
        w2.str(iwd.NAME);
        var serials = [3]u32{
            bus.sendCall("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", w.bytes()) catch 0,
            bus.sendCall(NM, NM_PATH, NM, "GetDevices", "", "") catch 0,
            bus.sendCall("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", w2.bytes()) catch 0,
        };
        bus.collect(&serials, &devs, gotDevices) catch {};
    }
    if (!devs.ok or bus.peer_len == 0) {
        if (devs.iwd_owner.len > 0) {
            backend = .iwd;
            return iwd.init(devs.iwd_owner.get());
        }
        setError("Neither NetworkManager nor iwd is running");
        return false;
    }
    // Subscriptions: radio power (before reading it, so a change in between isn't lost), then everything
    // from our device (state changes — so the failure reason isn't lost; access points added/removed,
    // scan finished — LastScan). The menu learns about new networks and connection progress right away.
    addMatch("type='signal',sender='" ++ NM ++ "',path='" ++ NM_PATH ++ "',member='PropertiesChanged'");
    // the type of every device and whether the radio is on — in one batch too
    {
        var w = dbus.W{ .buf = &body_buf };
        w.str(DEV);
        w.str("DeviceType");
        var serials = @as([33]u32, @splat(0));
        for (devs.paths[0..devs.n], 0..) |*p, i| serials[i] = bus.sendCall(NM, p.get(), PROPS, "Get", "ss", w.bytes()) catch 0;
        w = .{ .buf = &body_buf };
        w.str(NM);
        w.str("WirelessEnabled");
        serials[devs.n] = bus.sendCall(NM, NM_PATH, PROPS, "Get", "ss", w.bytes()) catch 0;
        bus.collect(serials[0 .. devs.n + 1], &devs, gotType) catch {};
    }
    if (devs.enabled) |on| wifi_enabled = on;
    for (devs.paths[0..devs.n], devs.types[0..devs.n]) |*p, t| {
        if (t == 2) { // NM_DEVICE_TYPE_WIFI
            device = p.*;
            break;
        }
    }
    if (device.len == 0) {
        setError("Wi‑Fi adapter not found");
        return false;
    }
    var rule_buf: [400]u8 = undefined;
    addMatch(sys.joinZ(&rule_buf, &.{ "type='signal',sender='", NM, "',path='", device.get(), "'" }));
    bus.on_signal = onSignal;
    return true;
}

fn gotDevices(d: *Devices, i: usize, rep: dbus.Reply) void {
    if (!rep.ok()) return;
    var r = rep.reader();
    if (i == 0) {
        const owner = r.str();
        if (!r.bad) bus.setPeer(owner);
        return;
    }
    if (i == 2) {
        const owner = r.str();
        if (!r.bad) d.iwd_owner.set(owner);
        return;
    }
    const end = r.arrayEnd(4);
    while (r.p < end and !r.bad and d.n < d.paths.len) {
        d.paths[d.n].set(r.str());
        d.n += 1;
    }
    d.ok = !r.bad;
}

/// The reply to Get DeviceType of device i, or (i == n) to Get WirelessEnabled.
fn gotType(d: *Devices, i: usize, rep: dbus.Reply) void {
    if (!rep.ok()) return;
    var r = rep.reader();
    const sig = r.sig();
    if (i == d.n) {
        if (!std.mem.eql(u8, sig, "b")) return;
        const on = r.boolean();
        if (!r.bad) d.enabled = on;
        return;
    }
    if (!std.mem.eql(u8, sig, "u")) return;
    const t = r.u32_();
    if (!r.bad) d.types[i] = t;
}

/// A match rule without waiting for the reply: the bus handles a connection's messages in order,
/// so the rule is in place before the next call — and there's one round trip less per rule.
fn addMatch(rule: []const u8) void {
    var w = dbus.W{ .buf = &body_buf };
    w.str(rule);
    bus.callNoReply("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", w.bytes());
}

/// The last reason the device went to FAILED (0 — none).
var fail_reason: u32 = 0;
/// The network list changed (new/vanished access points, scan finished) — worth rereading.
pub var nets_changed = false;
/// The device changed state — worth checking the connection progress.
pub var state_changed = false;

fn onSignal(path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) void {
    const eql = std.mem.eql;
    if (eql(u8, path, NM_PATH)) {
        // the radio was turned on/off (e.g. by right-clicking the panel icon)
        if (!eql(u8, member, "PropertiesChanged") or !eql(u8, sig, "sa{sv}as")) return;
        var r = dbus.R{ .d = body };
        if (!eql(u8, r.str(), NM)) return;
        const end = r.arrayEnd(8);
        while (r.p < end and !r.bad) {
            r.alignTo(8);
            const key = r.str();
            const vs = r.sig();
            if (eql(u8, key, "WirelessEnabled") and eql(u8, vs, "b")) {
                const on = r.boolean();
                if (!r.bad and on != wifi_enabled) {
                    wifi_enabled = on;
                    nets_changed = true;
                }
            } else r.skip(vs);
        }
        return;
    }
    if (!eql(u8, path, device.get())) return;
    if (eql(u8, iface, DEV) and eql(u8, member, "StateChanged") and eql(u8, sig, "uuu")) {
        var r = dbus.R{ .d = body };
        const new_state = r.u32_();
        _ = r.u32_();
        const reason = r.u32_();
        if (new_state == 120 and !r.bad) fail_reason = reason; // NM_DEVICE_STATE_FAILED
        state_changed = true;
    } else if (eql(u8, iface, WIFI) and (eql(u8, member, "AccessPointAdded") or eql(u8, member, "AccessPointRemoved"))) {
        nets_changed = true;
    } else if (eql(u8, member, "PropertiesChanged")) {
        // LastScan, AccessPoints, ActiveAccessPoint of Device.Wireless (old NM send the signal on behalf of the interface)
        var r = dbus.R{ .d = body };
        if (eql(u8, iface, WIFI) or (eql(u8, sig, "sa{sv}as") and eql(u8, r.str(), WIFI))) nets_changed = true;
    }
}

pub fn setEnabled(on: bool) bool {
    if (backend == .iwd) return iwd.setEnabled(on);
    var w = dbus.W{ .buf = &body_buf };
    w.str(NM);
    w.str("WirelessEnabled");
    w.sig("b");
    w.boolean(on);
    _ = call(NM_PATH, PROPS, "Set", "ssv", w.bytes()) orelse return false;
    wifi_enabled = on;
    return true;
}

/// Ask NM to scan for networks. We don't wait for the reply ("too often" is harmless):
/// the AccessPointAdded and LastScan signals report the results.
pub fn scan() void {
    if (backend == .iwd) return iwd.scan();
    var w = dbus.W{ .buf = &body_buf };
    const a = w.arrayBegin(8); // empty a{sv}
    w.arrayEnd(a);
    bus.callNoReply(NM, device.get(), WIFI, "RequestScan", "a{sv}", w.bytes());
}

// ================================================================= network list

const Saved = struct { path: Path = .{}, ssid: [32]u8 = undefined, ssid_len: u8 = 0 };
var saved: [64]Saved = undefined;
var nsaved: usize = 0;

/// Reread the saved Wi‑Fi connections (path + SSID).
pub fn loadSaved() void {
    nsaved = 0;
    if (backend == .iwd) return; // iwd reports the known network with each network
    const rep = call("/org/freedesktop/NetworkManager/Settings", SETTINGS, "ListConnections", "", "") orelse return;
    var paths: [128]Path = undefined;
    var n: usize = 0;
    var r = rep.reader();
    const end = r.arrayEnd(4);
    while (r.p < end and !r.bad and n < paths.len) {
        paths[n].set(r.str());
        n += 1;
    }
    // GetSettings for all profiles — in batches, not one call at a time with a wait each
    var start: usize = 0;
    while (start < n) : (start += BATCH) {
        const stop = @min(n, start + BATCH);
        var serials = @as([BATCH]u32, @splat(0));
        for (paths[start..stop], 0..) |*p, i| {
            serials[i] = bus.sendCall(NM, p.get(), CONN, "GetSettings", "", "") catch 0;
        }
        bus.collect(serials[0 .. stop - start], paths[start..stop], gotSettings) catch {
            setError("error talking to NetworkManager");
            return;
        };
    }
}

/// How many calls to send in one batch (the system bus limits pending replies).
const BATCH = 32;

fn gotSettings(paths: []Path, i: usize, s: dbus.Reply) void {
    if (!s.ok() or nsaved == saved.len) return;
    const p = &paths[i];
    {
        var item = Saved{};
        var is_wifi = false;
        var gr = s.reader();
        const gend = gr.arrayEnd(8);
        while (gr.p < gend and !gr.bad) {
            gr.alignTo(8);
            const group = gr.str();
            const kend = gr.arrayEnd(8);
            while (gr.p < kend and !gr.bad) {
                gr.alignTo(8);
                const key = gr.str();
                const vs = gr.sig();
                if (std.mem.eql(u8, group, "connection") and std.mem.eql(u8, key, "type") and std.mem.eql(u8, vs, "s")) {
                    is_wifi = std.mem.eql(u8, gr.str(), "802-11-wireless");
                } else if (std.mem.eql(u8, group, "802-11-wireless") and std.mem.eql(u8, key, "ssid") and std.mem.eql(u8, vs, "ay")) {
                    const e = gr.arrayEnd(1);
                    const bytes = gr.d[gr.p..e];
                    const k = @min(bytes.len, 32);
                    @memcpy(item.ssid[0..k], bytes[0..k]);
                    item.ssid_len = @intCast(k);
                    gr.p = e;
                } else gr.skip(vs);
            }
            gr.p = @max(gr.p, kend);
        }
        if (is_wifi and item.ssid_len > 0) {
            item.path = p.*;
            saved[nsaved] = item;
            nsaved += 1;
        }
    }
}

fn savedFor(ssid: []const u8) ?*const Saved {
    for (saved[0..nsaved]) |*s| {
        if (std.mem.eql(u8, s.ssid[0..s.ssid_len], ssid)) return s;
    }
    return null;
}

fn securityOf(flags: u32, wpa: u32, rsn: u32) Security {
    const km = wpa | rsn;
    if (km & 0x200 != 0 or km & 0x2000 != 0) return .eap; // 802.1X, Suite-B
    if (km & 0x100 != 0) return .psk; // PSK (including mixed PSK/SAE)
    if (km & 0x400 != 0) return .sae; // WPA3 Personal only
    if (km & 0x800 != 0) return .owe; // Enhanced Open
    if (flags & 1 != 0) return .wep;
    return .open;
}

/// Fill the list of visible networks (one per SSID, the strongest access point). Returns the count.
pub fn networks(out: []Net) usize {
    if (backend == .iwd) return iwd.networks(out);
    nets_changed = false;
    // active access point and the access point list in one batch, one wait instead of two
    var head = Head{};
    {
        var w = dbus.W{ .buf = &body_buf };
        w.str(WIFI);
        w.str("ActiveAccessPoint");
        var serials = [2]u32{
            bus.sendCall(NM, device.get(), PROPS, "Get", "ss", w.bytes()) catch 0,
            bus.sendCall(NM, device.get(), WIFI, "GetAllAccessPoints", "", "") catch 0,
        };
        if (serials[1] == 0) {
            setError("error talking to NetworkManager");
            return 0;
        }
        bus.collect(&serials, &head, gotHead) catch {
            setError("error talking to NetworkManager");
            return 0;
        };
    }
    if (!head.ok) return 0;
    const aps = head.aps[0..head.naps];
    const naps = head.naps;
    const active_ap = head.active;

    var n: usize = 0;
    var ctx = ApCtx{ .aps = aps, .out = out, .n = &n, .active = active_ap.get() };
    var start: usize = 0;
    while (start < naps) : (start += BATCH) {
        const stop = @min(naps, start + BATCH);
        var serials = @as([BATCH]u32, @splat(0));
        var w = dbus.W{ .buf = &body_buf };
        w.str(AP);
        for (aps[start..stop], 0..) |*ap, i| {
            serials[i] = bus.sendCall(NM, ap.get(), PROPS, "GetAll", "s", w.bytes()) catch 0;
        }
        ctx.base = start;
        bus.collect(serials[0 .. stop - start], &ctx, gotAp) catch {
            setError("error talking to NetworkManager");
            break;
        };
    }
    for (out[0..n]) |*net| {
        if (savedFor(net.ssid())) |sv| {
            net.known = true;
            net.conn = sv.path;
        }
    }
    // active on top, then by signal strength
    std.mem.sort(Net, out[0..n], {}, struct {
        fn lt(_: void, a: Net, b: Net) bool {
            if (a.active != b.active) return a.active;
            return a.strength > b.strength;
        }
    }.lt);
    return n;
}

const Head = struct { active: Path = .{}, aps: [96]Path = undefined, naps: usize = 0, ok: bool = false };

fn gotHead(h: *Head, i: usize, rep: dbus.Reply) void {
    if (!rep.ok()) {
        if (i == 1) setError(rep.message());
        return;
    }
    var r = rep.reader();
    if (i == 0) {
        if (std.mem.eql(u8, r.sig(), "o")) {
            const p = r.str();
            if (!r.bad) h.active.set(p);
        }
        return;
    }
    const end = r.arrayEnd(4);
    while (r.p < end and !r.bad and h.naps < h.aps.len) {
        h.aps[h.naps].set(r.str());
        h.naps += 1;
    }
    h.ok = !r.bad;
}

const ApCtx = struct { aps: []Path, out: []Net, n: *usize, active: []const u8, base: usize = 0 };

/// Properties of one access point → a list row (one per SSID, the strongest access point).
fn gotAp(ctx: *ApCtx, i: usize, props: dbus.Reply) void {
    if (!props.ok()) return;
    const ap = &ctx.aps[ctx.base + i];
    const out = ctx.out;
    const n = ctx.n.*;
    {
        var net = Net{ .ap = ap.* };
        var flags: u32 = 0;
        var wpa: u32 = 0;
        var rsn: u32 = 0;
        var pr = props.reader();
        const pend = pr.arrayEnd(8);
        while (pr.p < pend and !pr.bad) {
            pr.alignTo(8);
            const key = pr.str();
            const vs = pr.sig();
            const eql = std.mem.eql;
            if (eql(u8, key, "Ssid") and eql(u8, vs, "ay")) {
                const e = pr.arrayEnd(1);
                const bytes = pr.d[pr.p..e];
                const k = @min(bytes.len, 32);
                @memcpy(net.ssid_buf[0..k], bytes[0..k]);
                net.ssid_len = @intCast(k);
                pr.p = e;
            } else if (eql(u8, key, "Strength") and eql(u8, vs, "y")) {
                net.strength = pr.byte();
            } else if (eql(u8, key, "Flags") and eql(u8, vs, "u")) {
                flags = pr.u32_();
            } else if (eql(u8, key, "WpaFlags") and eql(u8, vs, "u")) {
                wpa = pr.u32_();
            } else if (eql(u8, key, "RsnFlags") and eql(u8, vs, "u")) {
                rsn = pr.u32_();
            } else pr.skip(vs);
        }
        if (pr.bad or net.ssid_len == 0) return; // hidden networks are not shown in the list
        net.sec = securityOf(flags, wpa, rsn);
        net.active = std.mem.eql(u8, ap.get(), ctx.active);

        // one row per SSID: keep the strongest access point (but the active one always)
        var dup: ?usize = null;
        for (out[0..n], 0..) |*o, k| {
            if (std.mem.eql(u8, o.ssid(), net.ssid())) dup = k;
        }
        if (dup) |d| {
            if (net.active or (!out[d].active and net.strength > out[d].strength)) out[d] = net;
            return;
        }
        if (n == out.len) return;
        out[n] = net;
        ctx.n.* = n + 1;
    }
}

// ================================================================= actions

/// Path of the active connection currently coming up (for tracking).
pub var activating: Path = .{};
/// Path of the saved profile we created (removed if the connection failed).
pub var created: Path = .{};

pub fn activateSaved(conn: []const u8, ap: []const u8) bool {
    if (backend == .iwd) return iwd.activateSaved(conn, ap);
    fail_reason = 0;
    var w = dbus.W{ .buf = &body_buf };
    w.str(conn);
    w.str(device.get());
    w.str(if (ap.len > 0) ap else "/");
    const rep = call(NM_PATH, NM, "ActivateConnection", "ooo", w.bytes()) orelse return false;
    var r = rep.reader();
    activating.set(r.str());
    created.len = 0;
    return true;
}

fn fileUri(buf: []u8, path: []const u8) []const u8 {
    // file:///absolute/path\0 ; "~/" is expanded to $HOME
    var p = path;
    var home: []const u8 = "";
    if (std.mem.startsWith(u8, p, "~/")) {
        home = sys.getenv("HOME") orelse "";
        p = p[1..];
    }
    const z = sys.joinZ(buf, &.{ "file://", home, p });
    return buf[0 .. z.len + 1]; // including the terminating zero
}

pub fn addAndActivate(spec: Spec, ap: []const u8) bool {
    if (backend == .iwd) return iwd.addAndActivate(spec, ap);
    fail_reason = 0;
    var w = dbus.W{ .buf = &body_buf };
    const top = w.arrayBegin(8);

    var g = w.groupBegin("connection");
    w.kvStr("type", "802-11-wireless");
    w.kvStr("id", spec.ssid);
    w.arrayEnd(g);

    g = w.groupBegin("802-11-wireless");
    w.kvBytes("ssid", spec.ssid);
    w.kvStr("mode", "infrastructure");
    if (spec.hidden) w.kvBool("hidden", true);
    w.arrayEnd(g);

    if (spec.sec != .open) {
        g = w.groupBegin("802-11-wireless-security");
        w.kvStr("key-mgmt", switch (spec.sec) {
            .psk => "wpa-psk",
            .sae => "sae",
            .owe => "owe",
            .eap => "wpa-eap",
            .wep, .open => "none",
        });
        if (spec.sec == .psk or spec.sec == .sae) w.kvStr("psk", spec.psk);
        w.arrayEnd(g);
    }

    if (spec.sec == .eap) {
        var b1: [600]u8 = undefined;
        var b2: [600]u8 = undefined;
        var b3: [600]u8 = undefined;
        g = w.groupBegin("802-1x");
        w.kvStrArray("eap", &.{switch (spec.eap) {
            .peap => "peap",
            .ttls => "ttls",
            .tls => "tls",
        }});
        if (spec.identity.len > 0) w.kvStr("identity", spec.identity);
        if (spec.anon_identity.len > 0) w.kvStr("anonymous-identity", spec.anon_identity);
        switch (spec.eap) {
            .peap, .ttls => {
                w.kvStr("password", spec.password);
                w.kvStr("phase2-auth", spec.phase2);
            },
            .tls => {
                w.kvBytes("client-cert", fileUri(&b1, spec.client_cert));
                // for .p12/.pfx the key is in the same file
                w.kvBytes("private-key", fileUri(&b2, if (spec.private_key.len > 0) spec.private_key else spec.client_cert));
                if (spec.key_password.len > 0) w.kvStr("private-key-password", spec.key_password);
            },
        }
        if (spec.ca_cert.len > 0) {
            w.kvBytes("ca-cert", fileUri(&b3, spec.ca_cert));
        } else if (spec.domain.len > 0) {
            w.kvBool("system-ca-certs", true);
        }
        if (spec.domain.len > 0) w.kvStr("domain-suffix-match", spec.domain);
        w.arrayEnd(g);
    }
    w.arrayEnd(top);
    w.str(device.get());
    w.str(if (ap.len > 0 and !spec.hidden) ap else "/");
    if (w.overflow) {
        setError("data is too long");
        return false;
    }
    const ok = blk: {
        const rep = call(NM_PATH, NM, "AddAndActivateConnection", "a{sa{sv}}oo", w.bytes()) orelse break :blk false;
        var r = rep.reader();
        created.set(r.str());
        activating.set(r.str());
        break :blk !r.bad;
    };
    // the buffers held passwords — wipe them right after sending
    secureZero(&body_buf);
    secureZero(bus.out);
    return ok;
}

pub const Progress = enum { working, done, failed };

/// State of the current connection. On error the reason is in lastError().
pub fn progress() Progress {
    if (backend == .iwd) return iwd.progress();
    if (activating.len == 0) return .failed;
    var p = getProp(activating.get(), ACTIVE, "State") orelse {
        // the object is gone — activation was canceled/failed
        failReason();
        return .failed;
    };
    if (!std.mem.eql(u8, p.sig, "u")) return .working;
    switch (p.r.u32_()) {
        2 => return .done, // ACTIVATED
        3, 4 => {
            failReason();
            return .failed;
        },
        else => return .working,
    }
}

fn failReason() void {
    var reason = fail_reason;
    if (reason == 0) {
        if (getProp(device.get(), DEV, "StateReason")) |p0| {
            var p = p0;
            p.r.alignTo(8);
            _ = p.r.u32_();
            reason = p.r.u32_();
        }
    }
    setError(switch (reason) {
        7, 8 => "Wrong password or login",
        9, 10 => "802.1X authentication error — check the method and certificates",
        11 => "The server did not respond to authentication",
        5, 6 => "Could not get an IP address",
        53 => "Network not found",
        else => "Could not connect",
    });
}

pub fn disconnect() bool {
    if (backend == .iwd) return iwd.disconnect();
    _ = call(device.get(), DEV, "Disconnect", "", "") orelse return false;
    return true;
}

pub fn forget(conn: []const u8) bool {
    if (backend == .iwd) return iwd.forget(conn);
    _ = call(conn, CONN, "Delete", "", "") orelse return false;
    return true;
}

/// Remove the profile we just created (if the connection failed).
pub fn dropCreated() void {
    if (backend == .iwd) return; // iwd saves a network only after it connected
    if (created.len > 0) _ = forget(created.get());
    created.len = 0;
}

pub const secureZero = sys.secureZero;
