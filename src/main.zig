// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! netline — a minimalist panel for MangoWM in pure Zig.
//! A Wayland client without libwayland: wl_shm + wlr-layer-shell + wl_pointer (+ cursor-shape).
//!
//! Load: the process sleeps in ppoll and wakes only on events — once a minute for the clock,
//! on kernel netlink events for Wi‑Fi/Bluetooth, on input and on a rare fallback timer.
//! A frame is drawn only on change, and only the changed rectangle is handed to the compositor.

const std = @import("std");
const sys = @import("sys.zig");
const wl = @import("wl.zig");
const draw = @import("draw.zig");
const status = @import("status.zig");
const tz = @import("tz.zig");
const ttf = @import("ttf.zig");
const mango = @import("mango.zig");
const broker = @import("broker.zig");
const sandbox = @import("sandbox.zig");
const theme = @import("theme.zig");
const cfg = @import("config.zig");
const rt = @import("rt.zig");

pub const panic = rt.panic;
pub const std_options = rt.std_options;

const MAX_BARS = mango.MAX_MONS;

const Kind = enum(u8) {
    none,
    display,
    registry,
    callback,
    compositor,
    shm,
    pool,
    buffer,
    surface,
    layer_shell,
    layer_surface,
    seat,
    pointer,
    output,
    cursor_mgr,
    cursor_dev,
};

const Buf = struct { id: u32 = 0, busy: bool = false };

const Hit = struct { item: cfg.Item, idx: u8 = 0, x: f32, y: f32, w: f32, h: f32 };

const Bar = struct {
    used: bool = false,
    out_name: u32 = 0, // name of the wl_output global
    output: u32 = 0,
    out_ver: u32 = 0,
    mon_buf: [64]u8 = undefined,
    mon_len: usize = 0,
    surface: u32 = 0,
    layer: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    scale: u32 = 1,
    configured: bool = false,
    dirty: bool = false,
    pool: u32 = 0,
    mem: ?[*]u8 = null,
    mem_len: usize = 0,
    pw: u32 = 0,
    ph: u32 = 0,
    bufs: [2]Buf = .{ .{}, .{} },
    last: ?u1 = null, // buffer with the last shown frame
    // the opaque region handed to the compositor: for which size, and whether there is one
    opaque_on: bool = false,
    opaque_w: u32 = 0,
    opaque_h: u32 = 0,
    tags: [mango.MAX_TAGS]mango.Tag = @as([mango.MAX_TAGS]mango.Tag, @splat(.{})),
    ntags: u8 = 0,
    hits: [48]Hit = undefined,
    nhits: usize = 0,
    hover: ?Hit = null,

    fn monName(self: *const Bar) []const u8 {
        return self.mon_buf[0..self.mon_len];
    }
};

// Command table for the broker: [item][button]. Built at compile time from config.zig.
const actions = [_]cfg.Action{ cfg.launcher, cfg.clock, cfg.wifi, cfg.bluetooth, cfg.wallpaper, cfg.power };
const commands = blk: {
    var c: [actions.len * 3]?broker.Cmd = undefined;
    for (actions, 0..) |a, i| {
        c[i * 3] = broker.compile(a.left);
        c[i * 3 + 1] = broker.compile(a.right);
        c[i * 3 + 2] = broker.compile(a.middle);
    }
    break :blk c;
};

fn actionIndex(item: cfg.Item) ?u8 {
    return switch (item) {
        .launcher => 0,
        .clock => 1,
        .wifi => 2,
        .bluetooth => 3,
        .wallpaper => 4,
        .power => 5,
        .tags => null,
    };
}

var conn: wl.Conn = .{};
var kinds: [wl.MAX_IDS]Kind = @as([wl.MAX_IDS]Kind, @splat(.none));
var owner: [wl.MAX_IDS]u8 = @as([wl.MAX_IDS]u8, @splat(0));
// filled in main: with defaults here (scale = 1) the whole array would sit in the file's .data
var bars: [MAX_BARS]Bar = undefined;

var registry: u32 = 0;
var compositor: u32 = 0;
var compositor_ver: u32 = 0;
var shm: u32 = 0;
var layer_shell: u32 = 0;
var seat: u32 = 0;
var seat_ver: u32 = 0;
var pointer: u32 = 0;
var cursor_mgr: u32 = 0;
var cursor_dev: u32 = 0;
var sync_done = false;
var ready = false;

var ptr_bar: ?u8 = null;
var ptr_x: f32 = 0;
var ptr_y: f32 = 0;
var scroll_acc: f32 = 0;
var last_click: [commands.len]?u32 = @as([commands.len]?u32, @splat(null));

var wifi_state: status.Wifi = .{};
var bt_state: status.Bt = .none;
var clock_buf: [64]u8 = undefined;
var clock_len: usize = 0;
var clock_hour: u32 = 99;

var clock_timer: i32 = -1;
var poll_timer: i32 = -1;
var poll_period: u32 = 0; // how many seconds the fallback poll is armed for (0 — off)
var burst: u32 = 0; // how many more quick (once a second) checks after a click

// ================================================================= main

