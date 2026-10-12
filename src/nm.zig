// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Клиент NetworkManager поверх D-Bus: список сетей, подключение (открытые, WPA/WPA2/WPA3
//! Personal, OWE, 802.1X: PEAP, TTLS, EAP-TLS), отключение, «забыть сеть», вкл/выкл радио.
//! Сама аутентификация и шифрование выполняются системным демоном — пароли уходят ему по D-Bus.

const std = @import("std");
const sys = @import("sys.zig");
const dbus = @import("dbus.zig");

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
        std.mem.copyForwards(u8, p.buf[0..k], s[0..k]); // источник может быть этим же буфером
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
    conn: Path = .{}, // сохранённое подключение (если известна)
    strength: u8 = 0,
    sec: Security = .open,
    active: bool = false,
    known: bool = false,

    pub fn ssid(n: *const Net) []const u8 {
        return n.ssid_buf[0..n.ssid_len];
    }
};

pub const Eap = enum(u8) { peap, ttls, tls };

/// Что нужно для нового подключения.
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
pub var device: Path = .{};
pub var wifi_enabled: bool = true;
/// Текст последней ошибки (для показа пользователю).
pub var err_buf: [200]u8 = undefined;
pub var err_len: usize = 0;

var body_buf: [16 * 1024]u8 = undefined;

pub fn lastError() []const u8 {
    return err_buf[0..err_len];
}

fn setError(msg: []const u8) void {
    err_len = @min(msg.len, err_buf.len);
    @memcpy(err_buf[0..err_len], msg[0..err_len]);
}

fn call(path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) ?dbus.Reply {
    const r = bus.call(NM, path, iface, member, sig, body) catch |e| {
        setError(switch (e) {
            error.Timeout => "NetworkManager не отвечает",
            else => "ошибка связи с NetworkManager",
        });
        return null;
    };
    if (!r.ok()) {
        setError(r.message());
        return null;
    }
    return r;
}

/// Прочитать свойство: возвращает читатель, стоящий на значении, и его сигнатуру.
fn getProp(path: []const u8, iface: []const u8, name: []const u8) ?struct { r: dbus.R, sig: []const u8 } {
    var w = dbus.W{ .buf = &body_buf };
    w.str(iface);
    w.str(name);
    const rep = call(path, PROPS, "Get", "ss", w.bytes()) orelse return null;
    var r = rep.reader();
    const s = r.sig();
    return .{ .r = r, .sig = s };
}

fn getU32(path: []const u8, iface: []const u8, name: []const u8) ?u32 {
    var p = getProp(path, iface, name) orelse return null;
    if (!std.mem.eql(u8, p.sig, "u")) return null;
    return p.r.u32_();
}

fn getPath(path: []const u8, iface: []const u8, name: []const u8, out: *Path) bool {
    var p = getProp(path, iface, name) orelse return false;
    if (!std.mem.eql(u8, p.sig, "o")) return false;
    out.set(p.r.str());
    return !p.r.bad;
}

// ================================================================= инициализация

pub fn init() bool {
    bus.connectSystem() catch {
        setError("нет доступа к системной шине D-Bus");
        return false;
    };
    const rep = call(NM_PATH, NM, "GetDevices", "", "") orelse {
        setError("NetworkManager не запущен");
        return false;
    };
    // копируем пути: следующий вызов перезапишет буфер ответа
    var paths: [32]Path = undefined;
    var n: usize = 0;
    var r = rep.reader();
    const end = r.arrayEnd(4);
    while (r.p < end and !r.bad and n < paths.len) {
        paths[n].set(r.str());
        n += 1;
    }
    for (paths[0..n]) |*p| {
        if (getU32(p.get(), DEV, "DeviceType") == 2) { // NM_DEVICE_TYPE_WIFI
            device = p.*;
            break;
        }
    }
    if (device.len == 0) {
        setError("Wi‑Fi адаптер не найден");
        return false;
    }
    // подписка на смену состояния устройства: так не теряется причина неудачи
    var rule_buf: [400]u8 = undefined;
    const rule = sys.joinZ(&rule_buf, &.{ "type='signal',sender='", NM, "',interface='", DEV, "',member='StateChanged',path='", device.get(), "'" });
    var w = dbus.W{ .buf = &body_buf };
    w.str(rule);
    _ = bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", w.bytes()) catch {};
    bus.on_signal = onSignal;
    refreshEnabled();
    return true;
}

