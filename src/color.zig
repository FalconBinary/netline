// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Parses colors like "#RRGGBB" and "#RRGGBBAA" into the internal 0xAARRGGBB format.
//! The same function works at compile time (config.zig) and when reading the theme file.

pub fn parse(s: []const u8) ?u32 {
    const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (h.len != 6 and h.len != 8) return null;
    var v: u32 = 0;
    for (h) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = (v << 4) | d;
    }
    if (h.len == 6) return 0xff000000 | v;
    // RRGGBBAA -> AARRGGBB
    return (v >> 8) | ((v & 0xff) << 24);
}

/// A color checked at compile time: a typo in config.zig is a build error.
pub fn hex(comptime s: []const u8) u32 {
    return comptime parse(s) orelse @compileError("invalid color: " ++ s);
}

pub fn alpha(c: u32) u8 {
    return @truncate(c >> 24);
}
