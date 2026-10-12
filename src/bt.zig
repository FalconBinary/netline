// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zbt — меню Bluetooth для zpanel на чистом Zig.
//!
//! Сопряжённые устройства (подключить, отключить, забыть), поиск и сопряжение новых
//! со своим агентом (подтверждение кода, ввод PIN), заряд батареи, включение адаптера.
//! Работает с bluetoothd по D-Bus. `zbt toggle` — включить/выключить Bluetooth без окна,
//! `zbt scan` — поискать устройства и вывести всё, что видит bluetoothd (для диагностики).

const std = @import("std");
const sys = @import("sys.zig");
const draw = @import("draw.zig");
const theme = @import("theme.zig");
const cfg = @import("config.zig");
const bz = @import("bz.zig");
const ui = @import("ui.zig");
const rt = @import("rt.zig");

pub const panic = rt.panic;
pub const std_options = rt.std_options;

const PAD = ui.PAD;
const ROW_H: f32 = 52;
const LIST_Y: f32 = 62;

const View = enum { list, add, actions, pairing, done };
var view: View = .list;

var devs: [128]bz.Dev = undefined;
var ndev: usize = 0;
var shown: [128]u8 = undefined; // индексы devs в текущем списке
var list: ui.List = .{};
var target: bz.Dev = .{};
var ok = false;
var ticks: u32 = 0;
var timer_on = false;

const OpKind = enum { none, connect, disconnect, pair, connect_after_pair, ignore };
var op: OpKind = .none;
var op_serial: u32 = 0;
var op_dev: bz.Path = .{};

var pin_field: ui.Field = .{};

/// PIN, которые пробуем сами для старых устройств без экрана и клавиатуры (наушники, колонки, мыши):
/// у них PIN зашит, и почти всегда это 0000 или 1234. Не подошли — спросим у пользователя.
const auto_pins = [_][]const u8{ "0000", "1234" };
var pin_try: usize = 0;
var pin_dev: bz.Path = .{};

const Wid = enum(u8) { none, row, more, toggle, back, add, primary, secondary, act_conn, act_forget, field };

fn wid(w: ui.Widget) Wid {
    return @enumFromInt(w.id);
}

// ================================================================= запуск

pub fn main(init: std.process.Init.Minimal) void {
    sys.init(init);
    if (sys.argIs(1, "toggle")) {
        if (!bz.init()) fatalCli();
        _ = bz.refresh(&devs);
        if (bz.adapter.len == 0 or !bz.setPowered(!bz.powered)) fatalCli();
        sys.exit(0);
    }
    if (sys.argIs(1, "scan")) scanCli();
    ui.begin("zbt");
    ok = bz.init();
    if (!ok) ui.setMsg(bz.lastError());
    ui.run(.{
        .width = cfg.menu_width,
        .height = cfg.menu_height,
        .layout = layout,
        .paint = paint,
        .activate = activate,
        .back = goBack,
        .submit = submit,
        .key = onKey,
        .scroll = onScroll,
        .tick = onTick,
        .field = fieldAt,
        .extra_fd = busFd,
        .on_extra = onBus,
        .start = start,
        .cleanup = cleanup,
    }, .{}, .{});
}

fn fatalCli() noreturn {
    sys.log("{s}", .{bz.lastError()});
    sys.exit(1);
}