pub fn main(init: std.process.Init.Minimal) void {
    sys.init(init);
    for (&bars) |*b| b.* = .{};
    if (sys.getuid() == 0) {
        sys.log("running as root is not allowed", .{});
        sys.exit(1);
    }
    // The broker forks off first: it has no Wayland socket or any other panel descriptors.
    if (!broker.start(&commands)) {
        sys.log("could not start the broker process", .{});
        sys.exit(1);
    }
    tz.load();
    theme.init();
    status.init();
    // The date and time are drawn with one TrueType font (clock_font_paths). Loaded before the
    // sandbox; if none is found, the clock falls back to the panel's vector digits.
    _ = ttf.load(&cfg.clock_font_paths);

    conn.connect() catch {
        sys.log("could not connect to Wayland (WAYLAND_DISPLAY/XDG_RUNTIME_DIR)", .{});
        sys.exit(1);
    };
    kinds[1] = .display;
    registry = create(.registry, 0);
    conn.send(1, 1, .{registry}); // wl_display.get_registry
    roundtrip();
    if (compositor == 0 or shm == 0 or layer_shell == 0) {
        sys.log("the compositor does not support wl_compositor/wl_shm/zwlr_layer_shell_v1", .{});
        sys.exit(1);
    }
    roundtrip(); // output names and scale
    ready = true;
    for (&bars, 0..) |*b, i| {
        if (b.used) setupBar(@intCast(i));
    }

    if (mango.connect()) applyTags() else burst = 5; // mango may not have its IPC up yet — retry

    clock_timer = sys.timerfdCreate(sys.CLOCK_REALTIME) catch fatal("timerfd");
    poll_timer = sys.timerfdCreate(sys.CLOCK_MONOTONIC) catch fatal("timerfd");
    armClock();
    _ = updateClock();
    refreshStatus(true, true); // also arms the fallback poll if it's needed

    if (cfg.sandbox) {
        const paths = [_][:0]const u8{ "/sys", "/proc", "/usr/share/zoneinfo", "/etc/localtime", tz.path, theme.dir };
        sandbox.apply(&paths, &.{}, .{ .ioctl = status.HCIGETDEVINFO });
    }

    while (true) {
        for (&bars, 0..) |*b, i| {
            if (b.used and b.configured and b.dirty) render(@intCast(i));
        }
        conn.flush() catch fatal("writing to the Wayland socket");

        var fds = [8]sys.PollFd{
            .{ .fd = conn.fd, .events = sys.POLLIN },
            .{ .fd = clock_timer, .events = sys.POLLIN },
            .{ .fd = poll_timer, .events = sys.POLLIN },
            .{ .fd = mango.fd, .events = sys.POLLIN },
            .{ .fd = status.route_fd, .events = sys.POLLIN },
            .{ .fd = status.uevent_fd, .events = sys.POLLIN },
            .{ .fd = theme.inotify_fd, .events = sys.POLLIN },
            .{ .fd = status.mgmt_fd, .events = sys.POLLIN },
        };
        _ = sys.poll(&fds, theme.timeout()) catch continue;
        if (sys.tracing()) traceWake(&fds);

        if (fds[0].revents != 0) readWayland();
        if (fds[1].revents != 0) onClockTimer();
        if (fds[2].revents != 0) onPollTimer();
        if (fds[3].revents != 0 and mango.fd >= 0) {
            if (mango.onReadable()) applyTags();
            if (mango.fd < 0) armPoll(); // mango closed the IPC — we'll reconnect
        }
        if (fds[4].revents != 0 or fds[5].revents != 0) {
            const ch = status.drainEvents(fds[4].revents != 0, fds[5].revents != 0);
            refreshStatus(ch.wifi, ch.bt);
        }
        if (fds[6].revents != 0 and theme.inotify_fd >= 0) theme.onInotify();
        if (theme.settle()) markAllDirty();
        if (fds[7].revents != 0 and status.mgmt_fd >= 0) {
            if (status.drainMgmt()) refreshStatus(false, true);
        }
    }
}

/// NETLINE_TRACE: why the panel woke up (when idle there should be no lines except the clock).
fn traceWake(fds: []const sys.PollFd) void {
    const names = [_][]const u8{ " wayland", " clock", " poll", " mango", " net", " devices", " theme", " bluetooth" };
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (fds, names) |f, nm| {
        if (f.revents == 0 or n + nm.len > buf.len) continue;
        @memcpy(buf[n..][0..nm.len], nm);
        n += nm.len;
    }
    sys.tracef("wakeup:{s}", .{buf[0..n]});
}

fn fatal(what: []const u8) noreturn {
    sys.log("error: {s}", .{what});
    sys.exit(1);
}

fn create(kind: Kind, own: u8) u32 {
    const id = conn.newId();
    kinds[id] = kind;
    owner[id] = own;
    return id;
}

fn forget(id: *u32) void {
    if (id.* != 0) kinds[id.*] = .none;
    id.* = 0;
}

fn roundtrip() void {
    const cb = create(.callback, 0);
    conn.send(1, 0, .{cb}); // wl_display.sync
    conn.flush() catch fatal("writing to the Wayland socket");
    sync_done = false;
    while (!sync_done) readWayland();
}

fn readWayland() void {
    const alive = conn.fill() catch fatal("reading from the Wayland socket");
    if (!alive) {
        sys.log("the compositor closed the connection", .{});
        sys.exit(0);
    }
    while (conn.next()) |ev| dispatch(ev);
}

// ================================================================= timers and status

fn armClock() void {
    const step: i64 = if (cfg.clock_format == .hms) 1 else 60;
    const now = sys.realtime();
    const next = now - @mod(now, step) + step;
    sys.timerfdArm(clock_timer, sys.TFD_TIMER_ABSTIME | sys.TFD_TIMER_CANCEL_ON_SET, next, @intCast(step)) catch {};
}

