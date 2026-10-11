// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zwifi — меню Wi‑Fi для zpanel на чистом Zig.
//!
//! Карточка по центру экрана с затемнением вокруг. Список сетей, подключение к открытым,
//! WPA/WPA2/WPA3 Personal и корпоративным (802.1X: PEAP, TTLS, EAP-TLS) сетям через
//! NetworkManager по D-Bus. Повторный запуск закрывает открытое меню.
//! Клавиатура: Tab/Shift+Tab, ↑/↓, Enter, Esc, Ctrl+V — вставка, Ctrl+U — очистить поле.

const std = @import("std");
const sys = @import("sys.zig");
const wl = @import("wl.zig");
const draw = @import("draw.zig");
const ttf = @import("ttf.zig");
const theme = @import("theme.zig");
const cfg = @import("config.zig");
const nm = @import("nm.zig");
const xkb = @import("xkb.zig");
const sandbox = @import("sandbox.zig");

// ================================================================= Wayland

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
    keyboard,
    viewporter,
    viewport,
    spb,
    ddm,
    data_device,
    cursor_mgr,
    cursor_dev,
};

var conn: wl.Conn = .{};
var kinds: [wl.MAX_IDS]Kind = [_]Kind{.none} ** wl.MAX_IDS;
var owner: [wl.MAX_IDS]u8 = [_]u8{0} ** wl.MAX_IDS;

var registry: u32 = 0;
var compositor: u32 = 0;
var compositor_ver: u32 = 0;
var shm: u32 = 0;
var layer_shell: u32 = 0;
var seat: u32 = 0;
var pointer: u32 = 0;
var keyboard: u32 = 0;
var viewporter: u32 = 0;
var spb: u32 = 0;
var ddm: u32 = 0;
var data_device: u32 = 0;
var cursor_mgr: u32 = 0;
var cursor_dev: u32 = 0;
var sync_done = false;

// буфер обмена: предложения данных создаёт сервер (id >= 0xff000000)
const SRV_BASE: u32 = 0xff000000;
const Offer = struct { id: u32 = 0, mime: u8 = 0 };
var offers: [16]Offer = [_]Offer{.{}} ** 16;
var selection: u32 = 0;
const mimes = [_][]const u8{ "", "text/plain;charset=utf-8", "UTF8_STRING", "text/plain" };

const Buf = struct { id: u32 = 0, busy: bool = false };

const Surf = struct {
    surface: u32 = 0,
    layer: u32 = 0,
    configured: bool = false,
    w: u32 = 0,
    h: u32 = 0,
    scale: u32 = 1,
    dirty: bool = false,
    pool: u32 = 0,
    mem: ?[*]u8 = null,
    mem_len: usize = 0,
    pw: u32 = 0,
    ph: u32 = 0,
    bufs: [2]Buf = .{ .{}, .{} },
    last: ?u1 = null,
};

var card: Surf = .{}; // owner 0
var back: Surf = .{}; // owner 1 — затемнение, ловит клики вокруг карточки
var back_buffer: u32 = 0;
var back_viewport: u32 = 0;

var km: xkb.Keymap = .{};
var mods: u32 = 0;
var group: u32 = 0;
var repeat_rate: u32 = 25;
var repeat_delay: u32 = 600;
var repeat_key: u32 = 0;

var ptr_on_card = false;
var ptr_x: f32 = 0;
var ptr_y: f32 = 0;
var ptr_serial: u32 = 0;
var cursor_shape: u32 = 0;
var scroll_acc: f32 = 0;

var ui_timer: i32 = -1;
var repeat_timer: i32 = -1;
var lock_fd: i32 = -1;

// ================================================================= состояние интерфейса

const View = enum { list, password, enterprise, hidden, actions, connecting, done };
var view: View = .list;
var form_view: View = .password; // куда вернуться при неудаче

var nets: [48]nm.Net = undefined;
var nnets: usize = 0;
var scroll: usize = 0;
var sel: usize = 0;
var kbd_nav = false; // строку выбрали стрелками — подсвечиваем её, а не строку под мышью
var target: nm.Net = .{};
var target_hidden = false;
var reenter = false; // сохранённый профиль не подошёл — при отправке старый удаляется
var nm_ok = false;
var ticks: u32 = 0;

const F = enum(u8) { ssid, password, identity, anon, ca, domain, cert, key, keypass };
const Field = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    caret: usize = 0,

    fn text(f: *const Field) []const u8 {
        return f.buf[0..f.len];
    }
};
var fields: [9]Field = [_]Field{.{}} ** 9;
var reveal = false;
var method: nm.Eap = .peap;
var phase2: u8 = 0;
var hsec: u8 = 1; // скрытая сеть: 0 открытая, 1 personal, 2 enterprise

const peap_p2 = [_][]const u8{ "mschapv2", "gtc", "md5" };
const peap_p2_label = [_][]const u8{ "MSCHAPv2", "GTC", "MD5" };
const ttls_p2 = [_][]const u8{ "pap", "mschapv2", "mschap", "chap" };
const ttls_p2_label = [_][]const u8{ "PAP", "MSCHAPv2", "MSCHAP", "CHAP" };
const method_label = [_][]const u8{ "PEAP", "TTLS", "TLS (сертификат)" };
const hsec_label = [_][]const u8{ "Открытая", "WPA/WPA2/WPA3 Personal", "Корпоративная 802.1X" };

var msg_buf: [200]u8 = undefined;
var msg_len: usize = 0;

fn setMsg(s: []const u8) void {
    msg_len = @min(s.len, msg_buf.len);
    @memcpy(msg_buf[0..msg_len], s[0..msg_len]);
}

// ---- виджеты (раскладка пересчитывается перед отрисовкой и обработкой ввода)

const Wid = enum(u8) { none, row, more, toggle, back, other, field, select, eye, primary, secondary, act_connect, act_disconnect, act_forget };
const Widget = struct { id: Wid, idx: u8 = 0, x: f32, y: f32, w: f32, h: f32 };
const Ref = struct { id: Wid = .none, idx: u8 = 0 };

var widgets: [40]Widget = undefined;
var nwid: usize = 0;
var focus: Ref = .{};
var hover: Ref = .{};

fn add(id: Wid, idx: u8, x: f32, y: f32, w: f32, h: f32) void {
    if (nwid == widgets.len) return;
    widgets[nwid] = .{ .id = id, .idx = idx, .x = x, .y = y, .w = w, .h = h };
    nwid += 1;
}

fn same(a: Ref, id: Wid, idx: u8) bool {
    return a.id == id and a.idx == idx;
}

fn focusable(w: Widget) bool {
    return switch (w.id) {
        .field, .select, .primary, .secondary, .act_connect, .act_disconnect, .act_forget, .other => true,
        else => false,
    };
}

// ================================================================= main

