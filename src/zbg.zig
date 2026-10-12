// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zbg — демон обоев для zpanel на чистом Zig (вместо swaybg).
//!
//! Рисует обои на каждом мониторе (слой background), поддерживает горячее подключение
//! мониторов, целый и дробный масштаб. Картинка декодируется своими декодерами JPEG/PNG,
//! вписывается фильтром высокого качества, после чего память отдаётся системе: в простое
//! zbg спит в ppoll и почти не занимает память — пиксели живут в буфере композитора.
//!
//! Управление — через сокет `zbg-<uid>` (только от того же пользователя):
//!   "set ИМЯ\n" — показать файл из папки обоев,  "get\n" — какое сейчас.
//! Выбор запоминается в ~/.cache/zpanel/wallpaper.

const std = @import("std");
const sys = @import("sys.zig");
const wl = @import("wl.zig");
const img = @import("img.zig");
const theme = @import("theme.zig");
const cfg = @import("config.zig");
const sandbox = @import("sandbox.zig");

const MAX_OUT = 8;

const Kind = enum(u8) { none, display, registry, callback, compositor, shm, pool, buffer, surface, layer_shell, layer_surface, output, viewporter, viewport, frac_mgr, frac };

const Out = struct {
    used: bool = false,
    gname: u32 = 0,
    output: u32 = 0,
    out_ver: u32 = 0,
    surface: u32 = 0,
    layer: u32 = 0,
    viewport: u32 = 0,
    frac: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    scale: u32 = 1, // целый масштаб
    scale120: u32 = 0, // дробный масштаб × 120 (0 — нет)
    configured: bool = false,
    dirty: bool = false,
    buffer: u32 = 0,

    fn pixelSize(o: *const Out) [2]u32 {
        if (o.scale120 > 0 and o.viewport != 0) {
            return .{ @max(1, (o.w * o.scale120 + 60) / 120), @max(1, (o.h * o.scale120 + 60) / 120) };
        }
        return .{ o.w * o.scale, o.h * o.scale };
    }
};

var conn: wl.Conn = .{};
var kinds: [wl.MAX_IDS]Kind = [_]Kind{.none} ** wl.MAX_IDS;
var owner: [wl.MAX_IDS]u8 = [_]u8{0} ** wl.MAX_IDS;
var outs: [MAX_OUT]Out = [_]Out{.{}} ** MAX_OUT;
var registry: u32 = 0;
var compositor: u32 = 0;
var compositor_ver: u32 = 0;
var shm: u32 = 0;
var layer_shell: u32 = 0;
var viewporter: u32 = 0;
var frac_mgr: u32 = 0;
var sync_done = false;
var ready = false;

var dir_buf: [512]u8 = undefined;
var dir: [:0]const u8 = "";
var cur_buf: [256]u8 = undefined;
var cur_len: usize = 0;
var state_fd: i32 = -1;
var listen_fd: i32 = -1;
var my_uid: u32 = 0;

/// Клиенты сокета управления (меню zwall держит связь, пока открыто).
const MAX_CLIENTS = 4;
const Client = struct {
    fd: i32 = -1,
    buf: [600]u8 = undefined,
    len: usize = 0,
};
var clients: [MAX_CLIENTS]Client = [_]Client{.{}} ** MAX_CLIENTS;