/// The fallback poll is only for things that send no events: Wi‑Fi signal level,
/// Bluetooth power (if the kernel gives no mgmt channel) and reconnecting to mango.
/// Nothing to poll — the timer is off and the panel sleeps until an event.
fn pollPeriod() u32 {
    if (burst > 0) return 1;
    if (mango.fd < 0 or wifi_state.state == .connected) return cfg.status_poll_s;
    if (bt_state != .none and !status.btEvents()) return cfg.status_poll_s;
    return 0;
}

fn armPoll() void {
    const s = pollPeriod();
    if (s == poll_period) return; // same period — don't reset the timer phase
    poll_period = s;
    sys.timerfdArm(poll_timer, 0, s, s) catch {};
}

fn drainTimer(fd: i32) bool {
    var exp: [8]u8 = undefined;
    _ = sys.read(fd, &exp) catch {
        return sys.last_errno == sys.ECANCELED; // the clock was changed — the timer must be re-armed
    };
    return false;
}

fn onClockTimer() void {
    if (drainTimer(clock_timer)) armClock();
    if (updateClock()) markAllDirty();
}

fn onPollTimer() void {
    _ = drainTimer(poll_timer);
    if (burst > 0) {
        burst -= 1;
        refreshStatus(true, true);
    } else if (status.events()) {
        // state changes arrive as kernel events: the regular poll only reads what sends none —
        // the Wi‑Fi signal level and, without the mgmt channel, Bluetooth power
        if (wifi_state.state == .connected) {
            const lvl = status.signalLevel();
            if (lvl != wifi_state.level) {
                wifi_state.level = lvl;
                markAllDirty();
            }
        }
        if (!status.btEvents()) refreshStatus(false, true);
    } else refreshStatus(true, true);
    if (mango.fd < 0 and mango.connect()) applyTags();
    armPoll();
}

fn refreshStatus(do_wifi: bool, do_bt: bool) void {
    var changed = false;
    if (do_wifi) {
        const w = status.wifi();
        if (w.state != wifi_state.state or w.level != wifi_state.level) changed = true;
        wifi_state = w;
    }
    if (do_bt) {
        const bt = status.bluetooth();
        if (bt != bt_state) changed = true;
        bt_state = bt;
    }
    if (changed) markAllDirty();
    armPoll(); // whether polling is needed depends on the state (Wi‑Fi connected, adapter present)
}

fn two(buf: []u8, v: u32) void {
    buf[0] = '0' + @as(u8, @intCast((v / 10) % 10));
    buf[1] = '0' + @as(u8, @intCast(v % 10));
}

const wshort = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

fn updateClock() bool {
    var t = tz.now();
    if (t.hour != clock_hour) {
        // reread the time zone once an hour (zone change, tzdata update)
        if (clock_hour != 99) {
            tz.load();
            t = tz.now();
        }
        clock_hour = t.hour;
    }
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    if (cfg.clock_format == .full) {
        if (ttf.font != null) {
            const d = std.fmt.bufPrint(&buf, "{s}, {d} {s} {d}  ", .{ wshort[t.wday % 7], t.day, months[(t.month -% 1) % 12], t.year }) catch "";
            n = d.len;
        } else {
            // without a TrueType font — digits only: 12.10.2026  13:31
            two(buf[0..], t.day);
            buf[2] = '.';
            two(buf[3..], t.month);
            buf[5] = '.';
            const y = std.fmt.bufPrint(buf[6..], "{d}  ", .{t.year}) catch "";
            n = 6 + y.len;
        }
    }
    if (cfg.clock_format == .date_hm) {
        two(buf[0..], t.day);
        buf[2] = '.';
        two(buf[3..], t.month);
        buf[5] = ' ';
        buf[6] = ' ';
        n = 7;
    }
    two(buf[n..], t.hour);
    buf[n + 2] = ':';
    two(buf[n + 3 ..], t.min);
    n += 5;
    if (cfg.clock_format == .hms) {
        buf[n] = ':';
        two(buf[n + 1 ..], t.sec);
        n += 3;
    }
    if (n == clock_len and std.mem.eql(u8, buf[0..n], clock_buf[0..n])) return false;
    @memcpy(clock_buf[0..n], buf[0..n]);
    clock_len = n;
    return true;
}

fn clockText() []const u8 {
    return clock_buf[0..clock_len];
}

/// Font size in pixels per em: the digits come out about clock_size tall.
fn clockFontSize(S: f32) u16 {
    return @intFromFloat(@round(cfg.clock_size * 1.3 * S));
}

fn clockWidth(S: f32) f32 {
    if (ttf.font != null) return ttf.width(clockText(), clockFontSize(S)) / S;
    return draw.textWidth(clockText(), cfg.clock_size);
}

// ================================================================= Wayland events