/// `zbt scan`: 10 секунд поиска и полный список устройств, которые видит bluetoothd.
fn scanCli() noreturn {
    if (!bz.init()) fatalCli();
    bz.keep_all = true;
    _ = bz.refresh(&devs);
    if (bz.adapter.len == 0) fatalCli();
    sys.log("адаптер {s}: {s}", .{ bz.adapter.get(), if (bz.powered) "включён" else "ВЫКЛЮЧЕН — включите Bluetooth" });
    if (!bz.powered) sys.exit(1);
    if (!bz.startDiscovery()) {
        sys.log("поиск не запустился: {s}", .{bz.lastError()});
        sys.exit(1);
    }
    sys.log("поиск 10 секунд...", .{});
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        var pfd = [1]sys.PollFd{.{ .fd = bz.bus.fd, .events = sys.POLLIN }};
        _ = sys.poll(&pfd, 500) catch {};
        bz.bus.pump() catch break;
    }
    const n = bz.refresh(&devs);
    bz.stopDiscovery();
    var named: usize = 0;
    for (devs[0..n]) |*d| {
        if (d.has_name or d.paired or d.kind != .generic) named += 1;
        const rssi: i32 = d.rssi;
        sys.log("{s}  {s}  {s}{s}rssi {d}", .{
            d.path.get()[bz.adapter.len..],
            d.name(),
            kindLabel(d.kind),
            if (d.paired) ", сопряжено, " else ", ",
            rssi,
        });
    }
    sys.log("всего {d}, из них показываются в меню: {d}", .{ n, named });
    sys.exit(0);
}

fn start() void {
    list.visible = @intFromFloat((ui.H() - LIST_Y - 64) / ROW_H);
    if (!ok) return;
    if (!bz.registerAgent()) sys.log("агент сопряжения не зарегистрирован: {s}", .{bz.lastError()});
    refresh();
    if (bz.adapter.len == 0) {
        ok = false;
        ui.setMsg(bz.lastError());
    }
}

fn cleanup() void {
    pin_field.clear();
    if (ok and view == .add) bz.stopDiscovery();
    if (ok) bz.rejectPending();
}

fn busFd() i32 {
    return if (ok) bz.bus.fd else -1;
}

fn fieldAt(idx: u16) ?*ui.Field {
    _ = idx;
    return &pin_field;
}

// ================================================================= данные

fn lessPaired(_: void, a: u8, b: u8) bool {
    const x = &devs[a];
    const y = &devs[b];
    if (x.connected != y.connected) return x.connected;
    return std.mem.order(u8, x.name(), y.name()) == .lt;
}

fn lessFound(_: void, a: u8, b: u8) bool {
    return devs[a].rssi > devs[b].rssi;
}

fn refresh() void {
    ndev = bz.refresh(&devs);
    var n: usize = 0;
    for (devs[0..ndev], 0..) |*d, i| {
        const want = switch (view) {
            // имя у классических устройств приходит не сразу, а тип (наушники и т. п.) — уже с первым ответом
            .add, .pairing => !d.paired and (d.has_name or d.kind != .generic),
            else => d.paired,
        };
        if (want) {
            shown[n] = @intCast(i);
            n += 1;
        }
    }
    if (view == .add or view == .pairing) {
        std.mem.sort(u8, shown[0..n], {}, lessFound);
    } else std.mem.sort(u8, shown[0..n], {}, lessPaired);
    list.setCount(n);
    // свежие данные о выбранном устройстве (статус в «Действиях»)
    for (devs[0..ndev]) |*d| {
        if (d.path.eql(target.path.get())) target = d.*;
    }
    ui.redraw();
}

fn devAt(row: usize) *bz.Dev {
    return &devs[shown[row]];
}

fn busy(path: []const u8) bool {
    return (op == .connect or op == .disconnect or op == .connect_after_pair) and op_dev.eql(path);
}

// ================================================================= таймер и события

fn armTimer() void {
    const want = switch (view) {
        .add, .pairing => true,
        .list => op != .none and op != .ignore,
        else => false,
    };
    if (view == .done) {
        ui.setTimer(900, 0);
        timer_on = true;
    } else if (want and !timer_on) {
        ui.setTimer(350, 350);
        timer_on = true;
    } else if (!want and timer_on) {
        ui.setTimer(0, 0);
        timer_on = false;
    }
}

fn onTick() void {
    ticks +%= 1;
    if (view == .done) return ui.quit();
    // Синхронный вызов мог дочитать из сокета сигналы и запросы агента сверх своего ответа:
    // они лежат в буфере, а сокет уже не «готов к чтению» — разбираем их здесь.
    if (ok) pumpBus();
    if (bz.changed) refresh();
    ui.redraw(); // анимация точек
}