pub fn main() void {
    sys.initEnv();
    if (sys.getuid() == 0) {
        sys.log("запуск от root запрещён", .{});
        sys.exit(1);
    }
    // повторный запуск = закрыть уже открытое меню
    var name_buf: [64]u8 = undefined;
    const lock_name = std.fmt.bufPrint(&name_buf, "zwifi-{d}", .{sys.getuid()}) catch "zwifi";
    if (sys.connectAbstract(lock_name)) sys.exit(0);
    lock_fd = sys.listenAbstract(lock_name) catch -1;

    if (!ttf.load(&cfg.font_paths)) {
        sys.log("не найден шрифт TrueType — укажите путь в font_paths (config.zig)", .{});
        sys.exit(1);
    }
    theme.init();
    nm_ok = nm.init();
    if (!nm_ok) setMsg(nm.lastError());

    conn.connect() catch {
        sys.log("не удалось подключиться к Wayland", .{});
        sys.exit(1);
    };
    kinds[1] = .display;
    registry = create(.registry, 0);
    conn.send(1, 1, .{registry});
    roundtrip();
    if (compositor == 0 or shm == 0 or layer_shell == 0) {
        sys.log("композитор не поддерживает wlr-layer-shell", .{});
        sys.exit(1);
    }
    if (ddm != 0 and seat != 0) {
        data_device = create(.data_device, 0);
        conn.send(ddm, 1, .{ data_device, seat }); // get_data_device
    }
    setupBackdrop();
    setupCard();

    ui_timer = sys.timerfdCreate(sys.CLOCK_MONOTONIC) catch fatal("timerfd");
    repeat_timer = sys.timerfdCreate(sys.CLOCK_MONOTONIC) catch fatal("timerfd");

    if (cfg.sandbox) {
        const paths = [_][:0]const u8{theme.dir};
        sandbox.apply(&paths, .{ .extra = &.{.pipe2} });
    }

    if (nm_ok) {
        nm.loadSaved();
        nm.scan();
        refresh();
    }
    armTimer();

    while (true) {
        if (card.configured and card.dirty) render();
        conn.flush() catch fatal("запись в сокет Wayland");
        var fds = [5]sys.PollFd{
            .{ .fd = conn.fd, .events = sys.POLLIN },
            .{ .fd = ui_timer, .events = sys.POLLIN },
            .{ .fd = repeat_timer, .events = sys.POLLIN },
            .{ .fd = lock_fd, .events = sys.POLLIN },
            .{ .fd = theme.inotify_fd, .events = sys.POLLIN },
        };
        _ = sys.poll(&fds, -1) catch continue;
        if (fds[0].revents != 0) readWayland();
        if (fds[1].revents != 0) {
            drainTimer(ui_timer);
            onTick();
        }
        if (fds[2].revents != 0) {
            drainTimer(repeat_timer);
            if (repeat_key != 0) keyPress(repeat_key);
        }
        if (fds[3].revents != 0) quit(); // запустили ещё раз — закрываемся
        if (fds[4].revents != 0 and theme.inotify_fd >= 0) {
            if (theme.onInotify()) {
                card.dirty = true;
                paintBackdrop();
            }
        }
    }
}

fn quit() noreturn {
    for (&fields) |*f| nm.secureZero(&f.buf);
    nm.secureZero(&nm.bus.out);
    sys.exit(0);
}

fn fatal(what: []const u8) noreturn {
    sys.log("ошибка: {s}", .{what});
    sys.exit(1);
}

fn drainTimer(fd: i32) void {
    var b: [8]u8 = undefined;
    _ = sys.read(fd, &b) catch {};
}

fn create(kind: Kind, own: u8) u32 {
    const id = conn.newId();
    kinds[id] = kind;
    owner[id] = own;
    return id;
}

fn roundtrip() void {
    const cb = create(.callback, 0);
    conn.send(1, 0, .{cb});
    conn.flush() catch fatal("запись в сокет Wayland");
    sync_done = false;
    while (!sync_done) readWayland();
}

fn readWayland() void {
    const alive = conn.fill() catch fatal("чтение из сокета Wayland");
    if (!alive) quit();
    while (conn.next()) |ev| dispatch(ev);
}

fn bind(name: u32, iface: []const u8, ver: u32, kind: Kind) u32 {
    const id = create(kind, 0);
    conn.send(registry, 0, .{ name, wl.str(iface), ver, id });
    return id;
}

fn onGlobal(name: u32, iface: []const u8, ver: u32) void {
    const eql = std.mem.eql;
    if (eql(u8, iface, "wl_compositor") and compositor == 0) {
        compositor_ver = @min(ver, 6);
        compositor = bind(name, iface, compositor_ver, .compositor);
    } else if (eql(u8, iface, "wl_shm") and shm == 0) {
        shm = bind(name, iface, 1, .shm);
    } else if (eql(u8, iface, "zwlr_layer_shell_v1") and layer_shell == 0) {
        layer_shell = bind(name, iface, @min(ver, 3), .layer_shell);
    } else if (eql(u8, iface, "wl_seat") and seat == 0) {
        seat = bind(name, iface, @min(ver, 5), .seat);
    } else if (eql(u8, iface, "wp_viewporter") and viewporter == 0) {
        viewporter = bind(name, iface, 1, .viewporter);
    } else if (eql(u8, iface, "wp_single_pixel_buffer_manager_v1") and spb == 0) {
        spb = bind(name, iface, 1, .spb);
    } else if (eql(u8, iface, "wl_data_device_manager") and ddm == 0) {
        ddm = bind(name, iface, @min(ver, 3), .ddm);
    } else if (eql(u8, iface, "wp_cursor_shape_manager_v1") and cursor_mgr == 0) {
        cursor_mgr = bind(name, iface, 1, .cursor_mgr);
    }
}

fn dispatch(ev: wl.Event) void {
    var a = ev.args;
    if (ev.obj >= SRV_BASE) return onOffer(ev.obj, ev.op, &a);
    if (ev.obj >= wl.MAX_IDS) return;
    const own = owner[ev.obj];
    switch (kinds[ev.obj]) {
        .display => switch (ev.op) {
            0 => {
                const obj = a.uint();
                const code = a.uint();
                sys.log("ошибка протокола (объект {d}, код {d}): {s}", .{ obj, code, a.string() });
                sys.exit(1);
            },
            1 => {
                const id = a.uint();
                if (id < wl.MAX_IDS) kinds[id] = .none;
                conn.releaseId(id);
            },
            else => {},
        },
        .registry => if (ev.op == 0) {
            const name = a.uint();
            const iface = a.string();
            const ver = a.uint();
            onGlobal(name, iface, ver);
        },
        .callback => if (ev.op == 0) {
            sync_done = true;
        },
        .seat => if (ev.op == 0) onSeatCaps(a.uint()),
        .pointer => onPointer(ev.op, &a),
        .keyboard => onKeyboard(ev.op, &a),
        .data_device => onDataDevice(ev.op, &a),
        .surface => if (ev.op == 2 and own == 0) { // preferred_buffer_scale
            const s: u32 = @intCast(std.math.clamp(a.int(), 1, 4));
            if (s != card.scale) {
                card.scale = s;
                card.dirty = true;
            }
        },
        .layer_surface => onLayer(own, ev.op, &a),
        .buffer => if (ev.op == 0 and own < 2) {
            card.bufs[own].busy = false;
        },
        else => {},
    }
}

fn onSeatCaps(caps: u32) void {
    if (caps & 1 != 0 and pointer == 0) {
        pointer = create(.pointer, 0);
        conn.send(seat, 0, .{pointer});
        if (cursor_mgr != 0) {
            cursor_dev = create(.cursor_dev, 0);
            conn.send(cursor_mgr, 1, .{ cursor_dev, pointer });
        }
    }
    if (caps & 2 != 0 and keyboard == 0) {
        keyboard = create(.keyboard, 0);
        conn.send(seat, 1, .{keyboard});
    }
}

fn onLayer(own: u8, op: u16, a: *wl.Args) void {
    const s = if (own == 0) &card else &back;
    switch (op) {
        0 => {
            const serial = a.uint();
            const w = a.uint();
            const h = a.uint();
            conn.send(s.layer, 6, .{serial}); // ack_configure
            s.w = if (w > 0) @min(w, 16384) else 1;
            s.h = if (h > 0) @min(h, 16384) else 1;
            s.configured = true;
            if (own == 0) s.dirty = true else paintBackdrop();
        },
        1 => quit(), // композитор закрыл наш слой
        else => {},
    }
}

// ---------------------------------------------------------------- поверхности

fn setupCard() void {
    card.surface = create(.surface, 0);
    conn.send(compositor, 0, .{card.surface});
    card.layer = create(.layer_surface, 0);
    // get_layer_surface(id, surface, output = любой, layer = overlay, namespace)
    conn.send(layer_shell, 0, .{ card.layer, card.surface, @as(u32, 0), @as(u32, 3), wl.str("zwifi") });
    conn.send(card.layer, 0, .{ cfg.menu_width, cfg.menu_height }); // set_size
    conn.send(card.layer, 1, .{@as(u32, 0)}); // без якорей — по центру
    conn.send(card.layer, 4, .{@as(u32, 1)}); // клавиатура: exclusive
    conn.send(card.surface, 6, .{});
}

