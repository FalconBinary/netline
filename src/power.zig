// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zpower — power menu for netline, in pure Zig.
//!
//! Lock, log out, sleep, hibernate, reboot, power off.
//! Power goes through systemd-logind over D-Bus (no systemctl), logout through the mango IPC
//! (or logind if mango is unavailable). Locking is started by a small broker process:
//! zpower itself cannot launch programs after startup.
//! Keys: ←/→ and Enter, Esc; L — lock, E — log out, S — sleep, H — hibernate,
//! R — reboot, P — power off.

const std = @import("std");
const sys = @import("sys.zig");
const draw = @import("draw.zig");
const theme = @import("theme.zig");
const cfg = @import("config.zig");
const dbus = @import("dbus.zig");
const broker = @import("broker.zig");
const ui = @import("ui.zig");
const rt = @import("rt.zig");

pub const panic = rt.panic;
pub const std_options = rt.std_options;

const PAD = ui.PAD;
const LOGIN = "org.freedesktop.login1";
const LPATH = "/org/freedesktop/login1";
const MGR = "org.freedesktop.login1.Manager";

const Act = enum(u8) { lock, logout, sleep, hibernate, reboot, poweroff };
const all = [_]Act{ .lock, .logout, .sleep, .hibernate, .reboot, .poweroff };

const CELL: f32 = 92;
const GAP: f32 = 4;
const CIRCLE: f32 = 60;

var acts: [6]Act = undefined;
var nacts: usize = 0;

var bus: dbus.Conn = .{};
var logind_ok = false;
var mango_fd: i32 = -1;
var have_broker = false;

const View = enum { main, confirm, wait };
var view: View = .main;
var chosen: Act = .lock;
var pending: u32 = 0; // serial of the async logind call
var suspend_after_lock = false;

var user_buf: [64]u8 = undefined;
var user_len: usize = 0;
var sub_buf: [128]u8 = undefined;
var sub_len: usize = 0;
var body_buf: [256]u8 = undefined;

const Wid = enum(u8) { none, act, primary, secondary };

fn wid(w: ui.Widget) Wid {
    return @enumFromInt(w.id);
}

// ================================================================= startup

pub fn main(init: std.process.Init.Minimal) void {
    sys.init(init);
    ui.begin("zpower");
    // the broker comes before all other connections so it holds no extra descriptors
    const cmds = [_]?broker.Cmd{comptime broker.compile(cfg.lock_cmd)};
    have_broker = broker.start(&cmds);

    if (bus.connectSystem()) |_| {
        logind_ok = true;
    } else |_| {}
    if (sys.getenv("MANGO_INSTANCE_SIGNATURE")) |p| mango_fd = sys.connectUnix(p) catch -1;

    var can = [_]bool{false} ** all.len;
    queryAvailable(&can);
    nacts = 0;
    for (all, can) |a, ok| {
        if (ok) {
            acts[nacts] = a;
            nacts += 1;
        }
    }
    readInfo();
    if (!logind_ok) ui.setMsg("systemd-logind is unavailable — only lock and log out work");

    const n: f32 = @floatFromInt(@max(nacts, 4));
    const width: u32 = @intFromFloat(2 * PAD + n * CELL + (n - 1) * GAP);
    ui.run(.{
        .width = width,
        .height = 200,
        .layout = layout,
        .paint = paint,
        .activate = activate,
        .back = goBack,
        .key = onKey,
        .tick = onTick,
        .extra_fd = busFd,
        .on_extra = onBus,
    }, .{}, .{});
}

const Ask = struct { act: Act, member: []const u8 };
const asks = [_]Ask{
    .{ .act = .sleep, .member = "CanSuspend" },
    .{ .act = .hibernate, .member = "CanHibernate" },
    .{ .act = .reboot, .member = "CanReboot" },
    .{ .act = .poweroff, .member = "CanPowerOff" },
};

