// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Программная отрисовка в ARGB8888 (premultiplied): заливки, скруглённые прямоугольники
//! и векторные примитивы с антиалиасингом через функции расстояния (SDF).
//! Цифры и иконки — свои, векторные, поэтому масштабируются без потерь.

const std = @import("std");

pub const Canvas = struct {
    px: []u32,
    w: i32,
    h: i32,

    pub fn clear(self: *Canvas, color: u32) void {
        @memset(self.px, premul(color));
    }

    pub inline fn blend(self: *Canvas, x: i32, y: i32, color: u32, cov: f32) void {
        if (cov <= 0.0) return;
        const i: usize = @intCast(y * self.w + x);
        const a = @as(f32, @floatFromInt(color >> 24)) / 255.0 * @min(cov, 1.0);
        if (a >= 0.999) {
            self.px[i] = color | 0xff000000;
            return;
        }
        const d = self.px[i];
        const inv = 1.0 - a;
        var out: u32 = 0;
        inline for (.{ 0, 8, 16 }) |sh| {
            const s: f32 = @floatFromInt((color >> sh) & 0xff);
            const dv: f32 = @floatFromInt((d >> sh) & 0xff);
            out |= @as(u32, @intFromFloat(@min(255.0, s * a + dv * inv + 0.5))) << sh;
        }
        const da: f32 = @floatFromInt(d >> 24);
        out |= @as(u32, @intFromFloat(@min(255.0, 255.0 * a + da * inv + 0.5))) << 24;
        self.px[i] = out;
    }

    /// Наложить 8-битную маску покрытия (глиф шрифта) цветом `color`.
    pub fn blit(self: *Canvas, bmp: []const u8, w: u16, h: u16, x: i32, y: i32, color: u32) void {
        var row: i32 = 0;
        while (row < h) : (row += 1) {
            const py = y + row;
            if (py < 0 or py >= self.h) continue;
            var col: i32 = 0;
            while (col < w) : (col += 1) {
                const px = x + col;
                if (px < 0 or px >= self.w) continue;
                const c = bmp[@as(usize, @intCast(row)) * w + @as(usize, @intCast(col))];
                if (c != 0) self.blend(px, py, color, @as(f32, @floatFromInt(c)) / 255.0);
            }
        }
    }

    /// Картинка RGB (3 байта на пиксель, sw×sh) в прямоугольник (x, y, w, h) устройства:
    /// при уменьшении — усреднение, углы скруглены радиусом r.
    pub fn image(self: *Canvas, rgb: []const u8, sw: u32, sh: u32, x: f32, y: f32, w: f32, h: f32, r: f32) void {
        if (w < 1 or h < 1 or sw == 0 or sh == 0 or rgb.len < @as(usize, sw) * sh * 3) return;
        const x0: i32 = @max(0, @as(i32, @intFromFloat(@floor(x))));
        const y0: i32 = @max(0, @as(i32, @intFromFloat(@floor(y))));
        const x1: i32 = @min(self.w, @as(i32, @intFromFloat(@ceil(x + w))));
        const y1: i32 = @min(self.h, @as(i32, @intFromFloat(@ceil(y + h))));
        const fx: f32 = @as(f32, @floatFromInt(sw)) / w;
        const fy: f32 = @as(f32, @floatFromInt(sh)) / h;
        const rr = @min(r, @min(w, h) / 2);
        var py = y0;
        while (py < y1) : (py += 1) {
            const ly = @as(f32, @floatFromInt(py)) - y;
            const sy0: u32 = @intFromFloat(std.math.clamp(@floor(ly * fy), 0, @as(f32, @floatFromInt(sh - 1))));
            const sy1: u32 = @max(sy0 + 1, @min(sh, @as(u32, @intFromFloat(@max(0, @floor((ly + 1) * fy))))));
            var px = x0;
            while (px < x1) : (px += 1) {
                const lx = @as(f32, @floatFromInt(px)) - x;
                const d = sdBox(lx + 0.5 - w / 2, ly + 0.5 - h / 2, w / 2, h / 2, rr);
                const cov = 0.5 - d;
                if (cov <= 0) continue;
                const sx0: u32 = @intFromFloat(std.math.clamp(@floor(lx * fx), 0, @as(f32, @floatFromInt(sw - 1))));
                const sx1: u32 = @max(sx0 + 1, @min(sw, @as(u32, @intFromFloat(@max(0, @floor((lx + 1) * fx))))));
                var acc: [3]u32 = .{ 0, 0, 0 };
                var cnt: u32 = 0;
                var sy = sy0;
                while (sy < sy1) : (sy += 1) {
                    var sx = sx0;
                    while (sx < sx1) : (sx += 1) {
                        const i = (@as(usize, sy) * sw + sx) * 3;
                        acc[0] += rgb[i];
                        acc[1] += rgb[i + 1];
                        acc[2] += rgb[i + 2];
                        cnt += 1;
                    }
                }
                const c = 0xff000000 | ((acc[0] / cnt) << 16) | ((acc[1] / cnt) << 8) | (acc[2] / cnt);
                self.blend(px, py, c, cov);
            }
        }
    }

    /// Обходит пиксели прямоугольника и красит с покрытием clamp(0.5 - dist).
    fn paint(self: *Canvas, x0f: f32, y0f: f32, x1f: f32, y1f: f32, color: u32, ctx: anytype, comptime dist: fn (@TypeOf(ctx), f32, f32) f32) void {
        const x0: i32 = @max(0, @as(i32, @intFromFloat(@floor(x0f))));
        const y0: i32 = @max(0, @as(i32, @intFromFloat(@floor(y0f))));
        const x1: i32 = @min(self.w, @as(i32, @intFromFloat(@ceil(x1f))));
        const y1: i32 = @min(self.h, @as(i32, @intFromFloat(@ceil(y1f))));
        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const d = dist(ctx, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
                self.blend(x, y, color, 0.5 - d);
            }
        }
    }

    pub fn fillRoundRect(self: *Canvas, x: f32, y: f32, w: f32, h: f32, r: f32, color: u32) void {
        const ctx = Box{ .cx = x + w / 2, .cy = y + h / 2, .hw = w / 2, .hh = h / 2, .r = @min(r, @min(w, h) / 2) };
        self.paint(x - 1, y - 1, x + w + 1, y + h + 1, color, ctx, Box.sdf);
    }

    /// Рисует набор примитивов. Координаты примитивов в «единицах»,
    /// пиксель = (ox, oy) + единица * s. stroke — толщина линий в пикселях.
    pub fn prims(self: *Canvas, list: []const Prim, ox: f32, oy: f32, s: f32, stroke: f32, color: u32) void {
        var buf: [24]Prim = undefined;
        const n = @min(list.len, buf.len);
        var bx0: f32 = 1e9;
        var by0: f32 = 1e9;
        var bx1: f32 = -1e9;
        var by1: f32 = -1e9;
        for (list[0..n], 0..) |p, i| {
            const t = p.transform(ox, oy, s);
            buf[i] = t;
            const b = t.bounds();
            bx0 = @min(bx0, b[0]);
            by0 = @min(by0, b[1]);
            bx1 = @max(bx1, b[2]);
            by1 = @max(by1, b[3]);
        }
        const ctx = Group{ .p = buf[0..n], .hw = stroke / 2 };
        const pad = stroke / 2 + 1;
        self.paint(bx0 - pad, by0 - pad, bx1 + pad, by1 + pad, color, ctx, Group.sdf);
    }
};

