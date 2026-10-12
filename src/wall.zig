// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zwall — выбор обоев для zpanel на чистом Zig.
//!
//! Сетка превью из папки обоев, клик — обои сразу меняются (меню остаётся открытым,
//! можно перебрать несколько). Превью делаются своими декодерами и кэшируются в
//! ~/.cache/zpanel/thumbs, поэтому повторное открытие мгновенное. Показ обоев — у zbg.
//! `zwall random` — случайные обои без окна.

const std = @import("std");
const sys = @import("sys.zig");
const draw = @import("draw.zig");
const img = @import("img.zig");
const theme = @import("theme.zig");
const cfg = @import("config.zig");
const ui = @import("ui.zig");
const zbg = @import("zbg.zig");

const PAD = ui.PAD;
const COLS = 4;
const ROWS = 3;
const TILE_W: f32 = 152;
const TILE_H: f32 = 95;
const GAP: f32 = 12;
const GRID_Y: f32 = 66;
// превью хранятся в двойном размере — чётко и на HiDPI
const TW: u32 = 304;
const TH: u32 = 190;
const MAX_FILES = 512;

const State = enum(u8) { pending, ok, failed };

var names_buf: [96 * 1024]u8 = undefined;
var names_len: usize = 0;
var names: [MAX_FILES][]const u8 = undefined;
var sizes: [MAX_FILES]usize = undefined;
var thumbs: [MAX_FILES][]u8 = undefined;
var states: [MAX_FILES]State = undefined;
var nfiles: usize = 0;

var dir_buf: [512]u8 = undefined;
var dir: [:0]const u8 = "";
var cache_buf: [512]u8 = undefined;
var cache: [:0]const u8 = "";
var cache_ok = false;

var zbg_fd: i32 = -1;
var cur: ?usize = null;
var sel: usize = 0;
var scroll: usize = 0; // первая видимая строка
// обои меняются асинхронно: меню не замирает, пока zbg декодирует картинку
var pending: ?usize = null; // отправлено zbg, ждём ответа
var queued: ?usize = null; // выбрали ещё, пока ждали, — отправим следом
var in_buf: [320]u8 = undefined;
var in_len: usize = 0;

const Wid = enum(u8) { none, tile, random };

// ================================================================= запуск

pub fn main() void {
    sys.initEnv();
    if (sys.argIs(1, "random")) return randomCli();
    ui.begin("zwall");
    prepare();
    if (zbg_fd < 0) ui.setMsg(NO_ZBG);
    const W = 2 * PAD + COLS * TILE_W + (COLS - 1) * GAP;
    const H = GRID_Y + ROWS * TILE_H + (ROWS - 1) * GAP + 54;
    const write: []const [:0]const u8 = if (cache_ok) &.{cache} else &.{};
    ui.run(.{
        .width = @intFromFloat(W),
        .height = @intFromFloat(H),
        .layout = layout,
        .paint = paint,
        .activate = activate,
        .back = ui.quit,
        .key = onKey,
        .scroll = onScroll,
        .tick = onTick,
        .start = start,
        .extra_fd = zbgFd,
        .on_extra = onZbg,
    }, .{ .read = &.{dir}, .write = write }, .{ .extra = &.{ .lseek, .getrandom }, .write_files = true });
}

/// До песочницы: папки, список файлов, связь с zbg.
fn prepare() void {
    dir = zbg.expandHome(&dir_buf, cfg.wallpaper_dir) orelse "";
    if (sys.getenv("HOME")) |home| {
        var b: [512]u8 = undefined;
        sys.mkdir(sys.joinZ(&b, &.{ home, "/.cache" }));
        sys.mkdir(sys.joinZ(&b, &.{ home, "/.cache/zpanel" }));
        cache = sys.joinZ(&cache_buf, &.{ home, "/.cache/zpanel/thumbs" });
        sys.mkdir(cache);
        cache_ok = sys.exists(cache);
    }
    listFiles();
    pruneCache();
    connectZbg();
    if (zbg_fd >= 0) {
        if (ask("get\n")) |r| {
            if (std.mem.startsWith(u8, r, "cur ")) {
                for (names[0..nfiles], 0..) |n, i| {
                    if (std.mem.eql(u8, n, r[4..])) cur = i;
                }
            }
        }
    }
    sel = cur orelse 0;
}