/// Which actions are available. Lock and log out need no logind; for the rest we ask
/// logind in one batch ("yes" or "challenge" — with a polkit password).
fn queryAvailable(can: *[all.len]bool) void {
    can[@intFromEnum(Act.lock)] = have_broker;
    can[@intFromEnum(Act.logout)] = mango_fd >= 0 or logind_ok;
    if (!logind_ok) return;
    var serials: [asks.len]u32 = undefined;
    for (asks, &serials) |q, *sr| sr.* = bus.sendCall(LOGIN, LPATH, MGR, q.member, "", "") catch 0;
    bus.collect(&serials, can, gotCan) catch {};
}

fn gotCan(can: *[all.len]bool, i: usize, r: dbus.Reply) void {
    if (!r.ok()) return;
    var rr = r.reader();
    const v = rr.str();
    can[@intFromEnum(asks[i].act)] = !rr.bad and (std.mem.eql(u8, v, "yes") or std.mem.eql(u8, v, "challenge"));
}

/// User, host name and uptime — before the sandbox.
fn readInfo() void {
    const u = sys.getenv("USER") orelse "";
    user_len = @min(u.len, user_buf.len);
    @memcpy(user_buf[0..user_len], u[0..user_len]);
    var hb: [64]u8 = undefined;
    const host = std.mem.trim(u8, sys.readFile("/proc/sys/kernel/hostname", &hb) orelse "", " \n");
    var ub: [64]u8 = undefined;
    const up_s = sys.readFile("/proc/uptime", &ub) orelse "";
    const dot = std.mem.indexOfAny(u8, up_s, ". ") orelse up_s.len;
    const up = std.fmt.parseInt(u64, up_s[0..dot], 10) catch 0;
    const h = up / 3600;
    const m = (up / 60) % 60;
    const s: []const u8 = (if (h > 0)
        std.fmt.bufPrint(&sub_buf, "{s} · up {d} h {d} min", .{ host, h, m })
    else
        std.fmt.bufPrint(&sub_buf, "{s} · up {d} min", .{ host, m })) catch "";
    sub_len = s.len;
}

fn busFd() i32 {
    return if (logind_ok) bus.fd else -1;
}

// ================================================================= actions

fn label(a: Act) []const u8 {
    return switch (a) {
        .lock => "Lock",
        .logout => "Log out",
        .sleep => "Sleep",
        .hibernate => "Hibernate",
        .reboot => "Reboot",
        .poweroff => "Power off",
    };
}

fn needsConfirm(a: Act) bool {
    return cfg.power_confirm and (a == .logout or a == .reboot or a == .poweroff);
}

fn choose(a: Act) void {
    chosen = a;
    ui.clearMsg();
    if (needsConfirm(a)) {
        view = .confirm;
        ui.resetFocus(true);
        return;
    }
    run(a);
}

fn run(a: Act) void {
    switch (a) {
        .lock => {
            broker.run(0);
            ui.quit();
        },
        .logout => {
            if (mango_fd >= 0) {
                sys.sendAll(mango_fd, "dispatch quit\n") catch {};
                ui.quit();
            }
            // without mango — end our session through logind
            logind("/org/freedesktop/login1/session/auto", "org.freedesktop.login1.Session", "Terminate", false);
        },
        .sleep => {
            if (cfg.lock_before_suspend and have_broker) {
                // lock first, then sleep — so the screen is locked on wakeup
                broker.run(0);
                suspend_after_lock = true;
                view = .wait;
                ui.setTimer(600, 0);
                ui.redraw();
            } else logind(LPATH, MGR, "Suspend", true);
        },
        .hibernate => logind(LPATH, MGR, "Hibernate", true),
        .reboot => logind(LPATH, MGR, "Reboot", true),
        .poweroff => logind(LPATH, MGR, "PowerOff", true),
    }
}

/// Async logind call: the window doesn't freeze while polkit asks for a password.
fn logind(path: []const u8, iface: []const u8, member: []const u8, interactive: bool) void {
    if (!logind_ok) return ui.setMsg("systemd-logind is unavailable");
    var w = dbus.W{ .buf = &body_buf };
    const sig: []const u8 = if (interactive) "b" else "";
    if (interactive) w.boolean(true);
    pending = bus.callAsync(LOGIN, path, iface, member, sig, w.bytes()) catch {
        return ui.setMsg("error talking to systemd-logind");
    };
    view = .wait;
    ui.redraw();
}