/// Последняя причина перехода устройства в FAILED (0 — не было).
var fail_reason: u32 = 0;

fn onSignal(iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) void {
    if (!std.mem.eql(u8, iface, DEV) or !std.mem.eql(u8, member, "StateChanged") or !std.mem.eql(u8, sig, "uuu")) return;
    var r = dbus.R{ .d = body };
    const new_state = r.u32_();
    _ = r.u32_();
    const reason = r.u32_();
    if (new_state == 120 and !r.bad) fail_reason = reason; // NM_DEVICE_STATE_FAILED
}

pub fn refreshEnabled() void {
    var p = getProp(NM_PATH, NM, "WirelessEnabled") orelse return;
    if (std.mem.eql(u8, p.sig, "b")) wifi_enabled = p.r.boolean();
}

pub fn setEnabled(on: bool) bool {
    var w = dbus.W{ .buf = &body_buf };
    w.str(NM);
    w.str("WirelessEnabled");
    w.sig("b");
    w.boolean(on);
    _ = call(NM_PATH, PROPS, "Set", "ssv", w.bytes()) orelse return false;
    wifi_enabled = on;
    return true;
}

pub fn scan() void {
    var w = dbus.W{ .buf = &body_buf };
    const a = w.arrayBegin(8); // пустой a{sv}
    w.arrayEnd(a);
    _ = call(device.get(), WIFI, "RequestScan", "a{sv}", w.bytes()); // «слишком часто» — не страшно
}

// ================================================================= список сетей

const Saved = struct { path: Path = .{}, ssid: [32]u8 = undefined, ssid_len: u8 = 0 };
var saved: [64]Saved = undefined;
var nsaved: usize = 0;