pub fn main() void {
    sys.initEnv();
    my_uid = @intCast(sys.getuid());
    if (my_uid == 0) {
        sys.log("запуск от root запрещён", .{});
        sys.exit(1);
    }
    var lock_buf: [48]u8 = undefined;
    const lock = std.fmt.bufPrint(&lock_buf, "zbg-{d}", .{my_uid}) catch "zbg";
    if (sys.connectAbstract(lock)) {
        sys.log("zbg уже запущен", .{});
        sys.exit(0);
    }
    listen_fd = sys.listenAbstract(lock) catch {
        sys.log("не удалось открыть сокет управления", .{});
        sys.exit(1);
    };
    dir = expandHome(&dir_buf, cfg.wallpaper_dir) orelse {
        sys.log("не задан $HOME", .{});
        sys.exit(1);
    };
    openState();
    theme.init();

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
    roundtrip();
    ready = true;
    for (&outs, 0..) |*o, i| {
        if (o.used) setup(@intCast(i));
    }

    if (cfg.sandbox) {
        const paths = [_][:0]const u8{ dir, theme.dir };
        sandbox.apply(&paths, &.{}, .{ .extra = &.{ .lseek, .accept4, .getsockopt } });
    }

    while (true) {
        renderDirty();
        conn.flush() catch fatal();
        var fds: [3 + MAX_CLIENTS]sys.PollFd = undefined;
        fds[0] = .{ .fd = conn.fd, .events = sys.POLLIN };
        fds[1] = .{ .fd = listen_fd, .events = sys.POLLIN };
        fds[2] = .{ .fd = theme.inotify_fd, .events = sys.POLLIN };
        for (clients, 0..) |c, i| fds[3 + i] = .{ .fd = c.fd, .events = sys.POLLIN };
        _ = sys.poll(&fds, -1) catch continue;
        if (fds[0].revents != 0) readWayland();
        if (fds[1].revents != 0) acceptClient();
        if (fds[2].revents != 0 and theme.inotify_fd >= 0) {
            if (theme.onInotify()) markAll(); // поменялся цвет рабочего стола
        }
        for (&clients, 0..) |*c, i| {
            if (fds[3 + i].revents != 0 and c.fd >= 0) readClient(c);
        }
    }
}

fn fatal() noreturn {
    sys.log("ошибка связи с композитором", .{});
    sys.exit(1);
}

/// "~/…" или "$HOME/…" → полный путь.
pub fn expandHome(buf: []u8, p: []const u8) ?[:0]const u8 {
    if (std.mem.startsWith(u8, p, "~/") or std.mem.startsWith(u8, p, "$HOME/")) {
        const home = sys.getenv("HOME") orelse return null;
        const rest = p[std.mem.indexOfScalar(u8, p, '/').?..];
        return sys.joinZ(buf, &.{ home, rest });
    }
    return sys.joinZ(buf, &.{p});
}

// ================================================================= состояние

fn openState() void {
    const home = sys.getenv("HOME") orelse return;
    var b: [512]u8 = undefined;
    sys.mkdir(sys.joinZ(&b, &.{ home, "/.cache" }));
    sys.mkdir(sys.joinZ(&b, &.{ home, "/.cache/zpanel" }));
    state_fd = sys.openCreate(sys.joinZ(&b, &.{ home, "/.cache/zpanel/wallpaper" })) catch -1;
    if (state_fd < 0) return;
    const n = sys.read(state_fd, &cur_buf) catch 0;
    const name = std.mem.trim(u8, cur_buf[0..n], " \n\r");
    if (validName(name)) {
        std.mem.copyForwards(u8, cur_buf[0..name.len], name);
        cur_len = name.len;
    }
}

fn saveState() void {
    if (state_fd < 0) return;
    _ = sys.lseek(state_fd, 0) catch return;
    _ = sys.write(state_fd, cur_buf[0..cur_len]) catch {};
    sys.ftruncate(state_fd, cur_len) catch {};
}

