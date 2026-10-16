// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zwifi — Wi‑Fi menu for netline, in pure Zig.
//!
//! Network list, connecting to open, WPA/WPA2/WPA3 Personal and enterprise
//! (802.1X: PEAP, TTLS, EAP-TLS) networks through NetworkManager over D-Bus,
//! or through iwd when NetworkManager isn't running (802.1X then needs a profile from root).
//! `zwifi toggle` turns Wi‑Fi on/off without a window.
//! Keyboard: Tab/Shift+Tab, ↑/↓, Enter, Esc, Ctrl+V — paste, Ctrl+U — clear the field.

const std = @import("std");
const sys = @import("sys.zig");
const draw = @import("draw.zig");
const theme = @import("theme.zig");
const cfg = @import("config.zig");
const nm = @import("nm.zig");
const ui = @import("ui.zig");
const rt = @import("rt.zig");

pub const panic = rt.panic;
pub const std_options = rt.std_options;

const PAD = ui.PAD;
const ROW_H: f32 = 44;
const LIST_Y: f32 = 62;
const FIELD_H: f32 = 34;
const LABEL_W: f32 = 124;
const STEP: f32 = 42;

const View = enum { list, password, enterprise, hidden, actions, connecting, done };
var view: View = .list;
var form_view: View = .password; // where to go back on failure

var nets: [48]nm.Net = undefined;
var list: ui.List = .{};
var target: nm.Net = .{};
var target_hidden = false;
var reenter = false; // the saved profile didn't work — the old one is removed on submit
var nm_ok = false;
var loaded = false; // the list isn't loaded yet: the window shows right away, the data on the next tick
var ticks: u32 = 0;

const F = enum(u8) { ssid, password, identity, anon, ca, domain, cert, key, keypass };
var fields: [9]ui.Field = @as([9]ui.Field, @splat(.{}));
var reveal = false;
var method: nm.Eap = .peap;
var phase2: u8 = 0;
var hsec: u8 = 1; // hidden network: 0 open, 1 personal, 2 enterprise

const peap_p2 = [_][]const u8{ "mschapv2", "gtc", "md5" };
const peap_p2_label = [_][]const u8{ "MSCHAPv2", "GTC", "MD5" };
const ttls_p2 = [_][]const u8{ "pap", "mschapv2", "mschap", "chap" };
const ttls_p2_label = [_][]const u8{ "PAP", "MSCHAPv2", "MSCHAP", "CHAP" };
const method_label = [_][]const u8{ "PEAP", "TTLS", "TLS (certificate)" };
const hsec_label = [_][]const u8{ "Open", "WPA/WPA2/WPA3 Personal", "Enterprise 802.1X" };

const Wid = enum(u8) { none, row, more, toggle, back, other, field, select, eye, primary, secondary, act_connect, act_disconnect, act_forget };

fn wid(w: ui.Widget) Wid {
    return @enumFromInt(w.id);
}

// ================================================================= startup

pub fn main(init: std.process.Init.Minimal) void {
    sys.init(init);
    if (sys.argIs(1, "toggle")) {
        // no window: toggle the radio and exit
        if (!nm.init()) {
            sys.log("{s}", .{nm.lastError()});
            sys.exit(1);
        }
        if (!nm.setEnabled(!nm.wifi_enabled)) {
            sys.log("{s}", .{nm.lastError()});
            sys.exit(1);
        }
        sys.exit(0);
    }
    ui.begin("zwifi");
    nm_ok = nm.init();
    if (!nm_ok) ui.setMsg(nm.lastError());
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
        .cycle = cycleSelect,
        .extra_fd = busFd,
        .on_extra = onBus,
        .start = start,
        .cleanup = cleanup,
        .hover_local = true,
    }, .{}, .{});
}

fn start() void {
    list.visible = @intFromFloat((ui.H() - LIST_Y - 64) / ROW_H);
    // the menu appears right away ("Searching for networks…"), the list loads on the first timer tick
    if (nm_ok) ui.setTimer(1, SCAN_MS) else armTimer();
}