fn dispatch(ev: wl.Event) void {
    if (ev.obj >= wl.MAX_IDS) return;
    var a = ev.args;
    const own = owner[ev.obj];
    switch (kinds[ev.obj]) {
        .display => switch (ev.op) {
            0 => {
                const obj = a.uint();
                const code = a.uint();
                const msg = a.string();
                sys.log("protocol error (object {d}, code {d}): {s}", .{ obj, code, msg });
                sys.exit(1);
            },
            1 => {
                const id = a.uint();
                if (id < wl.MAX_IDS) kinds[id] = .none;
                conn.releaseId(id);
            },
            else => {},
        },
        .registry => switch (ev.op) {
            0 => {
                const name = a.uint();
                const iface = a.string();
                const ver = a.uint();
                onGlobal(name, iface, ver);
            },
            1 => onGlobalRemove(a.uint()),
            else => {},
        },
        .callback => if (ev.op == 0) {
            sync_done = true;
        },
        .seat => if (ev.op == 0) onSeatCaps(a.uint()),
        .pointer => onPointer(ev.op, &a),
        .output => onOutput(own, ev.op, &a),
        .surface => if (ev.op == 2) { // preferred_buffer_scale (wl_surface v6)
            const s = a.int();
            setScale(own, s);
        },
        .layer_surface => onLayer(own, ev.op, &a),
        .buffer => if (ev.op == 0) { // release
            const b = &bars[own / 2];
            b.bufs[own % 2].busy = false;
        },
        else => {},
    }
}

fn bind(name: u32, iface: []const u8, ver: u32, kind: Kind, own: u8) u32 {
    const id = create(kind, own);
    conn.send(registry, 0, .{ name, wl.str(iface), ver, id });
    return id;
}

fn onGlobal(name: u32, iface: []const u8, ver: u32) void {
    const eql = std.mem.eql;
    if (eql(u8, iface, "wl_compositor") and compositor == 0) {
        compositor_ver = @min(ver, 6);
        compositor = bind(name, iface, compositor_ver, .compositor, 0);
    } else if (eql(u8, iface, "wl_shm") and shm == 0) {
        shm = bind(name, iface, 1, .shm, 0);
    } else if (eql(u8, iface, "zwlr_layer_shell_v1") and layer_shell == 0) {
        layer_shell = bind(name, iface, @min(ver, 3), .layer_shell, 0);
    } else if (eql(u8, iface, "wl_seat") and seat == 0) {
        seat_ver = @min(ver, 5);
        seat = bind(name, iface, seat_ver, .seat, 0);
    } else if (eql(u8, iface, "wp_cursor_shape_manager_v1") and cursor_mgr == 0) {
        cursor_mgr = bind(name, iface, 1, .cursor_mgr, 0);
        if (pointer != 0 and cursor_dev == 0) makeCursorDevice();
    } else if (eql(u8, iface, "wl_output")) {
        for (&bars, 0..) |*b, i| {
            if (b.used) continue;
            const idx: u8 = @intCast(i);
            b.* = .{ .used = true, .out_name = name, .out_ver = @min(ver, 4) };
            b.output = bind(name, iface, b.out_ver, .output, idx);
            if (ready) setupBar(idx);
            break;
        }
    }
}

fn onGlobalRemove(name: u32) void {
    for (&bars, 0..) |*b, i| {
        if (b.used and b.out_name == name) destroyBar(@intCast(i));
    }
}

fn onSeatCaps(caps: u32) void {
    const has_pointer = caps & 1 != 0;
    if (has_pointer and pointer == 0) {
        pointer = create(.pointer, 0);
        conn.send(seat, 0, .{pointer}); // get_pointer
        if (cursor_mgr != 0) makeCursorDevice();
    } else if (!has_pointer and pointer != 0) {
        if (cursor_dev != 0) {
            conn.send(cursor_dev, 0, .{});
            forget(&cursor_dev);
        }
        if (seat_ver >= 3) conn.send(pointer, 1, .{});
        forget(&pointer);
        ptr_bar = null;
    }
}

fn makeCursorDevice() void {
    cursor_dev = create(.cursor_dev, 0);
    conn.send(cursor_mgr, 1, .{ cursor_dev, pointer });
}

fn onOutput(own: u8, op: u16, a: *wl.Args) void {
    const b = &bars[own];
    switch (op) {
        3 => { // scale
            const s = a.int();
            if (compositor_ver < 6) setScale(own, s);
        },
        4 => { // name
            const n = a.string();
            const k = @min(n.len, b.mon_buf.len);
            @memcpy(b.mon_buf[0..k], n[0..k]);
            b.mon_len = k;
            applyTags();
        },
        else => {},
    }
}

fn setScale(own: u8, s: i32) void {
    const b = &bars[own];
    const v: u32 = @intCast(std.math.clamp(s, 1, 4));
    if (v != b.scale) {
        b.scale = v;
        b.dirty = true;
    }
}

fn onLayer(own: u8, op: u16, a: *wl.Args) void {
    const b = &bars[own];
    switch (op) {
        0 => { // configure
            const serial = a.uint();
            const w = a.uint();
            const h = a.uint();
            conn.send(b.layer, 6, .{serial}); // ack_configure
            // clamp the sizes from the compositor to sane limits
            b.w = if (w > 0) @min(w, 16384) else 1280;
            b.h = if (h > 0) @min(h, 512) else cfg.height;
            b.configured = true;
            b.dirty = true;
        },
        1 => destroyBar(own), // closed
        else => {},
    }
}

// ---------------------------------------------------------------- pointer

fn barBySurface(id: u32) ?u8 {
    for (&bars, 0..) |*b, i| {
        if (b.used and b.surface == id) return @intCast(i);
    }
    return null;
}

