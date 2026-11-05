// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zctl — sound, brightness and battery, in pure Zig. The panel's menu, in the place and manner
//! of the macOS Control Center, and a command for hotkeys:
//!
//!     zctl vol +5 | vol -5 | vol 40     volume; raising it also unmutes
//!     zctl mute                         mute on/off
//!     zctl bright +5 | bright 40        brightness
//!     zctl status                       the state, one line per item
//!
//! Sound goes over the server's own socket (audio.zig), no pactl or wpctl. Brightness is written to
//! the kernel's file if that is allowed (the video group, with the rule brightnessctl and others
//! install), otherwise logind or elogind does it for the active session: no setuid helper, no root.
//! Everything is opened before the sandbox, which then allows neither opening anything for
//! writing nor making new connections.
//! Keys in the menu: ↑/↓ — volume, ←/→ — brightness, M — mute, Esc — close.

const std = @import("std");
const sys = @import("sys.zig");
const draw = @import("draw.zig");
const theme = @import("theme.zig");
const cfg = @import("config.zig");
const dbus = @import("dbus.zig");
const audio = @import("audio.zig");
const status = @import("status.zig");
const sandbox = @import("sandbox.zig");
const ui = @import("ui.zig");
const rt = @import("rt.zig");

pub const panic = rt.panic;
pub const std_options = rt.std_options;

const LOGIN = "org.freedesktop.login1";
const SESSION_PATH = "/org/freedesktop/login1/session/auto";
const SESSION = "org.freedesktop.login1.Session";

const WIDTH: f32 = 320;
const M: f32 = 10; // margin of the tiles inside the card
const GAP: f32 = 8;
const TILE_H: f32 = 74;
const BATTERY_H: f32 = 60;
const SLIDER_H: f32 = 28;
const SLIDER_Y: f32 = 34; // from the top of the tile
const ICON_ROOM: f32 = 30; // the left end of a slider holds its icon, the knob stops before it
const STEP: i32 = 5;
const REFRESH_MS: u32 = 2000; // brightness and battery while the menu is open
const SEND_MS: u64 = 16; // a dragged slider talks to the sound server at most this often

const read_paths = [_][:0]const u8{ "/sys/class", "/sys/devices", status.root };

var snd: audio.Client = .{};
var light: status.Backlight = .{};
var bat: status.Battery = .{};
var has_sound = false;
var has_light = false;
var has_battery = false;

var light_fd: i32 = -1;
var bus: dbus.Conn = .{};
var bus_ok = false;
var bus_serial: u32 = 0; // a brightness call under way
var bus_next: ?u32 = null; // the value to send when it returns
var body_buf: [256]u8 = undefined;

var drag_vol: u8 = 0;
var drag_light: u8 = 0;
var vol_pending = false;
var vol_sent_ms: u64 = 0;

const Wid = enum(u8) { none, vol, mute, light };

// ================================================================= startup

pub fn main(init: std.process.Init.Minimal) void {
    sys.init(init);
    if (sys.argAt(1)) |cmd| oneShot(cmd);
    if (sys.getuid() == 0) {
        sys.log("running as root is not allowed", .{});
        sys.exit(1);
    }
    ui.begin("zctl");
    connectSound();
    if (snd.fd >= 0) _ = snd.waitInfo(300);
    light = status.backlight();
    bat = status.battery();
    has_sound = snd.sink.present;
    has_light = light.present;
    has_battery = bat.state != .none;
    if (has_light) openLight();

    var h: f32 = M;
    if (has_sound) h += TILE_H + GAP;
    if (has_light) h += TILE_H + GAP;
    if (has_battery) h += BATTERY_H + GAP;
    if (!has_sound and !has_light and !has_battery) h += BATTERY_H + GAP;
    h += M - GAP;

    ui.run(.{
        .place = .top_right,
        .width = @intFromFloat(WIDTH),
        .height = @intFromFloat(h),
        .layout = layout,
        .paint = paint,
        .activate = activate,
        .back = ui.quit,
        .key = onKey,
        .scroll = onScroll,
        .tick = onTick,
        .drag = onDrag,
        .extra_fd = soundFd,
        .on_extra = onSound,
        .extra2_fd = busFd,
        .on_extra2 = onBus,
        .start = onStart,
    }, .{ .read = &read_paths }, .{});
}

fn onStart() void {
    ui.setTimer(REFRESH_MS, REFRESH_MS);
}