fn busFd() i32 {
    return if (nm_ok) nm.bus.fd else -1;
}

/// NetworkManager signals: new networks are shown as soon as NM finds them,
/// and the connection result as soon as the device changes state.
fn onBus() void {
    // second pass: synchronous calls from handleSignals may have read signals into the buffer
    for (0..2) |_| {
        if (!nm_ok) return;
        nm.bus.pump() catch {
            nm_ok = false;
            ui.setMsg("lost connection to the Wi‑Fi service");
            return;
        };
        handleSignals();
    }
}

fn handleSignals() void {
    if (nm.nets_changed and view == .list and loaded and !refresh_pending) {
        // NM sends changes in a batch (access points, LastScan) — reread once, a little later;
        // the next scan comes a full interval after fresh results
        refresh_pending = true;
        ui.setTimer(SETTLE_MS, SCAN_MS);
    }
    if (nm.state_changed and view == .connecting) {
        nm.state_changed = false;
        checkProgress();
    }
}

fn cleanup() void {
    for (&fields) |*f| f.clear();
    sys.secureZero(nm.bus.out);
}

fn fieldAt(idx: u16) ?*ui.Field {
    return if (idx < fields.len) &fields[idx] else null;
}

// ================================================================= logic

/// Reread the network list. Whether the radio is on is reported by a signal — we don't ask separately.
fn refresh() void {
    nm.nets_changed = false; // even with the radio off: otherwise the signal would reschedule the update again and again
    list.setCount(if (nm.wifi_enabled) nm.networks(&nets) else 0);
    ui.redraw();
}

/// How often to ask NM to scan while the list is open. The list itself is updated from signals.
const SCAN_MS = 10_000;
/// How long to wait after the first list-change signal to collect the whole batch.
const SETTLE_MS = 40;
var refresh_pending = false;

/// Timer: in the list — repeated network scans; while connecting — the dots animation
/// (the result comes as a signal, polling is only a fallback).
fn armTimer() void {
    switch (view) {
        .connecting => ui.setTimer(500, 500),
        .done => ui.setTimer(900, 0),
        .list => ui.setTimer(SCAN_MS, SCAN_MS),
        else => ui.setTimer(0, 0), // nothing is polled in forms
    }
}

fn setView(v: View) void {
    view = v;
    refresh_pending = false;
    armTimer();
    ui.resetFocus(v == .actions);
}

fn onTick() void {
    ticks +%= 1;
    switch (view) {
        .list => {
            if (!nm_ok) return;
            if (!loaded) {
                // first what NM already knows (the list shows right away), then a new scan
                loaded = true;
                nm.loadSaved();
                refresh();
                if (nm.wifi_enabled) nm.scan();
            } else if (refresh_pending) {
                refresh_pending = false;
                refresh();
            } else if (nm.wifi_enabled) nm.scan(); // the results arrive as signals (AccessPointAdded, LastScan)
        },
        .connecting => {
            ui.redrawText(ui.H() / 2 + 14, 14); // dots animation — only its row
            if (ticks > 90 * 1000 / 500) return fail("Timed out");
            // the result comes with the device's StateChanged signal; asking NM is only a fallback, once a second
            // (iwd's answer is the reply to Connect — checking for it costs nothing)
            if (nm.backend == .iwd or ticks % 2 == 0) checkProgress();
        },
        .done => ui.quit(),
        else => {},
    }
    onBus();
}

fn checkProgress() void {
    switch (nm.progress()) {
        .working => {},
        .done => {
            for (&fields) |*f| f.clear();
            setView(.done);
        },
        .failed => fail(nm.lastError()),
    }
}