/// Только имя файла в папке обоев: без «/», не скрытый, без управляющих символов.
pub fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > 255 or n[0] == '.') return false;
    for (n) |c| {
        if (c == '/' or c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

// ================================================================= управление

fn acceptClient() void {
    const fd = sys.accept(listen_fd) orelse return;
    // только от того же пользователя
    if ((sys.peerUid(fd) orelse 0xffffffff) != my_uid) return sys.close(fd);
    for (&clients) |*c| {
        if (c.fd < 0) {
            c.* = .{ .fd = fd };
            return;
        }
    }
    sys.close(fd); // все места заняты
}

fn dropClient(c: *Client) void {
    sys.close(c.fd);
    c.fd = -1;
}

fn readClient(c: *Client) void {
    const n = sys.read(c.fd, c.buf[c.len..]) catch 0;
    if (n == 0) return dropClient(c);
    c.len += n;
    while (std.mem.indexOfScalar(u8, c.buf[0..c.len], '\n')) |nl| {
        const r = command(c.buf[0..nl]);
        sys.sendAll(c.fd, r) catch return dropClient(c);
        std.mem.copyForwards(u8, c.buf[0 .. c.len - nl - 1], c.buf[nl + 1 .. c.len]);
        c.len -= nl + 1;
    }
    if (c.len == c.buf.len) dropClient(c); // строка без конца — выгоняем
}

var reply_buf: [300]u8 = undefined;

fn command(line: []const u8) []const u8 {
    if (std.mem.eql(u8, line, "get")) {
        return sys.joinZ(&reply_buf, &.{ "cur ", cur_buf[0..cur_len], "\n" });
    }
    if (std.mem.startsWith(u8, line, "set ")) {
        const name = line[4..];
        if (!validName(name)) return "err неверное имя файла\n";
        // сначала раскодировать (под размер мониторов) и только потом менять обои:
        // битый файл не испортит текущие, а картинка декодируется один раз
        var pb: [800]u8 = undefined;
        const path = sys.joinZ(&pb, &.{ dir, "/", name });
        const need = needSize();
        var pic = img.load(path, @max(need[0], 64), @max(need[1], 64)) catch |e| return errText(e);
        defer pic.deinit();
        @memcpy(cur_buf[0..name.len], name);
        cur_len = name.len;
        saveState();
        for (&outs, 0..) |*o, i| {
            if (o.used and o.configured) paint(@intCast(i), &pic) else if (o.used) o.dirty = true;
        }
        conn.flush() catch fatal();
        return "ok\n";
    }
    return "err неизвестная команда\n";
}

fn errText(e: img.Error) []const u8 {
    return switch (e) {
        error.Unsupported => "err формат не поддерживается (нужен JPEG или PNG)\n",
        error.TooLarge => "err слишком большое изображение\n",
        error.NoMem => "err не хватило памяти\n",
        error.Io => "err файл не открывается\n",
        error.Invalid => "err файл повреждён\n",
    };
}

// ================================================================= Wayland

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
    conn.send(1, 0, .{cb});
    conn.flush() catch fatal();
    sync_done = false;
    while (!sync_done) readWayland();
}

fn readWayland() void {
    const alive = conn.fill() catch fatal();
    if (!alive) sys.exit(0);
    while (conn.next()) |ev| dispatch(ev);
}

fn bind(gname: u32, iface: []const u8, ver: u32, kind: Kind, own: u8) u32 {
    const id = create(kind, own);
    conn.send(registry, 0, .{ gname, wl.str(iface), ver, id });
    return id;
}

fn dispatch(ev: wl.Event) void {
    if (ev.obj >= wl.MAX_IDS) return;
    var a = ev.args;
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
        .registry => switch (ev.op) {
            0 => {
                const gname = a.uint();
                const iface = a.string();
                const ver = a.uint();
                onGlobal(gname, iface, ver);
            },
            1 => {
                const gname = a.uint();
                for (&outs, 0..) |*o, i| {
                    if (o.used and o.gname == gname) destroy(@intCast(i));
                }
            },
            else => {},
        },
        .callback => if (ev.op == 0) {
            sync_done = true;
        },
        .output => if (ev.op == 3) { // scale
            const s: u32 = @intCast(std.math.clamp(a.int(), 1, 4));
            if (compositor_ver < 6) setScale(own, s);
        },
        .surface => if (ev.op == 2) setScale(own, @intCast(std.math.clamp(a.int(), 1, 4))), // preferred_buffer_scale
        .frac => if (ev.op == 0) { // preferred_scale (× 120)
            const s = std.math.clamp(a.uint(), 60, 480);
            if (s != outs[own].scale120) {
                outs[own].scale120 = s;
                outs[own].dirty = true;
            }
        },
        .layer_surface => switch (ev.op) {
            0 => {
                const serial = a.uint();
                const w = a.uint();
                const h = a.uint();
                const o = &outs[own];
                conn.send(o.layer, 6, .{serial});
                if (w > 0 and h > 0 and (w != o.w or h != o.h or !o.configured)) o.dirty = true;
                o.w = @min(@max(w, 1), 16384);
                o.h = @min(@max(h, 1), 16384);
                o.configured = true;
            },
            1 => destroy(own),
            else => {},
        },
        .buffer => if (ev.op == 0) { // release
            // После release буфер можно уничтожить — картинка на экране останется
            // (wl_surface.attach). Композитор с GPU-рендером (wlroots) может отпустить
            // shm-буфер сразу после загрузки в текстуру: раньше текущий буфер здесь
            // не трогали, и при следующей смене обоев он уже не получал release —
            // смена оставляла в композиторе полноэкранный буфер. Теперь память
            // обоев возвращается системе, как только композитору она не нужна.
            conn.send(ev.obj, 0, .{});
            kinds[ev.obj] = .none;
            if (outs[own].buffer == ev.obj) outs[own].buffer = 0;
        },
        else => {},
    }
}