fn connectZbg() void {
    var lb: [48]u8 = undefined;
    const lock = std.fmt.bufPrint(&lb, "zbg-{d}", .{sys.getuid()}) catch return;
    zbg_fd = sys.connectAbstractFd(lock) catch -1;
}

fn isImage(n: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, n, '.') orelse return false;
    const ext = n[dot + 1 ..];
    return std.ascii.eqlIgnoreCase(ext, "jpg") or std.ascii.eqlIgnoreCase(ext, "jpeg") or std.ascii.eqlIgnoreCase(ext, "png");
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn listFiles() void {
    var d = sys.Dir.open(dir) orelse return;
    defer d.deinit();
    while (d.next()) |n| {
        if (nfiles == MAX_FILES) break;
        if (!zbg.validName(n) or !isImage(n)) continue;
        if (names_len + n.len > names_buf.len) break;
        @memcpy(names_buf[names_len..][0..n.len], n);
        names[nfiles] = names_buf[names_len .. names_len + n.len];
        names_len += n.len;
        nfiles += 1;
    }
    std.mem.sort([]const u8, names[0..nfiles], {}, lessName);
    for (0..nfiles) |i| {
        states[i] = .pending;
        thumbs[i] = &[_]u8{};
        sizes[i] = 0;
        var pb: [800]u8 = undefined;
        if (sys.openRead(sys.joinZ(&pb, &.{ dir, "/", names[i] }))) |fd| {
            sizes[i] = sys.fileSize(fd) catch 0;
            sys.close(fd);
        } else |_| {}
    }
}

fn start() void {
    ensureVisible();
    if (nfiles > 0) ui.setTimer(1, 0); // превью готовятся в фоне небольшими порциями
}

// ================================================================= связь с zbg

var reply_buf: [320]u8 = undefined;

/// Отправить команду и дождаться строки ответа (до 10 с).
fn ask(cmd: []const u8) ?[]const u8 {
    if (zbg_fd < 0) return null;
    sys.sendAll(zbg_fd, cmd) catch return null;
    var n: usize = 0;
    while (n < reply_buf.len) {
        var pfd = [1]sys.PollFd{.{ .fd = zbg_fd, .events = sys.POLLIN }};
        const r = sys.poll(&pfd, 10000) catch return null;
        if (r == 0) return null;
        const k = sys.read(zbg_fd, reply_buf[n..]) catch return null;
        if (k == 0) return null;
        n += k;
        if (std.mem.indexOfScalar(u8, reply_buf[0..n], '\n')) |nl| return reply_buf[0..nl];
    }
    return null;
}

const NO_ZBG = "Демон обоев zbg не запущен — добавьте exec_once=zbg в конфиг mango";

fn zbgFd() i32 {
    return zbg_fd;
}

fn lostZbg() void {
    if (zbg_fd >= 0) sys.close(zbg_fd);
    zbg_fd = -1;
    pending = null;
    queued = null;
    ui.setMsg(NO_ZBG);
    ui.redraw();
}

fn apply(i: usize) void {
    if (i >= nfiles) return;
    if (zbg_fd < 0) return ui.setMsg(NO_ZBG);
    if (pending != null) {
        queued = i; // применим, когда zbg закончит с предыдущими
        return;
    }
    var b: [300]u8 = undefined;
    sys.sendAll(zbg_fd, sys.joinZ(&b, &.{ "set ", names[i], "\n" })) catch return lostZbg();
    pending = i;
    ui.clearMsg();
    ui.redraw();
}

/// Ответ zbg на "set": "ok" или "err текст".
fn onZbg() void {
    const n = sys.read(zbg_fd, in_buf[in_len..]) catch 0;
    if (n == 0) return lostZbg();
    in_len += n;
    while (std.mem.indexOfScalar(u8, in_buf[0..in_len], '\n')) |nl| {
        const r = in_buf[0..nl];
        if (pending) |i| {
            if (std.mem.eql(u8, r, "ok")) {
                cur = i;
                ui.clearMsg();
            } else ui.setMsg(if (std.mem.startsWith(u8, r, "err ")) r[4..] else r);
        }
        pending = null;
        std.mem.copyForwards(u8, in_buf[0 .. in_len - nl - 1], in_buf[nl + 1 .. in_len]);
        in_len -= nl + 1;
    }
    if (in_len == in_buf.len) in_len = 0;
    if (pending == null) {
        if (queued) |q| {
            queued = null;
            apply(q);
        }
    }
    ui.redraw();
}

