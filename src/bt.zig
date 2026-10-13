// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zbt — Bluetooth menu for netline, in pure Zig.
//!
//! Paired devices (connect, disconnect, forget), discovering and pairing new ones
//! with our own agent (passkey confirmation, PIN entry), battery level, adapter power.
//! Talks to bluetoothd over D-Bus. `zbt toggle` turns Bluetooth on/off without a window,
//! `zbt scan` discovers devices and prints everything bluetoothd sees (for diagnostics).

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

const devs = &bz.devs; // bz maintains the table from bluetoothd signals
var shown: [bz.MAX_DEVS]u8 = undefined; // indices into devs of the current list
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

/// PINs we try ourselves for old devices with no screen or keyboard (headphones, speakers, mice):
/// their PIN is hard-wired and is almost always 0000 or 1234. If they fail, we ask the user.
const auto_pins = [_][]const u8{ "0000", "1234" };
var pin_try: usize = 0;
var pin_dev: bz.Path = .{};

const Wid = enum(u8) { none, row, more, toggle, back, add, primary, secondary, act_conn, act_forget, field };

fn wid(w: ui.Widget) Wid {
    return @enumFromInt(w.id);
}

// ================================================================= startup

pub fn main(init: std.process.Init.Minimal) void {
    sys.init(init);
    if (sys.argIs(1, "toggle")) {
        if (!bz.init()) fatalCli();
        _ = bz.load();
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
        .hover_local = true,
    }, .{}, .{});
}

fn fatalCli() noreturn {
    sys.log("{s}", .{bz.lastError()});
    sys.exit(1);
}

/// `zbt scan [seconds]`: discovery (20 seconds by default) and the full list of devices
/// bluetoothd sees, with a hint if the one you need isn't among them.
fn scanCli() noreturn {
    if (!bz.init()) fatalCli();
    _ = bz.load();
    if (bz.adapter.len == 0) fatalCli();
    sys.log("adapter {s}: {s}", .{ bz.adapter.get(), if (bz.powered) "on" else "OFF — turn Bluetooth on" });
    if (!bz.powered) sys.exit(1);
    const secs: u32 = if (sys.argAt(2)) |a| std.math.clamp(std.fmt.parseInt(u32, a, 10) catch 20, 5, 120) else 20;
    if (!bz.startDiscovery()) {
        sys.log("discovery did not start: {s}", .{bz.lastError()});
        sys.exit(1);
    }
    sys.log("discovering for {d} seconds...", .{secs});
    var i: u32 = 0;
    while (i < secs * 2) : (i += 1) {
        var pfd = [1]sys.PollFd{.{ .fd = bz.bus.fd, .events = sys.POLLIN }};
        _ = sys.poll(&pfd, 500) catch {};
        bz.bus.pump() catch break;
    }
    const n = bz.load();
    bz.stopDiscovery();
    var named: usize = 0;
    var classic: usize = 0;
    var random: usize = 0;
    for (devs[0..n]) |*d| {
        if (d.has_name or d.paired or d.kind != .generic) named += 1;
        if (d.classic) classic += 1;
        if (d.random) random += 1;
        const rssi: i32 = d.rssi;
        var mk: [24]u8 = undefined;
        sys.log("{s}  {s}  {s}, {s}{s}{s}rssi {d}", .{
            d.path.get()[bz.adapter.len..],
            d.name(),
            kindLabel(d.kind),
            if (d.classic) "classic" else if (d.random) "BLE, random address" else "BLE",
            makerLabel(d.maker, &mk),
            if (d.paired) ", paired, " else ", ",
            rssi,
        });
    }
    sys.log("{d} in total, shown in the menu: {d}", .{ n, named });
    if (named == 0) {
        if (random == n and n > 0) sys.log("everything found is nameless BLE with random addresses: other people's phones, watches and tags nearby", .{});
        if (classic == 0) sys.log("no classic devices (headphones, speakers, mice) found", .{});
        sys.log("put the device into pairing mode (usually hold the power or Bluetooth button until it blinks)", .{});
        sys.log("headphones connected to a phone don't show up in discovery — turn off Bluetooth on the phone", .{});
    }
    sys.exit(0);
}

