// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Общий каркас меню zpanel (zrun, zwifi, zbt, zwall, zpower, zcal).
//!
//! Карточка по центру экрана поверх лёгкого затемнения, указатель, клавиатура (XKB, повтор
//! клавиш), буфер обмена, поля ввода, кнопки, тема с перезагрузкой на лету, песочница.
//! Каждое меню описывает только свои экраны: раскладку виджетов, рисование и реакцию на них.
//! Повторный запуск того же меню закрывает уже открытое.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const wl = @import("wl.zig");
const draw = @import("draw.zig");
const ttf = @import("ttf.zig");
const theme = @import("theme.zig");
const cfg = @import("config.zig");
const xkb = @import("xkb.zig");
const sandbox = @import("sandbox.zig");

// ================================================================= описание меню

/// Как виджет ведёт себя с клавиатурой и курсором.
pub const Kind = enum(u8) {
    plain, // только клик
    row, // строка списка: выбор стрелками ↑/↓ делает само меню
    button, // фокус Tab, Enter/Пробел — нажатие
    field, // поле ввода
    select, // выбор из вариантов: ←/→/Пробел
    toggle, // переключатель: только клик
};

pub const Widget = struct { id: u8, idx: u16 = 0, kind: Kind = .plain, x: f32, y: f32, w: f32, h: f32 };
pub const Ref = struct { id: u8 = 0, idx: u16 = 0 };
pub const Key = struct { code: u32, ch: u32, shift: bool, ctrl: bool };

pub const App = struct {
    width: u32,
    height: u32,
    layout: *const fn () void,
    paint: *const fn (cv: *draw.Canvas) void,
    /// клик или Enter по виджету
    activate: *const fn (w: Widget, right: bool) void,
    /// Esc
    back: *const fn () void,
    /// Enter, когда в фокусе поле ввода (или ничего)
    submit: ?*const fn () void = null,
    /// клавиша раньше общей обработки; true — обработано
    key: ?*const fn (k: Key) bool = null,
    /// колёсико над карточкой: +1 вниз, -1 вверх
    scroll: ?*const fn (dir: i32) void = null,
    /// таймер, взведённый через setTimer
    tick: ?*const fn () void = null,
    /// поле ввода по индексу виджета-поля
    field: ?*const fn (idx: u16) ?*Field = null,
    /// выбор в select: ←/→ или клик (back = назад по списку)
    cycle: ?*const fn (idx: u16, back: bool) void = null,
    /// дополнительный дескриптор в цикле событий (например, D-Bus)
    extra_fd: ?*const fn () i32 = null,
    on_extra: ?*const fn () void = null,
    /// после включения песочницы, перед первым кадром
    start: ?*const fn () void = null,
    /// перед выходом: затереть секреты
    cleanup: ?*const fn () void = null,
};

// ================================================================= поля ввода

pub const Field = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    caret: usize = 0,

    pub fn text(f: *const Field) []const u8 {
        return f.buf[0..f.len];
    }
    pub fn clear(f: *Field) void {
        sys.secureZero(&f.buf);
        f.len = 0;
        f.caret = 0;
    }
};

// ================================================================= состояние