fn randomCli() void {
    dir = zbg.expandHome(&dir_buf, cfg.wallpaper_dir) orelse "";
    listFiles();
    connectZbg();
    if (zbg_fd < 0) {
        sys.log("zbg не запущен", .{});
        sys.exit(1);
    }
    if (nfiles == 0) {
        sys.log("в {s} нет изображений", .{dir});
        sys.exit(1);
    }
    if (ask("get\n")) |r| {
        for (names[0..nfiles], 0..) |n, i| {
            if (r.len > 4 and std.mem.eql(u8, n, r[4..])) cur = i;
        }
    }
    var i: usize = @intCast(sys.random() % nfiles);
    if (cur != null and i == cur.? and nfiles > 1) i = (i + 1 + @as(usize, @intCast(sys.random() % (nfiles - 1)))) % nfiles;
    var b: [300]u8 = undefined;
    const r = ask(sys.joinZ(&b, &.{ "set ", names[i], "\n" })) orelse "нет ответа";
    if (!std.mem.eql(u8, r, "ok")) {
        sys.log("{s}: {s}", .{ names[i], r });
        sys.exit(1);
    }
    sys.exit(0);
}

// ================================================================= превью

fn fnv(s: []const u8, h0: u64) u64 {
    var h = h0;
    for (s) |c| h = (h ^ c) *% 0x100000001b3;
    return h;
}

/// Ключ превью: имя и размер файла (файл заменили — превью пересоздастся).
fn cacheKey(i: usize) u64 {
    var hb: [8]u8 = undefined;
    std.mem.writeInt(u64, &hb, sizes[i], .little);
    return fnv(&hb, fnv(names[i], 0xcbf29ce484222325));
}

fn cachePath(buf: []u8, i: usize) [:0]const u8 {
    var name: [24]u8 = undefined;
    const n = std.fmt.bufPrint(&name, "{x:0>16}.thumb", .{cacheKey(i)}) catch "x.thumb";
    return sys.joinZ(buf, &.{ cache, "/", n });
}

/// Удалить превью файлов, которых в папке больше нет (кэш не растёт бесконечно).
fn pruneCache() void {
    if (!cache_ok) return;
    var d = sys.Dir.open(cache) orelse return;
    defer d.deinit();
    var stale: [64][22]u8 = undefined;
    var nstale: usize = 0;
    while (d.next()) |n| {
        if (n.len != 22 or !std.mem.endsWith(u8, n, ".thumb")) continue;
        const key = std.fmt.parseInt(u64, n[0..16], 16) catch continue;
        var used = false;
        for (0..nfiles) |i| {
            if (cacheKey(i) == key) {
                used = true;
                break;
            }
        }
        if (!used and nstale < stale.len) {
            @memcpy(&stale[nstale], n[0..22]);
            nstale += 1;
        }
    }
    for (stale[0..nstale]) |*n| {
        var pb: [600]u8 = undefined;
        sys.unlink(sys.joinZ(&pb, &.{ cache, "/", n }));
    }
}

const HDR = 8; // "ZTH1" + u16 w + u16 h

fn loadCached(i: usize, out: []u8) bool {
    if (!cache_ok) return false;
    var pb: [600]u8 = undefined;
    var tmp: [HDR]u8 = undefined;
    const fd = sys.openRead(cachePath(&pb, i)) catch return false;
    defer sys.close(fd);
    if ((sys.read(fd, &tmp) catch 0) != HDR) return false;
    if (!std.mem.eql(u8, tmp[0..4], "ZTH1") or std.mem.readInt(u16, tmp[4..6], .little) != TW or std.mem.readInt(u16, tmp[6..8], .little) != TH) return false;
    var n: usize = 0;
    while (n < out.len) {
        const k = sys.read(fd, out[n..]) catch return false;
        if (k == 0) return false;
        n += k;
    }
    return true;
}

fn saveCached(i: usize, rgb: []const u8) void {
    if (!cache_ok) return;
    var pb: [600]u8 = undefined;
    const fd = sys.createFile(cachePath(&pb, i)) catch return;
    defer sys.close(fd);
    var hdr: [HDR]u8 = undefined;
    @memcpy(hdr[0..4], "ZTH1");
    std.mem.writeInt(u16, hdr[4..6], TW, .little);
    std.mem.writeInt(u16, hdr[6..8], TH, .little);
    sys.writeAll(fd, &hdr) catch return;
    sys.writeAll(fd, rgb) catch return;
}