fn setupBackdrop() void {
    if (viewporter == 0) return; // без масштабирования буфера затемнение не делаем
    back.surface = create(.surface, 1);
    conn.send(compositor, 0, .{back.surface});
    back.layer = create(.layer_surface, 1);
    conn.send(layer_shell, 0, .{ back.layer, back.surface, @as(u32, 0), @as(u32, 3), wl.str("zwifi-backdrop") });
    conn.send(back.layer, 0, .{ @as(u32, 0), @as(u32, 0) });
    conn.send(back.layer, 1, .{@as(u32, 1 | 2 | 4 | 8)}); // на весь экран
    conn.send(back.layer, 2, .{@as(i32, -1)}); // поверх панелей тоже
    back_viewport = create(.viewport, 1);
    conn.send(viewporter, 1, .{ back_viewport, back.surface });
    conn.send(back.surface, 6, .{});
}

/// Затемнение — один пиксель, растянутый на весь экран: память и GPU почти не тратятся.
fn paintBackdrop() void {
    if (!back.configured or back_viewport == 0) return;
    const c = theme.t.menu_backdrop;
    const a: u64 = c >> 24;
    if (back_buffer != 0) conn.send(back_buffer, 0, .{});
    back_buffer = 0;
    if (spb != 0) {
        back_buffer = create(.buffer, 2);
        const ch = struct {
            fn f(v: u32, al: u64) u32 {
                return @intCast(((@as(u64, v & 0xff) * al / 255) * 0x01010101));
            }
        }.f;
        conn.send(spb, 1, .{ back_buffer, ch(c >> 16, a), ch(c >> 8, a), ch(c, a), @as(u32, @intCast(a * 0x01010101)) });
    } else {
        const fd = sys.memfd("zwifi-backdrop") catch return;
        defer sys.close(fd);
        sys.ftruncate(fd, 4) catch return;
        const m = sys.mmap(4, fd) catch return;
        const pix: *u32 = @ptrCast(@alignCast(m));
        pix.* = draw.premul(c);
        sys.munmap(m, 4);
        const pool = create(.pool, 2);
        conn.send(shm, 0, .{ pool, wl.Fd{ .fd = fd }, @as(i32, 4) });
        conn.flush() catch fatal("запись в сокет Wayland");
        back_buffer = create(.buffer, 2);
        conn.send(pool, 0, .{ back_buffer, @as(i32, 0), @as(i32, 1), @as(i32, 1), @as(i32, 4), @as(u32, 0) });
        conn.send(pool, 1, .{});
    }
    conn.send(back_viewport, 2, .{ @as(i32, @intCast(back.w)), @as(i32, @intCast(back.h)) }); // set_destination
    conn.send(back.surface, 1, .{ back_buffer, @as(i32, 0), @as(i32, 0) });
    conn.send(back.surface, 2, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(back.w)), @as(i32, @intCast(back.h)) });
    conn.send(back.surface, 6, .{});
}

fn ensureBuffers() bool {
    const pw = card.w * card.scale;
    const ph = card.h * card.scale;
    if (card.pool != 0 and pw == card.pw and ph == card.ph) return true;
    for (&card.bufs) |*bf| {
        if (bf.id != 0) conn.send(bf.id, 0, .{});
        bf.* = .{};
    }
    if (card.pool != 0) conn.send(card.pool, 1, .{});
    card.pool = 0;
    if (card.mem) |m| sys.munmap(m, card.mem_len);
    card.mem = null;
    card.last = null;
    const stride = pw * 4;
    const size: usize = @as(usize, stride) * ph;
    const fd = sys.memfd("zwifi") catch return false;
    defer sys.close(fd);
    sys.ftruncate(fd, size * 2) catch return false;
    card.mem = sys.mmap(size * 2, fd) catch return false;
    card.mem_len = size * 2;
    card.pw = pw;
    card.ph = ph;
    card.pool = create(.pool, 0);
    conn.send(shm, 0, .{ card.pool, wl.Fd{ .fd = fd }, @as(i32, @intCast(size * 2)) });
    conn.flush() catch fatal("запись в сокет Wayland");
    for (&card.bufs, 0..) |*bf, k| {
        bf.* = .{ .id = create(.buffer, @intCast(k)) };
        conn.send(card.pool, 0, .{ bf.id, @as(i32, @intCast(k * size)), @as(i32, @intCast(pw)), @as(i32, @intCast(ph)), @as(i32, @intCast(stride)), @as(u32, 0) });
    }
    return true;
}

fn pixels(k: u1) []u32 {
    const n = @as(usize, card.pw) * card.ph;
    const p: [*]u32 = @ptrCast(@alignCast(card.mem.? + @as(usize, k) * n * 4));
    return p[0..n];
}

fn render() void {
    if (!ensureBuffers()) return;
    const k: u1 = if (card.last) |l| ~l else 0;
    if (card.bufs[k].busy) return;
    layout();
    var cv = draw.Canvas{ .px = pixels(k), .w = @intCast(card.pw), .h = @intCast(card.ph) };
    paint(&cv);
    // отправляем только изменившуюся полосу строк
    var y0: u32 = 0;
    var y1: u32 = card.ph;
    if (card.last) |l| {
        const old = pixels(l);
        const w = card.pw;
        while (y0 < y1 and std.mem.eql(u32, cv.px[y0 * w ..][0..w], old[y0 * w ..][0..w])) y0 += 1;
        while (y1 > y0 and std.mem.eql(u32, cv.px[(y1 - 1) * w ..][0..w], old[(y1 - 1) * w ..][0..w])) y1 -= 1;
        if (y0 == y1) {
            card.dirty = false;
            return;
        }
    }
    conn.send(card.surface, 1, .{ card.bufs[k].id, @as(i32, 0), @as(i32, 0) });
    if (compositor_ver >= 3) conn.send(card.surface, 8, .{@as(i32, @intCast(card.scale))});
    if (compositor_ver >= 4) {
        conn.send(card.surface, 9, .{ @as(i32, 0), @as(i32, @intCast(y0)), @as(i32, @intCast(card.pw)), @as(i32, @intCast(y1 - y0)) });
    } else {
        conn.send(card.surface, 2, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(card.w)), @as(i32, @intCast(card.h)) });
    }
    conn.send(card.surface, 6, .{});
    card.bufs[k].busy = true;
    card.last = k;
    card.dirty = false;
}

// ---------------------------------------------------------------- указатель

fn setCursor(shape: u32) void {
    if (cursor_dev == 0 or shape == cursor_shape) return;
    cursor_shape = shape;
    conn.send(cursor_dev, 1, .{ ptr_serial, shape });
}

fn onPointer(op: u16, a: *wl.Args) void {
    switch (op) {
        0 => { // enter
            ptr_serial = a.uint();
            const surf = a.uint();
            ptr_x = a.fixed();
            ptr_y = a.fixed();
            ptr_on_card = surf == card.surface;
            cursor_shape = 0;
            updateHover();
        },
        1 => { // leave
            ptr_on_card = false;
            setHover(.{});
        },
        2 => {
            _ = a.uint();
            ptr_x = a.fixed();
            ptr_y = a.fixed();
            if (kbd_nav) {
                kbd_nav = false;
                card.dirty = true;
            }
            updateHover();
        },
        3 => { // button
            _ = a.uint();
            _ = a.uint();
            const btn = a.uint();
            const state = a.uint();
            if (state == 1) onClick(btn);
        },
        4 => { // axis
            _ = a.uint();
            const axis = a.uint();
            const v = a.fixed();
            if (axis == 0 and ptr_on_card and view == .list) {
                scroll_acc += v;
                while (scroll_acc >= 15) : (scroll_acc -= 15) scrollBy(1);
                while (scroll_acc <= -15) : (scroll_acc += 15) scrollBy(-1);
            }
        },
        else => {},
    }
}