fn onBus() void {
    pumpBus();
    // в простое (таймер выключен) обновляемся сразу по сигналу
    if (ok and bz.changed and !timer_on) refresh();
}

fn pumpBus() void {
    bz.bus.pump() catch {
        ok = false;
        ui.setMsg("связь с bluetoothd потеряна");
        return;
    };
    checkOp();
    if (bz.req_changed) {
        bz.req_changed = false;
        if (view == .pairing and !autoAnswer()) ui.resetFocus(true);
        ui.redraw();
    }
}

/// Устройства, на которых нечего показывать и некуда вводить код.
fn noScreen(k: bz.Kind) bool {
    return switch (k) {
        .headphones, .speaker, .mouse, .gamepad => true,
        else => false,
    };
}

/// Ответить агенту самим, если пользователю нечего сравнивать или вводить:
/// подтверждение для устройств без экрана и стандартные PIN для старых устройств.
fn autoAnswer() bool {
    // только запросы от устройства, которое пользователь сам выбрал для сопряжения
    if (!bz.req.device.eql(target.path.get())) return false;
    switch (bz.req.kind) {
        // «Just Works»: кода нет, сравнивать нечего, а сопряжение пользователь уже начал сам
        .authorize => {
            bz.answer(true, "");
            return true;
        },
        .confirm => if (noScreen(target.kind)) {
            bz.answer(true, "");
            return true;
        },
        .ask_pin => if ((noScreen(target.kind) or target.kind == .generic) and pin_try < auto_pins.len) {
            bz.answer(true, auto_pins[pin_try]);
            pin_try += 1;
            return true;
        },
        else => {},
    }
    return false;
}

fn startOp(kind: OpKind, serial: ?u32, dev: []const u8) void {
    const s = serial orelse return ui.setMsg(bz.lastError());
    op = kind;
    op_serial = s;
    op_dev.set(dev);
    ui.clearMsg();
    armTimer();
}

fn checkOp() void {
    if (op == .none) return;
    const d = bz.bus.result(op_serial) orelse return;
    const kind = op;
    op = .none;
    switch (kind) {
        .ignore, .none => {},
        .connect, .disconnect => {
            if (!d.ok and !std.mem.endsWith(u8, d.errName(), "AlreadyConnected")) ui.setMsg(bz.friendly(d.errName(), d.message()));
            refresh();
        },
        .pair => {
            if (d.ok) {
                // сопряжено: доверяем (чтобы переподключалось само) и подключаемся
                bz.trust(op_dev.get());
                startOp(.connect_after_pair, bz.connect(op_dev.get()), op_dev.get());
            } else {
                bz.req.kind = .none;
                const auth = std.mem.endsWith(u8, d.errName(), "AuthenticationFailed") or std.mem.endsWith(u8, d.errName(), "AuthenticationRejected");
                // стандартный PIN не подошёл — пробуем следующий, не выходя с экрана сопряжения
                if (auth and pin_try > 0 and pin_try < auto_pins.len) {
                    startOp(.pair, bz.pair(op_dev.get()), op_dev.get());
                    if (op == .pair) return;
                }
                setView(.add);
                if (auth and pin_try >= auto_pins.len) {
                    ui.setMsg("PIN 0000 и 1234 не подошли — выберите устройство ещё раз и введите PIN");
                } else ui.setMsg(bz.friendly(d.errName(), d.message()));
            }
        },
        .connect_after_pair => {
            if (d.ok or std.mem.endsWith(u8, d.errName(), "AlreadyConnected")) {
                setView(.done);
            } else {
                setView(.list);
                ui.setMsg(bz.friendly(d.errName(), d.message()));
            }
        },
    }
    armTimer();
}

// ================================================================= переходы

fn setView(v: View) void {
    const was = view;
    view = v;
    ui.clearMsg();
    if (ok and v == .add and was != .add and bz.powered and !bz.startDiscovery()) ui.setMsg(bz.lastError());
    if (ok and was == .add and v != .add) bz.stopDiscovery();
    armTimer();
    if (ok and v != .done) refresh();
    ui.resetFocus(v == .actions or v == .pairing);
}