/// ", Apple" etc. by the manufacturer code from the BLE advertisement.
fn makerLabel(id: u16, buf: []u8) []const u8 {
    const known = [_]struct { u16, []const u8 }{
        .{ 0x004c, "Apple" },  .{ 0x0006, "Microsoft" }, .{ 0x0075, "Samsung" },
        .{ 0x00e0, "Google" }, .{ 0x038f, "Xiaomi" },    .{ 0x027d, "Huawei" },
        .{ 0x012d, "Sony" },   .{ 0x009e, "Bose" },      .{ 0x0087, "Garmin" },
    };
    if (id == 0xffff) return "";
    for (known) |k| if (k[0] == id) return std.fmt.bufPrint(buf, ", {s}", .{k[1]}) catch "";
    return std.fmt.bufPrint(buf, ", manufacturer 0x{x:0>4}", .{id}) catch "";
}

fn start() void {
    list.visible = @intFromFloat((ui.H() - LIST_Y - 64) / ROW_H);
    if (!ok) return;
    if (!bz.registerAgent()) sys.log("pairing agent not registered: {s}", .{bz.lastError()});
    _ = bz.load();
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

// ================================================================= data

fn lessPaired(_: void, a: u8, b: u8) bool {
    const x = &devs[a];
    const y = &devs[b];
    if (x.connected != y.connected) return x.connected;
    return std.mem.order(u8, x.name(), y.name()) == .lt;
}

fn lessFound(_: void, a: u8, b: u8) bool {
    return devs[a].rssi > devs[b].rssi;
}

/// Rebuild the shown list from the bz table — without asking bluetoothd.
fn refresh() void {
    _ = rebuild();
    ui.redraw();
}

/// Rebuild the list; true — the set or order of rows changed.
fn rebuild() bool {
    bz.changed = false;
    bz.rssi_changed = false;
    var old: [bz.MAX_DEVS]u8 = undefined;
    const old_n = list.n;
    @memcpy(old[0..old_n], shown[0..old_n]);
    var n: usize = 0;
    for (devs[0..bz.ndev], 0..) |*d, i| {
        const want = switch (view) {
            // classic devices' names don't arrive right away, but the type (headphones etc.) comes with the first reply
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
    // fresh data about the selected device (the status in "Actions")
    for (devs[0..bz.ndev]) |*d| {
        if (d.path.eql(target.path.get())) target = d.*;
    }
    return n != old_n or !std.mem.eql(u8, old[0..n], shown[0..n]);
}

fn devAt(row: usize) *bz.Dev {
    if (bz.changed) refresh(); // the table may have changed since the last frame
    return &devs[shown[@min(row, bz.MAX_DEVS - 1)]];
}

fn busy(path: []const u8) bool {
    return (op == .connect or op == .disconnect or op == .connect_after_pair) and op_dev.eql(path);
}

// ================================================================= timer and events

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
        ui.setTimer(500, 500);
        timer_on = true;
    } else if (!want and timer_on) {
        ui.setTimer(0, 0);
        timer_on = false;
    }
}

fn onTick() void {
    ticks +%= 1;
    if (view == .done) return ui.quit();
    // A synchronous call may have read signals and agent requests from the socket beyond its reply:
    // they sit in the buffer and the socket is no longer "readable" — handle them here.
    if (ok) pumpBus();
    // the signal level changes all the time — reorder found devices once per tick, not on every signal;
    // RSSI itself isn't shown, so a redraw is needed only if rows swapped places
    if (bz.changed) {
        refresh();
    } else if (bz.rssi_changed and rebuild()) ui.redraw();
    animate();
}

/// Dots animation: redraw only the row with them, not the whole card.
fn animate() void {
    switch (view) {
        .add, .actions => ui.redrawText(56, 12), // "Searching..." / "Connecting..." under the header
        .pairing => ui.redrawText(ui.H() / 2 + 6, 14),
        .list => for (ui.widgets[0..ui.nwid]) |w| {
            if (wid(w) == .row and busy(devAt(w.idx).path.get())) ui.redrawArea(w.y, w.h);
        },
        .done => {},
    }
}

fn onBus() void {
    pumpBus();
    // new device, name, connection — show right away, without waiting for the tick
    if (ok and bz.changed) refresh();
}

fn pumpBus() void {
    bz.bus.pump() catch {
        ok = false;
        ui.setMsg("lost connection to bluetoothd");
        return;
    };
    checkOp();
    if (bz.req_changed) {
        bz.req_changed = false;
        if (view == .pairing and !autoAnswer()) ui.resetFocus(true);
        ui.redraw();
    }
}

/// Devices with nothing to show and nowhere to enter a code.
fn noScreen(k: bz.Kind) bool {
    return switch (k) {
        .headphones, .speaker, .mouse, .gamepad => true,
        else => false,
    };
}

/// Answer the agent ourselves if the user has nothing to compare or enter:
/// confirmation for devices without a screen and standard PINs for old devices.
fn autoAnswer() bool {
    // only requests from the device the user chose to pair
    if (!bz.req.device.eql(target.path.get())) return false;
    switch (bz.req.kind) {
        // "Just Works": there is no code, nothing to compare, and the user already started pairing
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
                // paired: trust it (so it reconnects by itself) and connect
                bz.trust(op_dev.get());
                startOp(.connect_after_pair, bz.connect(op_dev.get()), op_dev.get());
            } else {
                bz.req.kind = .none;
                const auth = std.mem.endsWith(u8, d.errName(), "AuthenticationFailed") or std.mem.endsWith(u8, d.errName(), "AuthenticationRejected");
                // the standard PIN didn't work — try the next one without leaving the pairing screen
                if (auth and pin_try > 0 and pin_try < auto_pins.len) {
                    startOp(.pair, bz.pair(op_dev.get()), op_dev.get());
                    if (op == .pair) return;
                }
                setView(.add);
                if (auth and pin_try >= auto_pins.len) {
                    ui.setMsg("PIN 0000 and 1234 didn't work — select the device again and enter the PIN");
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

// ================================================================= transitions

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
    if (op == .pair) op = .ignore; // the reply to Pair will still come — discard it
    pin_field.clear();
    setView(.add);
}

fn choose(row: usize, right: bool) void {
    if (row >= list.n) return;
    target = devAt(row).*;
    ui.clearMsg();
    if (view == .add) {
        // pairing: better to stop discovery while pairing
        bz.stopDiscovery();
        bz.req = .{};
        pin_field.clear();
        // automatic PIN guessing — once per device; after a failure we ask the user for the PIN
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
    // signals that came in the same read as a synchronous call's reply sit in the buffer
    if (ok) pumpBus();
}

/// "Confirm"/"Done" on the pairing screen.
fn submit() void {
    if (view != .pairing) return;
    switch (bz.req.kind) {
        .confirm, .authorize => bz.answer(true, ""),
        .ask_pin => {
            const p = pin_field.text();
            if (p.len == 0 or p.len > 16) return ui.setMsg("PIN must be 1 to 16 characters");
            bz.answer(true, p);
            pin_field.clear();
        },
        .ask_passkey => {
            const p = pin_field.text();
            const v = std.fmt.parseInt(u32, p, 10) catch return ui.setMsg("The code must be digits only");
            if (v > 999999) return ui.setMsg("The code is at most six digits");
            bz.answer(true, p);
            pin_field.clear();
        },
        else => return,
    }
    ui.clearMsg();
    ui.resetFocus(true);
}

// ================================================================= layout

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
    if (bz.changed) refresh(); // rows follow the current table
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

// ================================================================= drawing

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
        .headphones => "Headphones",
        .speaker => "Speaker",
        .keyboard => "Keyboard",
        .mouse => "Mouse",
        .gamepad => "Gamepad",
        .phone => "Phone",
        .computer => "Computer",
        .generic => "Device",
    };
}

fn statusOf(d: *const bz.Dev, buf: []u8) []const u8 {
    if (busy(d.path.get())) {
        const base = if (op == .disconnect) "Disconnecting" else "Connecting";
        return ui.dots(base, ticks, buf);
    }
    if (view == .add or view == .pairing) return kindLabel(d.kind);
    if (d.connected) {
        if (d.battery <= 100) return std.fmt.bufPrint(buf, "Connected · {d}%", .{d.battery}) catch "Connected";
        return "Connected";
    }
    return "Not connected";
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
                ui.header(cv, "Add device", ui.dots("Searching", ticks, &b), true);
            }
            if (!ok) {
                ui.centered(cv, "Bluetooth is unavailable", W / 2, H / 2 - 8, 15, t.menu_text);
                ui.centered(cv, ui.msg(), W / 2, H / 2 + 16, 12, t.menu_muted);
                return;
            }
            if (!bz.powered) {
                ui.centered(cv, "Bluetooth is off", W / 2, H / 2, 15, t.menu_muted);
            } else if (list.n == 0) {
                const empty = if (view == .list) "No paired devices" else "Put the device into pairing mode";
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
        .done => ui.paintDone(cv, "Connected"),
    }
}

fn paintPairing(cv: *draw.Canvas) void {
    const t = &theme.t;
    const W = ui.W();
    const H = ui.H();
    ui.header(cv, target.name(), "Pairing", true);
    var b: [32]u8 = undefined;
    switch (bz.req.kind) {
        .none => {
            ui.icon(cv, kindIcon(target.kind), W / 2 - 24, H / 2 - 70, 48, 1.4, t.menu_text);
            const pairing = op == .pair;
            ui.centered(cv, ui.dots(if (pairing) "Pairing" else "Connecting", ticks, &b), W / 2, H / 2 + 6, 14, t.menu_muted);
            if (pairing) _ = ui.wrap(cv, "Confirm pairing on the device if it asks", PAD, H / 2 + 30, 12, t.menu_muted, W - 2 * PAD, 16, true);
        },
        .confirm, .show_passkey => {
            const hint = if (bz.req.kind == .confirm)
                "If the device has a screen, check that the code matches. If it has none, just press \"Confirm\":"
            else
                "Enter this code on the device and press Enter:";
            _ = ui.wrap(cv, hint, PAD, 110, 13, t.menu_muted, W - 2 * PAD, 17, true);
            const code = std.fmt.bufPrint(&b, "{d:0>6}", .{bz.req.passkey}) catch "";
            paintCode(cv, code, if (bz.req.kind == .show_passkey) bz.req.entered else 0);
        },
        .show_pin => {
            ui.centered(cv, "Enter this PIN on the device:", W / 2, 110, 13, t.menu_muted);
            paintCode(cv, bz.req.pin(), 0);
        },
        .authorize => {
            ui.icon(cv, kindIcon(target.kind), W / 2 - 24, H / 2 - 70, 48, 1.4, t.menu_text);
            ui.centered(cv, "Allow pairing with this device?", W / 2, H / 2 + 10, 14, t.menu_text);
        },
        .ask_pin => ui.centered(cv, "Enter the device PIN (usually given in the manual):", W / 2, 130, 13, t.menu_muted),
        .ask_passkey => ui.centered(cv, "Enter the code shown on the device:", W / 2, 130, 13, t.menu_muted),
    }
    paintWidgets(cv);
    ui.paintMsg(cv, H - PAD - 52);
}

/// A large code digit by digit; digits already typed on the device are in the accent color.
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
            .add => ui.button(cv, w, "Add device", .secondary),
            .act_conn => ui.button(cv, w, if (target.connected) "Disconnect" else "Connect", if (target.connected) .secondary else .primary),
            .act_forget => ui.button(cv, w, "Forget device", .danger),
            .primary => ui.button(cv, w, switch (bz.req.kind) {
                .confirm => "Confirm",
                .authorize => "Allow",
                else => "Done",
            }, .primary),
            .secondary => ui.button(cv, w, "Cancel", .secondary),
            .field => ui.field(cv, w, &pin_field, if (bz.req.kind == .ask_pin) "PIN" else "000000", false, 0),
            .none => {},
        }
    }
}