const OKind = enum(u8) {
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
var kinds: [wl.MAX_IDS]OKind = [_]OKind{.none} ** wl.MAX_IDS;
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

var app_timer: i32 = -1;
var repeat_timer: i32 = -1;
var lock_fd: i32 = -1;
var name_buf: [32]u8 = undefined;
var name: []const u8 = "zmenu";
var app: App = undefined;
var my_uid: u32 = 0; // запоминаем до песочницы: getuid в ней запрещён

pub var widgets: [64]Widget = undefined;
pub var nwid: usize = 0;
pub var focus: Ref = .{};
pub var hover: Ref = .{};
/// строку выбрали стрелками — подсвечиваем её, а не строку под мышью
pub var kbd_nav = false;

// ================================================================= запуск

/// Первая часть запуска: окружение, «повторный запуск закрывает», шрифт, тема.
/// После неё меню подключается к своим службам (D-Bus и т.п.), затем вызывает run().
pub fn begin(menu_name: []const u8) void {
    my_uid = @intCast(sys.getuid());
    if (my_uid == 0) {
        sys.log("запуск от root запрещён", .{});
        sys.exit(1);
    }
    const k = @min(menu_name.len, name_buf.len);
    @memcpy(name_buf[0..k], menu_name[0..k]);
    name = name_buf[0..k];
    var lock_buf: [64]u8 = undefined;
    const lock_name = std.fmt.bufPrint(&lock_buf, "{s}-{d}", .{ name, my_uid }) catch name;
    if (sys.connectAbstract(lock_name)) sys.exit(0);
    lock_fd = sys.listenAbstract(lock_name) catch -1;

    if (!ttf.load(&cfg.font_paths)) {
        sys.log("не найден шрифт TrueType — укажите путь в font_paths (config.zig)", .{});
        sys.exit(1);
    }
    theme.init();
}

pub const Access = struct {
    /// что ещё разрешить читать
    read: []const [:0]const u8 = &.{},
    /// куда разрешить писать (папки)
    write: []const [:0]const u8 = &.{},
};

pub const Sandbox = struct {
    /// дополнительные системные вызовы
    extra: []const linux.SYS = &.{},
    /// разрешить создавать и писать файлы (только в Access.write — это решает Landlock)
    write_files: bool = false,
};

/// Вторая часть: окно, песочница, цикл событий.
pub fn run(a: App, access: Access, comptime sb: Sandbox) noreturn {
    app = a;
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

    app_timer = sys.timerfdCreate(sys.CLOCK_MONOTONIC) catch fatal("timerfd");
    repeat_timer = sys.timerfdCreate(sys.CLOCK_MONOTONIC) catch fatal("timerfd");

    if (cfg.sandbox) {
        var paths: [24][:0]const u8 = undefined;
        var n: usize = 0;
        paths[n] = theme.dir;
        n += 1;
        for (access.read) |p| {
            if (n == paths.len) break;
            paths[n] = p;
            n += 1;
        }
        // pipe2 — вставка из буфера обмена; accept4/getsockopt — проверка, кто нас закрывает
        sandbox.apply(paths[0..n], access.write, .{
            .extra = &([_]linux.SYS{ .pipe2, .accept4, .getsockopt } ++ sb.extra[0..sb.extra.len].*),
            .write_files = sb.write_files,
        });
    }

    if (app.start) |f| f();
    redraw();

    while (true) {
        if (card.configured and card.dirty) render();
        conn.flush() catch fatal("запись в сокет Wayland");
        const xfd: i32 = if (app.extra_fd) |f| f() else -1;
        var fds = [6]sys.PollFd{
            .{ .fd = conn.fd, .events = sys.POLLIN },
            .{ .fd = app_timer, .events = sys.POLLIN },
            .{ .fd = repeat_timer, .events = sys.POLLIN },
            .{ .fd = lock_fd, .events = sys.POLLIN },
            .{ .fd = theme.inotify_fd, .events = sys.POLLIN },
            .{ .fd = xfd, .events = sys.POLLIN },
        };
        _ = sys.poll(&fds, -1) catch continue;
        if (fds[0].revents != 0) readWayland();
        if (fds[5].revents != 0) {
            if (app.on_extra) |f| f();
        }
        if (fds[1].revents != 0) {
            drainTimer(app_timer);
            if (app.tick) |f| f();
        }
        if (fds[2].revents != 0) {
            drainTimer(repeat_timer);
            if (repeat_key != 0) keyPress(repeat_key);
        }
        if (fds[3].revents != 0) {
            // нас закрывает повторный запуск — но только от того же пользователя
            if (sys.acceptPeerUid(lock_fd)) |uid| {
                if (uid == my_uid) quit();
            }
        }
        if (fds[4].revents != 0 and theme.inotify_fd >= 0) {
            if (theme.onInotify()) {
                redraw();
                paintBackdrop();
            }
        }
    }
}

pub fn quit() noreturn {
    if (app.cleanup) |f| f();
    sys.exit(0);
}

fn fatal(what: []const u8) noreturn {
    sys.log("ошибка: {s}", .{what});
    sys.exit(1);
}

pub fn redraw() void {
    card.dirty = true;
}

/// Таймер меню: первое срабатывание через first_ms, затем каждые every_ms (0, 0 — выключить).
pub fn setTimer(first_ms: u32, every_ms: u32) void {
    sys.timerfdArmMs(app_timer, first_ms, every_ms);
}

fn drainTimer(fd: i32) void {
    var b: [8]u8 = undefined;
    _ = sys.read(fd, &b) catch {};
}

// ================================================================= Wayland

fn create(kind: OKind, own: u8) u32 {
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

fn bind(gname: u32, iface: []const u8, ver: u32, kind: OKind) u32 {
    const id = create(kind, 0);
    conn.send(registry, 0, .{ gname, wl.str(iface), ver, id });
    return id;
}

fn onGlobal(gname: u32, iface: []const u8, ver: u32) void {
    const eql = std.mem.eql;
    if (eql(u8, iface, "wl_compositor") and compositor == 0) {
        compositor_ver = @min(ver, 6);
        compositor = bind(gname, iface, compositor_ver, .compositor);
    } else if (eql(u8, iface, "wl_shm") and shm == 0) {
        shm = bind(gname, iface, 1, .shm);
    } else if (eql(u8, iface, "zwlr_layer_shell_v1") and layer_shell == 0) {
        layer_shell = bind(gname, iface, @min(ver, 3), .layer_shell);
    } else if (eql(u8, iface, "wl_seat") and seat == 0) {
        seat = bind(gname, iface, @min(ver, 5), .seat);
    } else if (eql(u8, iface, "wp_viewporter") and viewporter == 0) {
        viewporter = bind(gname, iface, 1, .viewporter);
    } else if (eql(u8, iface, "wp_single_pixel_buffer_manager_v1") and spb == 0) {
        spb = bind(gname, iface, 1, .spb);
    } else if (eql(u8, iface, "wl_data_device_manager") and ddm == 0) {
        ddm = bind(gname, iface, @min(ver, 3), .ddm);
    } else if (eql(u8, iface, "wp_cursor_shape_manager_v1") and cursor_mgr == 0) {
        cursor_mgr = bind(gname, iface, 1, .cursor_mgr);
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
            const gname = a.uint();
            const iface = a.string();
            const ver = a.uint();
            onGlobal(gname, iface, ver);
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
    conn.send(layer_shell, 0, .{ card.layer, card.surface, @as(u32, 0), @as(u32, 3), wl.str(name) });
    conn.send(card.layer, 0, .{ app.width, app.height }); // set_size
    conn.send(card.layer, 1, .{@as(u32, 0)}); // без якорей — по центру
    conn.send(card.layer, 4, .{@as(u32, 1)}); // клавиатура: exclusive
    conn.send(card.surface, 6, .{});
}

fn setupBackdrop() void {
    if (viewporter == 0) return; // без масштабирования буфера затемнение не делаем
    back.surface = create(.surface, 1);
    conn.send(compositor, 0, .{back.surface});
    back.layer = create(.layer_surface, 1);
    var ns_buf: [48]u8 = undefined;
    const ns = std.fmt.bufPrint(&ns_buf, "{s}-backdrop", .{name}) catch "zmenu-backdrop";
    conn.send(layer_shell, 0, .{ back.layer, back.surface, @as(u32, 0), @as(u32, 3), wl.str(ns) });
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
        const fd = sys.memfd("zmenu-backdrop") catch return;
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
    const fd = sys.memfd("zmenu") catch return false;
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
    app.layout();
    var cv = draw.Canvas{ .px = pixels(k), .w = @intCast(card.pw), .h = @intCast(card.ph) };
    S = @floatFromInt(card.scale);
    cv.clear(0);
    rrect(&cv, 0, 0, W(), H(), cfg.menu_radius, theme.t.menu_background);
    outline(&cv, 0.5, 0.5, W() - 1, H() - 1, cfg.menu_radius, theme.t.menu_border, 1);
    app.paint(&cv);
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

// ================================================================= виджеты

pub fn add(id: anytype, idx: usize, kind: Kind, x: f32, y: f32, w: f32, h: f32) void {
    if (nwid == widgets.len) return;
    widgets[nwid] = .{ .id = @intFromEnum(id), .idx = @intCast(idx), .kind = kind, .x = x, .y = y, .w = w, .h = h };
    nwid += 1;
}

pub fn isFocus(w: Widget) bool {
    return focus.id == w.id and focus.idx == w.idx;
}

pub fn isHover(w: Widget) bool {
    return hover.id == w.id and hover.idx == w.idx;
}

fn focusable(w: Widget) bool {
    return w.kind == .button or w.kind == .field or w.kind == .select;
}

/// После смены экрана: сбросить фокус и поставить его на первое поле (или первую кнопку).
pub fn resetFocus(prefer_button: bool) void {
    focus = .{};
    hover = .{};
    app.layout();
    for (widgets[0..nwid]) |w| {
        if (w.kind == .field or (prefer_button and w.kind == .button)) {
            focus = .{ .id = w.id, .idx = w.idx };
            if (w.kind == .field) {
                if (fieldOf(w.idx)) |f| f.caret = f.len;
            }
            break;
        }
    }
    redraw();
    updateHover();
}

fn fieldOf(idx: u16) ?*Field {
    return if (app.field) |f| f(idx) else null;
}

/// Навигация по списку строк (↑/↓, колёсико).
pub const List = struct {
    n: usize = 0,
    sel: usize = 0,
    scroll: usize = 0,
    visible: usize = 1,

    pub fn setCount(l: *List, n: usize) void {
        l.n = n;
        if (l.sel >= n) l.sel = if (n > 0) n - 1 else 0;
        if (l.scroll + l.visible > n) l.scroll = if (n > l.visible) n - l.visible else 0;
    }
    pub fn move(l: *List, d: i32) void {
        if (l.n == 0) return;
        kbd_nav = true;
        const n: i32 = @intCast(l.n);
        l.sel = @intCast(std.math.clamp(@as(i32, @intCast(l.sel)) + d, 0, n - 1));
        if (l.sel < l.scroll) l.scroll = l.sel;
        if (l.sel >= l.scroll + l.visible) l.scroll = l.sel + 1 - l.visible;
        redraw();
    }
    pub fn scrollBy(l: *List, d: i32) void {
        if (l.n <= l.visible) return;
        const max: i32 = @intCast(l.n - l.visible);
        l.scroll = @intCast(std.math.clamp(@as(i32, @intCast(l.scroll)) + d, 0, max));
        redraw();
        updateHover();
    }
    /// Подсвечивать ли строку i (мышь или выбор стрелками).
    pub fn lit(l: *const List, w: Widget) bool {
        if (kbd_nav) return w.idx == l.sel;
        return isHover(w);
    }
};

// ================================================================= указатель

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
                redraw();
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
            if (axis == 0 and ptr_on_card) {
                const f = app.scroll orelse return;
                scroll_acc += v;
                while (scroll_acc >= 15) : (scroll_acc -= 15) f(1);
                while (scroll_acc <= -15) : (scroll_acc += 15) f(-1);
            }
        },
        else => {},
    }
}

fn hitAt(x: f32, y: f32) ?Widget {
    app.layout();
    var i = nwid;
    while (i > 0) { // последние добавленные — сверху (кнопка «⋯» поверх строки)
        i -= 1;
        const w = widgets[i];
        if (x >= w.x and x < w.x + w.w and y >= w.y and y < w.y + w.h) return w;
    }
    return null;
}

fn setHover(r: Ref) void {
    if (hover.id != r.id or hover.idx != r.idx) {
        hover = r;
        redraw();
    }
}

fn updateHover() void {
    if (!ptr_on_card) return setCursor(1);
    if (hitAt(ptr_x, ptr_y)) |w| {
        setHover(.{ .id = w.id, .idx = w.idx });
        setCursor(if (w.kind == .field) 9 else 4); // text / pointer
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
    if (w.kind == .field) {
        if (fieldOf(w.idx)) |f| f.caret = f.len; // курсор в конец поля
    } else if (w.kind == .select) {
        if (app.cycle) |f| f(w.idx, right);
    } else {
        app.activate(w, right);
    }
    redraw();
}

// ================================================================= клавиатура

pub const K_ESC = 1;
pub const K_BACKSPACE = 14;
pub const K_TAB = 15;
pub const K_ENTER = 28;
pub const K_KPENTER = 96;
pub const K_HOME = 102;
pub const K_UP = 103;
pub const K_PGUP = 104;
pub const K_LEFT = 105;
pub const K_RIGHT = 106;
pub const K_END = 107;
pub const K_DOWN = 108;
pub const K_PGDN = 109;
pub const K_DELETE = 111;
pub const K_SPACE = 57;
pub const K_V = 47;
pub const K_U = 22;

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

fn repeatable(key: u32) bool {
    return switch (key) {
        K_ESC, K_TAB, K_ENTER, K_KPENTER, 29, 97, 42, 54, 56, 100, 125, 126, 58 => false,
        else => true,
    };
}

fn keyPress(key: u32) void {
    const shift = mods & 1 != 0;
    const ctrl = mods & 4 != 0;
    redraw();
    app.layout();
    const ch = km.char(key, group, shift, mods & 2 != 0);
    if (app.key) |f| {
        if (f(.{ .code = key, .ch = ch, .shift = shift, .ctrl = ctrl })) return;
    }
    switch (key) {
        K_ESC => return app.back(),
        K_TAB => return moveFocus(if (shift) -1 else 1),
        K_ENTER, K_KPENTER => return enter(),
        K_UP => return moveFocus(-1),
        K_DOWN => return moveFocus(1),
        else => {},
    }
    const fw = focused();
    if (fw != null and fw.?.kind == .field) {
        const f = fieldOf(focus.idx) orelse return;
        switch (key) {
            K_BACKSPACE => return backspace(f),
            K_DELETE => return delete(f),
            K_LEFT => f.caret = prevCp(f, f.caret),
            K_RIGHT => f.caret = nextCp(f, f.caret),
            K_HOME => f.caret = 0,
            K_END => f.caret = f.len,
            else => {
                if (ctrl and key == K_V) return paste(f);
                if (ctrl and key == K_U) return f.clear();
                if (ctrl) return;
                if (ch >= 0x20 and ch != 0x7f) insertCp(f, @intCast(ch));
            },
        }
        return;
    }
    if (fw != null and fw.?.kind == .select and (key == K_LEFT or key == K_RIGHT or key == K_SPACE)) {
        if (app.cycle) |f| f(focus.idx, key == K_LEFT);
        return;
    }
    if (key == K_SPACE) enter();
}

fn focused() ?Widget {
    for (widgets[0..nwid]) |w| {
        if (isFocus(w)) return w;
    }
    return null;
}

pub fn moveFocus(d: i32) void {
    var list: [64]Ref = undefined;
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
        if (focus.id == r.id and focus.idx == r.idx) cur = i;
    }
    const ni: usize = if (cur) |c|
        @intCast(@mod(@as(i32, @intCast(c)) + d, @as(i32, @intCast(n))))
    else if (d > 0) 0 else n - 1;
    focus = list[ni];
    if (focused()) |w| {
        if (w.kind == .field) {
            if (fieldOf(w.idx)) |f| f.caret = f.len;
        }
    }
    redraw();
}

fn enter() void {
    if (focused()) |w| {
        switch (w.kind) {
            .select => if (app.cycle) |f| return f(w.idx, false),
            .field => {},
            else => return app.activate(w, false),
        }
    }
    if (app.submit) |f| f();
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
    sys.secureZero(f.buf[f.len..@min(f.buf.len, f.len + (b - a))]);
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
    sys.secureZero(&buf);
}

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

// ================================================================= сообщение об ошибке

var msg_buf: [200]u8 = undefined;
var msg_len: usize = 0;

pub fn setMsg(s: []const u8) void {
    msg_len = @min(s.len, msg_buf.len);
    @memcpy(msg_buf[0..msg_len], s[0..msg_len]);
    redraw();
}

pub fn clearMsg() void {
    msg_len = 0;
}

pub fn msg() []const u8 {
    return msg_buf[0..msg_len];
}

pub fn paintMsg(cv: *draw.Canvas, y: f32) void {
    if (msg_len == 0) return;
    _ = wrap(cv, msg(), PAD, y, 13, theme.t.menu_error, W() - 2 * PAD, 17, false);
}

/// Текст с переносом по словам. Возвращает базовую линию после последней строки.
pub fn wrap(cv: *draw.Canvas, s: []const u8, x: f32, y: f32, size: f32, c: u32, max_w: f32, line_h: f32, center: bool) f32 {
    var rest = std.mem.trim(u8, s, " ");
    var base = y;
    var lines: u32 = 0;
    while (rest.len > 0 and lines < 6) : (lines += 1) {
        // самый длинный префикс по границе слова, который влезает
        var cut: usize = rest.len;
        if (textW(rest, size) > max_w) {
            cut = 0;
            var i: usize = 0;
            while (i < rest.len) : (i += 1) {
                if (rest[i] == ' ') {
                    if (textW(rest[0..i], size) > max_w) break;
                    cut = i;
                }
            }
            if (cut == 0) cut = rest.len; // одно длинное слово — обрежется при выводе
        }
        const line = rest[0..cut];
        if (center) centered(cv, line, x + max_w / 2, base, size, c) else _ = text(cv, line, x, base, size, c, x + max_w);
        rest = std.mem.trimStart(u8, rest[cut..], " ");
        base += line_h;
    }
    return base;
}

// ================================================================= рисование

pub const PAD: f32 = 18;
pub var S: f32 = 1;

pub fn W() f32 {
    return @floatFromInt(app.width);
}
pub fn H() f32 {
    return @floatFromInt(app.height);
}

fn px(v: f32) f32 {
    return v * S;
}

fn fpx(size: f32) u16 {
    return @intFromFloat(@round(size * S));
}

pub fn rrect(cv: *draw.Canvas, x: f32, y: f32, w: f32, h: f32, r: f32, c: u32) void {
    cv.fillRoundRect(px(x), px(y), px(w), px(h), px(r), c);
}

pub fn outline(cv: *draw.Canvas, x: f32, y: f32, w: f32, h: f32, r: f32, c: u32, width: f32) void {
    const b = [_]draw.Prim{.{ .box = .{ .x = px(x), .y = px(y), .w = px(w), .h = px(h), .r = px(r) } }};
    cv.prims(&b, 0, 0, 1, px(width), c);
}

/// Текст: (x, baseline) в логических пикселях. Возвращает X после текста.
pub fn text(cv: *draw.Canvas, s: []const u8, x: f32, baseline: f32, size: f32, c: u32, max_x: f32) f32 {
    return ttf.drawText(cv, s, @round(px(x)), px(baseline), fpx(size), c, px(max_x)) / S;
}

/// Текст с подсветкой: байты, отмеченные в hl (по первому байту символа), — цветом hc.
pub fn textMarked(cv: *draw.Canvas, s: []const u8, x: f32, baseline: f32, size: f32, c: u32, hc: u32, max_x: f32, hl: *const [4]u64) f32 {
    var pen = @round(px(x));
    var i: usize = 0;
    while (i < s.len) {
        const on = isMarked(hl, i);
        var j = i + 1;
        while (j < s.len and (s[j] & 0xc0 == 0x80 or isMarked(hl, j) == on)) j += 1;
        pen = ttf.drawText(cv, s[i..j], pen, px(baseline), fpx(size), if (on) hc else c, px(max_x));
        i = j;
    }
    return pen / S;
}

fn isMarked(hl: *const [4]u64, i: usize) bool {
    return i < 256 and hl[i / 64] & (@as(u64, 1) << @intCast(i % 64)) != 0;
}

pub fn textW(s: []const u8, size: f32) f32 {
    return ttf.width(s, fpx(size)) / S;
}

/// Базовая линия, при которой текст размера size по центру полосы [y, y+h].
pub fn mid(y: f32, h: f32, size: f32) f32 {
    return y + h / 2 + size * 0.36;
}

pub fn centered(cv: *draw.Canvas, s: []const u8, cx: f32, baseline: f32, size: f32, c: u32) void {
    _ = text(cv, s, cx - textW(s, size) / 2, baseline, size, c, W());
}

/// Иконка из примитивов в сетке 16×16, размером size логических пикселей.
pub fn icon(cv: *draw.Canvas, prims: []const draw.Prim, x: f32, y: f32, size: f32, stroke: f32, c: u32) void {
    cv.prims(prims, @round(px(x)), @round(px(y)), px(size / 16), px(stroke), c);
}

pub const ic_back = [_]draw.Prim{
    .{ .seg = .{ .x0 = 10, .y0 = 3, .x1 = 5, .y1 = 8 } },
    .{ .seg = .{ .x0 = 5, .y0 = 8, .x1 = 10, .y1 = 13 } },
};
pub const ic_fwd = [_]draw.Prim{
    .{ .seg = .{ .x0 = 6, .y0 = 3, .x1 = 11, .y1 = 8 } },
    .{ .seg = .{ .x0 = 11, .y0 = 8, .x1 = 6, .y1 = 13 } },
};
pub const ic_check = [_]draw.Prim{
    .{ .seg = .{ .x0 = 3, .y0 = 8.5, .x1 = 6.5, .y1 = 12 } },
    .{ .seg = .{ .x0 = 6.5, .y0 = 12, .x1 = 13, .y1 = 4.5 } },
};
pub const ic_lock = [_]draw.Prim{
    .{ .fbox = .{ .x = 3.5, .y = 7.5, .w = 9, .h = 7, .r = 1.6 } },
    .{ .arc = .{ .cx = 8, .cy = 7.5, .r = 2.9, .a0 = 180, .a1 = 360 } },
};
pub const ic_more = [_]draw.Prim{
    .{ .dot = .{ .cx = 3.5, .cy = 8, .r = 1.4 } },
    .{ .dot = .{ .cx = 8, .cy = 8, .r = 1.4 } },
    .{ .dot = .{ .cx = 12.5, .cy = 8, .r = 1.4 } },
};
pub const ic_eye = [_]draw.Prim{
    .{ .arc = .{ .cx = 8, .cy = 14, .r = 8.5, .a0 = 218, .a1 = 322 } },
    .{ .arc = .{ .cx = 8, .cy = 2, .r = 8.5, .a0 = 38, .a1 = 142 } },
    .{ .dot = .{ .cx = 8, .cy = 8, .r = 2.1 } },
};
pub const ic_slash = [_]draw.Prim{.{ .seg = .{ .x0 = 3, .y0 = 13, .x1 = 13, .y1 = 3 } }};
pub const ic_chevron = [_]draw.Prim{
    .{ .seg = .{ .x0 = 4.5, .y0 = 6.5, .x1 = 8, .y1 = 10 } },
    .{ .seg = .{ .x0 = 8, .y0 = 10, .x1 = 11.5, .y1 = 6.5 } },
};
pub const ic_plus = [_]draw.Prim{
    .{ .seg = .{ .x0 = 8, .y0 = 3, .x1 = 8, .y1 = 13 } },
    .{ .seg = .{ .x0 = 3, .y0 = 8, .x1 = 13, .y1 = 8 } },
};

/// Заголовок экрана: (стрелка «назад») название и подзаголовок.
pub fn header(cv: *draw.Canvas, title: []const u8, sub: []const u8, with_back: bool) void {
    const t = &theme.t;
    const x: f32 = if (with_back) PAD + 26 else PAD;
    _ = text(cv, title, x, if (sub.len > 0) 37 else 38, if (with_back) 17 else 19, t.menu_text, W() - PAD - 50);
    if (sub.len > 0) _ = text(cv, sub, x, 56, 12, t.menu_muted, W() - PAD);
}

/// Стрелка «назад» в заголовке (виджет добавляет само меню).
pub fn paintBack(cv: *draw.Canvas, w: Widget) void {
    if (isHover(w)) rrect(cv, w.x, w.y, w.w, w.h, 8, theme.t.menu_hover);
    icon(cv, &ic_back, w.x + 7, w.y + 7, 16, 2, theme.t.menu_text);
}

pub const BtnKind = enum { primary, secondary, danger };

pub fn button(cv: *draw.Canvas, w: Widget, label: []const u8, kind: BtnKind) void {
    const t = &theme.t;
    const bg = if (kind == .primary) t.menu_accent else t.menu_field;
    rrect(cv, w.x, w.y, w.w, w.h, 10, bg);
    if (isHover(w)) rrect(cv, w.x, w.y, w.w, w.h, 10, t.menu_hover);
    if (isFocus(w)) outline(cv, w.x - 2, w.y - 2, w.w + 4, w.h + 4, 12, t.menu_accent, 1.5);
    const fg = switch (kind) {
        .primary => t.menu_accent_text,
        .secondary => t.menu_text,
        .danger => t.menu_error,
    };
    centered(cv, label, w.x + w.w / 2, mid(w.y, w.h, 14), 14, fg);
}

pub fn toggle(cv: *draw.Canvas, w: Widget, on: bool) void {
    const t = &theme.t;
    rrect(cv, w.x, w.y, w.w, w.h, w.h / 2, if (on) t.menu_accent else t.menu_field);
    const kx = if (on) w.x + w.w - w.h + 3 else w.x + 3;
    rrect(cv, kx, w.y + 3, w.h - 6, w.h - 6, (w.h - 6) / 2, if (on) t.menu_accent_text else t.menu_muted);
}

pub fn select(cv: *draw.Canvas, w: Widget, label: []const u8) void {
    const t = &theme.t;
    rrect(cv, w.x, w.y, w.w, w.h, 8, t.menu_field);
    if (isHover(w)) rrect(cv, w.x, w.y, w.w, w.h, 8, t.menu_hover);
    if (isFocus(w)) outline(cv, w.x, w.y, w.w, w.h, 8, t.menu_accent, 1.5);
    _ = text(cv, label, w.x + 10, mid(w.y, w.h, 13), 13, t.menu_text, w.x + w.w - 26);
    icon(cv, &ic_chevron, w.x + w.w - 24, w.y + (w.h - 16) / 2, 16, 1.6, t.menu_muted);
}

/// Поле ввода: плейсхолдер, точки вместо секрета, курсор, прокрутка к курсору.
/// right_pad — место справа под кнопку (например, «показать пароль»).
pub fn field(cv: *draw.Canvas, w: Widget, f: *const Field, placeholder: []const u8, hidden: bool, right_pad: f32) void {
    const t = &theme.t;
    const foc = isFocus(w);
    rrect(cv, w.x, w.y, w.w, w.h, 8, t.menu_field);
    if (foc) outline(cv, w.x, w.y, w.w, w.h, 8, t.menu_accent, 1.5);
    const size: f32 = 13;
    const x0 = w.x + 10;
    const avail = w.w - 20 - right_pad;
    if (f.len == 0) {
        if (placeholder.len > 0) _ = text(cv, placeholder, x0, mid(w.y, w.h, size), size, t.menu_muted, x0 + avail);
        if (foc) rrect(cv, x0, w.y + 8, 1.5, w.h - 16, 0.5, t.menu_accent);
        return;
    }
    // что показываем: текст или точки
    var shown: [768]u8 = undefined;
    var slen: usize = 0;
    var caret_s: usize = 0;
    if (hidden) {
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
    if (hidden) sys.secureZero(&shown);
}

/// Экран «готово»: кольцо с галочкой и подпись.
pub fn paintDone(cv: *draw.Canvas, label: []const u8) void {
    const t = &theme.t;
    const r: f32 = 26;
    const ring = [_]draw.Prim{.{ .ring = .{ .cx = 8, .cy = 8, .r = 7.4 } }};
    icon(cv, &ring, W() / 2 - r, H() / 2 - r - 24, 2 * r, 2.2, t.menu_accent);
    icon(cv, &ic_check, W() / 2 - 14, H() / 2 - 38, 28, 2.4, t.menu_accent);
    centered(cv, label, W() / 2, H() / 2 + 30, 16, t.menu_text);
}

/// Анимированное «Подключение...» (n — номер тика).
pub fn dots(base: []const u8, n: u32, buf: []u8) []const u8 {
    const b = base[0..@min(base.len, buf.len)]; // длинная подпись не выйдет за буфер
    const len = @min(b.len + n % 4, buf.len);
    @memcpy(buf[0..b.len], b);
    @memset(buf[b.len..len], '.');
    return buf[0..len];
}

/// Полоса прокрутки списка справа.
pub fn scrollbar(cv: *draw.Canvas, l: *const List, top: f32, row_h: f32) void {
    if (l.n <= l.visible) return;
    const track = @as(f32, @floatFromInt(l.visible)) * row_h;
    const h = track * @as(f32, @floatFromInt(l.visible)) / @as(f32, @floatFromInt(l.n));
    const y = top + (track - h) * @as(f32, @floatFromInt(l.scroll)) / @as(f32, @floatFromInt(l.n - l.visible));
    rrect(cv, W() - 6, y, 3, h, 1.5, theme.t.menu_border);
}