fn hitAt(x: f32, y: f32) ?Widget {
    layout();
    var i = nwid;
    while (i > 0) { // последние добавленные — сверху (кнопка «⋯» поверх строки)
        i -= 1;
        const w = widgets[i];
        if (x >= w.x and x < w.x + w.w and y >= w.y and y < w.y + w.h) return w;
    }
    return null;
}

fn setHover(r: Ref) void {
    if (!same(hover, r.id, r.idx)) {
        hover = r;
        card.dirty = true;
    }
}

fn updateHover() void {
    if (!ptr_on_card) return setCursor(1);
    if (hitAt(ptr_x, ptr_y)) |w| {
        setHover(.{ .id = w.id, .idx = w.idx });
        setCursor(if (w.id == .field) 9 else 4); // text / pointer
    } else {
        setHover(.{});
        setCursor(1);
    }
}

fn onClick(btn: u32) void {
    if (!ptr_on_card) return quit(); // клик мимо карточки
    const w = hitAt(ptr_x, ptr_y) orelse return;
    const right = btn == 0x111;
    if (focusable(w)) focus = .{ .id = w.id, .idx = w.idx };
    if (w.id == .field) {
        // курсор в конец поля, по которому кликнули
        const f = &fields[w.idx];
        f.caret = f.len;
    }
    activate(w, right);
    card.dirty = true;
}

// ---------------------------------------------------------------- клавиатура

fn onKeyboard(op: u16, a: *wl.Args) void {
    switch (op) {
        0 => { // keymap(format, fd, size)
            const format = a.uint();
            const size = a.uint();
            const fd = conn.takeFd() orelse return;
            defer sys.close(fd);
            if (format != 1 or size == 0 or size > 4 * 1024 * 1024) return;
            const mem = sys.mmapRead(size, fd) catch return;
            km = xkb.parse(mem[0..size]);
            sys.munmap(@constCast(mem), size);
        },
        2 => stopRepeat(), // leave
        3 => { // key
            _ = a.uint();
            _ = a.uint();
            const key = a.uint();
            const state = a.uint();
            if (state == 1) {
                keyPress(key);
                if (repeatable(key) and repeat_rate > 0) {
                    repeat_key = key;
                    sys.timerfdArmMs(repeat_timer, repeat_delay, 1000 / repeat_rate);
                }
            } else if (key == repeat_key) stopRepeat();
        },
        4 => { // modifiers
            _ = a.uint();
            const dep = a.uint();
            const lat = a.uint();
            const loc = a.uint();
            group = a.uint();
            mods = dep | lat | loc;
        },
        5 => { // repeat_info
            const rate = a.int();
            const delay = a.int();
            repeat_rate = @intCast(std.math.clamp(rate, 0, 100));
            repeat_delay = @intCast(std.math.clamp(delay, 100, 2000));
        },
        else => {},
    }
}

fn stopRepeat() void {
    repeat_key = 0;
    sys.timerfdArmMs(repeat_timer, 0, 0);
}

const K_ESC = 1;
const K_BACKSPACE = 14;
const K_TAB = 15;
const K_ENTER = 28;
const K_KPENTER = 96;
const K_HOME = 102;
const K_UP = 103;
const K_LEFT = 105;
const K_RIGHT = 106;
const K_END = 107;
const K_DOWN = 108;
const K_DELETE = 111;
const K_SPACE = 57;
const K_V = 47;
const K_U = 22;

fn repeatable(key: u32) bool {
    return switch (key) {
        K_ESC, K_TAB, K_ENTER, K_KPENTER, 29, 97, 42, 54, 56, 100, 125, 126, 58 => false,
        else => true,
    };
}

fn keyPress(key: u32) void {
    const shift = mods & 1 != 0;
    const ctrl = mods & 4 != 0;
    card.dirty = true;
    layout();
    switch (key) {
        K_ESC => return goBack(),
        K_TAB => return moveFocus(if (shift) -1 else 1),
        K_ENTER, K_KPENTER => return enter(),
        K_UP => return if (view == .list) moveSel(-1) else moveFocus(-1),
        K_DOWN => return if (view == .list) moveSel(1) else moveFocus(1),
        else => {},
    }
    // поле ввода в фокусе?
    if (focus.id == .field) {
        const f = &fields[focus.idx];
        switch (key) {
            K_BACKSPACE => return backspace(f),
            K_DELETE => return delete(f),
            K_LEFT => return caretLeft(f),
            K_RIGHT => return caretRight(f),
            K_HOME => f.caret = 0,
            K_END => f.caret = f.len,
            else => {
                if (ctrl and key == K_V) return paste(f);
                if (ctrl and key == K_U) {
                    nm.secureZero(f.buf[0..f.len]);
                    f.len = 0;
                    f.caret = 0;
                    return;
                }
                if (ctrl) return;
                const cp = km.char(key, group, shift, mods & 2 != 0);
                if (cp >= 0x20 and cp != 0x7f) insertCp(f, @intCast(cp));
            },
        }
        return;
    }
    if (focus.id == .select and (key == K_LEFT or key == K_RIGHT or key == K_SPACE)) {
        return cycleSelect(focus.idx, key == K_LEFT);
    }
    if (key == K_SPACE) enter();
}

fn moveSel(d: i32) void {
    if (nnets == 0) return;
    kbd_nav = true;
    const n: i32 = @intCast(nnets);
    sel = @intCast(std.math.clamp(@as(i32, @intCast(sel)) + d, 0, n - 1));
    const vis = visibleRows();
    if (sel < scroll) scroll = sel;
    if (sel >= scroll + vis) scroll = sel + 1 - vis;
}

fn moveFocus(d: i32) void {
    var list: [40]Ref = undefined;
    var n: usize = 0;
    for (widgets[0..nwid]) |w| {
        if (focusable(w)) {
            list[n] = .{ .id = w.id, .idx = w.idx };
            n += 1;
        }
    }
    if (n == 0) return;
    var cur: ?usize = null;
    for (list[0..n], 0..) |r, i| {
        if (same(focus, r.id, r.idx)) cur = i;
    }
    const ni: usize = if (cur) |c|
        @intCast(@mod(@as(i32, @intCast(c)) + d, @as(i32, @intCast(n))))
    else if (d > 0) 0 else n - 1;
    focus = list[ni];
    if (focus.id == .field) fields[focus.idx].caret = fields[focus.idx].len;
}

fn enter() void {
    if (view == .list) {
        if (nnets > 0 and sel < nnets) return chooseNet(sel, false);
        return;
    }
    if (focus.id == .select) return cycleSelect(focus.idx, false);
    for (widgets[0..nwid]) |w| {
        if (same(focus, w.id, w.idx) and w.id != .field) return activate(w, false);
    }
    submit();
}

// ---------------------------------------------------------------- редактирование поля

fn insertCp(f: *Field, cp: u21) void {
    var tmp: [4]u8 = undefined;
    const k = std.unicode.utf8Encode(cp, &tmp) catch return;
    insertBytes(f, tmp[0..k]);
}

fn insertBytes(f: *Field, b: []const u8) void {
    if (f.len + b.len > f.buf.len) return;
    std.mem.copyBackwards(u8, f.buf[f.caret + b.len .. f.len + b.len], f.buf[f.caret..f.len]);
    @memcpy(f.buf[f.caret..][0..b.len], b);
    f.len += b.len;
    f.caret += b.len;
    msg_len = 0;
}

fn prevCp(f: *const Field, i: usize) usize {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (f.buf[j] & 0xc0 != 0x80) break;
    }
    return j;
}

fn nextCp(f: *const Field, i: usize) usize {
    var j = i;
    if (j < f.len) j += 1;
    while (j < f.len and f.buf[j] & 0xc0 == 0x80) j += 1;
    return j;
}

fn removeRange(f: *Field, a: usize, b: usize) void {
    std.mem.copyForwards(u8, f.buf[a .. f.len - (b - a)], f.buf[b..f.len]);
    f.len -= b - a;
    nm.secureZero(f.buf[f.len..@min(f.buf.len, f.len + (b - a))]);
}

fn backspace(f: *Field) void {
    if (f.caret == 0) return;
    const p = prevCp(f, f.caret);
    removeRange(f, p, f.caret);
    f.caret = p;
}

