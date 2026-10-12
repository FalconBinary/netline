// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Клиент BlueZ поверх D-Bus: адаптер, устройства, подключение, сопряжение и свой агент
//! сопряжения (подтверждение кода, ввод PIN). Радио и протоколы — у системного bluetoothd.

const std = @import("std");
const sys = @import("sys.zig");
const dbus = @import("dbus.zig");

const BZ = "org.bluez";
const OM = "org.freedesktop.DBus.ObjectManager";
const PROPS = "org.freedesktop.DBus.Properties";
const ADAPTER = "org.bluez.Adapter1";
const DEVICE = "org.bluez.Device1";
const BATTERY = "org.bluez.Battery1";
const AGENT_MGR = "org.bluez.AgentManager1";
const AGENT = "org.bluez.Agent1";
pub const AGENT_PATH = "/org/zpanel/agent";

pub const Path = struct {
    buf: [96]u8 = undefined,
    len: u8 = 0,

    pub fn set(p: *Path, s: []const u8) void {
        const k = @min(s.len, p.buf.len);
        std.mem.copyForwards(u8, p.buf[0..k], s[0..k]); // источник может быть этим же буфером
        p.len = @intCast(k);
    }
    pub fn get(p: *const Path) []const u8 {
        return p.buf[0..p.len];
    }
    pub fn eql(p: *const Path, s: []const u8) bool {
        return std.mem.eql(u8, p.get(), s);
    }
};

pub const Kind = enum(u8) { generic, headphones, speaker, keyboard, mouse, gamepad, phone, computer };

pub const Dev = struct {
    path: Path = .{},
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    has_name: bool = false, // настоящее имя, а не адрес
    kind: Kind = .generic,
    paired: bool = false,
    trusted: bool = false,
    connected: bool = false,
    battery: u8 = 255, // 255 — неизвестно
    rssi: i16 = -32768, // нет данных
    // для `zbt scan`
    random: bool = false, // случайный BLE-адрес (телефоны, часы, метки)
    classic: bool = false, // есть класс устройства — значит, найдено как классическое (BR/EDR)
    maker: u16 = 0xffff, // производитель из рекламы BLE, 0xffff — нет

    pub fn name(d: *const Dev) []const u8 {
        return d.name_buf[0..d.name_len];
    }
};

pub var bus: dbus.Conn = .{};
pub var adapter: Path = .{};
pub var powered = false;
pub var discovering = false;
/// пришёл сигнал от bluetoothd — список стоит перечитать
pub var changed = false;
/// отдавать из refresh все устройства, в том числе безымянные (для `zbt scan`)
pub var keep_all = false;

var owner_buf: [64]u8 = undefined;
var owner_len: usize = 0;
var rfkill_fd: i32 = -1;

var err_buf: [200]u8 = undefined;
var err_len: usize = 0;
var body_buf: [4096]u8 = undefined;

pub fn lastError() []const u8 {
    return err_buf[0..err_len];
}

fn setError(m: []const u8) void {
    err_len = @min(m.len, err_buf.len);
    @memcpy(err_buf[0..err_len], m[0..err_len]);
}

fn call(path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) ?dbus.Reply {
    const r = bus.call(BZ, path, iface, member, sig, body) catch |e| {
        setError(switch (e) {
            error.Timeout => "bluetoothd не отвечает",
            else => "ошибка связи с bluetoothd",
        });
        return null;
    };
    if (!r.ok()) {
        setError(friendly(r.err_name, r.message()));
        return null;
    }
    return r;
}

// ================================================================= запуск

/// Подключиться к системной шине и bluetoothd. /dev/rfkill открывается заранее —
/// чтобы снимать программную блокировку без утилиты rfkill (и уже в песочнице).
pub fn init() bool {
    rfkill_fd = sys.openRW("/dev/rfkill") catch -1;
    bus.connectSystem() catch {
        setError("нет доступа к системной шине D-Bus");
        return false;
    };
    var w = dbus.W{ .buf = &body_buf };
    w.str(BZ);
    const r = bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", w.bytes()) catch {
        setError("ошибка связи с D-Bus");
        return false;
    };
    if (!r.ok()) {
        setError("Служба Bluetooth (bluetoothd) не запущена");
        return false;
    }
    var rr = r.reader();
    const o = rr.str();
    owner_len = @min(o.len, owner_buf.len);
    @memcpy(owner_buf[0..owner_len], o[0..owner_len]);

    w = .{ .buf = &body_buf };
    w.str("type='signal',sender='org.bluez'");
    _ = bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", w.bytes()) catch {};
    bus.on_signal = onSignal;
    return true;
}