pub fn premul(c: u32) u32 {
    const a = c >> 24;
    if (a == 255) return c;
    var out: u32 = a << 24;
    inline for (.{ 0, 8, 16 }) |sh| {
        out |= (((c >> sh) & 0xff) * a / 255) << sh;
    }
    return out;
}

const Box = struct {
    cx: f32,
    cy: f32,
    hw: f32,
    hh: f32,
    r: f32,
    fn sdf(b: Box, x: f32, y: f32) f32 {
        return sdBox(x - b.cx, y - b.cy, b.hw, b.hh, b.r);
    }
};

fn sdBox(px: f32, py: f32, hw: f32, hh: f32, r: f32) f32 {
    const qx = @abs(px) - (hw - r);
    const qy = @abs(py) - (hh - r);
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0) - r;
}

fn segDist(px: f32, py: f32, x0: f32, y0: f32, x1: f32, y1: f32) f32 {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const l2 = dx * dx + dy * dy;
    var t: f32 = if (l2 > 0) ((px - x0) * dx + (py - y0) * dy) / l2 else 0;
    t = std.math.clamp(t, 0.0, 1.0);
    const ex = px - (x0 + t * dx);
    const ey = py - (y0 + t * dy);
    return @sqrt(ex * ex + ey * ey);
}