fn connectSound() void {
    var buf: [128]u8 = undefined;
    const path = audio.socketPath(&buf) orelse return;
    const fd = sys.connectUnix(path) catch return;
    if (!snd.start(fd)) snd.close();
}

/// The direct way if the file allows it; otherwise the session's logind.
fn openLight() void {
    var path: [256]u8 = undefined;
    const file = sys.joinZ(&path, &.{ status.light_dir ++ "/", light.name(), "/brightness" });
    light_fd = (if (status.root.len > 0) sys.openAppend(file) else sys.openRW(file)) catch -1;
    if (light_fd >= 0) return;
    if (bus.connectSystem()) |_| {
        bus_ok = true;
    } else |_| {}
}

// ================================================================= brightness

fn writeRaw(raw: u32) bool {
    var b: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{d}\n", .{raw}) catch return false;
    // sysfs takes each write as the whole value; the plain file of a test needs emptying first
    if (status.root.len > 0) sys.ftruncate(light_fd, 0) catch return false;
    sys.writeAll(light_fd, s) catch return false;
    return true;
}

fn lightBody(raw: u32) []const u8 {
    var w = dbus.W{ .buf = &body_buf };
    w.str("backlight");
    w.str(light.name());
    w.u32_(raw);
    return w.bytes();
}

fn setLightRaw(raw: u32) void {
    light.raw = raw;
    light.percent = status.lightPercent(raw, light.max);
    if (light_fd >= 0) {
        _ = writeRaw(raw);
    } else if (bus_ok) {
        // one call at a time, the last value wins: a dragged slider can't flood logind
        if (bus_serial != 0) {
            bus_next = raw;
            return;
        }
        bus_serial = bus.callAsync(LOGIN, SESSION_PATH, SESSION, "SetBrightness", "ssu", lightBody(raw)) catch 0;
    }
}

fn busFd() i32 {
    return if (bus_ok) bus.fd else -1;
}

fn onBus() void {
    bus.pump() catch {
        bus_ok = false;
        return;
    };
    if (bus_serial == 0) return;
    const d = bus.result(bus_serial) orelse return;
    bus_serial = 0;
    if (!d.ok) ui.setMsg("Brightness refused: no active session, or not in the video group");
    if (bus_next) |raw| {
        bus_next = null;
        setLightRaw(raw);
    }
}

// ================================================================= sound

fn soundFd() i32 {
    return snd.fd;
}

fn onSound() void {
    if (snd.onReadable()) ui.redraw();
    snd.moved = false;
}

fn setVolume(p: u8) void {
    if (snd.sink.muted and p > 0) _ = snd.setMuted(false);
    _ = snd.setPercent(p);
    vol_sent_ms = sys.monoMs();
    vol_pending = false;
}

fn stepVolume(d: i32) void {
    if (!snd.sink.present) return;
    setVolume(@intCast(std.math.clamp(@as(i32, snd.sink.percent) + d, 0, 100)));
}

fn toggleMute() void {
    if (snd.sink.present) _ = snd.setMuted(!snd.sink.muted);
}

fn stepLight(d: i32) void {
    if (has_light) setLightRaw(status.lightStep(light.raw, light.max, d));
}

// ================================================================= input

fn onTick() void {
    if (vol_pending) setVolume(drag_vol);
    ui.setTimer(REFRESH_MS, REFRESH_MS);
    // a slider being dragged knows better than a file that hasn't caught up
    if (has_light and ui.draggedId() != @intFromEnum(Wid.light)) {
        const now = status.backlight();
        if (now.raw != light.raw or now.present != light.present) light = now;
    }
    if (has_battery) bat = status.battery();
    ui.redraw(); // the frame goes out only if a pixel differs
}

fn onKey(k: ui.Key) bool {
    switch (k.code) {
        ui.K_UP => stepVolume(STEP),
        ui.K_DOWN => stepVolume(-STEP),
        ui.K_RIGHT => stepLight(STEP),
        ui.K_LEFT => stepLight(-STEP),
        K_M => toggleMute(),
        ui.K_ENTER, ui.K_KPENTER, ui.K_TAB, ui.K_SPACE => {},
        else => return false,
    }
    return true;
}

const K_M = 50;

fn onScroll(dir: i32) void {
    switch (@as(Wid, @enumFromInt(ui.hover.id))) {
        .vol, .mute => stepVolume(-dir * STEP),
        .light => stepLight(-dir * STEP),
        .none => {},
    }
    ui.redraw();
}