fn onSignal(iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) void {
    _ = iface;
    _ = member;
    _ = sig;
    _ = body;
    changed = true;
}

/// Зарегистрировать наш агент сопряжения (только для сопряжений, которые начали мы).
pub fn registerAgent() bool {
    var w = dbus.W{ .buf = &body_buf };
    w.str(AGENT_PATH);
    w.str("KeyboardDisplay");
    bus.on_method = onMethod;
    _ = call("/org/bluez", AGENT_MGR, "RegisterAgent", "os", w.bytes()) orelse return false;
    return true;
}

// ================================================================= устройства

fn kindOf(icon: []const u8) Kind {
    const eql = std.mem.eql;
    if (eql(u8, icon, "audio-headset") or eql(u8, icon, "audio-headphones")) return .headphones;
    if (std.mem.startsWith(u8, icon, "audio")) return .speaker;
    if (eql(u8, icon, "input-keyboard")) return .keyboard;
    if (eql(u8, icon, "input-mouse") or eql(u8, icon, "input-tablet")) return .mouse;
    if (eql(u8, icon, "input-gaming")) return .gamepad;
    if (eql(u8, icon, "phone")) return .phone;
    if (eql(u8, icon, "computer")) return .computer;
    return .generic;
}

/// Перечитать адаптер и устройства (GetManagedObjects). Возвращает число устройств.
pub fn refresh(out: []Dev) usize {
    changed = false;
    const rep = call("/", OM, "GetManagedObjects", "", "") orelse return 0;
    var r = rep.reader();
    const end = r.arrayEnd(8);
    var n: usize = 0;
    var found_adapter = false;
    var ad = Path{};
    var ad_powered = false;
    var ad_disc = false;
    const eql = std.mem.eql;
    while (r.p < end and !r.bad) {
        r.alignTo(8);
        const path = r.str();
        const iend = r.arrayEnd(8);
        var d = Dev{};
        d.path.set(path);
        var is_dev = false;
        var is_ad = false;
        var p_powered = false;
        var p_disc = false;
        var alias: []const u8 = "";
        var nm: []const u8 = "";
        while (r.p < iend and !r.bad) {
            r.alignTo(8);
            const iface = r.str();
            const pend = r.arrayEnd(8);
            const which: u8 = if (eql(u8, iface, DEVICE)) 1 else if (eql(u8, iface, ADAPTER)) 2 else if (eql(u8, iface, BATTERY)) 3 else 0;
            if (which == 1) is_dev = true;
            if (which == 2) is_ad = true;
            while (r.p < pend and !r.bad) {
                r.alignTo(8);
                const key = r.str();
                const vs = r.sig();
                const vt = if (vs.len == 1) vs[0] else 0;
                if (which == 1 and vt == 's' and eql(u8, key, "Alias")) {
                    alias = r.str();
                } else if (which == 1 and vt == 's' and eql(u8, key, "Name")) {
                    nm = r.str();
                } else if (which == 1 and vt == 's' and eql(u8, key, "Icon")) {
                    d.kind = kindOf(r.str());
                } else if (which == 1 and vt == 'b' and eql(u8, key, "Paired")) {
                    d.paired = d.paired or r.boolean();
                } else if (which == 1 and vt == 'b' and eql(u8, key, "Bonded")) {
                    d.paired = d.paired or r.boolean();
                } else if (which == 1 and vt == 'b' and eql(u8, key, "Trusted")) {
                    d.trusted = r.boolean();
                } else if (which == 1 and vt == 'b' and eql(u8, key, "Connected")) {
                    d.connected = r.boolean();
                } else if (which == 1 and vt == 'n' and eql(u8, key, "RSSI")) {
                    d.rssi = @bitCast(r.u16_());
                } else if (which == 1 and vt == 's' and eql(u8, key, "AddressType")) {
                    d.random = eql(u8, r.str(), "random");
                } else if (which == 1 and vt == 'u' and eql(u8, key, "Class")) {
                    _ = r.u32_();
                    d.classic = true;
                } else if (which == 1 and eql(u8, vs, "a{qv}") and eql(u8, key, "ManufacturerData")) {
                    const mend = r.arrayEnd(8);
                    if (r.p < mend) {
                        r.alignTo(8);
                        d.maker = r.u16_();
                    }
                    r.p = @max(r.p, mend);
                } else if (which == 2 and vt == 'b' and eql(u8, key, "Powered")) {
                    p_powered = r.boolean();
                } else if (which == 2 and vt == 'b' and eql(u8, key, "Discovering")) {
                    p_disc = r.boolean();
                } else if (which == 3 and vt == 'y' and eql(u8, key, "Percentage")) {
                    d.battery = @min(r.byte(), 100);
                } else r.skip(vs);
            }
            r.p = @max(r.p, pend);
        }
        r.p = @max(r.p, iend);
        if (is_ad and !found_adapter) {
            found_adapter = true;
            ad.set(path);
            ad_powered = p_powered;
            ad_disc = p_disc;
        }
        // Во время поиска bluetoothd копит десятки безымянных BLE-устройств (телефоны со
        // случайными адресами, метки, телевизоры). Их отбрасываем сразу, чтобы они не
        // вытеснили из списка нужные: оставляем сопряжённые, с именем или с известным типом.
        const useful = keep_all or d.paired or nm.len > 0 or d.kind != .generic;
        if (is_dev and useful and n < out.len) {
            const label = if (alias.len > 0) alias else nm;
            d.has_name = nm.len > 0;
            d.name_len = @intCast(@min(label.len, d.name_buf.len));
            @memcpy(d.name_buf[0..d.name_len], label[0..d.name_len]);
            out[n] = d;
            n += 1;
        }
    }
    if (r.bad) {
        setError("неверный ответ bluetoothd");
        return 0;
    }
    adapter = ad;
    powered = ad_powered;
    discovering = ad_disc;
    if (!found_adapter) {
        setError("Адаптер Bluetooth не найден");
        return 0;
    }
    // только устройства нашего адаптера: /org/bluez/hci0/dev_...
    var k: usize = 0;
    for (out[0..n]) |d| {
        const p = d.path.get();
        if (p.len > ad.len and std.mem.startsWith(u8, p, ad.get()) and p[ad.len] == '/') {
            out[k] = d;
            k += 1;
        }
    }
    return k;
}

