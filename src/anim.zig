// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! The slide used by the panel and the menus: time-based, so it takes the same time at any
//! refresh rate, and integer, so a frame that would not move anything sends nothing.
//! Tests: zig test src/anim.zig

const std = @import("std");

pub const Curve = enum {
    /// fast start, long soft stop: how things arrive
    out,
    /// soft start, fast end: how things leave
    in,
};

fn ease(curve: Curve, t: f32) f32 {
    return switch (curve) {
        .out => blk: {
            const u = 1 - t;
            break :blk 1 - u * u * u * u;
        },
        .in => t * t * t,
    };
}

pub const Slide = struct {
    from: i32 = 0,
    to: i32 = 0,
    start_ms: u64 = 0,
    ms: u32 = 0,
    curve: Curve = .out,

    pub fn at(s: Slide, now_ms: u64) i32 {
        if (s.ms == 0) return s.to;
        const passed = now_ms -| s.start_ms;
        if (passed >= s.ms) return s.to;
        const t = @as(f32, @floatFromInt(passed)) / @as(f32, @floatFromInt(s.ms));
        const span: f32 = @floatFromInt(s.to - s.from);
        return s.from + @as(i32, @intFromFloat(@round(span * ease(s.curve, t))));
    }

    pub fn done(s: Slide, now_ms: u64) bool {
        return now_ms -| s.start_ms >= s.ms;
    }
};

/// A slide from `from` to `to`. Interrupted half way, it covers the rest in proportional time,
/// so reversing direction does not slow the movement down. `full` is the whole path in pixels.
pub fn slide(from: i32, to: i32, full: u32, full_ms: u32, curve: Curve, now_ms: u64) Slide {
    const dist: u64 = @abs(to - from);
    const ms: u64 = if (full == 0) 0 else @min(full_ms, full_ms * dist / full);
    return .{ .from = from, .to = to, .start_ms = now_ms, .ms = @intCast(ms), .curve = curve };
}

test "starts and ends exactly at the ends" {
    const s = slide(-40, 6, 46, 240, .out, 1000);
    try std.testing.expectEqual(@as(i32, -40), s.at(1000));
    try std.testing.expectEqual(@as(i32, 6), s.at(1240));
    try std.testing.expectEqual(@as(i32, 6), s.at(99999));
    try std.testing.expect(!s.done(1239));
    try std.testing.expect(s.done(1240));
}

test "moves in one direction without overshoot" {
    inline for (.{ Curve.out, Curve.in }) |curve| {
        const s = slide(-40, 6, 46, 240, curve, 0);
        var prev = s.at(0);
        var t: u64 = 0;
        while (t <= 240) : (t += 1) {
            const y = s.at(t);
            try std.testing.expect(y >= prev and y >= -40 and y <= 6);
            prev = y;
        }
    }
    const back = slide(6, -40, 46, 200, .in, 0);
    try std.testing.expectEqual(@as(i32, 6), back.at(0));
    try std.testing.expectEqual(@as(i32, -40), back.at(200));
}

test "the arriving curve is ahead of the leaving one" {
    const a = slide(0, 100, 100, 100, .out, 0);
    const b = slide(0, 100, 100, 100, .in, 0);
    try std.testing.expect(a.at(30) > 50 and b.at(30) < 50);
}

test "an interrupted slide takes proportional time" {
    const s = slide(-17, 6, 46, 240, .out, 0);
    try std.testing.expectEqual(@as(u32, 120), s.ms);
    try std.testing.expectEqual(@as(u32, 0), slide(6, 6, 46, 240, .out, 0).ms);
    try std.testing.expectEqual(@as(u32, 0), slide(0, 5, 0, 240, .out, 0).ms);
}

test "no animation configured: at the end at once" {
    const s = slide(-40, 6, 46, 0, .out, 500);
    try std.testing.expectEqual(@as(i32, 6), s.at(500));
    try std.testing.expect(s.done(500));
}

test "a clock going backwards does not break it" {
    const s = slide(0, 100, 100, 100, .out, 1000);
    try std.testing.expectEqual(@as(i32, 0), s.at(900));
}