fn activate(w: ui.Widget, right: bool) void {
    _ = right;
    if (@as(Wid, @enumFromInt(w.id)) == .mute) toggleMute();
}

fn sliderPercent(w: ui.Widget, x: f32) u8 {
    const k = knobRange(w.x, w.w, w.h);
    const f = (x - k[0]) / (k[1] - k[0]);
    return @intFromFloat(@round(std.math.clamp(f, 0, 1) * 100));
}

fn onDrag(w: ui.Widget, x: f32, final: bool) void {
    const p = sliderPercent(w, x);
    switch (@as(Wid, @enumFromInt(w.id))) {
        .vol => {
            drag_vol = p;
            if (final) {
                setVolume(p);
                snd.sink.percent = p; // until the server's report arrives
            } else if (sys.monoMs() -| vol_sent_ms >= SEND_MS) {
                setVolume(p);
            } else if (!vol_pending) {
                vol_pending = true;
                ui.setTimer(@intCast(SEND_MS), 0);
            }
        },
        .light => {
            drag_light = p;
            if (light.max > 0) setLightRaw(status.lightRaw(p, light.max));
        },
        else => {},
    }
}

// ================================================================= the card

fn soundY() f32 {
    return M;
}
fn lightY() f32 {
    return M + (if (has_sound) TILE_H + GAP else 0);
}
fn batteryY() f32 {
    return lightY() + (if (has_light) TILE_H + GAP else 0);
}

fn layout() void {
    ui.nwid = 0;
    const x = M + 12;
    const w = WIDTH - 2 * x;
    if (has_sound) {
        ui.add(Wid.vol, 0, .slider, x, soundY() + SLIDER_Y, w, SLIDER_H);
        ui.add(Wid.mute, 0, .plain, x, soundY() + SLIDER_Y, ICON_ROOM, SLIDER_H);
    }
    if (has_light) ui.add(Wid.light, 0, .slider, x, lightY() + SLIDER_Y, w, SLIDER_H);
}

/// Where the knob's center travels.
fn knobRange(x: f32, w: f32, h: f32) [2]f32 {
    return .{ x + ICON_ROOM + h / 2, x + w - h / 2 };
}

fn slider(cv: *draw.Canvas, x: f32, y: f32, w: f32, pct: u8, off: bool) void {
    const t = &theme.t;
    const h = SLIDER_H;
    ui.rrect(cv, x, y, w, h, h / 2, t.menu_field);
    const k = knobRange(x, w, h);
    const cx = k[0] + (k[1] - k[0]) * @as(f32, @floatFromInt(pct)) / 100;
    ui.rrect(cv, x, y, cx + h / 2 - x, h, h / 2, if (off) t.menu_muted else t.menu_accent);
    ui.rrect(cv, cx - h / 2 + 3, y + 3, h - 6, h - 6, (h - 6) / 2, t.menu_text);
}

fn title(cv: *draw.Canvas, name: []const u8, detail: []const u8, pct: u8, x: f32, y: f32, w: f32) void {
    const t = &theme.t;
    var b: [8]u8 = undefined;
    const ps = std.fmt.bufPrint(&b, "{d}%", .{pct}) catch "";
    const right = x + w - ui.textW(ps, 12.5);
    const end = ui.text(cv, name, x, y, 13, t.menu_text, right);
    if (detail.len > 0) _ = ui.text(cv, detail, end + 8, y, 11.5, t.menu_muted, right - 8);
    _ = ui.text(cv, ps, right, y, 12.5, t.menu_muted, x + w);
}