// ================================================================= действия

/// Снять программную блокировку Bluetooth (как `rfkill unblock bluetooth`).
fn rfkillUnblock() void {
    if (rfkill_fd < 0) return;
    // struct rfkill_event { u32 idx; u8 type; u8 op; u8 soft; u8 hard; }
    const ev = [8]u8{ 0, 0, 0, 0, 2, 3, 0, 0 }; // RFKILL_TYPE_BLUETOOTH, RFKILL_OP_CHANGE_ALL, soft=0
    _ = sys.write(rfkill_fd, &ev) catch {};
}

fn setBool(path: []const u8, iface: []const u8, name: []const u8, v: bool) bool {
    var w = dbus.W{ .buf = &body_buf };
    w.str(iface);
    w.str(name);
    w.sig("b");
    w.boolean(v);
    _ = call(path, PROPS, "Set", "ssv", w.bytes()) orelse return false;
    return true;
}

pub fn setPowered(on: bool) bool {
    if (adapter.len == 0) {
        setError("Адаптер Bluetooth не найден");
        return false;
    }
    if (on) rfkillUnblock();
    // после снятия rfkill адаптеру нужно мгновение, чтобы стать доступным
    var attempt: u32 = 0;
    while (attempt < 8) : (attempt += 1) {
        if (setBool(adapter.get(), ADAPTER, "Powered", on)) {
            powered = on;
            return true;
        }
        if (!on) return false;
        var none = [0]sys.PollFd{};
        _ = sys.poll(&none, 250) catch {};
    }
    return false;
}