/// Быстрый atan2 (погрешность ~1e-5 рад) — чтобы не зависеть от сигнатуры std.math.atan2.
fn atan2(y: f32, x: f32) f32 {
    const ax = @abs(x);
    const ay = @abs(y);
    const mx = @max(ax, ay);
    if (mx == 0) return 0;
    const a = @min(ax, ay) / mx;
    const s = a * a;
    var r = ((-0.0464964749 * s + 0.15931422) * s - 0.327622764) * s * a + a;
    if (ay > ax) r = 1.57079637 - r;
    if (x < 0) r = 3.14159274 - r;
    if (y < 0) r = -r;
    return r;
}

const TAU: f32 = 6.28318531;

/// Векторный примитив. Углы дуг — в градусах, 0° = вправо, 90° = вниз,
/// дуга идёт по часовой стрелке от a0 к a1.
pub const Prim = union(enum) {
    seg: struct { x0: f32, y0: f32, x1: f32, y1: f32 },
    arc: struct { cx: f32, cy: f32, r: f32, a0: f32, a1: f32 },
    ring: struct { cx: f32, cy: f32, r: f32 },
    dot: struct { cx: f32, cy: f32, r: f32 }, // заливка
    box: struct { x: f32, y: f32, w: f32, h: f32, r: f32 }, // контур
    fbox: struct { x: f32, y: f32, w: f32, h: f32, r: f32 }, // заливка

    fn transform(p: Prim, ox: f32, oy: f32, s: f32) Prim {
        return switch (p) {
            .seg => |v| .{ .seg = .{ .x0 = ox + v.x0 * s, .y0 = oy + v.y0 * s, .x1 = ox + v.x1 * s, .y1 = oy + v.y1 * s } },
            .arc => |v| .{ .arc = .{ .cx = ox + v.cx * s, .cy = oy + v.cy * s, .r = v.r * s, .a0 = v.a0 * TAU / 360.0, .a1 = v.a1 * TAU / 360.0 } },
            .ring => |v| .{ .ring = .{ .cx = ox + v.cx * s, .cy = oy + v.cy * s, .r = v.r * s } },
            .dot => |v| .{ .dot = .{ .cx = ox + v.cx * s, .cy = oy + v.cy * s, .r = v.r * s } },
            .box => |v| .{ .box = .{ .x = ox + v.x * s, .y = oy + v.y * s, .w = v.w * s, .h = v.h * s, .r = v.r * s } },
            .fbox => |v| .{ .fbox = .{ .x = ox + v.x * s, .y = oy + v.y * s, .w = v.w * s, .h = v.h * s, .r = v.r * s } },
        };
    }

    fn bounds(p: Prim) [4]f32 {
        return switch (p) {
            .seg => |v| .{ @min(v.x0, v.x1), @min(v.y0, v.y1), @max(v.x0, v.x1), @max(v.y0, v.y1) },
            .arc => |v| .{ v.cx - v.r, v.cy - v.r, v.cx + v.r, v.cy + v.r },
            .ring => |v| .{ v.cx - v.r, v.cy - v.r, v.cx + v.r, v.cy + v.r },
            .dot => |v| .{ v.cx - v.r, v.cy - v.r, v.cx + v.r, v.cy + v.r },
            .box => |v| .{ v.x, v.y, v.x + v.w, v.y + v.h },
            .fbox => |v| .{ v.x, v.y, v.x + v.w, v.y + v.h },
        };
    }

    /// Расстояние до примитива с учётом полутолщины линии hw.
    fn dist(p: Prim, x: f32, y: f32, hw: f32) f32 {
        switch (p) {
            .seg => |v| return segDist(x, y, v.x0, v.y0, v.x1, v.y1) - hw,
            .ring => |v| {
                const dx = x - v.cx;
                const dy = y - v.cy;
                return @abs(@sqrt(dx * dx + dy * dy) - v.r) - hw;
            },
            .dot => |v| {
                const dx = x - v.cx;
                const dy = y - v.cy;
                return @sqrt(dx * dx + dy * dy) - v.r;
            },
            .arc => |v| {
                const dx = x - v.cx;
                const dy = y - v.cy;
                var t = atan2(dy, dx) - v.a0;
                t -= TAU * @floor(t / TAU);
                if (t <= v.a1 - v.a0) return @abs(@sqrt(dx * dx + dy * dy) - v.r) - hw;
                const e0x = v.cx + v.r * @cos(v.a0) - x;
                const e0y = v.cy + v.r * @sin(v.a0) - y;
                const e1x = v.cx + v.r * @cos(v.a1) - x;
                const e1y = v.cy + v.r * @sin(v.a1) - y;
                return @min(@sqrt(e0x * e0x + e0y * e0y), @sqrt(e1x * e1x + e1y * e1y)) - hw;
            },
            .box => |v| return @abs(sdBox(x - v.x - v.w / 2, y - v.y - v.h / 2, v.w / 2, v.h / 2, v.r)) - hw,
            .fbox => |v| return sdBox(x - v.x - v.w / 2, y - v.y - v.h / 2, v.w / 2, v.h / 2, v.r),
        }
    }
};