fn onTick() void {
    if (suspend_after_lock) {
        suspend_after_lock = false;
        logind(LPATH, MGR, "Suspend", true);
    }
}

fn onBus() void {
    bus.pump() catch {
        logind_ok = false;
        return;
    };
    if (pending == 0) return;
    const d = bus.result(pending) orelse return;
    pending = 0;
    if (d.ok) ui.quit(); // the system is going to sleep/rebooting — the menu is no longer needed
    view = .main;
    const name = d.errName();
    if (std.mem.indexOf(u8, name, "InteractiveAuthorizationRequired") != null or std.mem.indexOf(u8, name, "AccessDenied") != null) {
        ui.setMsg("Administrator rights required (polkit refused)");
    } else ui.setMsg(d.message());
    ui.resetFocus(false);
}

fn goBack() void {
    if (view == .confirm) {
        view = .main;
        ui.clearMsg();
        return ui.resetFocus(false);
    }
    ui.quit();
}

fn activate(w: ui.Widget, right: bool) void {
    _ = right;
    switch (wid(w)) {
        .act => if (view == .main) choose(acts[w.idx]),
        .primary => run(chosen),
        .secondary => goBack(),
        .none => {},
    }
}

fn onKey(k: ui.Key) bool {
    if (view == .wait) return k.code != ui.K_ESC; // while waiting — only Esc
    if (view == .confirm) {
        // the same hotkey once more confirms (P, P — power off)
        if (!k.ctrl and hotkey(k.code) == chosen) {
            run(chosen);
            return true;
        }
        return false;
    }
    switch (k.code) {
        ui.K_LEFT, ui.K_RIGHT => {
            ui.moveFocus(if (k.code == ui.K_LEFT) -1 else 1);
            return true;
        },
        else => {},
    }
    if (k.ctrl) return false;
    const a = hotkey(k.code) orelse return false;
    for (acts[0..nacts]) |x| {
        if (x == a) choose(a);
    }
    return true;
}

/// Hotkeys go by physical keys and work in any layout.
fn hotkey(code: u32) ?Act {
    return switch (code) {
        38 => .lock, // L
        18 => .logout, // E
        31 => .sleep, // S
        35 => .hibernate, // H
        19 => .reboot, // R
        25 => .poweroff, // P
        else => null,
    };
}

// ================================================================= layout and drawing

fn layout() void {
    ui.nwid = 0;
    switch (view) {
        .main => {
            const n: f32 = @floatFromInt(nacts);
            var x = (ui.W() - (n * CELL + (n - 1) * GAP)) / 2;
            for (0..nacts) |i| {
                ui.add(Wid.act, i, .button, x, 76, CELL, 104);
                x += CELL + GAP;
            }
        },
        .confirm => {
            const bw: f32 = 150;
            const y = ui.H() - PAD - 38;
            ui.add(Wid.secondary, 0, .button, ui.W() / 2 - bw - 5, y, bw, 38);
            ui.add(Wid.primary, 0, .button, ui.W() / 2 + 5, y, bw, 38);
        },
        .wait => {},
    }
}

const P = draw.Prim;
fn seg(x0: f32, y0: f32, x1: f32, y1: f32) P {
    return .{ .seg = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 } };
}