fn delete(f: *Field) void {
    if (f.caret >= f.len) return;
    removeRange(f, f.caret, nextCp(f, f.caret));
}

fn caretLeft(f: *Field) void {
    f.caret = prevCp(f, f.caret);
}

fn caretRight(f: *Field) void {
    f.caret = nextCp(f, f.caret);
}

/// Вставка из буфера обмена (одна строка, управляющие символы отбрасываются).
fn paste(f: *Field) void {
    if (selection == 0) return;
    var mime: u8 = 0;
    for (offers) |o| {
        if (o.id == selection) mime = o.mime;
    }
    if (mime == 0) return;
    const p = sys.pipe() catch return;
    conn.send(selection, 1, .{ wl.str(mimes[mime]), wl.Fd{ .fd = p[1] } }); // wl_data_offer.receive
    conn.flush() catch fatal("запись в сокет Wayland");
    sys.close(p[1]);
    defer sys.close(p[0]);
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        var pfd = [1]sys.PollFd{.{ .fd = p[0], .events = sys.POLLIN }};
        const r = sys.poll(&pfd, 500) catch break;
        if (r == 0) break;
        const k = sys.read(p[0], buf[n..]) catch break;
        if (k == 0) break;
        n += k;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = buf[i];
        if (c == '\n' or c == '\r') break;
        if (c < 0x20 or c == 0x7f) continue;
        insertBytes(f, buf[i .. i + 1]);
    }
    nm.secureZero(&buf);
}

// ---------------------------------------------------------------- буфер обмена (события)

fn onDataDevice(op: u16, a: *wl.Args) void {
    switch (op) {
        0 => { // data_offer(new_id)
            const id = a.uint();
            for (&offers) |*o| {
                if (o.id == 0) {
                    o.* = .{ .id = id };
                    return;
                }
            }
            conn.send(id, 2, .{}); // некуда записать — сразу уничтожаем
        },
        5 => { // selection(offer | null)
            const id = a.uint();
            for (&offers) |*o| {
                if (o.id != 0 and o.id != id) {
                    conn.send(o.id, 2, .{}); // wl_data_offer.destroy
                    o.* = .{};
                }
            }
            selection = id;
        },
        else => {},
    }
}

fn onOffer(id: u32, op: u16, a: *wl.Args) void {
    if (op != 0) return; // offer(mime)
    const mime = a.string();
    for (&offers) |*o| {
        if (o.id != id) continue;
        for (mimes[1..], 1..) |m, i| {
            if (std.mem.eql(u8, m, mime) and (o.mime == 0 or i < o.mime)) o.mime = @intCast(i);
        }
    }
}

// ================================================================= логика

fn visibleRows() usize {
    return @intFromFloat((@as(f32, @floatFromInt(cfg.menu_height)) - LIST_Y - 64) / ROW_H);
}

fn scrollBy(d: i32) void {
    const vis = visibleRows();
    if (nnets <= vis) return;
    const max: i32 = @intCast(nnets - vis);
    scroll = @intCast(std.math.clamp(@as(i32, @intCast(scroll)) + d, 0, max));
    card.dirty = true;
    updateHover();
}

fn refresh() void {
    nm.refreshEnabled();
    nnets = if (nm.wifi_enabled) nm.networks(&nets) else 0;
    if (sel >= nnets) sel = if (nnets > 0) nnets - 1 else 0;
    const vis = visibleRows();
    if (scroll + vis > nnets) scroll = if (nnets > vis) nnets - vis else 0;
    card.dirty = true;
}

/// Таймер: список обновляется раз в 3 с, при подключении состояние проверяется 3 раза в секунду.
fn armTimer() void {
    switch (view) {
        .connecting => sys.timerfdArmMs(ui_timer, 330, 330),
        .done => sys.timerfdArmMs(ui_timer, 900, 0),
        .list => sys.timerfdArmMs(ui_timer, 3000, 3000),
        else => sys.timerfdArmMs(ui_timer, 0, 0), // в формах ничего не опрашиваем
    }
}

fn setView(v: View) void {
    view = v;
    focus = .{};
    hover = .{};
    card.dirty = true;
    armTimer();
    // фокус на первое поле формы
    layout();
    for (widgets[0..nwid]) |w| {
        if (w.id == .field or (v == .actions and focusable(w))) {
            focus = .{ .id = w.id, .idx = w.idx };
            if (w.id == .field) fields[w.idx].caret = fields[w.idx].len;
            break;
        }
    }
    updateHover();
}

fn onTick() void {
    ticks +%= 1;
    switch (view) {
        .list => {
            if (!nm_ok) return;
            if (ticks % 4 == 0) nm.scan();
            refresh();
        },
        .connecting => {
            card.dirty = true; // анимация точек
            switch (nm.progress()) {
                .working => if (ticks > 3 * 90) fail("Превышено время ожидания"),
                .done => {
                    for (&fields) |*f| nm.secureZero(&f.buf);
                    setView(.done);
                },
                .failed => fail(nm.lastError()),
            }
        },
        .done => quit(),
        else => {},
    }
}

fn fail(why: []const u8) void {
    setMsg(why);
    nm.dropCreated();
    // сохранённый профиль не подошёл — предлагаем ввести данные заново
    if (form_view == .list) {
        reenter = true;
        form_view = switch (target.sec) {
            .eap => .enterprise,
            .psk, .sae => .password,
            else => .list,
        };
    }
    const keep = msg_buf;
    const keep_len = msg_len;
    setView(form_view);
    msg_buf = keep;
    msg_len = keep_len;
    nm.loadSaved();
}

fn startConnecting(from: View) void {
    form_view = from;
    ticks = 0;
    msg_len = 0;
    setView(.connecting);
}

fn goBack() void {
    switch (view) {
        .list => quit(),
        .connecting => {
            _ = nm.disconnect();
            nm.dropCreated();
            setView(.list);
            refresh();
        },
        .enterprise => setView(if (target_hidden) .hidden else .list),
        else => setView(.list),
    }
    msg_len = 0;
}

fn clearForm() void {
    for (&fields) |*f| {
        nm.secureZero(&f.buf);
        f.len = 0;
        f.caret = 0;
    }
    reveal = false;
    msg_len = 0;
}

fn chooseNet(i: usize, right: bool) void {
    if (i >= nnets) return;
    target = nets[i];
    target_hidden = false;
    reenter = false;
    clearForm();
    if (target.active or (right and target.known)) return setView(.actions);
    if (target.known) {
        if (nm.activateSaved(target.conn.get(), target.ap.get())) startConnecting(.list) else setMsg(nm.lastError());
        return;
    }
    switch (target.sec) {
        .open, .owe => connectSimple(),
        .psk, .sae => setView(.password),
        .eap => {
            method = .peap;
            phase2 = 0;
            setView(.enterprise);
        },
        .wep => setMsg("WEP устарел и небезопасен — не поддерживается"),
    }
}

fn connectSimple() void {
    if (nm.addAndActivate(.{ .ssid = target.ssid(), .hidden = target_hidden, .sec = target.sec }, target.ap.get())) {
        startConnecting(.list);
    } else setMsg(nm.lastError());
}

fn activate(w: Widget, right: bool) void {
    switch (w.id) {
        .row => {
            sel = w.idx;
            chooseNet(w.idx, right);
        },
        .more => {
            target = nets[w.idx];
            setView(.actions);
        },
        .toggle => {
            if (nm.setEnabled(!nm.wifi_enabled)) refresh() else setMsg(nm.lastError());
        },
        .back => goBack(),
        .other => {
            clearForm();
            hsec = 1;
            target_hidden = true;
            setView(.hidden);
        },
        .select => cycleSelect(w.idx, right),
        .eye => reveal = !reveal,
        .primary => submit(),
        .secondary => goBack(),
        .act_connect => {
            if (nm.activateSaved(target.conn.get(), target.ap.get())) startConnecting(.list) else setMsg(nm.lastError());
        },
        .act_disconnect => {
            if (nm.disconnect()) {
                setView(.list);
                refresh();
            } else setMsg(nm.lastError());
        },
        .act_forget => {
            if (target.known and nm.forget(target.conn.get())) {
                nm.loadSaved();
                setView(.list);
                refresh();
            } else setMsg(nm.lastError());
        },
        .field, .none => {},
    }
}