fn setScale(own: u8, s: u32) void {
    if (s != outs[own].scale) {
        outs[own].scale = s;
        outs[own].dirty = true;
    }
}

fn onGlobal(gname: u32, iface: []const u8, ver: u32) void {
    const eql = std.mem.eql;
    if (eql(u8, iface, "wl_compositor") and compositor == 0) {
        compositor_ver = @min(ver, 6);
        compositor = bind(gname, iface, compositor_ver, .compositor, 0);
    } else if (eql(u8, iface, "wl_shm") and shm == 0) {
        shm = bind(gname, iface, 1, .shm, 0);
    } else if (eql(u8, iface, "zwlr_layer_shell_v1") and layer_shell == 0) {
        layer_shell = bind(gname, iface, @min(ver, 3), .layer_shell, 0);
    } else if (eql(u8, iface, "wp_viewporter") and viewporter == 0) {
        viewporter = bind(gname, iface, 1, .viewporter, 0);
    } else if (eql(u8, iface, "wp_fractional_scale_manager_v1") and frac_mgr == 0) {
        frac_mgr = bind(gname, iface, 1, .frac_mgr, 0);
    } else if (eql(u8, iface, "wl_output")) {
        for (&outs, 0..) |*o, i| {
            if (o.used) continue;
            const idx: u8 = @intCast(i);
            o.* = .{ .used = true, .gname = gname, .out_ver = @min(ver, 4) };
            o.output = bind(gname, iface, o.out_ver, .output, idx);
            if (ready) setup(idx);
            break;
        }
    }
}

fn setup(i: u8) void {
    const o = &outs[i];
    o.surface = create(.surface, i);
    conn.send(compositor, 0, .{o.surface});
    if (viewporter != 0) {
        o.viewport = create(.viewport, i);
        conn.send(viewporter, 1, .{ o.viewport, o.surface });
        if (frac_mgr != 0) {
            o.frac = create(.frac, i);
            conn.send(frac_mgr, 1, .{ o.frac, o.surface });
        }
    }
    o.layer = create(.layer_surface, i);
    // слой background (0), пространство имён "wallpaper"
    conn.send(layer_shell, 0, .{ o.layer, o.surface, o.output, @as(u32, 0), wl.str("wallpaper") });
    conn.send(o.layer, 0, .{ @as(u32, 0), @as(u32, 0) });
    conn.send(o.layer, 1, .{@as(u32, 1 | 2 | 4 | 8)});
    conn.send(o.layer, 2, .{@as(i32, -1)});
    conn.send(o.surface, 6, .{});
}

fn destroy(i: u8) void {
    const o = &outs[i];
    if (!o.used) return;
    if (o.buffer != 0) conn.send(o.buffer, 0, .{});
    forget(&o.buffer);
    if (o.frac != 0) conn.send(o.frac, 0, .{});
    forget(&o.frac);
    if (o.viewport != 0) conn.send(o.viewport, 0, .{});
    forget(&o.viewport);
    if (o.layer != 0) conn.send(o.layer, 7, .{});
    forget(&o.layer);
    if (o.surface != 0) conn.send(o.surface, 0, .{});
    forget(&o.surface);
    if (o.output != 0 and o.out_ver >= 3) conn.send(o.output, 0, .{});
    forget(&o.output);
    o.* = .{};
}