fn fail(why: []const u8) void {
    nm.dropCreated();
    // the saved profile didn't work — offer to enter the credentials again
    if (form_view == .list) {
        reenter = true;
        form_view = switch (target.sec) {
            .eap => .enterprise,
            .psk, .sae => .password,
            else => .list,
        };
    }
    setView(form_view);
    ui.setMsg(why);
    nm.loadSaved();
}

fn startConnecting(from: View) void {
    form_view = from;
    ticks = 0;
    ui.clearMsg();
    setView(.connecting);
}

fn goBack() void {
    ui.clearMsg();
    switch (view) {
        .list => ui.quit(),
        .connecting => {
            _ = nm.disconnect();
            nm.dropCreated();
            setView(.list);
            refresh();
        },
        .enterprise => setView(if (target_hidden) .hidden else .list),
        else => setView(.list),
    }
}

fn clearForm() void {
    for (&fields) |*f| f.clear();
    reveal = false;
    ui.clearMsg();
}

fn chooseNet(i: usize, right: bool) void {
    if (i >= list.n) return;
    target = nets[i];
    target_hidden = false;
    reenter = false;
    clearForm();
    if (target.active or (right and target.known)) return setView(.actions);
    if (target.known) {
        if (nm.activateSaved(target.conn.get(), target.ap.get())) startConnecting(.list) else ui.setMsg(nm.lastError());
        return;
    }
    switch (target.sec) {
        .open, .owe => connectSimple(),
        .psk, .sae => setView(.password),
        .eap => {
            // iwd takes 802.1X settings only from a root-owned file — no form to fill in
            if (nm.backend == .iwd) return ui.setMsg(iwd_eap);
            method = .peap;
            phase2 = 0;
            setView(.enterprise);
        },
        .wep => ui.setMsg("WEP is outdated and insecure — not supported"),
    }
}

const iwd_eap = "802.1X with iwd: the administrator creates /var/lib/iwd/<SSID>.8021x";

fn connectSimple() void {
    if (nm.addAndActivate(.{ .ssid = target.ssid(), .hidden = target_hidden, .sec = target.sec }, target.ap.get())) {
        startConnecting(.list);
    } else ui.setMsg(nm.lastError());
}

fn onKey(k: ui.Key) bool {
    if (view != .list) return false;
    switch (k.code) {
        ui.K_UP, ui.K_DOWN => {
            ui.focus = .{}; // arrows move through the list again, not the button
            list.move(if (k.code == ui.K_UP) -1 else 1);
        },
        ui.K_ENTER, ui.K_KPENTER => {
            if (ui.focus.id != 0) return false; // a button has focus — press it
            if (list.n > 0) chooseNet(list.sel, false);
        },
        else => return false,
    }
    return true;
}

fn onScroll(d: i32) void {
    if (view == .list) list.scrollBy(d);
}

fn activate(w: ui.Widget, right: bool) void {
    switch (wid(w)) {
        .row => {
            list.sel = w.idx;
            chooseNet(w.idx, right);
        },
        .more => {
            target = nets[w.idx];
            setView(.actions);
        },
        .toggle => {
            if (nm.setEnabled(!nm.wifi_enabled)) refresh() else ui.setMsg(nm.lastError());
        },
        .back => goBack(),
        .other => {
            clearForm();
            hsec = 1;
            target_hidden = true;
            setView(.hidden);
        },
        .eye => reveal = !reveal,
        .primary => submit(),
        .secondary => goBack(),
        .act_connect => {
            if (nm.activateSaved(target.conn.get(), target.ap.get())) startConnecting(.list) else ui.setMsg(nm.lastError());
        },
        .act_disconnect => {
            if (nm.disconnect()) {
                setView(.list);
                refresh();
            } else ui.setMsg(nm.lastError());
        },
        .act_forget => {
            if (target.known and nm.forget(target.conn.get())) {
                nm.loadSaved();
                setView(.list);
                refresh();
            } else ui.setMsg(nm.lastError());
        },
        .field, .select, .none => {},
    }
}