fn onPointer(op: u16, a: *wl.Args) void {
    switch (op) {
        0 => { // enter
            const serial = a.uint();
            const surf = a.uint();
            ptr_x = a.fixed();
            ptr_y = a.fixed();
            ptr_bar = barBySurface(surf);
            if (cursor_dev != 0) conn.send(cursor_dev, 1, .{ serial, @as(u32, 1) }); // shape: default
            updateHover();
        },
        1 => { // leave
            if (ptr_bar) |i| setHover(i, null);
            ptr_bar = null;
        },
        2 => { // motion
            _ = a.uint();
            ptr_x = a.fixed();
            ptr_y = a.fixed();
            updateHover();
        },
        3 => { // button
            _ = a.uint();
            const time = a.uint();
            const button = a.uint();
            const state = a.uint();
            if (state == 1) {
                if (ptr_bar) |i| click(i, button, time);
            }
        },
        4 => { // axis
            _ = a.uint();
            const axis = a.uint();
            const v = a.fixed();
            if (axis == 0) {
                if (ptr_bar) |i| scroll(i, v);
            }
        },
        else => {},
    }
}

fn hitAt(b: *const Bar, x: f32, y: f32) ?Hit {
    for (b.hits[0..b.nhits]) |h| {
        if (x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h) return h;
    }
    return null;
}

fn sameHit(a: ?Hit, b: ?Hit) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.item == b.?.item and a.?.idx == b.?.idx;
}

fn setHover(i: u8, h: ?Hit) void {
    if (!cfg.hover_effect) return;
    const b = &bars[i];
    if (!sameHit(b.hover, h)) {
        b.hover = h;
        b.dirty = true;
    }
}

fn updateHover() void {
    const i = ptr_bar orelse return;
    var h = hitAt(&bars[i], ptr_x, ptr_y);
    if (h) |v| {
        if (v.item == .clock and cfg.clock.left == null and cfg.clock.right == null and cfg.clock.middle == null) h = null;
    }
    setHover(i, h);
}

const BTN_LEFT = 0x110;
const BTN_RIGHT = 0x111;
const BTN_MIDDLE = 0x112;

fn click(i: u8, button: u32, time: u32) void {
    const b = &bars[i];
    const h = hitAt(b, ptr_x, ptr_y) orelse return;
    if (h.item == .tags) return tagClick(b, h.idx, button);
    const btn: u8 = switch (button) {
        BTN_LEFT => 0,
        BTN_RIGHT => 1,
        BTN_MIDDLE => 2,
        else => return,
    };
    const slot = (actionIndex(h.item) orelse return) * 3 + btn;
    if (commands[slot] == null) return;
    // double-click guard: the same command no more than once per 400 ms
    if (last_click[slot]) |prev| {
        if (time -% prev < 400) return;
    }
    last_click[slot] = time;
    sys.tracef("click: command {d}", .{slot});
    broker.run(slot);
    // Wi‑Fi/Bluetooth toggles (right click) don't always produce an event — check more often
    // for a few seconds; Bluetooth power from the menu without an mgmt channel is also learned only by polling
    const toggle = btn == 1 and (h.item == .wifi or h.item == .bluetooth);
    if (toggle or (h.item == .bluetooth and !status.btEvents())) {
        burst = 6;
        armPoll();
    }
}

fn tagClick(b: *Bar, idx: u8, button: u32) void {
    var buf: [128]u8 = undefined;
    switch (button) {
        BTN_LEFT => viewTag(b, idx),
        BTN_RIGHT => broker.dispatch(std.fmt.bufPrint(&buf, "toggleview,{d}", .{idx + 1}) catch return),
        else => {},
    }
}

fn viewTag(b: *Bar, idx: u8) void {
    var buf: [128]u8 = undefined;
    // the monitor name goes into the IPC — take only safe names, otherwise the current monitor
    const cmd = if (broker.isMonName(b.monName()))
        std.fmt.bufPrint(&buf, "viewcrossmon,{d},{s}", .{ idx + 1, b.monName() }) catch return
    else
        std.fmt.bufPrint(&buf, "view,{d},0", .{idx + 1}) catch return;
    broker.dispatch(cmd);
}

fn scroll(i: u8, v: f32) void {
    scroll_acc += v;
    if (@abs(scroll_acc) < 15.0) return;
    const dir: i32 = if (scroll_acc > 0) 1 else -1;
    scroll_acc = 0;
    const b = &bars[i];
    if (b.ntags == 0) return;
    var cur: i32 = 0;
    for (b.tags[0..b.ntags], 0..) |t, k| {
        if (t.active) {
            cur = @intCast(k);
            break;
        }
    }
    const next: u8 = @intCast(@mod(cur + dir, @as(i32, b.ntags)));
    viewTag(b, next);
}

// ================================================================= bars

fn setupBar(i: u8) void {
    const b = &bars[i];
    b.surface = create(.surface, i);
    conn.send(compositor, 0, .{b.surface}); // create_surface
    b.layer = create(.layer_surface, i);
    // get_layer_surface(id, surface, output, layer = top, namespace)
    conn.send(layer_shell, 0, .{ b.layer, b.surface, b.output, @as(u32, 2), wl.str("netline") });
    conn.send(b.layer, 0, .{ @as(u32, 0), cfg.height }); // set_size (the compositor sets the width)
    const anchor: u32 = switch (cfg.position) {
        .top => 1 | 4 | 8,
        .bottom => 2 | 4 | 8,
    };
    conn.send(b.layer, 1, .{anchor});
    conn.send(b.layer, 2, .{@as(i32, @intCast(cfg.height))}); // exclusive zone
    const top: i32 = if (cfg.position == .top) cfg.margin_edge else 0;
    const bottom: i32 = if (cfg.position == .bottom) cfg.margin_edge else 0;
    conn.send(b.layer, 3, .{ top, cfg.margin_side, bottom, cfg.margin_side }); // set_margin
    conn.send(b.surface, 6, .{}); // commit without a buffer -> a configure will come
}