/// Начать поиск. «Уже идёт» — не ошибка; иначе false и текст в lastError.
pub fn startDiscovery() bool {
    const r = bus.call(BZ, adapter.get(), ADAPTER, "StartDiscovery", "", "") catch {
        setError("ошибка связи с bluetoothd");
        return false;
    };
    if (r.ok() or std.mem.endsWith(u8, r.err_name, "InProgress")) return true;
    setError(friendly(r.err_name, r.message()));
    return false;
}

pub fn stopDiscovery() void {
    _ = bus.call(BZ, adapter.get(), ADAPTER, "StopDiscovery", "", "") catch {};
}

fn devCall(path: []const u8, member: []const u8) ?u32 {
    return bus.callAsync(BZ, path, DEVICE, member, "", "") catch {
        setError("ошибка связи с bluetoothd");
        return null;
    };
}

pub fn connect(dev: []const u8) ?u32 {
    return devCall(dev, "Connect");
}

pub fn disconnect(dev: []const u8) ?u32 {
    return devCall(dev, "Disconnect");
}

pub fn pair(dev: []const u8) ?u32 {
    return devCall(dev, "Pair");
}

pub fn cancelPairing(dev: []const u8) void {
    _ = devCall(dev, "CancelPairing");
}

pub fn trust(dev: []const u8) void {
    _ = setBool(dev, DEVICE, "Trusted", true);
}

pub fn remove(dev: []const u8) bool {
    var w = dbus.W{ .buf = &body_buf };
    w.str(dev);
    _ = call(adapter.get(), ADAPTER, "RemoveDevice", "o", w.bytes()) orelse return false;
    return true;
}

/// Понятный текст по ошибке BlueZ.
pub fn friendly(name: []const u8, text: []const u8) []const u8 {
    const has = struct {
        fn f(s: []const u8, sub: []const u8) bool {
            return std.mem.indexOf(u8, s, sub) != null;
        }
    }.f;
    if (has(text, "page-timeout") or has(text, "Page Timeout") or has(text, "Host is down") or has(text, "le-connection-abort"))
        return "Устройство не отвечает — включите его и поднесите ближе";
    if (has(name, "AuthenticationCanceled")) return "Сопряжение отменено";
    if (has(name, "AuthenticationRejected") or has(name, "AuthenticationFailed")) return "Сопряжение отклонено — проверьте код";
    if (has(name, "AuthenticationTimeout")) return "Время ожидания истекло";
    if (has(name, "ConnectionAttemptFailed")) return "Не удалось подключиться";
    if (has(name, "AlreadyExists")) return "Устройство уже сопряжено";
    if (has(name, "InProgress")) return "Операция уже выполняется";
    if (has(name, "NotReady")) return "Адаптер не готов";
    if (has(name, "Blocked") or has(text, "rfkill")) return "Bluetooth заблокирован (rfkill)";
    if (has(name, "NotAvailable") or has(text, "profile-unavailable")) return "Устройство не поддерживает нужный профиль";
    if (has(name, "AccessDenied") or has(name, "NotAuthorized")) return "Нет прав — проверьте политику polkit/D-Bus";
    if (text.len > 0) return text;
    return name;
}

// ================================================================= агент сопряжения

pub const ReqKind = enum { none, confirm, authorize, ask_pin, ask_passkey, show_passkey, show_pin };

pub const Req = struct {
    kind: ReqKind = .none,
    serial: u32 = 0,
    flags: u8 = 0,
    sender_buf: [64]u8 = undefined,
    sender_len: usize = 0,
    device: Path = .{},
    passkey: u32 = 0,
    entered: u16 = 0,
    pin_buf: [17]u8 = undefined,
    pin_len: usize = 0,

    pub fn pin(q: *const Req) []const u8 {
        return q.pin_buf[0..q.pin_len];
    }
    fn deferred(q: *const Req) bool {
        return switch (q.kind) {
            .confirm, .authorize, .ask_pin, .ask_passkey => true,
            else => false,
        };
    }
};

pub var req: Req = .{};
/// агент получил запрос или отмену — экран нужно перерисовать
pub var req_changed = false;

fn incoming(q: *const Req, sender: []const u8) dbus.Incoming {
    return .{ .serial = q.serial, .flags = q.flags, .sender = sender, .path = AGENT_PATH, .iface = AGENT, .member = "", .sig = "", .body = "" };
}