fn cycleSelect(idx: u16, back_dir: bool) void {
    const d: i32 = if (back_dir) -1 else 1;
    switch (idx) {
        0 => {
            method = @enumFromInt(@as(u8, @intCast(@mod(@as(i32, @intFromEnum(method)) + d, 3))));
            phase2 = 0;
        },
        1 => {
            const n: i32 = if (method == .ttls) ttls_p2.len else peap_p2.len;
            phase2 = @intCast(@mod(@as(i32, phase2) + d, n));
        },
        2 => hsec = @intCast(@mod(@as(i32, hsec) + d, 3)),
        else => {},
    }
    ui.redraw();
}

fn val(f: F) []const u8 {
    return fields[@intFromEnum(f)].text();
}

fn submit() void {
    ui.clearMsg();
    switch (view) {
        .password => {
            const pw = val(.password);
            if (target.sec == .psk and (pw.len < 8 or pw.len > 63)) return ui.setMsg("A WPA password is 8 to 63 characters");
            if (pw.len == 0) return ui.setMsg("Enter the password");
            if (reenter and target.known) _ = nm.forget(target.conn.get());
            if (nm.addAndActivate(.{ .ssid = target.ssid(), .hidden = target_hidden, .sec = target.sec, .psk = pw }, target.ap.get())) {
                startConnecting(.password);
            } else ui.setMsg(nm.lastError());
        },
        .enterprise => {
            if (val(.identity).len == 0) return ui.setMsg("Enter the login");
            if (method == .tls) {
                if (val(.cert).len == 0) return ui.setMsg("Specify the certificate file");
            } else if (val(.password).len == 0) return ui.setMsg("Enter the password");
            if (reenter and target.known) _ = nm.forget(target.conn.get());
            const spec = nm.Spec{
                .ssid = target.ssid(),
                .hidden = target_hidden,
                .sec = .eap,
                .eap = method,
                .phase2 = if (method == .ttls) ttls_p2[phase2] else peap_p2[phase2],
                .identity = val(.identity),
                .anon_identity = val(.anon),
                .password = val(.password),
                .ca_cert = val(.ca),
                .domain = val(.domain),
                .client_cert = val(.cert),
                .private_key = val(.key),
                .key_password = val(.keypass),
            };
            if (nm.addAndActivate(spec, target.ap.get())) startConnecting(.enterprise) else ui.setMsg(nm.lastError());
        },
        .hidden => {
            const ssid = val(.ssid);
            if (ssid.len == 0 or ssid.len > 32) return ui.setMsg("The network name is 1 to 32 bytes");
            target = .{};
            @memcpy(target.ssid_buf[0..ssid.len], ssid);
            target.ssid_len = @intCast(ssid.len);
            target_hidden = true;
            switch (hsec) {
                0 => {
                    target.sec = .open;
                    connectSimple();
                },
                1 => {
                    target.sec = .psk;
                    const pw = val(.password);
                    if (pw.len < 8 or pw.len > 63) return ui.setMsg("A WPA password is 8 to 63 characters");
                    if (nm.addAndActivate(.{ .ssid = ssid, .hidden = true, .sec = .psk, .psk = pw }, "")) startConnecting(.hidden) else ui.setMsg(nm.lastError());
                },
                else => {
                    if (nm.backend == .iwd) return ui.setMsg(iwd_eap);
                    target.sec = .eap;
                    method = .peap;
                    phase2 = 0;
                    setView(.enterprise);
                },
            }
        },
        else => {},
    }
}

// ================================================================= layout

/// Rows of the 802.1X form: (field/selector, index, caption).
const FormRow = struct { id: Wid, idx: u8, label: []const u8 };