fn goBack() void {
    ui.clearMsg();
    switch (view) {
        .list => ui.quit(),
        .pairing => cancelPairing(),
        else => setView(.list),
    }
}

fn cancelPairing() void {
    bz.rejectPending();
    bz.cancelPairing(op_dev.get());
    if (op == .pair) op = .ignore; // ответ на Pair ещё придёт — выбросим
    pin_field.clear();
    setView(.add);
}

fn choose(row: usize, right: bool) void {
    if (row >= list.n) return;
    target = devAt(row).*;
    ui.clearMsg();
    if (view == .add) {
        // сопряжение: на время сопряжения поиск лучше остановить
        bz.stopDiscovery();
        bz.req = .{};
        pin_field.clear();
        // автоподбор PIN — один раз на устройство; после неудачи PIN спросим у пользователя
        if (!pin_dev.eql(target.path.get())) {
            pin_dev.set(target.path.get());
            pin_try = 0;
        }
        startOp(.pair, bz.pair(target.path.get()), target.path.get());
        if (op == .pair) setView(.pairing);
        return;
    }
    if (right or target.connected) return setView(.actions);
    if (busy(target.path.get())) return;
    startOp(.connect, bz.connect(target.path.get()), target.path.get());
}

fn onKey(k: ui.Key) bool {
    if (view != .list and view != .add) return false;
    switch (k.code) {
        ui.K_UP, ui.K_DOWN => {
            ui.focus = .{};
            list.move(if (k.code == ui.K_UP) -1 else 1);
        },
        ui.K_ENTER, ui.K_KPENTER => {
            if (ui.focus.id != 0) return false;
            if (list.n > 0) choose(list.sel, false);
        },
        else => return false,
    }
    return true;
}

fn onScroll(d: i32) void {
    if (view == .list or view == .add) list.scrollBy(d);
}

fn activate(w: ui.Widget, right: bool) void {
    switch (wid(w)) {
        .row => {
            list.sel = w.idx;
            choose(w.idx, right);
        },
        .more => {
            target = devAt(w.idx).*;
            setView(.actions);
        },
        .toggle => {
            if (bz.setPowered(!bz.powered)) refresh() else ui.setMsg(bz.lastError());
        },
        .back => goBack(),
        .add => setView(.add),
        .act_conn => {
            if (target.connected) {
                startOp(.disconnect, bz.disconnect(target.path.get()), target.path.get());
            } else {
                startOp(.connect, bz.connect(target.path.get()), target.path.get());
            }
            setView(.list);
        },
        .act_forget => {
            if (bz.remove(target.path.get())) setView(.list) else ui.setMsg(bz.lastError());
        },
        .primary => submit(),
        .secondary => goBack(),
        .field, .none => {},
    }
}

/// «Подтвердить»/«Готово» на экране сопряжения.
fn submit() void {
    if (view != .pairing) return;
    switch (bz.req.kind) {
        .confirm, .authorize => bz.answer(true, ""),
        .ask_pin => {
            const p = pin_field.text();
            if (p.len == 0 or p.len > 16) return ui.setMsg("PIN — от 1 до 16 символов");
            bz.answer(true, p);
            pin_field.clear();
        },
        .ask_passkey => {
            const p = pin_field.text();
            const v = std.fmt.parseInt(u32, p, 10) catch return ui.setMsg("Код — только цифры");
            if (v > 999999) return ui.setMsg("Код — не больше шести цифр");
            bz.answer(true, p);
            pin_field.clear();
        },
        else => return,
    }
    ui.clearMsg();
    ui.resetFocus(true);
}

// ================================================================= раскладка

fn back() void {
    ui.add(Wid.back, 0, .plain, PAD - 8, 16, 30, 30);
}