/// Отклонить отложенный запрос (если он есть).
pub fn rejectPending() void {
    if (!req.deferred()) {
        req.kind = .none;
        return;
    }
    const m = incoming(&req, req.sender_buf[0..req.sender_len]);
    bus.replyError(&m, "org.bluez.Error.Rejected", "отклонено пользователем");
    req.kind = .none;
}

/// Ответ пользователя на запрос агента. Для ask_pin/ask_passkey — введённое значение.
pub fn answer(accept: bool, value: []const u8) void {
    if (!req.deferred()) return;
    const m = incoming(&req, req.sender_buf[0..req.sender_len]);
    if (!accept) {
        bus.replyError(&m, "org.bluez.Error.Rejected", "отклонено пользователем");
    } else switch (req.kind) {
        .ask_pin => {
            var w = dbus.W{ .buf = &body_buf };
            w.str(value);
            bus.reply(&m, "s", w.bytes());
            sys.secureZero(&body_buf);
        },
        .ask_passkey => {
            const v = std.fmt.parseInt(u32, value, 10) catch 0;
            var w = dbus.W{ .buf = &body_buf };
            w.u32_(@min(v, 999999));
            bus.reply(&m, "u", w.bytes());
        },
        else => bus.reply(&m, "", ""),
    }
    req.kind = .none;
}

fn onMethod(c: *dbus.Conn, m: *const dbus.Incoming) void {
    const eql = std.mem.eql;
    if (!eql(u8, m.path, AGENT_PATH) or !eql(u8, m.iface, AGENT)) {
        return c.replyError(m, "org.freedesktop.DBus.Error.UnknownObject", "нет такого объекта");
    }
    // отвечаем только самому bluetoothd
    if (!eql(u8, m.sender, owner_buf[0..owner_len])) {
        return c.replyError(m, "org.freedesktop.DBus.Error.AccessDenied", "доступ запрещён");
    }
    var r = m.reader();
    const mem = m.member;
    if (eql(u8, mem, "Release") or eql(u8, mem, "AuthorizeService")) return c.reply(m, "", "");
    if (eql(u8, mem, "Cancel")) {
        req.kind = .none;
        req_changed = true;
        return c.reply(m, "", "");
    }
    // новый запрос вытесняет старый (старый отклоняем)
    rejectPending();
    var q = Req{ .serial = m.serial, .flags = m.flags };
    q.sender_len = @min(m.sender.len, q.sender_buf.len);
    @memcpy(q.sender_buf[0..q.sender_len], m.sender[0..q.sender_len]);
    if (eql(u8, mem, "DisplayPasskey") and eql(u8, m.sig, "ouq")) {
        q.device.set(r.str());
        q.passkey = r.u32_();
        q.entered = r.u16_();
        q.kind = .show_passkey;
        c.reply(m, "", "");
    } else if (eql(u8, mem, "DisplayPinCode") and eql(u8, m.sig, "os")) {
        q.device.set(r.str());
        const p = r.str();
        q.pin_len = @min(p.len, q.pin_buf.len);
        @memcpy(q.pin_buf[0..q.pin_len], p[0..q.pin_len]);
        q.kind = .show_pin;
        c.reply(m, "", "");
    } else if (eql(u8, mem, "RequestConfirmation") and eql(u8, m.sig, "ou")) {
        q.device.set(r.str());
        q.passkey = r.u32_();
        q.kind = .confirm;
    } else if (eql(u8, mem, "RequestAuthorization") and eql(u8, m.sig, "o")) {
        q.device.set(r.str());
        q.kind = .authorize;
    } else if (eql(u8, mem, "RequestPinCode") and eql(u8, m.sig, "o")) {
        q.device.set(r.str());
        q.kind = .ask_pin;
    } else if (eql(u8, mem, "RequestPasskey") and eql(u8, m.sig, "o")) {
        q.device.set(r.str());
        q.kind = .ask_passkey;
    } else {
        return c.replyError(m, "org.bluez.Error.Rejected", "не поддерживается");
    }
    if (r.bad) {
        q.kind = .none;
        return c.replyError(m, "org.bluez.Error.Rejected", "неверные аргументы");
    }
    req = q;
    req_changed = true;
}