fn enterpriseRows(out: *[8]FormRow) usize {
    var n: usize = 0;
    out[n] = .{ .id = .select, .idx = 0, .label = "Method" };
    n += 1;
    if (method != .tls) {
        out[n] = .{ .id = .select, .idx = 1, .label = "Phase 2" };
        n += 1;
    }
    out[n] = .{ .id = .field, .idx = @intFromEnum(F.identity), .label = "Login" };
    n += 1;
    if (method == .tls) {
        out[n] = .{ .id = .field, .idx = @intFromEnum(F.cert), .label = "Certificate" };
        n += 1;
        out[n] = .{ .id = .field, .idx = @intFromEnum(F.key), .label = "Key" };
        n += 1;
        out[n] = .{ .id = .field, .idx = @intFromEnum(F.keypass), .label = "Key password" };
        n += 1;
    } else {
        out[n] = .{ .id = .field, .idx = @intFromEnum(F.password), .label = "Password" };
        n += 1;
        out[n] = .{ .id = .field, .idx = @intFromEnum(F.anon), .label = "Anon. login" };
        n += 1;
    }
    out[n] = .{ .id = .field, .idx = @intFromEnum(F.ca), .label = "CA certificate" };
    n += 1;
    out[n] = .{ .id = .field, .idx = @intFromEnum(F.domain), .label = "Server domain" };
    n += 1;
    return n;
}

fn hiddenRows(out: *[8]FormRow) usize {
    var n: usize = 0;
    out[n] = .{ .id = .field, .idx = @intFromEnum(F.ssid), .label = "Network name" };
    n += 1;
    out[n] = .{ .id = .select, .idx = 2, .label = "Security" };
    n += 1;
    if (hsec == 1) {
        out[n] = .{ .id = .field, .idx = @intFromEnum(F.password), .label = "Password" };
        n += 1;
    }
    return n;
}

fn bottomButtons() void {
    const bw = (ui.W() - 2 * PAD - 10) / 2;
    const y = ui.H() - PAD - 38;
    ui.add(Wid.secondary, 0, .button, PAD, y, bw, 38);
    ui.add(Wid.primary, 0, .button, PAD + bw + 10, y, bw, 38);
}

fn back() void {
    ui.add(Wid.back, 0, .plain, PAD - 8, 16, 30, 30);
}

fn layout() void {
    ui.nwid = 0;
    const W = ui.W();
    switch (view) {
        .list => {
            if (nm_ok) ui.add(Wid.toggle, 0, .toggle, W - PAD - 40, 20, 40, 22);
            var i = list.scroll;
            var y = LIST_Y;
            while (i < list.n and i < list.scroll + list.visible) : (i += 1) {
                ui.add(Wid.row, i, .row, PAD - 8, y, W - 2 * PAD + 16, ROW_H - 4);
                if (nets[i].known) ui.add(Wid.more, i, .plain, W - PAD - 34, y + 6, 28, 28);
                y += ROW_H;
            }
            if (nm_ok and nm.wifi_enabled) ui.add(Wid.other, 0, .button, PAD, ui.H() - PAD - 38, W - 2 * PAD, 38);
        },
        .password => {
            back();
            ui.add(Wid.field, @intFromEnum(F.password), .field, PAD, 112, W - 2 * PAD, FIELD_H);
            ui.add(Wid.eye, 0, .plain, W - PAD - 32, 115, 28, 28);
            bottomButtons();
        },
        .enterprise, .hidden => {
            back();
            var rows: [8]FormRow = undefined;
            const n = if (view == .enterprise) enterpriseRows(&rows) else hiddenRows(&rows);
            var y: f32 = 64;
            for (rows[0..n]) |r| {
                ui.add(r.id, r.idx, if (r.id == .field) .field else .select, PAD + LABEL_W, y, W - 2 * PAD - LABEL_W, FIELD_H);
                y += STEP;
            }
            bottomButtons();
        },
        .actions => {
            back();
            var y: f32 = 110;
            if (target.active) {
                ui.add(Wid.act_disconnect, 0, .button, PAD, y, W - 2 * PAD, 40);
            } else {
                ui.add(Wid.act_connect, 0, .button, PAD, y, W - 2 * PAD, 40);
            }
            y += 50;
            if (target.known) ui.add(Wid.act_forget, 0, .button, PAD, y, W - 2 * PAD, 40);
        },
        .connecting => ui.add(Wid.secondary, 0, .button, (W - 140) / 2, ui.H() - PAD - 38, 140, 38),
        .done => {},
    }
}