fn paint(cv: *draw.Canvas) void {
    const t = &theme.t;
    const tx = M;
    const tw = WIDTH - 2 * M;
    const x = M + 12;
    const w = WIDTH - 2 * x;

    if (has_sound) {
        const y = soundY();
        ui.rrect(cv, tx, y, tw, TILE_H, 12, t.menu_hover);
        const dragged = ui.draggedId() == @intFromEnum(Wid.vol);
        const pct = if (dragged) drag_vol else snd.sink.percent;
        title(cv, "Sound", snd.sink.name(), pct, x, y + 23, w);
        const off = snd.sink.muted or !snd.sink.present;
        slider(cv, x, y + SLIDER_Y, w, pct, off);
        const ix = x + 7;
        const iy = y + SLIDER_Y + (SLIDER_H - 16) / 2;
        const ink = t.menu_accent_text;
        ui.icon(cv, &draw.icon_sound_body, ix, iy, 16, 1.5, ink);
        if (off) {
            ui.icon(cv, &draw.icon_sound_muted, ix, iy, 16, 1.5, ink);
        } else if (pct > 0) {
            const arcs: usize = if (pct < 34) 1 else if (pct < 67) 2 else 3;
            for (draw.icon_sound_arcs[0..arcs]) |*a| ui.icon(cv, a, ix, iy, 16, 1.5, ink);
        }
    }
    if (has_light) {
        const y = lightY();
        ui.rrect(cv, tx, y, tw, TILE_H, 12, t.menu_hover);
        const dragged = ui.draggedId() == @intFromEnum(Wid.light);
        const pct = if (dragged) drag_light else light.percent;
        title(cv, "Display", "", pct, x, y + 23, w);
        slider(cv, x, y + SLIDER_Y, w, pct, false);
        const ix = x + 7;
        const iy = y + SLIDER_Y + (SLIDER_H - 16) / 2;
        ui.icon(cv, &draw.icon_sun_core, ix, iy, 16, 1.5, t.menu_accent_text);
        ui.icon(cv, if (pct >= 50) &draw.icon_sun_rays else &draw.icon_sun_rays_low, ix, iy, 16, 1.5, t.menu_accent_text);
    }
    if (has_battery) paintBattery(cv, tx, batteryY(), tw);
    if (!has_sound and !has_light and !has_battery) {
        ui.centered(cv, "No sound server, backlight or battery found", WIDTH / 2, M + BATTERY_H / 2 + 4, 12, t.menu_muted);
    }
    if (ui.msg().len > 0) ui.centered(cv, ui.msg(), WIDTH / 2, ui.H() - 3, 9.5, t.menu_error);
}

fn stateWord(s: status.BatState) []const u8 {
    return switch (s) {
        .discharging => "On battery",
        .charging => "Charging",
        .full => "Fully charged",
        .idle => "Plugged in",
        .none => "",
    };
}

/// "On battery · 3 h 12 min left · 9.6 W": each part only if it is known.
pub fn batteryLine(buf: []u8, b: status.Battery) []const u8 {
    var n = (std.fmt.bufPrint(buf, "{s}", .{stateWord(b.state)}) catch return "").len;
    if (b.minutes > 0) {
        const tail: []const u8 = if (b.state == .charging) "to full" else "left";
        const h = b.minutes / 60;
        const m = b.minutes % 60;
        const part = (if (h > 0)
            std.fmt.bufPrint(buf[n..], " · {d} h {d} min {s}", .{ h, m, tail })
        else
            std.fmt.bufPrint(buf[n..], " · {d} min {s}", .{ m, tail })) catch return buf[0..n];
        n += part.len;
    }
    if (b.tenth_watts > 0 and (b.state == .discharging or b.state == .charging)) {
        const part = std.fmt.bufPrint(buf[n..], " · {d}.{d} W", .{ b.tenth_watts / 10, b.tenth_watts % 10 }) catch return buf[0..n];
        n += part.len;
    }
    return buf[0..n];
}

fn paintBattery(cv: *draw.Canvas, tx: f32, y: f32, tw: f32) void {
    const t = &theme.t;
    ui.rrect(cv, tx, y, tw, BATTERY_H, 12, t.menu_hover);
    const low = bat.state == .discharging and bat.percent <= cfg.battery_low;
    const col = if (bat.state == .charging) t.battery_charging else if (low) t.battery_low else t.menu_text;
    const ix = tx + 12;
    const iy = y + (BATTERY_H - 28) / 2;
    const fill = draw.batteryFill(bat.percent);
    ui.icon(cv, &draw.icon_battery, ix, iy, 28, 1.7, col);
    ui.icon(cv, &fill, ix, iy, 28, 1.7, col);
    if (bat.state == .charging) {
        ui.icon(cv, &draw.icon_bolt, ix, iy, 28, 3.6, t.menu_field | 0xff000000);
        ui.icon(cv, &draw.icon_bolt, ix, iy, 28, 1.3, col);
    }
    const x = ix + 28 + 12;
    var pb: [8]u8 = undefined;
    const ps = std.fmt.bufPrint(&pb, "{d}%", .{bat.percent}) catch "";
    _ = ui.text(cv, ps, x, y + 26, 17, t.menu_text, tx + tw - 8);
    var lb: [96]u8 = undefined;
    _ = ui.text(cv, batteryLine(&lb, bat), x, y + 45, 11.5, t.menu_muted, tx + tw - 8);
}

// ================================================================= the command

const Arg = struct { relative: bool, v: i32 };