fn freeBuffers(b: *Bar) void {
    for (&b.bufs) |*bf| {
        if (bf.id != 0) conn.send(bf.id, 0, .{}); // wl_buffer.destroy
        forget(&bf.id);
        bf.busy = false;
    }
    if (b.pool != 0) conn.send(b.pool, 1, .{}); // wl_shm_pool.destroy
    forget(&b.pool);
    if (b.mem) |m| sys.munmap(m, b.mem_len);
    b.mem = null;
    b.pw = 0;
    b.ph = 0;
    b.last = null;
}

fn destroyBar(i: u8) void {
    const b = &bars[i];
    if (!b.used) return;
    freeBuffers(b);
    if (b.layer != 0) conn.send(b.layer, 7, .{});
    forget(&b.layer);
    if (b.surface != 0) conn.send(b.surface, 0, .{});
    forget(&b.surface);
    if (b.output != 0 and b.out_ver >= 3) conn.send(b.output, 0, .{}); // wl_output.release
    forget(&b.output);
    if (ptr_bar == i) ptr_bar = null;
    b.* = .{};
}

fn ensureBuffers(i: u8) bool {
    const b = &bars[i];
    const pw = b.w * b.scale;
    const ph = b.h * b.scale;
    if (b.pool != 0 and pw == b.pw and ph == b.ph) return true;
    freeBuffers(b);
    const stride = pw * 4;
    const size: usize = @as(usize, stride) * ph;
    const total = size * 2;
    if (total == 0 or total > std.math.maxInt(i32)) return false; // wl_shm takes the pool size as i32
    const fd = sys.memfd("netline") catch return false;
    defer sys.close(fd);
    sys.ftruncate(fd, total) catch return false;
    const mem = sys.mmap(total, fd) catch return false;
    b.mem = mem;
    b.mem_len = total;
    b.pw = pw;
    b.ph = ph;
    b.pool = create(.pool, i);
    conn.send(shm, 0, .{ b.pool, wl.Fd{ .fd = fd }, @as(i32, @intCast(total)) }); // create_pool
    conn.flush() catch fatal("writing to the Wayland socket"); // the descriptor is sent — it can be closed
    for (&b.bufs, 0..) |*bf, k| {
        bf.* = .{ .id = create(.buffer, i * 2 + @as(u8, @intCast(k))) };
        // create_buffer(id, offset, width, height, stride, format = ARGB8888)
        conn.send(b.pool, 0, .{ bf.id, @as(i32, @intCast(k * size)), @as(i32, @intCast(pw)), @as(i32, @intCast(ph)), @as(i32, @intCast(stride)), @as(u32, 0) });
    }
    return true;
}

fn pixels(b: *const Bar, k: u1) []u32 {
    const n = @as(usize, b.pw) * b.ph;
    const px: [*]u32 = @ptrCast(@alignCast(b.mem.? + @as(usize, k) * n * 4));
    return px[0..n];
}

const Rect = struct { x0: u32, y0: u32, x1: u32, y1: u32 };
const MAX_RECTS = 6;
var col_changed: [16384 * 4]bool = undefined;

/// Areas where the frames differ: several rectangles, so that, for example, a highlight
/// change on the left and on the right doesn't turn into one full-width band. 0 — the frames are equal.
fn diffRects(a: []const u32, b: []const u32, w: u32, h: u32, out: *[MAX_RECTS]Rect) usize {
    const cols = col_changed[0..w];
    @memset(cols, false);
    var y0: u32 = h;
    var y1: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const ra = a[@as(usize, y) * w ..][0..w];
        const rb = b[@as(usize, y) * w ..][0..w];
        if (std.mem.eql(u32, ra, rb)) continue;
        for (ra, rb, cols) |pa, pb, *c| {
            if (pa != pb) c.* = true;
        }
        y0 = @min(y0, y);
        y1 = y + 1;
    }
    if (y1 == 0) return 0;
    // merge changed columns if fewer than `gap` pixels lie between them
    const gap: u32 = @max(16, h / 2);
    var n: usize = 0;
    var x: u32 = 0;
    while (x < w) {
        if (!cols[x]) {
            x += 1;
            continue;
        }
        var end = x + 1;
        var last = x + 1;
        while (end < w and end - last < gap) : (end += 1) {
            if (cols[end]) last = end + 1;
        }
        if (n == MAX_RECTS) {
            out[n - 1].x1 = last; // attach the excess to the last one
        } else {
            out[n] = .{ .x0 = x, .y0 = y0, .x1 = last, .y1 = y1 };
            n += 1;
        }
        x = last;
    }
    return n;
}