fn twoButtons(primary: bool) void {
    const y = ui.H() - PAD - 38;
    if (!primary) return ui.add(Wid.secondary, 0, .button, (ui.W() - 140) / 2, y, 140, 38);
    const bw = (ui.W() - 2 * PAD - 10) / 2;
    ui.add(Wid.secondary, 0, .button, PAD, y, bw, 38);
    ui.add(Wid.primary, 0, .button, PAD + bw + 10, y, bw, 38);
}

fn layout() void {
    ui.nwid = 0;
    const W = ui.W();
    switch (view) {
        .list, .add => {
            if (view == .add) back();
            if (view == .list and ok) ui.add(Wid.toggle, 0, .toggle, W - PAD - 40, 20, 40, 22);
            if (ok and bz.powered) {
                var i = list.scroll;
                var y = LIST_Y;
                while (i < list.n and i < list.scroll + list.visible) : (i += 1) {
                    ui.add(Wid.row, i, .row, PAD - 8, y, W - 2 * PAD + 16, ROW_H - 4);
                    if (view == .list) ui.add(Wid.more, i, .plain, W - PAD - 34, y + 10, 28, 28);
                    y += ROW_H;
                }
                if (view == .list) ui.add(Wid.add, 0, .button, PAD, ui.H() - PAD - 38, W - 2 * PAD, 38);
            }
        },
        .actions => {
            back();
            ui.add(Wid.act_conn, 0, .button, PAD, 110, W - 2 * PAD, 40);
            ui.add(Wid.act_forget, 0, .button, PAD, 160, W - 2 * PAD, 40);
        },
        .pairing => {
            back();
            switch (bz.req.kind) {
                .ask_pin, .ask_passkey => {
                    ui.add(Wid.field, 0, .field, PAD, 150, W - 2 * PAD, 34);
                    twoButtons(true);
                },
                .confirm, .authorize => twoButtons(true),
                else => twoButtons(false),
            }
        },
        .done => {},
    }
}

// ================================================================= рисование

const P = draw.Prim;
fn seg(x0: f32, y0: f32, x1: f32, y1: f32) P {
    return .{ .seg = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 } };
}
fn box(x: f32, y: f32, w: f32, h: f32, r: f32) P {
    return .{ .box = .{ .x = x, .y = y, .w = w, .h = h, .r = r } };
}
fn fbox(x: f32, y: f32, w: f32, h: f32, r: f32) P {
    return .{ .fbox = .{ .x = x, .y = y, .w = w, .h = h, .r = r } };
}
fn dot(x: f32, y: f32, r: f32) P {
    return .{ .dot = .{ .cx = x, .cy = y, .r = r } };
}

const ic_headphones = [_]P{ .{ .arc = .{ .cx = 8, .cy = 9, .r = 5.6, .a0 = 180, .a1 = 360 } }, fbox(1.6, 8.6, 3.6, 5.6, 1.4), fbox(10.8, 8.6, 3.6, 5.6, 1.4) };
const ic_speaker = [_]P{ box(3.5, 1.5, 9, 13, 2), .{ .ring = .{ .cx = 8, .cy = 9.8, .r = 2.4 } }, dot(8, 4.6, 0.9) };
const ic_keyboard = [_]P{ box(1, 4, 14, 8.5, 1.8), dot(4, 7, 0.75), dot(6.7, 7, 0.75), dot(9.3, 7, 0.75), dot(12, 7, 0.75), seg(5, 9.9, 11, 9.9) };
const ic_mouse = [_]P{ box(4, 1.5, 8, 13, 4), seg(8, 1.5, 8, 5.8) };
const ic_gamepad = [_]P{ box(1.5, 4.5, 13, 8, 4), seg(3.8, 8.5, 6.8, 8.5), seg(5.3, 7, 5.3, 10), dot(10.6, 7.6, 0.9), dot(12, 9.6, 0.9) };
const ic_phone = [_]P{ box(4.5, 1, 7, 14, 1.8), seg(7, 12.3, 9, 12.3) };
const ic_computer = [_]P{ box(2.5, 3, 11, 7.5, 1.2), seg(1, 13, 15, 13) };