var work: [TW * TH]u32 = undefined; // рабочий буфер превью (не на стеке)

/// Сделать одно превью: сначала видимые.
fn makeOne() bool {
    var pick: ?usize = null;
    const first = scroll * COLS;
    var i = first;
    while (i < @min(nfiles, first + ROWS * COLS)) : (i += 1) {
        if (states[i] == .pending) {
            pick = i;
            break;
        }
    }
    if (pick == null) {
        for (0..nfiles) |k| {
            if (states[k] == .pending) {
                pick = k;
                break;
            }
        }
    }
    const k = pick orelse return false;
    states[k] = .failed;
    var pb: [800]u8 = undefined;
    const path = sys.joinZ(&pb, &.{ dir, "/", names[k] });
    const rgb = sys.mmapAnon(TW * TH * 3) catch return true;
    thumbs[k] = rgb[0 .. TW * TH * 3];
    if (loadCached(k, thumbs[k])) {
        states[k] = .ok;
        return true;
    }
    var pic = img.load(path, TW, TH) catch return true;
    defer pic.deinit();
    img.render(&pic, &work, TW, TH, .fill, 0x202020) catch return true;
    for (work, 0..) |p, j| {
        thumbs[k][j * 3] = @truncate(p >> 16);
        thumbs[k][j * 3 + 1] = @truncate(p >> 8);
        thumbs[k][j * 3 + 2] = @truncate(p);
    }
    states[k] = .ok;
    saveCached(k, thumbs[k]);
    return true;
}

/// Превью из кэша грузятся пачкой, новые декодируются по одному — около 15 мс за такт,
/// чтобы меню отвечало сразу.
fn onTick() void {
    const t0 = sys.monoMs();
    var any = false;
    while (makeOne()) {
        any = true;
        if (sys.monoMs() -% t0 >= 15) break;
    }
    if (any) {
        ui.redraw();
        ui.setTimer(1, 0);
    }
}

// ================================================================= навигация

fn ensureVisible() void {
    const row = sel / COLS;
    if (row < scroll) scroll = row;
    if (row >= scroll + ROWS) scroll = row + 1 - ROWS;
}

fn moveSel(d: i32) void {
    if (nfiles == 0) return;
    ui.kbd_nav = true;
    sel = @intCast(std.math.clamp(@as(i64, @intCast(sel)) + d, 0, @as(i64, @intCast(nfiles)) - 1));
    ensureVisible();
    ui.redraw();
}

fn onKey(k: ui.Key) bool {
    switch (k.code) {
        ui.K_LEFT => moveSel(-1),
        ui.K_RIGHT => moveSel(1),
        ui.K_UP => moveSel(-COLS),
        ui.K_DOWN => moveSel(COLS),
        ui.K_PGUP => moveSel(-COLS * ROWS),
        ui.K_PGDN => moveSel(COLS * ROWS),
        ui.K_HOME => moveSel(-@as(i32, MAX_FILES)),
        ui.K_END => moveSel(MAX_FILES),
        ui.K_ENTER, ui.K_KPENTER => {
            if (ui.focus.id != 0) return false;
            apply(sel);
        },
        else => return false,
    }
    if (k.code != ui.K_ENTER and k.code != ui.K_KPENTER) ui.focus = .{};
    return true;
}

fn onScroll(d: i32) void {
    const rows = (nfiles + COLS - 1) / COLS;
    if (rows <= ROWS) return;
    scroll = @intCast(std.math.clamp(@as(i64, @intCast(scroll)) + d, 0, @as(i64, @intCast(rows - ROWS))));
    ui.redraw();
}

fn activate(w: ui.Widget, right: bool) void {
    _ = right;
    switch (@as(Wid, @enumFromInt(w.id))) {
        .tile => {
            sel = w.idx;
            apply(w.idx);
        },
        .random => {
            if (nfiles == 0) return;
            var i: usize = @intCast(sys.random() % nfiles);
            if (cur != null and i == cur.? and nfiles > 1) i = (i + 1) % nfiles;
            sel = i;
            ensureVisible();
            apply(i);
        },
        .none => {},
    }
}

// ================================================================= раскладка и рисование

fn tilePos(i: usize) [2]f32 {
    const r = i / COLS - scroll;
    const c = i % COLS;
    return .{ PAD + @as(f32, @floatFromInt(c)) * (TILE_W + GAP), GRID_Y + @as(f32, @floatFromInt(r)) * (TILE_H + GAP) };
}