// ================================================================= drawing

fn signal(cv: *draw.Canvas, x: f32, y: f32, strength: u8, on: u32, off: u32) void {
    const lvl: u8 = if (strength > 75) 4 else if (strength > 50) 3 else if (strength > 25) 2 else 1;
    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const h = 4 + fi * 3.3;
        ui.rrect(cv, x + fi * 4.5, y + 14 - h, 3, h, 1.2, if (i < lvl) on else off);
    }
}

fn secLabel(s: nm.Security) []const u8 {
    return switch (s) {
        .open => "Open network",
        .owe => "Open (OWE, encrypted)",
        .psk => "WPA/WPA2 Personal",
        .sae => "WPA3 Personal",
        .eap => "Enterprise 802.1X",
        .wep => "WEP — not supported",
    };
}

fn paint(cv: *draw.Canvas) void {
    const t = &theme.t;
    const W = ui.W();
    const H = ui.H();
    switch (view) {
        .list => paintList(cv),
        .password => {
            ui.header(cv, target.ssid(), secLabel(target.sec), true);
            _ = ui.text(cv, "Password", PAD, 102, 13, t.menu_muted, W);
            paintWidgets(cv);
            ui.paintMsg(cv, 168);
        },
        .enterprise, .hidden => {
            ui.header(cv, if (view == .hidden) "Other network" else target.ssid(), if (view == .hidden) "" else secLabel(.eap), true);
            var rows: [8]FormRow = undefined;
            const n = if (view == .enterprise) enterpriseRows(&rows) else hiddenRows(&rows);
            var y: f32 = 64;
            for (rows[0..n]) |r| {
                _ = ui.text(cv, r.label, PAD, ui.mid(y, FIELD_H, 13), 13, t.menu_muted, PAD + LABEL_W - 6);
                y += STEP;
            }
            paintWidgets(cv);
            if (ui.msg().len > 0) {
                ui.paintMsg(cv, y + 16);
            } else if (view == .enterprise and val(.ca).len == 0 and val(.domain).len == 0) {
                _ = ui.text(cv, "Without a CA and domain the server is not verified", PAD, y + 16, 12, t.menu_muted, W - PAD);
            }
        },
        .actions => {
            ui.header(cv, target.ssid(), if (target.active) "Connected" else "Saved network", true);
            paintWidgets(cv);
            ui.paintMsg(cv, 230);
        },
        .connecting => {
            ui.centered(cv, target.ssid(), W / 2, H / 2 - 18, 18, t.menu_text);
            var b: [40]u8 = undefined;
            _ = ui.text(cv, ui.dots("Connecting", ticks, &b), W / 2 - ui.textW("Connecting...", 14) / 2, H / 2 + 14, 14, t.menu_muted, W);
            paintWidgets(cv);
        },
        .done => ui.paintDone(cv, "Connected"),
    }
}

fn paintList(cv: *draw.Canvas) void {
    const t = &theme.t;
    const W = ui.W();
    const H = ui.H();
    ui.header(cv, "Wi‑Fi", "", false);
    if (!nm_ok) {
        ui.centered(cv, "Wi‑Fi service is unavailable", W / 2, H / 2 - 8, 15, t.menu_text);
        ui.centered(cv, ui.msg(), W / 2, H / 2 + 16, 12, t.menu_muted);
        return;
    }
    if (!nm.wifi_enabled) {
        ui.centered(cv, "Wi‑Fi is off", W / 2, H / 2, 15, t.menu_muted);
    } else if (list.n == 0) {
        ui.centered(cv, "Searching for networks…", W / 2, H / 2, 15, t.menu_muted);
    }
    paintWidgets(cv);
    ui.paintMsg(cv, H - PAD - 52);
    ui.scrollbar(cv, &list, LIST_Y, ROW_H);
}