fn render(i: u8) void {
    const b = &bars[i];
    const t0 = sys.traceStart();
    defer if (sys.tracing()) sys.tracef("frame {d}: {d} µs", .{ i, sys.traceSince(t0) });
    if (!ensureBuffers(i)) return;
    // draw into a buffer other than the shown one, to compare frames
    const k: u1 = if (b.last) |l| ~l else 0;
    if (b.bufs[k].busy) return; // the compositor is still reading — finish after release

    layout(b);
    var cv = draw.Canvas{ .px = pixels(b, k), .w = @intCast(b.pw), .h = @intCast(b.ph) };
    paint(b, &cv);

    var rects: [MAX_RECTS]Rect = undefined;
    var nr: usize = 1;
    rects[0] = .{ .x0 = 0, .y0 = 0, .x1 = b.pw, .y1 = b.ph };
    if (b.last) |l| {
        nr = diffRects(cv.px, pixels(b, l), b.pw, b.ph, &rects);
        if (nr == 0) {
            b.dirty = false; // nothing changed — don't touch the compositor at all
            return;
        }
    }

    syncOpaque(b);
    conn.send(b.surface, 1, .{ b.bufs[k].id, @as(i32, 0), @as(i32, 0) }); // attach
    if (compositor_ver >= 3) conn.send(b.surface, 8, .{@as(i32, @intCast(b.scale))}); // set_buffer_scale
    if (compositor_ver >= 4) {
        for (rects[0..nr]) |r| {
            conn.send(b.surface, 9, .{ @as(i32, @intCast(r.x0)), @as(i32, @intCast(r.y0)), @as(i32, @intCast(r.x1 - r.x0)), @as(i32, @intCast(r.y1 - r.y0)) });
        }
    } else {
        conn.send(b.surface, 2, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(b.w)), @as(i32, @intCast(b.h)) });
    }
    conn.send(b.surface, 6, .{}); // commit
    b.bufs[k].busy = true;
    b.last = k;
    b.dirty = false;
}

/// With an opaque background (alpha ff in the theme) the compositor gets an opaque region — the panel
/// without its rounded corners — and doesn't draw or blend what is under it. Sent with the next commit,
/// only when the size or the background's opacity changed.
fn syncOpaque(b: *Bar) void {
    const want = theme.solid(theme.t.background);
    if (want == b.opaque_on and (!want or (b.opaque_w == b.w and b.opaque_h == b.h))) return;
    b.opaque_on = want;
    b.opaque_w = b.w;
    b.opaque_h = b.h;
    conn.setOpaque(compositor, b.surface, want, b.w, b.h, cfg.radius);
}

fn sameTags(a: []const mango.Tag, b: []const mango.Tag) bool {
    for (a, b) |x, y| {
        if (x.active != y.active or x.urgent != y.urgent or x.clients != y.clients) return false;
    }
    return true;
}

/// Tags from mango → bars. Redraw only if something changed for this bar:
/// IPC events also arrive for things the bar doesn't show (e.g. a focus change).
fn applyTags() void {
    for (&bars) |*b| {
        if (!b.used) continue;
        var tags: [mango.MAX_TAGS]mango.Tag = @as([mango.MAX_TAGS]mango.Tag, @splat(.{}));
        var n: u8 = 0;
        if (mango.find(b.monName())) |m| {
            n = @min(m.ntags, mango.MAX_TAGS);
            @memcpy(tags[0..n], m.tags[0..n]);
        }
        if (n == b.ntags and sameTags(tags[0..n], b.tags[0..n])) continue;
        b.tags = tags;
        b.ntags = n;
        b.dirty = true;
    }
}

fn markAllDirty() void {
    for (&bars) |*b| {
        if (b.used) b.dirty = true;
    }
}

// ================================================================= layout and drawing

fn addHit(b: *Bar, item: cfg.Item, idx: u8, x: f32, y: f32, w: f32, h: f32) void {
    if (b.nhits >= b.hits.len) return;
    b.hits[b.nhits] = .{ .item = item, .idx = idx, .x = x, .y = y, .w = w, .h = h };
    b.nhits += 1;
}

fn itemWidth(b: *const Bar, item: cfg.Item) f32 {
    if (item != .tags) return cfg.button;
    var w: f32 = 0;
    for (b.tags[0..b.ntags]) |t| {
        if (cfg.hide_empty_tags and !t.active and t.clients == 0) continue;
        w += tagWidth(t);
    }
    return w;
}

fn tagWidth(t: mango.Tag) f32 {
    return switch (cfg.tag_style) {
        .dots => if (t.active) cfg.tag_active_w else cfg.tag_dot_w,
        .numbers => cfg.tag_number_w,
    };
}

fn place(b: *Bar, item: cfg.Item, x0: f32, by: f32) void {
    if (item == .tags) {
        var x = x0;
        for (b.tags[0..b.ntags], 0..) |t, k| {
            if (cfg.hide_empty_tags and !t.active and t.clients == 0) continue;
            const w = tagWidth(t);
            addHit(b, .tags, @intCast(k), x, by, w, cfg.button);
            x += w;
        }
    } else {
        addHit(b, item, 0, x0, by, cfg.button, cfg.button);
    }
}