const Group = struct {
    p: []const Prim,
    hw: f32,
    fn sdf(g: Group, x: f32, y: f32) f32 {
        var d: f32 = 1e9;
        for (g.p) |p| d = @min(d, p.dist(x, y, g.hw));
        return d;
    }
};

// ---------------------------------------------------------------- шрифт
// Цифры спроектированы в сетке 6×10 единиц, линия — STROKE единиц.

pub const STROKE: f32 = 1.45;

fn seg(x0: f32, y0: f32, x1: f32, y1: f32) Prim {
    return .{ .seg = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 } };
}
fn arc(cx: f32, cy: f32, r: f32, a0: f32, a1: f32) Prim {
    return .{ .arc = .{ .cx = cx, .cy = cy, .r = r, .a0 = a0, .a1 = a1 } };
}
fn ring(cx: f32, cy: f32, r: f32) Prim {
    return .{ .ring = .{ .cx = cx, .cy = cy, .r = r } };
}
fn dot(cx: f32, cy: f32, r: f32) Prim {
    return .{ .dot = .{ .cx = cx, .cy = cy, .r = r } };
}
fn box(x: f32, y: f32, w: f32, h: f32, r: f32) Prim {
    return .{ .box = .{ .x = x, .y = y, .w = w, .h = h, .r = r } };
}

/// Точка на дуге (для стыковки отрезков с дугами).
fn ap(cx: f32, cy: f32, r: f32, deg: f32) [2]f32 {
    const a = deg * TAU / 360.0;
    return .{ cx + r * @cos(a), cy + r * @sin(a) };
}

const g0 = [_]Prim{box(0, 0, 6, 10, 3)};
const g1 = [_]Prim{ seg(3.4, 0, 3.4, 10), seg(3.4, 0, 1.0, 2.0) };
const g2 = blk: {
    const e = ap(3, 3, 3, 380);
    break :blk [_]Prim{ arc(3, 3, 3, 165, 380), seg(e[0], e[1], 0, 10), seg(0, 10, 6, 10) };
};
const g3 = [_]Prim{ arc(3, 2.3, 2.3, 200, 450), arc(3, 7.3, 2.7, -90, 160) };
const g4 = [_]Prim{ seg(4.6, 10, 4.6, 0), seg(4.6, 0, 0, 7), seg(0, 7, 6, 7) };
const g5 = blk: {
    const st = ap(3, 6.9, 3.1, -140);
    break :blk [_]Prim{ seg(5.7, 0, 0.8, 0), seg(0.8, 0, st[0], st[1]), arc(3, 6.9, 3.1, -140, 150) };
};
const g6 = [_]Prim{ ring(3, 7, 3), arc(7.24, 7, 7.24, 180, 247.75) };
const g7 = [_]Prim{ seg(0, 0, 6, 0), seg(6, 0, 2.2, 10) };
const g8 = [_]Prim{ ring(3, 2.4, 2.4), ring(3, 7.3, 2.7) };
const g9 = [_]Prim{ ring(3, 3, 3), arc(-1.24, 3, 7.24, 0, 67.75) };
const gcolon = [_]Prim{ dot(1, 3.2, 0.95), dot(1, 7.8, 0.95) };
const gdot = [_]Prim{dot(1, 9.1, 0.95)};