/// Перечитать сохранённые Wi‑Fi-подключения (путь + SSID).
pub fn loadSaved() void {
    nsaved = 0;
    const rep = call("/org/freedesktop/NetworkManager/Settings", SETTINGS, "ListConnections", "", "") orelse return;
    var paths: [128]Path = undefined;
    var n: usize = 0;
    var r = rep.reader();
    const end = r.arrayEnd(4);
    while (r.p < end and !r.bad and n < paths.len) {
        paths[n].set(r.str());
        n += 1;
    }
    for (paths[0..n]) |*p| {
        if (nsaved == saved.len) break;
        const s = call(p.get(), CONN, "GetSettings", "", "") orelse continue;
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
    if (km & 0x100 != 0) return .psk; // PSK (в т.ч. смешанный PSK/SAE)
    if (km & 0x400 != 0) return .sae; // только WPA3 Personal
    if (km & 0x800 != 0) return .owe; // Enhanced Open
    if (flags & 1 != 0) return .wep;
    return .open;
}

/// Заполнить список видимых сетей (по одной на SSID, самая сильная точка). Возвращает число.
pub fn networks(out: []Net) usize {
    var active_ap = Path{};
    _ = getPath(device.get(), WIFI, "ActiveAccessPoint", &active_ap);

    const rep = call(device.get(), WIFI, "GetAllAccessPoints", "", "") orelse return 0;
    var aps: [96]Path = undefined;
    var naps: usize = 0;
    var r = rep.reader();
    const end = r.arrayEnd(4);
    while (r.p < end and !r.bad and naps < aps.len) {
        aps[naps].set(r.str());
        naps += 1;
    }

    var n: usize = 0;
    for (aps[0..naps]) |*ap| {
        var w = dbus.W{ .buf = &body_buf };
        w.str(AP);
        const props = call(ap.get(), PROPS, "GetAll", "s", w.bytes()) orelse continue;
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
        if (pr.bad or net.ssid_len == 0) continue; // скрытые сети в списке не показываем
        net.sec = securityOf(flags, wpa, rsn);
        net.active = std.mem.eql(u8, ap.get(), active_ap.get());

        // одна строка на SSID: оставляем самую сильную точку (но активную — всегда)
        var dup: ?usize = null;
        for (out[0..n], 0..) |*o, i| {
            if (std.mem.eql(u8, o.ssid(), net.ssid())) dup = i;
        }
        if (dup) |i| {
            if (net.active or (!out[i].active and net.strength > out[i].strength)) out[i] = net;
            continue;
        }
        if (n == out.len) continue;
        out[n] = net;
        n += 1;
    }
    for (out[0..n]) |*net| {
        if (savedFor(net.ssid())) |s| {
            net.known = true;
            net.conn = s.path;
        }
    }
    // активная сверху, затем по силе сигнала
    std.mem.sort(Net, out[0..n], {}, struct {
        fn lt(_: void, a: Net, b: Net) bool {
            if (a.active != b.active) return a.active;
            return a.strength > b.strength;
        }
    }.lt);
    return n;
}

// ================================================================= действия

/// Путь активного подключения, которое сейчас поднимается (для отслеживания).
pub var activating: Path = .{};
/// Путь сохранённого профиля, созданного нами (удаляется, если подключиться не удалось).
pub var created: Path = .{};

pub fn activateSaved(conn: []const u8, ap: []const u8) bool {
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
    // file:///абсолютный/путь\0 ; "~/" раскрываем в $HOME
    var p = path;
    var home: []const u8 = "";
    if (std.mem.startsWith(u8, p, "~/")) {
        home = sys.getenv("HOME") orelse "";
        p = p[1..];
    }
    const z = sys.joinZ(buf, &.{ "file://", home, p });
    return buf[0 .. z.len + 1]; // вместе с завершающим нулём
}

pub fn addAndActivate(spec: Spec, ap: []const u8) bool {
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
                // для .p12/.pfx ключ лежит в том же файле
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
        setError("слишком длинные данные");
        return false;
    }
    const ok = blk: {
        const rep = call(NM_PATH, NM, "AddAndActivateConnection", "a{sa{sv}}oo", w.bytes()) orelse break :blk false;
        var r = rep.reader();
        created.set(r.str());
        activating.set(r.str());
        break :blk !r.bad;
    };
    // в буферах были пароли — затираем сразу после отправки
    secureZero(&body_buf);
    secureZero(&bus.out);
    return ok;
}

pub const Progress = enum { working, done, failed };

/// Состояние текущего подключения. При ошибке — причина в lastError().
pub fn progress() Progress {
    if (activating.len == 0) return .failed;
    var p = getProp(activating.get(), ACTIVE, "State") orelse {
        // объект исчез — активация отменена/провалена
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
        7, 8 => "Неверный пароль или логин",
        9, 10 => "Ошибка аутентификации 802.1X — проверьте метод и сертификаты",
        11 => "Сервер не ответил на аутентификацию",
        5, 6 => "Не удалось получить IP-адрес",
        53 => "Сеть не найдена",
        else => "Не удалось подключиться",
    });
}

pub fn disconnect() bool {
    _ = call(device.get(), DEV, "Disconnect", "", "") orelse return false;
    return true;
}

pub fn forget(conn: []const u8) bool {
    _ = call(conn, CONN, "Delete", "", "") orelse return false;
    return true;
}

/// Удалить профиль, который мы только что создали (если подключение не удалось).
pub fn dropCreated() void {
    if (created.len > 0) _ = forget(created.get());
    created.len = 0;
}

pub const secureZero = sys.secureZero;