fn layout(b: *Bar) void {
    b.nhits = 0;
    const W: f32 = @floatFromInt(b.w);
    const H: f32 = @floatFromInt(b.h);
    const by = (H - cfg.button) / 2;

    var x: f32 = cfg.padding;
    for (cfg.left) |it| {
        const w = itemWidth(b, it);
        if (w == 0) continue;
        place(b, it, x, by);
        x += w + cfg.spacing * 3;
    }
    var rx: f32 = W - cfg.padding;
    for (0..cfg.right.len) |k| {
        const it = cfg.right[cfg.right.len - 1 - k];
        const w = itemWidth(b, it);
        if (w == 0) continue;
        rx -= w;
        place(b, it, rx, by);
        rx -= cfg.spacing;
    }
    const tw = clockWidth(@floatFromInt(b.scale));
    addHit(b, .clock, 0, (W - tw) / 2 - 8, by, tw + 16, cfg.button);
}

fn paint(b: *const Bar, cv: *draw.Canvas) void {
    const S: f32 = @floatFromInt(b.scale);
    const W: f32 = @floatFromInt(b.w);
    const H: f32 = @floatFromInt(b.h);
    const c = &theme.t;

    cv.clear(0);
    cv.fillRoundRect(0, 0, W * S, H * S, cfg.radius * S, c.background);
    if (cfg.border_width > 0) {
        const bw = cfg.border_width * S;
        const frame = [_]draw.Prim{.{ .box = .{ .x = bw / 2, .y = bw / 2, .w = W * S - bw, .h = H * S - bw, .r = @max(cfg.radius * S - bw / 2, 0) } }};
        cv.prims(&frame, 0, 0, 1, bw, c.border);
    }

    for (b.hits[0..b.nhits]) |h| {
        if (cfg.hover_effect and sameHit(b.hover, h))
            cv.fillRoundRect(h.x * S, h.y * S, h.w * S, h.h * S, cfg.button_radius * S, c.hover);
        switch (h.item) {
            .tags => paintTag(b, cv, h, S),
            .clock => {
                const tw = clockWidth(S);
                const x = @round((h.x + (h.w - tw) / 2) * S);
                const y = @round((H - cfg.clock_size) / 2 * S);
                if (ttf.font != null) {
                    // baseline at the bottom of the digits, as with the vector font
                    _ = ttf.drawText(cv, clockText(), x, y + cfg.clock_size * S, clockFontSize(S), c.clock, W * S);
                } else {
                    draw.text(cv, clockText(), x, y, cfg.clock_size * S, c.clock);
                }
            },
            else => paintIcon(cv, h, S),
        }
    }
}

fn paintTag(b: *const Bar, cv: *draw.Canvas, h: Hit, S: f32) void {
    const c = &theme.t;
    const t = b.tags[h.idx];
    const cx = (h.x + h.w / 2) * S;
    const cy = (h.y + h.h / 2) * S;
    const col = if (t.urgent) c.tag_urgent else if (t.active) c.tag_active else if (t.clients > 0) c.tag_occupied else c.tag_empty;
    switch (cfg.tag_style) {
        .dots => {
            if (t.active) {
                const pw = (h.w - 10) * S;
                const ph = 7 * S;
                cv.fillRoundRect(cx - pw / 2, cy - ph / 2, pw, ph, ph / 2, col);
            } else {
                const d: f32 = (if (t.clients > 0 or t.urgent) @as(f32, 7) else 5.5) * S;
                cv.fillRoundRect(cx - d / 2, cy - d / 2, d, d, d / 2, col);
            }
        },
        .numbers => {
            var nb: [4]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "{d}", .{h.idx + 1}) catch return;
            var tc = col;
            if (t.active) {
                cv.fillRoundRect((h.x + 2) * S, (h.y + 2) * S, (h.w - 4) * S, (h.h - 4) * S, cfg.button_radius * S, col);
                tc = c.tag_active_text;
            }
            const size = cfg.tag_number_size;
            const tw = draw.textWidth(s, size);
            draw.text(cv, s, @round(cx - tw * S / 2), @round(cy - size * S / 2), size * S, tc);
        },
    }
}

fn paintIcon(cv: *draw.Canvas, h: Hit, S: f32) void {
    const c = &theme.t;
    const s = cfg.icon / 16.0 * S;
    const ox = @round((h.x + (h.w - cfg.icon) / 2) * S);
    const oy = @round((h.y + (h.h - cfg.icon) / 2) * S);
    const st = cfg.icon_stroke * S;
    switch (h.item) {
        .launcher => cv.icon(&draw.icon_apps, ox, oy, s, st, c.launcher),
        .wallpaper => cv.icon(&draw.icon_wall, ox, oy, s, st, c.wallpaper),
        .power => cv.icon(&draw.icon_power, ox, oy, s, st, c.power),
        .wifi => {
            const w = wifi_state;
            const on = w.state == .connected or w.state == .disconnected;
            for (&draw.icon_wifi_arcs, 0..) |*arc, k| {
                const lit = w.state == .connected and k < w.level;
                cv.icon(arc, ox, oy, s, st, if (lit) c.wifi else c.wifi_inactive);
            }
            cv.icon(&draw.icon_wifi_dot, ox, oy, s, st, if (on) c.wifi else c.wifi_inactive);
            if (w.state == .off) cv.icon(&draw.icon_slash, ox, oy, s, st, c.wifi_off);
        },
        .bluetooth => {
            const col = switch (bt_state) {
                .connected => c.bluetooth_connected,
                .on => c.bluetooth_on,
                .off, .none => c.bluetooth_off,
            };
            cv.icon(&draw.icon_bt, ox, oy, s, st, col);
            if (bt_state == .connected) cv.icon(&draw.icon_bt_dots, ox, oy, s, st, col);
        },
        .tags, .clock => {},
    }
}