fn layout() void {
    ui.nwid = 0;
    if (nfiles > 1) ui.add(Wid.random, 0, .button, ui.W() - PAD - 128, 18, 128, 32);
    var i = scroll * COLS;
    while (i < @min(nfiles, (scroll + ROWS) * COLS)) : (i += 1) {
        const p = tilePos(i);
        ui.add(Wid.tile, i, .plain, p[0], p[1], TILE_W, TILE_H);
    }
}

fn paint(cv: *draw.Canvas) void {
    const t = &theme.t;
    const W = ui.W();
    const H = ui.H();
    var sb: [48]u8 = undefined;
    const sub = if (nfiles == 0) "" else std.fmt.bufPrint(&sb, "{d} {s}", .{ nfiles, plural(nfiles) }) catch "";
    ui.header(cv, "Обои", sub, false);
    if (nfiles == 0) {
        ui.centered(cv, "Здесь пока пусто", W / 2, H / 2 - 10, 15, t.menu_text);
        var b: [600]u8 = undefined;
        const hint = sys.joinZ(&b, &.{ "Положите .jpg или .png в ", cfg.wallpaper_dir });
        ui.centered(cv, hint, W / 2, H / 2 + 14, 12, t.menu_muted);
    }
    const S = ui.S;
    for (ui.widgets[0..ui.nwid]) |w| {
        switch (@as(Wid, @enumFromInt(w.id))) {
            .random => ui.button(cv, w, "Случайные", .secondary),
            .tile => {
                const i = w.idx;
                if (states[i] == .ok) {
                    cv.image(thumbs[i], TW, TH, w.x * S, w.y * S, w.w * S, w.h * S, 10 * S);
                } else {
                    ui.rrect(cv, w.x, w.y, w.w, w.h, 10, t.menu_field);
                    if (states[i] == .failed) ui.centered(cv, "не открывается", w.x + w.w / 2, ui.mid(w.y, w.h, 11), 11, t.menu_muted);
                }
                const is_cur = cur != null and cur.? == i;
                const waiting = (pending != null and pending.? == i) or (queued != null and queued.? == i);
                const lit = (ui.kbd_nav and sel == i) or (!ui.kbd_nav and ui.isHover(w));
                if (is_cur) {
                    ui.outline(cv, w.x - 1, w.y - 1, w.w + 2, w.h + 2, 11, t.menu_accent, 3);
                    ui.rrect(cv, w.x + w.w - 30, w.y + 8, 22, 22, 11, t.menu_accent);
                    ui.icon(cv, &ui.ic_check, w.x + w.w - 27, w.y + 11, 16, 2, t.menu_accent_text);
                } else if (lit) {
                    ui.outline(cv, w.x - 1, w.y - 1, w.w + 2, w.h + 2, 11, t.menu_text, 2);
                }
                if (waiting) { // применяется — затемняем и пишем
                    ui.rrect(cv, w.x, w.y, w.w, w.h, 10, 0x99000000);
                    ui.centered(cv, "применяю…", w.x + w.w / 2, ui.mid(w.y, w.h, 12), 12, 0xffffffff);
                }
            },
            .none => {},
        }
    }
    // подпись: файл под курсором или выбранный стрелками
    var show: ?usize = if (ui.kbd_nav) sel else null;
    if (!ui.kbd_nav and ui.hover.id == @intFromEnum(Wid.tile)) show = ui.hover.idx;
    if (show == null and cur != null) show = cur;
    if (ui.msg().len > 0) {
        ui.paintMsg(cv, H - 22);
    } else if (show) |i| {
        _ = ui.text(cv, names[i], PAD, H - 22, 12, t.menu_muted, W - PAD);
    }
    // полоса прокрутки
    const rows = (nfiles + COLS - 1) / COLS;
    if (rows > ROWS) {
        const track = ROWS * TILE_H + (ROWS - 1) * GAP;
        const hgt = track * ROWS / @as(f32, @floatFromInt(rows));
        const y = GRID_Y + (track - hgt) * @as(f32, @floatFromInt(scroll)) / @as(f32, @floatFromInt(rows - ROWS));
        ui.rrect(cv, W - 8, y, 3, hgt, 1.5, t.menu_border);
    }
}

fn plural(n: usize) []const u8 {
    const m10 = n % 10;
    const m100 = n % 100;
    if (m10 == 1 and m100 != 11) return "изображение";
    if (m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14)) return "изображения";
    return "изображений";
}