fn kindIcon(k: bz.Kind) []const P {
    return switch (k) {
        .headphones => &ic_headphones,
        .speaker => &ic_speaker,
        .keyboard => &ic_keyboard,
        .mouse => &ic_mouse,
        .gamepad => &ic_gamepad,
        .phone => &ic_phone,
        .computer => &ic_computer,
        .generic => &draw.icon_bt,
    };
}

fn kindLabel(k: bz.Kind) []const u8 {
    return switch (k) {
        .headphones => "Наушники",
        .speaker => "Колонка",
        .keyboard => "Клавиатура",
        .mouse => "Мышь",
        .gamepad => "Геймпад",
        .phone => "Телефон",
        .computer => "Компьютер",
        .generic => "Устройство",
    };
}

fn statusOf(d: *const bz.Dev, buf: []u8) []const u8 {
    if (busy(d.path.get())) {
        const base = if (op == .disconnect) "Отключение" else "Подключение";
        return ui.dots(base, ticks, buf);
    }
    if (view == .add or view == .pairing) return kindLabel(d.kind);
    if (d.connected) {
        if (d.battery <= 100) return std.fmt.bufPrint(buf, "Подключено · {d}%", .{d.battery}) catch "Подключено";
        return "Подключено";
    }
    return "Не подключено";
}

fn paint(cv: *draw.Canvas) void {
    const t = &theme.t;
    const W = ui.W();
    const H = ui.H();
    switch (view) {
        .list, .add => {
            if (view == .list) {
                ui.header(cv, "Bluetooth", "", false);
            } else {
                var b: [32]u8 = undefined;
                ui.header(cv, "Добавить устройство", ui.dots("Поиск", ticks, &b), true);
            }
            if (!ok) {
                ui.centered(cv, "Bluetooth недоступен", W / 2, H / 2 - 8, 15, t.menu_text);
                ui.centered(cv, ui.msg(), W / 2, H / 2 + 16, 12, t.menu_muted);
                return;
            }
            if (!bz.powered) {
                ui.centered(cv, "Bluetooth выключен", W / 2, H / 2, 15, t.menu_muted);
            } else if (list.n == 0) {
                const empty = if (view == .list) "Нет сопряжённых устройств" else "Переведите устройство в режим сопряжения";
                ui.centered(cv, empty, W / 2, H / 2, 14, t.menu_muted);
            }
            paintWidgets(cv);
            ui.paintMsg(cv, if (view == .list) H - PAD - 52 else H - PAD - 8);
            ui.scrollbar(cv, &list, LIST_Y, ROW_H);
        },
        .actions => {
            var b: [48]u8 = undefined;
            ui.header(cv, target.name(), statusOf(&target, &b), true);
            paintWidgets(cv);
            ui.paintMsg(cv, 230);
        },
        .pairing => paintPairing(cv),
        .done => ui.paintDone(cv, "Подключено"),
    }
}