fn markAll() void {
    for (&outs) |*o| {
        if (o.used) o.dirty = true;
    }
}

// ================================================================= рисование

/// Наибольший размер в пикселях среди настроенных мониторов.
fn needSize() [2]u32 {
    var w: u32 = 0;
    var h: u32 = 0;
    for (&outs) |*o| {
        if (!o.used or !o.configured) continue;
        const ps = o.pixelSize();
        w = @max(w, ps[0]);
        h = @max(h, ps[1]);
    }
    return .{ w, h };
}

fn renderDirty() void {
    var need_w: u32 = 0;
    var need_h: u32 = 0;
    var any = false;
    for (&outs) |*o| {
        if (!o.used or !o.configured or !o.dirty) continue;
        const ps = o.pixelSize();
        need_w = @max(need_w, ps[0]);
        need_h = @max(need_h, ps[1]);
        any = true;
    }
    if (!any) return;
    // одна раскодированная картинка на все мониторы, потом память сразу освобождается
    var pic: ?img.Image = null;
    if (cur_len > 0) {
        var pb: [800]u8 = undefined;
        const path = sys.joinZ(&pb, &.{ dir, "/", cur_buf[0..cur_len] });
        pic = img.load(path, need_w, need_h) catch |e| blk: {
            sys.log("обои {s}: {s}", .{ cur_buf[0..cur_len], @errorName(e) });
            break :blk null;
        };
    }
    defer if (pic) |*p| p.deinit();
    for (&outs, 0..) |*o, i| {
        if (o.used and o.configured and o.dirty) paint(@intCast(i), if (pic) |*p| p else null);
    }
}

fn paint(i: u8, pic: ?*const img.Image) void {
    const o = &outs[i];
    o.dirty = false;
    const ps = o.pixelSize();
    const pw = ps[0];
    const ph = ps[1];
    const size: usize = @as(usize, pw) * ph * 4;
    const fd = sys.memfd("zbg") catch return;
    defer sys.close(fd);
    sys.ftruncate(fd, size) catch return;
    const mem = sys.mmap(size, fd) catch return;
    const px: [*]u32 = @ptrCast(@alignCast(mem));
    const bg = theme.t.desktop & 0xffffff;
    if (pic) |p| {
        img.render(p, px[0 .. size / 4], pw, ph, if (cfg.wallpaper_mode == .fill) .fill else .fit, bg) catch @memset(px[0 .. size / 4], 0xff000000 | bg);
    } else @memset(px[0 .. size / 4], 0xff000000 | bg);
    // пиксели уже в разделяемой памяти — своё отображение сразу убираем
    sys.munmap(mem, size);

    const pool = create(.pool, i);
    conn.send(shm, 0, .{ pool, wl.Fd{ .fd = fd }, @as(i32, @intCast(size)) });
    conn.flush() catch fatal();
    const buf = create(.buffer, i);
    conn.send(pool, 0, .{ buf, @as(i32, 0), @as(i32, @intCast(pw)), @as(i32, @intCast(ph)), @as(i32, @intCast(pw * 4)), @as(u32, 1) }); // XRGB8888
    conn.send(pool, 1, .{});
    kinds[pool] = .none;

    conn.send(o.surface, 1, .{ buf, @as(i32, 0), @as(i32, 0) });
    if (o.scale120 > 0 and o.viewport != 0) {
        if (compositor_ver >= 3) conn.send(o.surface, 8, .{@as(i32, 1)});
        conn.send(o.viewport, 2, .{ @as(i32, @intCast(o.w)), @as(i32, @intCast(o.h)) }); // set_destination
    } else if (compositor_ver >= 3) {
        conn.send(o.surface, 8, .{@as(i32, @intCast(o.scale))});
    }
    if (compositor_ver >= 4) {
        conn.send(o.surface, 9, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(pw)), @as(i32, @intCast(ph)) });
    } else {
        conn.send(o.surface, 2, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(o.w)), @as(i32, @intCast(o.h)) });
    }
    conn.send(o.surface, 6, .{});
    // и прошлый, и этот буфер уничтожаются, когда композитор их отпустит (событие release)
    o.buffer = buf;
}