const ic_lock = [_]P{
    .{ .box = .{ .x = 3.2, .y = 7, .w = 9.6, .h = 7.6, .r = 1.8 } },
    .{ .arc = .{ .cx = 8, .cy = 7, .r = 3, .a0 = 180, .a1 = 360 } },
    .{ .dot = .{ .cx = 8, .cy = 10.8, .r = 0.9 } },
};
const ic_logout = [_]P{
    seg(7, 2.5, 3, 2.5), seg(3, 2.5, 3, 13.5), seg(3, 13.5, 7, 13.5),
    seg(7, 8, 14, 8),    seg(11, 5, 14, 8),    seg(11, 11, 14, 8),
};
const ic_moon = [_]P{
    .{ .arc = .{ .cx = 8, .cy = 8, .r = 6, .a0 = 60, .a1 = 300 } },
    .{ .arc = .{ .cx = 14.5, .cy = 8, .r = 6.27, .a0 = 124, .a1 = 236 } },
};
const ic_snow = [_]P{
    seg(8, 1.8, 8, 14.2),    seg(2.6, 4.9, 13.4, 11.1), seg(2.6, 11.1, 13.4, 4.9),
    seg(6.4, 2.6, 8, 4.1),   seg(9.6, 2.6, 8, 4.1),     seg(6.4, 13.4, 8, 11.9),
    seg(9.6, 13.4, 8, 11.9),
};
const ic_reboot = [_]P{
    .{ .arc = .{ .cx = 8, .cy = 8.6, .r = 5.6, .a0 = 300, .a1 = 600 } },
    seg(5.2, 3.75, 2.4, 3.3),
    seg(5.2, 3.75, 4.6, 6.5),
};

fn iconOf(a: Act) []const P {
    return switch (a) {
        .lock => &ic_lock,
        .logout => &ic_logout,
        .sleep => &ic_moon,
        .hibernate => &ic_snow,
        .reboot => &ic_reboot,
        .poweroff => &draw.icon_power,
    };
}

fn verb(a: Act) []const u8 {
    return switch (a) {
        .logout => "Log out",
        .reboot => "Reboot",
        .poweroff => "Power off",
        else => label(a),
    };
}

fn question(a: Act) []const u8 {
    return switch (a) {
        .logout => "Log out of the session?",
        .reboot => "Restart the computer?",
        .poweroff => "Shut down the computer?",
        else => "",
    };
}

fn paint(cv: *draw.Canvas) void {
    const t = &theme.t;
    const W = ui.W();
    switch (view) {
        .main, .wait => {
            ui.header(cv, if (user_len > 0) user_buf[0..user_len] else "Power", sub_buf[0..sub_len], false);
            for (ui.widgets[0..ui.nwid]) |w| {
                const a = acts[w.idx];
                const cx = w.x + w.w / 2;
                const r = CIRCLE / 2;
                ui.rrect(cv, cx - r, w.y, CIRCLE, CIRCLE, r, t.menu_field);
                if (ui.isHover(w)) ui.rrect(cv, cx - r, w.y, CIRCLE, CIRCLE, r, t.menu_hover);
                if (ui.isFocus(w)) ui.outline(cv, cx - r - 2, w.y - 2, CIRCLE + 4, CIRCLE + 4, r + 2, t.menu_accent, 1.5);
                const c = if (a == .poweroff) t.menu_error else t.menu_text;
                ui.icon(cv, iconOf(a), cx - 12, w.y + r - 12, 24, 1.8, c);
                ui.centered(cv, label(a), cx, w.y + CIRCLE + 22, 12, if (ui.isHover(w) or ui.isFocus(w)) t.menu_text else t.menu_muted);
            }
            if (view == .wait) ui.centered(cv, "Please wait…", W / 2, ui.H() - 14, 12, t.menu_muted);
            ui.paintMsg(cv, ui.H() - 14);
        },
        .confirm => {
            ui.icon(cv, iconOf(chosen), W / 2 - 16, 30, 32, 2, if (chosen == .poweroff) t.menu_error else t.menu_text);
            ui.centered(cv, question(chosen), W / 2, 100, 17, t.menu_text);
            ui.centered(cv, "Unsaved data will be lost", W / 2, 122, 12, t.menu_muted);
            for (ui.widgets[0..ui.nwid]) |w| {
                switch (wid(w)) {
                    .primary => ui.button(cv, w, verb(chosen), .primary),
                    .secondary => ui.button(cv, w, "Cancel", .secondary),
                    else => {},
                }
            }
        },
    }
}