/// "+5", "-5" or "40".
fn parseArg(s: []const u8) ?Arg {
    if (s.len == 0 or s.len > 4) return null;
    const relative = s[0] == '+' or s[0] == '-';
    const digits = if (relative) s[1..] else s;
    const n = std.fmt.parseInt(u8, digits, 10) catch return null;
    if (n > 100) return null;
    return .{ .relative = relative, .v = if (s[0] == '-') -@as(i32, n) else n };
}

fn applyArg(cur: u8, a: Arg) u8 {
    const v = if (a.relative) cur + a.v else a.v;
    return @intCast(std.math.clamp(v, 0, 100));
}

fn fail(msg: []const u8) noreturn {
    sys.say(&.{ "zctl: ", msg });
    sys.exit(1);
}

fn usage() noreturn {
    fail("usage: zctl [vol +N|-N|N] [mute] [bright +N|-N|N] [status]");
}

/// The rights a command needs are taken before it reads anything it didn't write itself.
fn lockDown() void {
    if (cfg.sandbox) sandbox.apply(&read_paths, &.{}, .{});
}

fn oneShot(cmd: []const u8) noreturn {
    const eql = std.mem.eql;
    if (eql(u8, cmd, "vol")) {
        const a = parseArg(sys.argAt(2) orelse usage()) orelse usage();
        const s = soundOrFail();
        const p = applyArg(s.sink.percent, a);
        // raising the volume says "I want to hear this": unmute, as the keys of a Mac do
        if (s.sink.muted and a.v > 0) _ = s.setMuted(false);
        if (!s.setPercent(p)) fail("the sound server stopped answering");
        waitWritten(s);
    } else if (eql(u8, cmd, "mute")) {
        const s = soundOrFail();
        if (!s.setMuted(!s.sink.muted)) fail("the sound server stopped answering");
        waitWritten(s);
    } else if (eql(u8, cmd, "bright")) {
        const a = parseArg(sys.argAt(2) orelse usage()) orelse usage();
        setBrightnessOnce(a);
    } else if (eql(u8, cmd, "status")) {
        printStatus();
    } else usage();
    sys.exit(0);
}

fn soundOrFail() *audio.Client {
    connectSound();
    if (snd.fd < 0) fail("no sound server is running");
    lockDown();
    if (!snd.waitInfo(1000)) fail("the sound server has no output");
    return &snd;
}

/// A request reaches the server before the process exits, but a server that sees the connection
/// end first may drop what it hasn't read: wait for its answer to the last one, briefly.
fn waitWritten(s: *audio.Client) void {
    var pfd = [1]sys.PollFd{.{ .fd = s.fd, .events = sys.POLLIN }};
    _ = sys.poll(&pfd, 200) catch {};
}

fn setBrightnessOnce(a: Arg) void {
    light = status.backlight();
    if (!light.present) fail("no backlight on this machine");
    const raw = if (a.relative)
        status.lightStep(light.raw, light.max, a.v)
    else
        status.lightRaw(@intCast(a.v), light.max);
    openLight();
    if (light_fd >= 0) {
        lockDown();
        if (!writeRaw(raw)) fail("could not write the brightness");
        return;
    }
    if (!bus_ok) fail("brightness needs logind, elogind or the video group");
    lockDown();
    const r = bus.call(LOGIN, SESSION_PATH, SESSION, "SetBrightness", "ssu", lightBody(raw)) catch fail("logind did not answer");
    if (!r.ok()) fail("logind refused: no active session?");
}

fn printStatus() void {
    connectSound();
    lockDown();
    var b: [160]u8 = undefined;
    if (snd.fd >= 0 and snd.waitInfo(500)) {
        const s = std.fmt.bufPrint(&b, "sound {d} {s} {s}\n", .{ snd.sink.percent, if (snd.sink.muted) "muted" else "on", snd.sink.name() }) catch "";
        sys.writeAll(1, s) catch {};
    }
    light = status.backlight();
    if (light.present) {
        const s = std.fmt.bufPrint(&b, "brightness {d} {d}/{d} {s}\n", .{ light.percent, light.raw, light.max, light.name() }) catch "";
        sys.writeAll(1, s) catch {};
    }
    bat = status.battery();
    if (bat.state != .none) {
        const s = std.fmt.bufPrint(&b, "battery {d} {s} {d}\n", .{ bat.percent, @tagName(bat.state), bat.minutes }) catch "";
        sys.writeAll(1, s) catch {};
    }
}