fn paintPairing(cv: *draw.Canvas) void {
    const t = &theme.t;
    const W = ui.W();
    const H = ui.H();
    ui.header(cv, target.name(), "Сопряжение", true);
    var b: [32]u8 = undefined;
    switch (bz.req.kind) {
        .none => {
            ui.icon(cv, kindIcon(target.kind), W / 2 - 24, H / 2 - 70, 48, 1.4, t.menu_text);
            const pairing = op == .pair;
            ui.centered(cv, ui.dots(if (pairing) "Сопряжение" else "Подключение", ticks, &b), W / 2, H / 2 + 6, 14, t.menu_muted);
            if (pairing) _ = ui.wrap(cv, "Подтвердите сопряжение на устройстве, если оно спросит", PAD, H / 2 + 30, 12, t.menu_muted, W - 2 * PAD, 16, true);
        },
        .confirm, .show_passkey => {
            const hint = if (bz.req.kind == .confirm)
                "Если на устройстве есть экран — сверьте код. Если экрана нет — просто нажмите «Подтвердить»:"
            else
                "Введите этот код на устройстве и нажмите Enter:";
            _ = ui.wrap(cv, hint, PAD, 110, 13, t.menu_muted, W - 2 * PAD, 17, true);
            const code = std.fmt.bufPrint(&b, "{d:0>6}", .{bz.req.passkey}) catch "";
            paintCode(cv, code, if (bz.req.kind == .show_passkey) bz.req.entered else 0);
        },
        .show_pin => {
            ui.centered(cv, "Введите этот PIN на устройстве:", W / 2, 110, 13, t.menu_muted);
            paintCode(cv, bz.req.pin(), 0);
        },
        .authorize => {
            ui.icon(cv, kindIcon(target.kind), W / 2 - 24, H / 2 - 70, 48, 1.4, t.menu_text);
            ui.centered(cv, "Разрешить сопряжение с этим устройством?", W / 2, H / 2 + 10, 14, t.menu_text);
        },
        .ask_pin => ui.centered(cv, "Введите PIN устройства (обычно указан в инструкции):", W / 2, 130, 13, t.menu_muted),
        .ask_passkey => ui.centered(cv, "Введите код, показанный на устройстве:", W / 2, 130, 13, t.menu_muted),
    }
    paintWidgets(cv);
    ui.paintMsg(cv, H - PAD - 52);
}

/// Крупный код по цифрам; уже набранные на устройстве цифры — акцентным цветом.
fn paintCode(cv: *draw.Canvas, code: []const u8, entered: u16) void {
    const t = &theme.t;
    const size: f32 = 30;
    const cell: f32 = 30;
    const total = cell * @as(f32, @floatFromInt(code.len));
    var x = ui.W() / 2 - total / 2;
    for (code, 0..) |ch, i| {
        const s = [1]u8{ch};
        const c = if (i < entered) t.menu_accent else t.menu_text;
        ui.centered(cv, &s, x + cell / 2, 175, size, c);
        x += cell;
    }
}

fn paintWidgets(cv: *draw.Canvas) void {
    const t = &theme.t;
    for (ui.widgets[0..ui.nwid]) |w| {
        switch (wid(w)) {
            .row => {
                const d = devAt(w.idx);
                if (list.lit(w)) ui.rrect(cv, w.x, w.y, w.w, w.h, 10, t.menu_hover);
                const c = if (d.connected) t.menu_accent else t.menu_text;
                ui.icon(cv, kindIcon(d.kind), w.x + 12, w.y + (w.h - 20) / 2, 20, 1.5, c);
                const right = w.x + w.w - (if (view == .list) @as(f32, 42) else 12);
                _ = ui.text(cv, d.name(), w.x + 44, w.y + 20, 14, c, right);
                var b: [48]u8 = undefined;
                _ = ui.text(cv, statusOf(d, &b), w.x + 44, w.y + 37, 11.5, t.menu_muted, right);
            },
            .more => {
                if (ui.isHover(w)) ui.rrect(cv, w.x, w.y, w.w, w.h, 8, t.menu_hover);
                ui.icon(cv, &ui.ic_more, w.x + 6, w.y + 6, 16, 1, t.menu_muted);
            },
            .toggle => ui.toggle(cv, w, bz.powered),
            .back => ui.paintBack(cv, w),
            .add => ui.button(cv, w, "Добавить устройство", .secondary),
            .act_conn => ui.button(cv, w, if (target.connected) "Отключить" else "Подключить", if (target.connected) .secondary else .primary),
            .act_forget => ui.button(cv, w, "Забыть устройство", .danger),
            .primary => ui.button(cv, w, switch (bz.req.kind) {
                .confirm => "Подтвердить",
                .authorize => "Разрешить",
                else => "Готово",
            }, .primary),
            .secondary => ui.button(cv, w, "Отмена", .secondary),
            .field => ui.field(cv, w, &pin_field, if (bz.req.kind == .ask_pin) "PIN" else "000000", false, 0),
            .none => {},
        }
    }
}