fn cycleSelect(idx: u8, back_dir: bool) void {
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
    card.dirty = true;
}

fn val(f: F) []const u8 {
    return fields[@intFromEnum(f)].text();
}

fn submit() void {
    msg_len = 0;
    switch (view) {
        .password => {
            const pw = val(.password);
            if (target.sec == .psk and (pw.len < 8 or pw.len > 63)) return setMsg("Пароль WPA — от 8 до 63 символов");
            if (pw.len == 0) return setMsg("Введите пароль");
            if (reenter and target.known) _ = nm.forget(target.conn.get());
            if (nm.addAndActivate(.{ .ssid = target.ssid(), .hidden = target_hidden, .sec = target.sec, .psk = pw }, target.ap.get())) {
                startConnecting(.password);
            } else setMsg(nm.lastError());
        },
        .enterprise => {
            if (val(.identity).len == 0) return setMsg("Введите логин");
            if (method == .tls) {
                if (val(.cert).len == 0) return setMsg("Укажите файл сертификата");
            } else if (val(.password).len == 0) return setMsg("Введите пароль");
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
            if (nm.addAndActivate(spec, target.ap.get())) startConnecting(.enterprise) else setMsg(nm.lastError());
        },
        .hidden => {
            const ssid = val(.ssid);
            if (ssid.len == 0 or ssid.len > 32) return setMsg("Имя сети — от 1 до 32 байт");
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
                    if (pw.len < 8 or pw.len > 63) return setMsg("Пароль WPA — от 8 до 63 символов");
                    if (nm.addAndActivate(.{ .ssid = ssid, .hidden = true, .sec = .psk, .psk = pw }, "")) startConnecting(.hidden) else setMsg(nm.lastError());
                },
                else => {
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

// ================================================================= раскладка

const PAD: f32 = 18;
const ROW_H: f32 = 44;
const LIST_Y: f32 = 62;
const FIELD_H: f32 = 34;
const LABEL_W: f32 = 124;
const STEP: f32 = 42;

fn cw() f32 {
    return @floatFromInt(cfg.menu_width);
}
fn chh() f32 {
    return @floatFromInt(cfg.menu_height);
}

/// Строки формы 802.1X: (поле/селектор, индекс, подпись).
const FormRow = struct { id: Wid, idx: u8, label: []const u8 };

fn enterpriseRows(out: *[8]FormRow) usize {
    var n: usize = 0;
    out[n] = .{ .id = .select, .idx = 0, .label = "Метод" };
    n += 1;
    if (method != .tls) {
        out[n] = .{ .id = .select, .idx = 1, .label = "Фаза 2" };
        n += 1;
    }
    out[n] = .{ .id = .field, .idx = @intFromEnum(F.identity), .label = "Логин" };
    n += 1;
    if (method == .tls) {
        out[n] = .{ .id = .field, .idx = @intFromEnum(F.cert), .label = "Сертификат" };
        n += 1;
        out[n] = .{ .id = .field, .idx = @intFromEnum(F.key), .label = "Ключ" };
        n += 1;
        out[n] = .{ .id = .field, .idx = @intFromEnum(F.keypass), .label = "Пароль ключа" };
        n += 1;
    } else {
        out[n] = .{ .id = .field, .idx = @intFromEnum(F.password), .label = "Пароль" };
        n += 1;
        out[n] = .{ .id = .field, .idx = @intFromEnum(F.anon), .label = "Анон. логин" };
        n += 1;
    }
    out[n] = .{ .id = .field, .idx = @intFromEnum(F.ca), .label = "CA-сертификат" };
    n += 1;
    out[n] = .{ .id = .field, .idx = @intFromEnum(F.domain), .label = "Домен сервера" };
    n += 1;
    return n;
}

fn hiddenRows(out: *[8]FormRow) usize {
    var n: usize = 0;
    out[n] = .{ .id = .field, .idx = @intFromEnum(F.ssid), .label = "Имя сети" };
    n += 1;
    out[n] = .{ .id = .select, .idx = 2, .label = "Защита" };
    n += 1;
    if (hsec == 1) {
        out[n] = .{ .id = .field, .idx = @intFromEnum(F.password), .label = "Пароль" };
        n += 1;
    }
    return n;
}

fn bottomButtons() void {
    const bw = (cw() - 2 * PAD - 10) / 2;
    const y = chh() - PAD - 38;
    add(.secondary, 0, PAD, y, bw, 38);
    add(.primary, 0, PAD + bw + 10, y, bw, 38);
}

fn layout() void {
    nwid = 0;
    const W = cw();
    switch (view) {
        .list => {
            if (nm_ok) add(.toggle, 0, W - PAD - 40, 20, 40, 22);
            const vis = visibleRows();
            var i = scroll;
            var y = LIST_Y;
            while (i < nnets and i < scroll + vis) : (i += 1) {
                add(.row, @intCast(i), PAD - 8, y, W - 2 * PAD + 16, ROW_H - 4);
                if (nets[i].known) add(.more, @intCast(i), W - PAD - 34, y + 6, 28, 28);
                y += ROW_H;
            }
            if (nm_ok and nm.wifi_enabled) add(.other, 0, PAD, chh() - PAD - 38, W - 2 * PAD, 38);
        },
        .password => {
            add(.back, 0, PAD - 8, 16, 30, 30);
            add(.field, @intFromEnum(F.password), PAD, 112, W - 2 * PAD, FIELD_H);
            add(.eye, 0, W - PAD - 32, 115, 28, 28);
            bottomButtons();
        },
        .enterprise, .hidden => {
            add(.back, 0, PAD - 8, 16, 30, 30);
            var rows: [8]FormRow = undefined;
            const n = if (view == .enterprise) enterpriseRows(&rows) else hiddenRows(&rows);
            var y: f32 = 64;
            for (rows[0..n]) |r| {
                add(r.id, r.idx, PAD + LABEL_W, y, W - 2 * PAD - LABEL_W, FIELD_H);
                y += STEP;
            }
            bottomButtons();
        },
        .actions => {
            add(.back, 0, PAD - 8, 16, 30, 30);
            var y: f32 = 110;
            if (target.active) {
                add(.act_disconnect, 0, PAD, y, W - 2 * PAD, 40);
            } else {
                add(.act_connect, 0, PAD, y, W - 2 * PAD, 40);
            }
            y += 50;
            if (target.known) add(.act_forget, 0, PAD, y, W - 2 * PAD, 40);
        },
        .connecting => add(.secondary, 0, (W - 140) / 2, chh() - PAD - 38, 140, 38),
        .done => {},
    }
}

// ================================================================= рисование

var S: f32 = 1;

fn px(v: f32) f32 {
    return v * S;
}

fn fpx(size: f32) u16 {
    return @intFromFloat(@round(size * S));
}

fn rrect(cv: *draw.Canvas, x: f32, y: f32, w: f32, h: f32, r: f32, c: u32) void {
    cv.fillRoundRect(px(x), px(y), px(w), px(h), px(r), c);
}

fn outline(cv: *draw.Canvas, x: f32, y: f32, w: f32, h: f32, r: f32, c: u32, width: f32) void {
    const b = [_]draw.Prim{.{ .box = .{ .x = px(x), .y = px(y), .w = px(w), .h = px(h), .r = px(r) } }};
    cv.prims(&b, 0, 0, 1, px(width), c);
}

fn text(cv: *draw.Canvas, s: []const u8, x: f32, baseline: f32, size: f32, c: u32, max_x: f32) f32 {
    return ttf.drawText(cv, s, @round(px(x)), px(baseline), fpx(size), c, px(max_x)) / S;
}

fn textW(s: []const u8, size: f32) f32 {
    return ttf.width(s, fpx(size)) / S;
}

/// Базовая линия, при которой текст размера size по центру полосы [y, y+h].
fn mid(y: f32, h: f32, size: f32) f32 {
    return y + h / 2 + size * 0.36;
}

fn centered(cv: *draw.Canvas, s: []const u8, cx: f32, baseline: f32, size: f32, c: u32) void {
    _ = text(cv, s, cx - textW(s, size) / 2, baseline, size, c, cw());
}

fn icon(cv: *draw.Canvas, prims: []const draw.Prim, x: f32, y: f32, size: f32, stroke: f32, c: u32) void {
    cv.prims(prims, @round(px(x)), @round(px(y)), px(size / 16), px(stroke), c);
}

const ic_back = [_]draw.Prim{
    .{ .seg = .{ .x0 = 10, .y0 = 3, .x1 = 5, .y1 = 8 } },
    .{ .seg = .{ .x0 = 5, .y0 = 8, .x1 = 10, .y1 = 13 } },
};
const ic_check = [_]draw.Prim{
    .{ .seg = .{ .x0 = 3, .y0 = 8.5, .x1 = 6.5, .y1 = 12 } },
    .{ .seg = .{ .x0 = 6.5, .y0 = 12, .x1 = 13, .y1 = 4.5 } },
};
const ic_lock = [_]draw.Prim{
    .{ .fbox = .{ .x = 3.5, .y = 7.5, .w = 9, .h = 7, .r = 1.6 } },
    .{ .arc = .{ .cx = 8, .cy = 7.5, .r = 2.9, .a0 = 180, .a1 = 360 } },
};
const ic_more = [_]draw.Prim{
    .{ .dot = .{ .cx = 3.5, .cy = 8, .r = 1.4 } },
    .{ .dot = .{ .cx = 8, .cy = 8, .r = 1.4 } },
    .{ .dot = .{ .cx = 12.5, .cy = 8, .r = 1.4 } },
};
const ic_eye = [_]draw.Prim{
    .{ .arc = .{ .cx = 8, .cy = 14, .r = 8.5, .a0 = 218, .a1 = 322 } },
    .{ .arc = .{ .cx = 8, .cy = 2, .r = 8.5, .a0 = 38, .a1 = 142 } },
    .{ .dot = .{ .cx = 8, .cy = 8, .r = 2.1 } },
};
const ic_slash = [_]draw.Prim{.{ .seg = .{ .x0 = 3, .y0 = 13, .x1 = 13, .y1 = 3 } }};
const ic_chevron = [_]draw.Prim{
    .{ .seg = .{ .x0 = 4.5, .y0 = 6.5, .x1 = 8, .y1 = 10 } },
    .{ .seg = .{ .x0 = 8, .y0 = 10, .x1 = 11.5, .y1 = 6.5 } },
};

fn signal(cv: *draw.Canvas, x: f32, y: f32, strength: u8, on: u32, off: u32) void {
    const lvl: u8 = if (strength > 75) 4 else if (strength > 50) 3 else if (strength > 25) 2 else 1;
    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const h = 4 + fi * 3.3;
        rrect(cv, x + fi * 4.5, y + 14 - h, 3, h, 1.2, if (i < lvl) on else off);
    }
}

fn secLabel(s: nm.Security) []const u8 {
    return switch (s) {
        .open => "Открытая сеть",
        .owe => "Открытая (OWE, шифрование)",
        .psk => "WPA/WPA2 Personal",
        .sae => "WPA3 Personal",
        .eap => "Корпоративная 802.1X",
        .wep => "WEP — не поддерживается",
    };
}

fn paint(cv: *draw.Canvas) void {
    S = @floatFromInt(card.scale);
    const t = &theme.t;
    const W = cw();
    const H = chh();
    cv.clear(0);
    rrect(cv, 0, 0, W, H, cfg.menu_radius, t.menu_background);
    outline(cv, 0.5, 0.5, W - 1, H - 1, cfg.menu_radius, t.menu_border, 1);

    switch (view) {
        .list => paintList(cv),
        .password => {
            header(cv, target.ssid(), secLabel(target.sec));
            _ = text(cv, "Пароль", PAD, 102, 13, t.menu_muted, W);
            paintWidgets(cv);
            paintMsg(cv, 168);
        },
        .enterprise, .hidden => {
            header(cv, if (view == .hidden) "Другая сеть" else target.ssid(), if (view == .hidden) "" else secLabel(.eap));
            var rows: [8]FormRow = undefined;
            const n = if (view == .enterprise) enterpriseRows(&rows) else hiddenRows(&rows);
            var y: f32 = 64;
            for (rows[0..n]) |r| {
                _ = text(cv, r.label, PAD, mid(y, FIELD_H, 13), 13, t.menu_muted, PAD + LABEL_W - 6);
                y += STEP;
            }
            paintWidgets(cv);
            if (msg_len > 0) {
                paintMsg(cv, y + 16);
            } else if (view == .enterprise and val(.ca).len == 0 and val(.domain).len == 0) {
                _ = text(cv, "Без CA и домена сервер не проверяется", PAD, y + 16, 12, t.menu_muted, W - PAD);
            }
        },
        .actions => {
            header(cv, target.ssid(), if (target.active) "Подключено" else "Сохранённая сеть");
            paintWidgets(cv);
            paintMsg(cv, 230);
        },
        .connecting => {
            centered(cv, target.ssid(), W / 2, H / 2 - 18, 18, t.menu_text);
            const dots = [_][]const u8{ "Подключение", "Подключение.", "Подключение..", "Подключение..." };
            _ = text(cv, dots[ticks % 4], W / 2 - textW("Подключение...", 14) / 2, H / 2 + 14, 14, t.menu_muted, W);
            paintWidgets(cv);
        },
        .done => {
            const r: f32 = 26;
            const ring = [_]draw.Prim{.{ .ring = .{ .cx = 8, .cy = 8, .r = 7.4 } }};
            icon(cv, &ring, W / 2 - r, H / 2 - r - 24, 2 * r, 2.2, t.menu_accent);
            icon(cv, &ic_check, W / 2 - 14, H / 2 - 38, 28, 2.4, t.menu_accent);
            centered(cv, "Подключено", W / 2, H / 2 + 30, 16, t.menu_text);
        },
    }
}

fn header(cv: *draw.Canvas, title: []const u8, sub: []const u8) void {
    const t = &theme.t;
    _ = text(cv, title, PAD + 26, 37, 17, t.menu_text, cw() - PAD);
    if (sub.len > 0) _ = text(cv, sub, PAD + 26, 56, 12, t.menu_muted, cw() - PAD);
}

fn paintMsg(cv: *draw.Canvas, y: f32) void {
    if (msg_len == 0) return;
    _ = text(cv, msg_buf[0..msg_len], PAD, y, 13, theme.t.menu_error, cw() - PAD);
}

fn paintList(cv: *draw.Canvas) void {
    const t = &theme.t;
    const W = cw();
    const H = chh();
    _ = text(cv, "Wi‑Fi", PAD, 38, 19, t.menu_text, W);
    if (!nm_ok) {
        centered(cv, "NetworkManager недоступен", W / 2, H / 2 - 8, 15, t.menu_text);
        centered(cv, msg_buf[0..msg_len], W / 2, H / 2 + 16, 12, t.menu_muted);
        return;
    }
    if (!nm.wifi_enabled) {
        centered(cv, "Wi‑Fi выключен", W / 2, H / 2, 15, t.menu_muted);
    } else if (nnets == 0) {
        centered(cv, "Поиск сетей…", W / 2, H / 2, 15, t.menu_muted);
    }
    paintWidgets(cv);
    if (msg_len > 0) paintMsg(cv, H - PAD - 52);
    // полоса прокрутки
    const vis = visibleRows();
    if (nnets > vis) {
        const track = @as(f32, @floatFromInt(vis)) * ROW_H;
        const h = track * @as(f32, @floatFromInt(vis)) / @as(f32, @floatFromInt(nnets));
        const y = LIST_Y + (track - h) * @as(f32, @floatFromInt(scroll)) / @as(f32, @floatFromInt(nnets - vis));
        rrect(cv, W - 6, y, 3, h, 1.5, t.menu_border);
    }
}

fn paintWidgets(cv: *draw.Canvas) void {
    const t = &theme.t;
    for (widgets[0..nwid]) |w| {
        const hov = same(hover, w.id, w.idx);
        const foc = same(focus, w.id, w.idx);
        switch (w.id) {
            .row => {
                const n = &nets[w.idx];
                const kbd = view == .list and w.idx == sel and kbd_nav;
                if ((hov and !kbd_nav) or kbd) rrect(cv, w.x, w.y, w.w, w.h, 10, t.menu_hover);
                signal(cv, w.x + 12, w.y + (w.h - 14) / 2, n.strength, if (n.active) t.menu_accent else t.menu_text, t.menu_border);
                const name_c = if (n.active) t.menu_accent else t.menu_text;
                var right = w.x + w.w - 12;
                if (n.known) right -= 30;
                if (n.active) {
                    icon(cv, &ic_check, right - 16, w.y + (w.h - 16) / 2, 16, 2, t.menu_accent);
                    right -= 22;
                }
                if (n.sec != .open and n.sec != .owe) {
                    icon(cv, &ic_lock, right - 14, w.y + (w.h - 14) / 2, 14, 1.6, t.menu_muted);
                    right -= 20;
                }
                if (n.sec == .eap) {
                    const tag = "802.1X";
                    const tw = textW(tag, 11);
                    _ = text(cv, tag, right - tw, mid(w.y, w.h, 11), 11, t.menu_muted, cw());
                    right -= tw + 8;
                }
                _ = text(cv, n.ssid(), w.x + 38, mid(w.y, w.h, 14), 14, name_c, right - 6);
            },
            .more => {
                if (hov) rrect(cv, w.x, w.y, w.w, w.h, 8, t.menu_hover);
                icon(cv, &ic_more, w.x + 6, w.y + 6, 16, 1, t.menu_muted);
            },
            .toggle => {
                const on = nm.wifi_enabled;
                rrect(cv, w.x, w.y, w.w, w.h, w.h / 2, if (on) t.menu_accent else t.menu_field);
                const kx = if (on) w.x + w.w - w.h + 3 else w.x + 3;
                rrect(cv, kx, w.y + 3, w.h - 6, w.h - 6, (w.h - 6) / 2, if (on) t.menu_accent_text else t.menu_muted);
            },
            .back => {
                if (hov) rrect(cv, w.x, w.y, w.w, w.h, 8, t.menu_hover);
                icon(cv, &ic_back, w.x + 7, w.y + 7, 16, 2, t.menu_text);
            },
            .other => drawButton(cv, w, "Другая сеть…", .secondary, hov, foc),
            .primary => drawButton(cv, w, if (view == .hidden and hsec == 2) "Далее" else "Подключить", .primary, hov, foc),
            .secondary => drawButton(cv, w, "Отмена", .secondary, hov, foc),
            .act_connect => drawButton(cv, w, "Подключиться", .primary, hov, foc),
            .act_disconnect => drawButton(cv, w, "Отключиться", .secondary, hov, foc),
            .act_forget => drawButton(cv, w, "Забыть сеть", .danger, hov, foc),
            .field => paintField(cv, w, foc),
            .select => {
                rrect(cv, w.x, w.y, w.w, w.h, 8, t.menu_field);
                if (hov) rrect(cv, w.x, w.y, w.w, w.h, 8, t.menu_hover);
                if (foc) outline(cv, w.x, w.y, w.w, w.h, 8, t.menu_accent, 1.5);
                const label = switch (w.idx) {
                    0 => method_label[@intFromEnum(method)],
                    1 => if (method == .ttls) ttls_p2_label[phase2] else peap_p2_label[phase2],
                    else => hsec_label[hsec],
                };
                _ = text(cv, label, w.x + 10, mid(w.y, w.h, 13), 13, t.menu_text, w.x + w.w - 26);
                icon(cv, &ic_chevron, w.x + w.w - 24, w.y + (w.h - 16) / 2, 16, 1.6, t.menu_muted);
            },
            .eye => {
                icon(cv, &ic_eye, w.x + 6, w.y + 6, 16, 1.5, if (hov) t.menu_text else t.menu_muted);
                if (!reveal) icon(cv, &ic_slash, w.x + 6, w.y + 6, 16, 1.5, if (hov) t.menu_text else t.menu_muted);
            },
            .none => {},
        }
    }
}

const BtnKind = enum { primary, secondary, danger };

fn drawButton(cv: *draw.Canvas, w: Widget, label: []const u8, kind: BtnKind, hov: bool, foc: bool) void {
    const t = &theme.t;
    const bg = if (kind == .primary) t.menu_accent else t.menu_field;
    rrect(cv, w.x, w.y, w.w, w.h, 10, bg);
    if (hov) rrect(cv, w.x, w.y, w.w, w.h, 10, t.menu_hover);
    if (foc) outline(cv, w.x - 2, w.y - 2, w.w + 4, w.h + 4, 12, t.menu_accent, 1.5);
    const fg = switch (kind) {
        .primary => t.menu_accent_text,
        .secondary => t.menu_text,
        .danger => t.menu_error,
    };
    centered(cv, label, w.x + w.w / 2, mid(w.y, w.h, 14), 14, fg);
}

fn placeholder(idx: u8) []const u8 {
    return switch (@as(F, @enumFromInt(idx))) {
        .ssid => "имя скрытой сети",
        .password => "",
        .identity => "user@example.com",
        .anon => "необязательно",
        .ca => "/путь/к/ca.pem — необязательно",
        .domain => "radius.example.com",
        .cert => "/путь/к/client.p12",
        .key => "для .p12 не нужен",
        .keypass => "",
    };
}

fn isSecret(idx: u8) bool {
    const f: F = @enumFromInt(idx);
    return f == .password or f == .keypass;
}

fn paintField(cv: *draw.Canvas, w: Widget, foc: bool) void {
    const t = &theme.t;
    const f = &fields[w.idx];
    rrect(cv, w.x, w.y, w.w, w.h, 8, t.menu_field);
    if (foc) outline(cv, w.x, w.y, w.w, w.h, 8, t.menu_accent, 1.5);
    const size: f32 = 13;
    const x0 = w.x + 10;
    const avail = w.w - 20 - (if (view == .password) @as(f32, 28) else 0);
    if (f.len == 0) {
        const ph = placeholder(w.idx);
        if (ph.len > 0) _ = text(cv, ph, x0, mid(w.y, w.h, size), size, t.menu_muted, x0 + avail);
        if (foc) rrect(cv, x0, w.y + 8, 1.5, w.h - 16, 0.5, t.menu_accent);
        return;
    }
    // что показываем: текст или точки
    var shown: [768]u8 = undefined;
    var slen: usize = 0;
    var caret_s: usize = 0;
    if (isSecret(w.idx) and !reveal) {
        var it = ttf.Utf8{ .s = f.text() };
        while (it.next()) |_| {
            if (it.i <= f.caret) caret_s = slen + 3;
            if (slen + 3 <= shown.len) {
                @memcpy(shown[slen..][0..3], "\u{2022}");
                slen += 3;
            }
        }
        if (f.caret == 0) caret_s = 0;
    } else {
        @memcpy(shown[0..f.len], f.text());
        slen = f.len;
        caret_s = f.caret;
    }
    const s = shown[0..slen];
    // окно прокрутки: курсор всегда виден
    var start: usize = 0;
    while (start < caret_s and textW(s[start..caret_s], size) > avail) {
        start += 1;
        while (start < slen and s[start] & 0xc0 == 0x80) start += 1;
    }
    _ = text(cv, s[start..], x0, mid(w.y, w.h, size), size, t.menu_text, x0 + avail);
    if (foc) {
        const cx = x0 + textW(s[start..caret_s], size);
        rrect(cv, cx, w.y + 8, 1.5, w.h - 16, 0.5, t.menu_accent);
    }
}