fn paintWidgets(cv: *draw.Canvas) void {
    const t = &theme.t;
    for (ui.widgets[0..ui.nwid]) |w| {
        const hov = ui.isHover(w);
        switch (wid(w)) {
            .row => {
                const n = &nets[w.idx];
                if (list.lit(w)) ui.rrect(cv, w.x, w.y, w.w, w.h, 10, t.menu_hover);
                signal(cv, w.x + 12, w.y + (w.h - 14) / 2, n.strength, if (n.active) t.menu_accent else t.menu_text, t.menu_border);
                const name_c = if (n.active) t.menu_accent else t.menu_text;
                var right = w.x + w.w - 12;
                if (n.known) right -= 30;
                if (n.active) {
                    ui.icon(cv, &ui.ic_check, right - 16, w.y + (w.h - 16) / 2, 16, 2, t.menu_accent);
                    right -= 22;
                }
                if (n.sec != .open and n.sec != .owe) {
                    ui.icon(cv, &ui.ic_lock, right - 14, w.y + (w.h - 14) / 2, 14, 1.6, t.menu_muted);
                    right -= 20;
                }
                if (n.sec == .eap) {
                    const tag = "802.1X";
                    const tw = ui.textW(tag, 11);
                    _ = ui.text(cv, tag, right - tw, ui.mid(w.y, w.h, 11), 11, t.menu_muted, ui.W());
                    right -= tw + 8;
                }
                _ = ui.text(cv, n.ssid(), w.x + 38, ui.mid(w.y, w.h, 14), 14, name_c, right - 6);
            },
            .more => {
                if (hov) ui.rrect(cv, w.x, w.y, w.w, w.h, 8, t.menu_hover);
                ui.icon(cv, &ui.ic_more, w.x + 6, w.y + 6, 16, 1, t.menu_muted);
            },
            .toggle => ui.toggle(cv, w, nm.wifi_enabled),
            .back => ui.paintBack(cv, w),
            .other => ui.button(cv, w, "Other network…", .secondary),
            .primary => ui.button(cv, w, if (view == .hidden and hsec == 2) "Next" else "Connect", .primary),
            .secondary => ui.button(cv, w, "Cancel", .secondary),
            .act_connect => ui.button(cv, w, "Connect", .primary),
            .act_disconnect => ui.button(cv, w, "Disconnect", .secondary),
            .act_forget => ui.button(cv, w, "Forget network", .danger),
            .field => {
                const fi: F = @enumFromInt(w.idx);
                const secret = fi == .password or fi == .keypass;
                ui.field(cv, w, &fields[w.idx], placeholder(fi), secret and !reveal, if (view == .password) 28 else 0);
            },
            .select => ui.select(cv, w, switch (w.idx) {
                0 => method_label[@intFromEnum(method)],
                1 => if (method == .ttls) ttls_p2_label[phase2] else peap_p2_label[phase2],
                else => hsec_label[hsec],
            }),
            .eye => {
                const c = if (hov) t.menu_text else t.menu_muted;
                ui.icon(cv, &ui.ic_eye, w.x + 6, w.y + 6, 16, 1.5, c);
                if (!reveal) ui.icon(cv, &ui.ic_slash, w.x + 6, w.y + 6, 16, 1.5, c);
            },
            .none => {},
        }
    }
}

fn placeholder(f: F) []const u8 {
    return switch (f) {
        .ssid => "hidden network name",
        .password => "",
        .identity => "user@example.com",
        .anon => "optional",
        .ca => "/path/to/ca.pem — optional",
        .domain => "radius.example.com",
        .cert => "/path/to/client.p12",
        .key => "not needed for .p12",
        .keypass => "",
    };
}