fn glyph(c: u8) ?[]const Prim {
    return switch (c) {
        '0' => &g0,
        '1' => &g1,
        '2' => &g2,
        '3' => &g3,
        '4' => &g4,
        '5' => &g5,
        '6' => &g6,
        '7' => &g7,
        '8' => &g8,
        '9' => &g9,
        ':' => &gcolon,
        '.' => &gdot,
        else => null,
    };
}

fn advance(c: u8) f32 {
    return switch (c) {
        ':', '.' => 4.2,
        ' ' => 4.5,
        else => 9.0,
    };
}

/// Ширина текста в пикселях при высоте цифр `size`.
pub fn textWidth(str: []const u8, size: f32) f32 {
    const s = size / 10.0;
    var w: f32 = 0;
    for (str) |ch| w += advance(ch) * s;
    // у последнего символа не учитываем межбуквенный промежуток
    if (str.len > 0) w -= (advance(str[str.len - 1]) - glyphWidth(str[str.len - 1])) * s;
    return w;
}

fn glyphWidth(c: u8) f32 {
    return switch (c) {
        ':', '.' => 2.0,
        ' ' => 4.5,
        else => 6.0,
    };
}

/// Рисует строку из цифр, ':' , '.' и пробелов. (x, y) — левый верхний угол цифр.
pub fn text(c: *Canvas, str: []const u8, x: f32, y: f32, size: f32, color: u32) void {
    const s = size / 10.0;
    var cx = x;
    for (str) |ch| {
        if (glyph(ch)) |g| c.prims(g, cx, y, s, STROKE * s, color);
        cx += advance(ch) * s;
    }
}

// ---------------------------------------------------------------- иконки (сетка 16×16)

pub const icon_wifi_dot = [_]Prim{dot(8, 13, 1.5)};
pub const icon_wifi_arcs = [_][1]Prim{
    .{arc(8, 13, 4.2, 225, 315)},
    .{arc(8, 13, 7.6, 225, 315)},
    .{arc(8, 13, 11.0, 225, 315)},
};
pub const icon_slash = [_]Prim{seg(2.5, 2.5, 13.5, 13.5)};

pub const icon_bt = [_]Prim{
    seg(8, 1.5, 8, 14.5),
    seg(8, 1.5, 11.5, 5),
    seg(11.5, 5, 4.5, 11.5),
    seg(8, 14.5, 11.5, 11),
    seg(11.5, 11, 4.5, 4.5),
};
pub const icon_bt_dots = [_]Prim{ dot(2.2, 8, 1.2), dot(13.8, 8, 1.2) };

pub const icon_wall = [_]Prim{
    box(1, 2.5, 14, 11, 2.5),
    seg(3.8, 11, 6.8, 7.3),
    seg(6.8, 7.3, 9.3, 10),
    seg(9.3, 10, 10.8, 8.5),
    seg(10.8, 8.5, 12.4, 10.2),
    dot(10.8, 5.6, 1.3),
};

pub const icon_apps = blk: {
    var a: [9]Prim = undefined;
    for (0..3) |i| {
        for (0..3) |j| {
            a[i * 3 + j] = dot(3 + 5 * @as(f32, @floatFromInt(j)), 3 + 5 * @as(f32, @floatFromInt(i)), 1.55);
        }
    }
    break :blk a;
};

pub const icon_power = [_]Prim{
    arc(8, 8.8, 5.6, -55, 235),
    seg(8, 1.5, 8, 7.5),
};
