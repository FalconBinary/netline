// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zcal — календарь для часов zpanel на чистом Zig.
//!
//! Месяц с выделенным «сегодня», неделя с понедельника, русские названия.
//! Клавиши: ←/→ (или PgUp/PgDn) — месяц, ↑/↓ — год, Home — сегодня, Esc — закрыть.
//! Колёсико листает месяцы, клик по названию месяца возвращает к сегодняшнему.

const std = @import("std");
const sys = @import("sys.zig");
const draw = @import("draw.zig");
const theme = @import("theme.zig");
const tz = @import("tz.zig");
const ui = @import("ui.zig");

const PAD: f32 = 20;
const CELL_W: f32 = 40;
const CELL_H: f32 = 34;
const GRID_Y: f32 = 146;

const months = [_][]const u8{ "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь" };
const months_gen = [_][]const u8{ "января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря" };
const wdays = [_][]const u8{ "Понедельник", "Вторник", "Среда", "Четверг", "Пятница", "Суббота", "Воскресенье" };
const wshort = [_][]const u8{ "Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс" };

var today: tz.Date = .{ .year = 1970, .month = 1, .day = 1 };
var year: i64 = 1970;
var month: u32 = 1;

const Wid = enum(u8) { none, prev, next, title };

pub fn main() void {
    ui.begin("zcal");
    tz.load(); // часовой пояс читается до песочницы
    const t = tz.now();
    today = .{ .year = t.year, .month = t.month, .day = t.day };
    year = t.year;
    month = t.month;
    ui.run(.{
        .width = @intFromFloat(2 * PAD + 7 * CELL_W),
        .height = @intFromFloat(GRID_Y + 6 * CELL_H + 16),
        .layout = layout,
        .paint = paint,
        .activate = activate,
        .back = ui.quit,
        .key = onKey,
        .scroll = shift,
    }, .{}, .{});
}

fn shift(d: i32) void {
    var m: i64 = @as(i64, month) - 1 + d;
    year += @divFloor(m, 12);
    m = @mod(m, 12);
    month = @intCast(m + 1);
    ui.redraw();
}

fn goToday() void {
    year = today.year;
    month = today.month;
    ui.redraw();
}

fn onKey(k: ui.Key) bool {
    switch (k.code) {
        ui.K_LEFT, ui.K_PGUP => shift(-1),
        ui.K_RIGHT, ui.K_PGDN => shift(1),
        ui.K_UP => shift(-12),
        ui.K_DOWN => shift(12),
        ui.K_HOME => goToday(),
        ui.K_ENTER, ui.K_KPENTER, ui.K_TAB => {},
        else => return false,
    }
    return true;
}

fn activate(w: ui.Widget, right: bool) void {
    _ = right;
    switch (@as(Wid, @enumFromInt(w.id))) {
        .prev => shift(-1),
        .next => shift(1),
        .title => goToday(),
        .none => {},
    }
}

fn layout() void {
    ui.nwid = 0;
    const W = ui.W();
    ui.add(Wid.title, 0, .plain, PAD - 6, 88, 170, 30);
    ui.add(Wid.prev, 0, .plain, W - PAD - 64, 89, 28, 28);
    ui.add(Wid.next, 0, .plain, W - PAD - 30, 89, 28, 28);
}

/// День недели с понедельника (0 = пн) для числа дней от эпохи.
fn mondayIndex(days: i64) usize {
    return @intCast(@mod(days + 3, 7)); // 1970-01-01 — четверг
}

fn paint(cv: *draw.Canvas) void {
    const t = &theme.t;
    const W = ui.W();

    // сегодняшняя дата
    const td = tz.daysFromCivil(today.year, today.month, today.day);
    _ = ui.text(cv, wdays[mondayIndex(td)], PAD, 32, 12, t.menu_muted, W - PAD);
    var b: [64]u8 = undefined;
    const date = std.fmt.bufPrint(&b, "{d} {s} {d}", .{ today.day, months_gen[today.month - 1], today.year }) catch "";
    _ = ui.text(cv, date, PAD, 56, 20, t.menu_text, W - PAD);
    ui.rrect(cv, PAD, 72, W - 2 * PAD, 1, 0.5, t.menu_border);

    // заголовок месяца и стрелки
    var mb: [48]u8 = undefined;
    const title = std.fmt.bufPrint(&mb, "{s} {d}", .{ months[month - 1], year }) catch "";
    for (ui.widgets[0..ui.nwid]) |w| {
        const hov = ui.isHover(w);
        switch (@as(Wid, @enumFromInt(w.id))) {
            .title => {
                if (hov and (year != today.year or month != today.month)) ui.rrect(cv, w.x, w.y, w.w, w.h, 8, t.menu_hover);
                _ = ui.text(cv, title, w.x + 6, ui.mid(w.y, w.h, 15), 15, t.menu_text, w.x + w.w);
            },
            .prev, .next => {
                if (hov) ui.rrect(cv, w.x, w.y, w.w, w.h, 8, t.menu_hover);
                const ic: []const draw.Prim = if (w.id == @intFromEnum(Wid.prev)) &ui.ic_back else &ui.ic_fwd;
                ui.icon(cv, ic, w.x + 6, w.y + 6, 16, 1.8, t.menu_text);
            },
            .none => {},
        }
    }

    // дни недели
    for (wshort, 0..) |d, i| {
        const cx = PAD + (@as(f32, @floatFromInt(i)) + 0.5) * CELL_W;
        ui.centered(cv, d, cx, 136, 11.5, if (i >= 5) t.menu_error else t.menu_muted);
    }

    // сетка 6×7: начинаем с понедельника недели, в которой 1-е число
    const first = tz.daysFromCivil(year, month, 1);
    const start = first - @as(i64, @intCast(mondayIndex(first)));
    for (0..42) |cell| {
        const day = start + @as(i64, @intCast(cell));
        const dt = tz.civilFromDays(day);
        const col: f32 = @floatFromInt(cell % 7);
        const row: f32 = @floatFromInt(cell / 7);
        const cx = PAD + (col + 0.5) * CELL_W;
        const cy = GRID_Y + row * CELL_H + CELL_H / 2;
        var nb: [4]u8 = undefined;
        const num = std.fmt.bufPrint(&nb, "{d}", .{dt.day}) catch "";
        const in_month = dt.month == month;
        if (day == td) {
            ui.rrect(cv, cx - 15, cy - 15, 30, 30, 15, t.menu_accent);
            ui.centered(cv, num, cx, cy + 5, 13.5, t.menu_accent_text);
        } else {
            const weekend = cell % 7 >= 5;
            const c = if (!in_month) t.menu_border else if (weekend) t.menu_error else t.menu_text;
            ui.centered(cv, num, cx, cy + 5, 13.5, c);
        }
    }
}
