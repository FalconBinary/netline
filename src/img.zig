// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Декодеры изображений без библиотек: PNG (свой inflate, все типы, Adam7) и JPEG
//! (baseline и progressive, 4:4:4/4:2:2/4:2:0, EXIF-ориентация, масштаб 1/2–1/8 прямо
//! при декодировании) и качественное масштабирование под экран.
//! Все чтения проверяют границы, размеры и объём ограничены: битый файл или «бомба»
//! дают ошибку, а не выход за буфер. Память — из mmap, после использования возвращается.

const std = @import("std");
const sys = @import("sys.zig");

pub const Error = error{ Invalid, Unsupported, TooLarge, NoMem, Io };

pub const MAX_DIM: u32 = 16384;
pub const MAX_PIXELS: u64 = 80 * 1000 * 1000;
pub const MAX_FILE: usize = 128 * 1024 * 1024;

// ================================================================= память

fn alloc(comptime T: type, n: usize) Error![]T {
    if (n == 0) return &[_]T{};
    const bytes = std.math.mul(usize, n, @sizeOf(T)) catch return error.TooLarge;
    const p = sys.mmapAnon(bytes) catch return error.NoMem;
    const t: [*]T = @ptrCast(@alignCast(p));
    return t[0..n];
}

fn free(comptime T: type, s: []T) void {
    if (s.len == 0) return;
    sys.munmap(@ptrCast(s.ptr), s.len * @sizeOf(T));
}

/// Изображение: пиксели 0xAARRGGBB (без предумножения альфы).
pub const Image = struct {
    w: u32 = 0,
    h: u32 = 0,
    px: []u32 = &[_]u32{},

    pub fn deinit(img: *Image) void {
        free(u32, img.px);
        img.* = .{};
    }
};

fn newImage(w: u32, h: u32) Error!Image {
    if (w == 0 or h == 0) return error.Invalid;
    if (w > MAX_DIM or h > MAX_DIM or @as(u64, w) * h > MAX_PIXELS) return error.TooLarge;
    return .{ .w = w, .h = h, .px = try alloc(u32, @as(usize, w) * h) };
}

// ================================================================= загрузка

pub const Format = enum { jpeg, png, unknown };

pub fn sniff(d: []const u8) Format {
    if (d.len >= 3 and d[0] == 0xFF and d[1] == 0xD8 and d[2] == 0xFF) return .jpeg;
    if (d.len >= 8 and std.mem.eql(u8, d[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    return .unknown;
}

/// Прочитать и раскодировать файл. need_w/need_h — сколько пикселей нужно на выходе
/// (JPEG тогда декодируется сразу в 1/2–1/8 размера); 0 — полный размер.
pub fn load(path: [*:0]const u8, need_w: u32, need_h: u32) Error!Image {
    const fd = sys.openRead(path) catch return error.Io;
    defer sys.close(fd);
    const size = sys.fileSize(fd) catch return error.Io;
    if (size < 8) return error.Invalid;
    if (size > MAX_FILE) return error.TooLarge;
    const m = sys.mmapRead(size, fd) catch return error.Io;
    defer sys.munmap(@constCast(m), size);
    return decode(m[0..size], need_w, need_h);
}

pub fn decode(d: []const u8, need_w: u32, need_h: u32) Error!Image {
    return switch (sniff(d)) {
        .jpeg => decodeJpeg(d, need_w, need_h),
        .png => decodePng(d),
        .unknown => error.Unsupported,
    };
}

// ================================================================= inflate (RFC 1951)

const FAST = 9;

const Huff = struct {
    count: [16]u16 = [_]u16{0} ** 16,
    sym: [320]u16 = undefined,
    fast: [1 << FAST]u16 = undefined, // (символ << 4) | длина; 0 — длинный код

    fn build(h: *Huff, lens: []const u8) Error!void {
        h.count = [_]u16{0} ** 16;
        for (lens) |l| {
            if (l > 15) return error.Invalid;
            h.count[l] += 1;
        }
        h.count[0] = 0;
        var left: i32 = 1;
        for (1..16) |len| {
            left <<= 1;
            left -= h.count[len];
            if (left < 0) return error.Invalid; // переподписанный код
        }
        var offs: [16]u16 = undefined;
        offs[1] = 0;
        for (1..15) |len| offs[len + 1] = offs[len] + h.count[len];
        for (lens, 0..) |l, s| {
            if (l != 0) {
                h.sym[offs[l]] = @intCast(s);
                offs[l] += 1;
            }
        }
        @memset(&h.fast, 0);
        var code: u32 = 0;
        var k: usize = 0;
        for (1..16) |len| {
            for (0..h.count[len]) |_| {
                if (len <= FAST) {
                    // коды в потоке идут младшим битом вперёд — разворачиваем
                    var rev: u32 = 0;
                    for (0..len) |b| rev |= ((code >> @intCast(b)) & 1) << @intCast(len - 1 - b);
                    var j: u32 = rev;
                    while (j < (1 << FAST)) : (j += @as(u32, 1) << @intCast(len)) h.fast[j] = @intCast((@as(u32, h.sym[k]) << 4) | @as(u32, @intCast(len)));
                }
                code += 1;
                k += 1;
            }
            code <<= 1;
        }
    }
};

const lbase = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const lext = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dbase = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dext = [_]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

const Inflate = struct {
    src: []const u8,
    pos: usize = 0,
    buf: u64 = 0,
    cnt: u32 = 0,
    padded: u32 = 0, // сколько нулевых бит подставлено за концом входа
    out: []u8,
    olen: usize = 0,

    fn refill(s: *Inflate) void {
        while (s.cnt <= 56) {
            if (s.pos < s.src.len) {
                s.buf |= @as(u64, s.src[s.pos]) << @intCast(s.cnt);
                s.pos += 1;
            } else s.padded += 8;
            s.cnt += 8;
        }
    }

    fn drop(s: *Inflate, n: u32) Error!void {
        s.buf >>= @intCast(n);
        s.cnt -= n;
        if (s.padded > s.cnt) return error.Invalid; // прочитали за концом данных
    }

    fn bits(s: *Inflate, n: u32) Error!u32 {
        if (n == 0) return 0;
        s.refill();
        const v: u32 = @truncate(s.buf & ((@as(u64, 1) << @intCast(n)) - 1));
        try s.drop(n);
        return v;
    }

    fn decode(s: *Inflate, h: *const Huff) Error!u16 {
        s.refill();
        const e = h.fast[@as(usize, @truncate(s.buf & ((1 << FAST) - 1)))];
        if (e != 0) {
            try s.drop(e & 15);
            return e >> 4;
        }
        // длинный код — побитно (как в puff)
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        for (1..16) |len| {
            code |= @intCast(try s.bits(1));
            const count: i32 = h.count[len];
            if (code - count < first) return h.sym[@intCast(index + (code - first))];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return error.Invalid;
    }

    fn put(s: *Inflate, b: u8) Error!void {
        if (s.olen >= s.out.len) return error.TooLarge; // больше, чем должно быть, — бомба
        s.out[s.olen] = b;
        s.olen += 1;
    }

    fn codes(s: *Inflate, lc: *const Huff, dc: *const Huff) Error!void {
        while (true) {
            const sym = try s.decode(lc);
            if (sym < 256) {
                try s.put(@intCast(sym));
            } else if (sym == 256) {
                return;
            } else {
                const li = sym - 257;
                if (li >= lbase.len) return error.Invalid;
                const len = lbase[li] + try s.bits(lext[li]);
                const ds = try s.decode(dc);
                if (ds >= dbase.len) return error.Invalid;
                const dist = dbase[ds] + try s.bits(dext[ds]);
                if (dist > s.olen) return error.Invalid;
                if (s.olen + len > s.out.len) return error.TooLarge;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    s.out[s.olen] = s.out[s.olen - dist];
                    s.olen += 1;
                }
            }
        }
    }

    fn run(s: *Inflate) Error!void {
        var lc: Huff = .{};
        var dc: Huff = .{};
        while (true) {
            const final = try s.bits(1);
            switch (try s.bits(2)) {
                0 => { // без сжатия
                    try s.drop(s.cnt % 8);
                    const len = try s.bits(16);
                    const nlen = try s.bits(16);
                    if (len != (~nlen & 0xffff)) return error.Invalid;
                    for (0..len) |_| try s.put(@intCast(try s.bits(8)));
                },
                1 => { // фиксированные коды
                    var l: [288]u8 = undefined;
                    @memset(l[0..144], 8);
                    @memset(l[144..256], 9);
                    @memset(l[256..280], 7);
                    @memset(l[280..288], 8);
                    try lc.build(&l);
                    var d: [30]u8 = undefined;
                    @memset(&d, 5);
                    try dc.build(&d);
                    try s.codes(&lc, &dc);
                },
                2 => { // динамические коды
                    const nlen = try s.bits(5) + 257;
                    const ndist = try s.bits(5) + 1;
                    const ncode = try s.bits(4) + 4;
                    if (nlen > 286 or ndist > 30) return error.Invalid;
                    const order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
                    var cl = [_]u8{0} ** 19;
                    for (0..ncode) |i| cl[order[i]] = @intCast(try s.bits(3));
                    var ch: Huff = .{};
                    try ch.build(&cl);
                    var lens = [_]u8{0} ** 320;
                    var i: usize = 0;
                    while (i < nlen + ndist) {
                        const sym = try s.decode(&ch);
                        if (sym < 16) {
                            lens[i] = @intCast(sym);
                            i += 1;
                            continue;
                        }
                        var prev: u8 = 0;
                        var rep: u32 = 0;
                        switch (sym) {
                            16 => {
                                if (i == 0) return error.Invalid;
                                prev = lens[i - 1];
                                rep = 3 + try s.bits(2);
                            },
                            17 => rep = 3 + try s.bits(3),
                            else => rep = 11 + try s.bits(7),
                        }
                        if (i + rep > nlen + ndist) return error.Invalid;
                        @memset(lens[i .. i + rep], prev);
                        i += rep;
                    }
                    if (lens[256] == 0) return error.Invalid;
                    try lc.build(lens[0..nlen]);
                    try dc.build(lens[nlen .. nlen + ndist]);
                    try s.codes(&lc, &dc);
                },
                else => return error.Invalid,
            }
            if (final == 1) return;
        }
    }
};

/// Распаковать поток zlib ровно в `out` (его длина — ожидаемый размер).
fn zlibInflate(src: []const u8, out: []u8) Error!void {
    if (src.len < 2) return error.Invalid;
    const cmf = src[0];
    const flg = src[1];
    if (cmf & 15 != 8 or (@as(u32, cmf) * 256 + flg) % 31 != 0 or flg & 0x20 != 0) return error.Invalid;
    var s = Inflate{ .src = src[2..], .out = out };
    try s.run();
    if (s.olen != out.len) return error.Invalid;
}

// ================================================================= PNG

fn be32(d: []const u8, p: usize) u32 {
    return std.mem.readInt(u32, d[p..][0..4], .big);
}

fn decodePng(d: []const u8) Error!Image {
    var p: usize = 8;
    var w: u32 = 0;
    var h: u32 = 0;
    var depth: u8 = 0;
    var ctype: u8 = 0;
    var interlace: u8 = 0;
    var pal: [256]u32 = [_]u32{0xff000000} ** 256;
    var npal: usize = 0;
    var trns_key: ?[3]u16 = null;
    var idat_total: usize = 0;
    var seen_ihdr = false;

    // первый проход: заголовок, палитра, прозрачность, общий размер IDAT
    while (p + 12 <= d.len) {
        const len = be32(d, p);
        if (len > d.len - p - 12) return error.Invalid;
        const typ = d[p + 4 .. p + 8];
        const data = d[p + 8 .. p + 8 + len];
        if (std.mem.eql(u8, typ, "IHDR")) {
            if (len < 13) return error.Invalid;
            w = be32(data, 0);
            h = be32(data, 4);
            depth = data[8];
            ctype = data[9];
            if (data[10] != 0 or data[11] != 0) return error.Invalid;
            interlace = data[12];
            seen_ihdr = true;
        } else if (std.mem.eql(u8, typ, "PLTE")) {
            npal = @min(len / 3, 256);
            for (0..npal) |i| pal[i] = 0xff000000 | (@as(u32, data[i * 3]) << 16) | (@as(u32, data[i * 3 + 1]) << 8) | data[i * 3 + 2];
        } else if (std.mem.eql(u8, typ, "tRNS")) {
            if (ctype == 3) {
                for (0..@min(len, 256)) |i| pal[i] = (pal[i] & 0xffffff) | (@as(u32, data[i]) << 24);
            } else if (ctype == 0 and len >= 2) {
                const v = std.mem.readInt(u16, data[0..2], .big);
                trns_key = .{ v, v, v };
            } else if (ctype == 2 and len >= 6) {
                trns_key = .{ std.mem.readInt(u16, data[0..2], .big), std.mem.readInt(u16, data[2..4], .big), std.mem.readInt(u16, data[4..6], .big) };
            }
        } else if (std.mem.eql(u8, typ, "IDAT")) {
            idat_total += len;
        } else if (std.mem.eql(u8, typ, "IEND")) break;
        p += 12 + len;
    }
    if (!seen_ihdr or idat_total == 0) return error.Invalid;
    const channels: u32 = switch (ctype) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.Invalid,
    };
    const ok_depth = switch (ctype) {
        0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
        3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
        else => depth == 8 or depth == 16,
    };
    if (!ok_depth or interlace > 1) return error.Invalid;
    if (ctype == 3 and npal == 0) return error.Invalid;

    var img = try newImage(w, h);
    errdefer img.deinit();

    // собрать IDAT в один буфер
    const z = try alloc(u8, idat_total);
    defer free(u8, z);
    var zn: usize = 0;
    p = 8;
    while (p + 12 <= d.len) {
        const len = be32(d, p);
        const typ = d[p + 4 .. p + 8];
        if (std.mem.eql(u8, typ, "IDAT")) {
            @memcpy(z[zn .. zn + len], d[p + 8 .. p + 8 + len]);
            zn += len;
        } else if (std.mem.eql(u8, typ, "IEND")) break;
        p += 12 + len;
    }

    const bitspp: u64 = channels * depth;
    const passes = [7][4]u32{ .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 } };
    const npass: usize = if (interlace == 1) 7 else 1;
    var raw_size: u64 = 0;
    for (0..npass) |pi| {
        const pw, const ph = passDims(w, h, if (interlace == 1) passes[pi] else .{ 0, 0, 1, 1 });
        if (pw == 0 or ph == 0) continue;
        raw_size += @as(u64, ph) * (1 + (pw * bitspp + 7) / 8);
    }
    if (raw_size > 1 << 31) return error.TooLarge;
    const raw = try alloc(u8, @intCast(raw_size));
    defer free(u8, raw);
    try zlibInflate(z[0..zn], raw);

    const bpp: usize = @intCast(@max(1, bitspp / 8));
    var off: usize = 0;
    for (0..npass) |pi| {
        const pass = if (interlace == 1) passes[pi] else [4]u32{ 0, 0, 1, 1 };
        const pw, const ph = passDims(w, h, pass);
        if (pw == 0 or ph == 0) continue;
        const stride: usize = @intCast((pw * bitspp + 7) / 8);
        var prev: ?[]u8 = null;
        for (0..ph) |y| {
            const ft = raw[off];
            const row = raw[off + 1 .. off + 1 + stride];
            off += 1 + stride;
            try unfilter(ft, row, prev, bpp);
            prev = row;
            const dy = pass[1] + @as(u32, @intCast(y)) * pass[3];
            for (0..pw) |x| {
                const dx = pass[0] + @as(u32, @intCast(x)) * pass[2];
                img.px[@as(usize, dy) * w + dx] = pngPixel(row, x, ctype, depth, &pal, trns_key);
            }
        }
    }
    return img;
}

fn passDims(w: u32, h: u32, pass: [4]u32) struct { u64, u64 } {
    const pw: u64 = if (w > pass[0]) (w - pass[0] + pass[2] - 1) / pass[2] else 0;
    const ph: u64 = if (h > pass[1]) (h - pass[1] + pass[3] - 1) / pass[3] else 0;
    return .{ pw, ph };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn unfilter(ft: u8, row: []u8, prev: ?[]u8, bpp: usize) Error!void {
    for (row, 0..) |*b, i| {
        const a: u8 = if (i >= bpp) row[i - bpp] else 0;
        const up: u8 = if (prev) |pr| pr[i] else 0;
        const c: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
        b.* = switch (ft) {
            0 => b.*,
            1 => b.* +% a,
            2 => b.* +% up,
            3 => b.* +% @as(u8, @intCast((@as(u16, a) + up) / 2)),
            4 => b.* +% paeth(a, up, c),
            else => return error.Invalid,
        };
    }
}

fn sample(row: []const u8, i: usize, depth: u8) u16 {
    switch (depth) {
        8 => return row[i],
        16 => return std.mem.readInt(u16, row[i * 2 ..][0..2], .big),
        else => {
            const bit = i * depth;
            const shift: u3 = @intCast(8 - depth - (bit % 8));
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(depth)) - 1);
            return (row[bit / 8] >> shift) & mask;
        },
    }
}

fn to8(v: u16, depth: u8) u32 {
    return switch (depth) {
        16 => v >> 8,
        8 => v,
        else => @as(u32, v) * 255 / ((@as(u32, 1) << @intCast(depth)) - 1),
    };
}

fn pngPixel(row: []const u8, x: usize, ctype: u8, depth: u8, pal: *const [256]u32, key: ?[3]u16) u32 {
    switch (ctype) {
        3 => return pal[sample(row, x, depth)],
        0 => {
            const v = sample(row, x, depth);
            const g = to8(v, depth);
            const a: u32 = if (key != null and key.?[0] == v) 0 else 255;
            return (a << 24) | (g << 16) | (g << 8) | g;
        },
        4 => {
            const g = to8(sample(row, x * 2, depth), depth);
            const a = to8(sample(row, x * 2 + 1, depth), depth);
            return (a << 24) | (g << 16) | (g << 8) | g;
        },
        2 => {
            const r = sample(row, x * 3, depth);
            const g = sample(row, x * 3 + 1, depth);
            const b = sample(row, x * 3 + 2, depth);
            const a: u32 = if (key != null and key.?[0] == r and key.?[1] == g and key.?[2] == b) 0 else 255;
            return (a << 24) | (to8(r, depth) << 16) | (to8(g, depth) << 8) | to8(b, depth);
        },
        else => { // 6
            const r = to8(sample(row, x * 4, depth), depth);
            const g = to8(sample(row, x * 4 + 1, depth), depth);
            const b = to8(sample(row, x * 4 + 2, depth), depth);
            const a = to8(sample(row, x * 4 + 3, depth), depth);
            return (a << 24) | (r << 16) | (g << 8) | b;
        },
    }
}

// ================================================================= JPEG

const zz = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

const JHuff = struct {
    fast: [512]u16 = [_]u16{0} ** 512, // (длина << 8) | значение
    maxcode: [18]i32 = [_]i32{-1} ** 18,
    valptr: [17]i32 = [_]i32{0} ** 17,
    vals: [256]u8 = [_]u8{0} ** 256,
    ok: bool = false,

    fn build(h: *JHuff, counts: []const u8, vals: []const u8) Error!void {
        h.* = .{};
        @memcpy(h.vals[0..vals.len], vals);
        var code: i32 = 0;
        var k: i32 = 0;
        for (1..17) |l| {
            const n: i32 = counts[l - 1];
            h.valptr[l] = k - code;
            var i: i32 = 0;
            while (i < n) : (i += 1) {
                if (code >= (@as(i32, 1) << @intCast(l))) return error.Invalid; // переполнение кода
                if (l <= 9) {
                    const lsh: u5 = @intCast(9 - l);
                    const start: u32 = @intCast(code << lsh);
                    for (0..(@as(u32, 1) << lsh)) |j| h.fast[start + j] = @intCast((l << 8) | vals[@intCast(k)]);
                }
                code += 1;
                k += 1;
            }
            h.maxcode[l] = if (n > 0) code - 1 else -1;
            code <<= 1;
        }
        h.maxcode[17] = std.math.maxInt(i32);
        h.ok = true;
    }
};

const Comp = struct {
    id: u8 = 0,
    h: u8 = 1,
    v: u8 = 1,
    tq: u8 = 0,
    td: u8 = 0,
    ta: u8 = 0,
    bw: u32 = 0, // блоков в строке (с дополнением до MCU)
    bh: u32 = 0,
    coefs: []i16 = &[_]i16{},
    pred: i32 = 0,
    plane: []u8 = &[_]u8{},
};

/// Больше стольких байт за концом файла — данные обрезаны (недокачанный файл), а не просто
/// дочитывание битового буфера.
const TRUNC = 64;

const Jpeg = struct {
    d: []const u8,
    pos: usize = 0,
    qt: [4][64]u16 = [_][64]u16{[_]u16{1} ** 64} ** 4,
    dc: [4]JHuff = [_]JHuff{.{}} ** 4,
    ac: [4]JHuff = [_]JHuff{.{}} ** 4,
    comps: [3]Comp = [_]Comp{.{}} ** 3,
    ncomp: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    hmax: u8 = 1,
    vmax: u8 = 1,
    mcux: u32 = 0,
    mcuy: u32 = 0,
    progressive: bool = false,
    restart: u32 = 0,
    adobe: i16 = -1,
    orientation: u8 = 1,
    scale: u32 = 1,
    ncoef: usize = 64,
    eobrun: u32 = 0,
    // чтение битов
    bits: u32 = 0,
    cnt: u32 = 0,
    marker: bool = false,
    past_end: u32 = 0, // сколько байт «дочитали» за концом файла

    fn byte(j: *Jpeg) Error!u8 {
        if (j.pos >= j.d.len) return error.Invalid;
        const b = j.d[j.pos];
        j.pos += 1;
        return b;
    }
    fn u16be(j: *Jpeg) Error!u16 {
        if (j.pos + 2 > j.d.len) return error.Invalid;
        const v = std.mem.readInt(u16, j.d[j.pos..][0..2], .big);
        j.pos += 2;
        return v;
    }

    // ---- энтропийно кодированные данные
    fn nextByte(j: *Jpeg) u8 {
        if (j.pos >= j.d.len) {
            j.past_end +|= 1;
            return 0;
        }
        if (j.marker) return 0;
        const b = j.d[j.pos];
        if (b != 0xFF) {
            j.pos += 1;
            return b;
        }
        if (j.pos + 1 < j.d.len and j.d[j.pos + 1] == 0) {
            j.pos += 2; // FF 00 — это просто байт FF
            return 0xFF;
        }
        j.marker = true; // дошли до маркера: дальше подставляем нули
        return 0;
    }
    fn fill(j: *Jpeg) void {
        while (j.cnt <= 24) {
            j.bits |= @as(u32, j.nextByte()) << @intCast(24 - j.cnt);
            j.cnt += 8;
        }
    }
    fn get(j: *Jpeg, n: u32) u32 {
        if (n == 0) return 0;
        j.fill();
        const v = j.bits >> @intCast(32 - n);
        j.bits <<= @intCast(n);
        j.cnt -= n;
        return v;
    }
    fn decode(j: *Jpeg, h: *const JHuff) Error!u8 {
        if (!h.ok) return error.Invalid;
        j.fill();
        const e = h.fast[j.bits >> 23];
        if (e != 0) {
            const l = e >> 8;
            j.bits <<= @intCast(l);
            j.cnt -= l;
            return @truncate(e);
        }
        var l: u32 = 10;
        while (l <= 16) : (l += 1) {
            const code: i32 = @intCast(j.bits >> @intCast(32 - l));
            if (code <= h.maxcode[l]) {
                const idx = h.valptr[l] + code;
                if (idx < 0 or idx > 255) return error.Invalid;
                j.bits <<= @intCast(l);
                j.cnt -= l;
                return h.vals[@intCast(idx)];
            }
        }
        return error.Invalid;
    }
    fn extend(v: u32, n: u32) i32 {
        if (n == 0) return 0;
        const vi: i32 = @intCast(v);
        return if (v < (@as(u32, 1) << @intCast(n - 1))) vi - (@as(i32, 1) << @intCast(n)) + 1 else vi;
    }

    fn resetBits(j: *Jpeg) void {
        j.bits = 0;
        j.cnt = 0;
        j.marker = false;
    }

    /// Перейти через маркер RSTn (или найти его, если поток повреждён).
    fn restartMarker(j: *Jpeg) void {
        j.resetBits();
        while (j.pos + 1 < j.d.len) : (j.pos += 1) {
            if (j.d[j.pos] == 0xFF and j.d[j.pos + 1] >= 0xD0 and j.d[j.pos + 1] <= 0xD7) {
                j.pos += 2;
                break;
            }
            if (j.d[j.pos] == 0xFF and j.d[j.pos + 1] != 0 and j.d[j.pos + 1] != 0xFF) break; // другой маркер
        }
        for (j.comps[0..j.ncomp]) |*c| c.pred = 0;
        j.eobrun = 0;
    }

    /// Пропустить данные скана до следующего маркера (кроме RSTn).
    fn skipScan(j: *Jpeg) void {
        while (j.pos + 1 < j.d.len) : (j.pos += 1) {
            if (j.d[j.pos] == 0xFF) {
                const m = j.d[j.pos + 1];
                if (m != 0 and !(m >= 0xD0 and m <= 0xD7) and m != 0xFF) return;
            }
        }
        j.pos = j.d.len;
    }

    fn block(j: *Jpeg, c: *Comp, bx: u32, by: u32) []i16 {
        const i = (@as(usize, by) * c.bw + bx) * j.ncoef;
        return c.coefs[i .. i + j.ncoef];
    }

    // ---- декодирование блоков
    fn baselineBlock(j: *Jpeg, c: *Comp, blk: []i16) Error!void {
        const t = try j.decode(&j.dc[c.td]);
        if (t > 16) return error.Invalid;
        c.pred += extend(j.get(t), t);
        blk[0] = @truncate(c.pred);
        var k: u32 = 1;
        while (k < 64) {
            const rs = try j.decode(&j.ac[c.ta]);
            const r = rs >> 4;
            const s = rs & 15;
            if (s == 0) {
                if (r != 15) break;
                k += 16;
                continue;
            }
            k += r;
            if (k > 63) return error.Invalid;
            const v = extend(j.get(s), s);
            if (j.ncoef == 64) blk[zz[k]] = @truncate(v);
            k += 1;
        }
    }

    fn dcFirst(j: *Jpeg, c: *Comp, blk: []i16, al: u5) Error!void {
        const t = try j.decode(&j.dc[c.td]);
        if (t > 16) return error.Invalid;
        c.pred += extend(j.get(t), t);
        blk[0] = @truncate(c.pred * (@as(i32, 1) << al));
    }

    fn dcRefine(j: *Jpeg, blk: []i16, al: u5) void {
        if (j.get(1) != 0) blk[0] |= @as(i16, 1) << @intCast(al);
    }

    fn acFirst(j: *Jpeg, c: *Comp, blk: []i16, ss: u32, se: u32, al: u5) Error!void {
        if (j.eobrun > 0) {
            j.eobrun -= 1;
            return;
        }
        var k = ss;
        while (k <= se) {
            const rs = try j.decode(&j.ac[c.ta]);
            const r = rs >> 4;
            const s = rs & 15;
            if (s == 0) {
                if (r < 15) {
                    j.eobrun = (@as(u32, 1) << @intCast(r)) - 1;
                    if (r > 0) j.eobrun += j.get(r);
                    return;
                }
                k += 16;
                continue;
            }
            k += r;
            if (k > 63) return error.Invalid;
            blk[zz[k]] = @truncate(extend(j.get(s), s) * (@as(i32, 1) << al));
            k += 1;
        }
    }

    fn refineOne(j: *Jpeg, coef: *i16, p1: i16) void {
        if (j.get(1) != 0 and (coef.* & p1) == 0) {
            coef.* += if (coef.* >= 0) p1 else -p1;
        }
    }

    fn acRefine(j: *Jpeg, c: *Comp, blk: []i16, ss: u32, se: u32, al: u5) Error!void {
        const p1: i16 = @as(i16, 1) << @intCast(al);
        var k = ss;
        if (j.eobrun == 0) {
            while (k <= se) : (k += 1) {
                const rs = try j.decode(&j.ac[c.ta]);
                var r: i32 = rs >> 4;
                const s = rs & 15;
                var val: i16 = 0;
                if (s != 0) {
                    val = if (j.get(1) != 0) p1 else -p1;
                } else if (r != 15) {
                    j.eobrun = @as(u32, 1) << @intCast(r);
                    if (r > 0) j.eobrun += j.get(@intCast(r));
                    break;
                }
                // пропускаем r нулевых коэффициентов, уточняя ненулевые по пути
                while (k <= se) {
                    const z = &blk[zz[k]];
                    if (z.* != 0) {
                        j.refineOne(z, p1);
                    } else {
                        if (r == 0) break;
                        r -= 1;
                    }
                    k += 1;
                }
                if (val != 0 and k <= se) blk[zz[k]] = val;
            }
        }
        if (j.eobrun > 0) {
            while (k <= se) : (k += 1) {
                const z = &blk[zz[k]];
                if (z.* != 0) j.refineOne(z, p1);
            }
            j.eobrun -= 1;
        }
    }

    fn scan(j: *Jpeg) Error!void {
        const len = try j.u16be();
        const ns = try j.byte();
        if (ns < 1 or ns > j.ncomp or len != 6 + 2 * @as(u16, ns)) return error.Invalid;
        var sc: [3]*Comp = undefined;
        for (0..ns) |i| {
            const id = try j.byte();
            const t = try j.byte();
            var found: ?*Comp = null;
            for (j.comps[0..j.ncomp]) |*c| {
                if (c.id == id) found = c;
            }
            const c = found orelse return error.Invalid;
            c.td = t >> 4;
            c.ta = t & 15;
            if (c.td > 3 or c.ta > 3) return error.Invalid;
            sc[i] = c;
        }
        const ss = try j.byte();
        const se = try j.byte();
        const a = try j.byte();
        const ah: u5 = @intCast(a >> 4);
        const al: u5 = @intCast(@min(a & 15, 13));
        if (j.progressive) {
            if (ss == 0 and se != 0) return error.Invalid;
            if (ss > 0 and (ns != 1 or se < ss or se > 63)) return error.Invalid;
            // для превью (1/8) нужны только DC — AC-сканы пропускаем целиком
            if (ss > 0 and j.ncoef == 1) return j.skipScan();
        } else if (ss != 0 or se != 63) return error.Invalid;

        j.resetBits();
        j.eobrun = 0;
        for (j.comps[0..j.ncomp]) |*c| c.pred = 0;
        var todo = j.restart;

        if (ns == 1) {
            // не перемежающийся скан: сетка блоков самой компоненты
            const c = sc[0];
            const cw = (j.width * c.h + j.hmax - 1) / j.hmax;
            const ch = (j.height * c.v + j.vmax - 1) / j.vmax;
            const nbx = (cw + 7) / 8;
            const nby = (ch + 7) / 8;
            for (0..nby) |by| for (0..nbx) |bx| {
                if (j.past_end > TRUNC) return error.Invalid; // файл обрезан посреди данных
                if (j.restart > 0) {
                    if (todo == 0) {
                        j.restartMarker();
                        todo = j.restart;
                    }
                    todo -= 1;
                }
                const blk = j.block(c, @intCast(bx), @intCast(by));
                try j.decodeBlock(c, blk, ss, se, ah, al);
            };
        } else {
            for (0..j.mcuy) |my| for (0..j.mcux) |mx| {
                if (j.past_end > TRUNC) return error.Invalid; // файл обрезан посреди данных
                if (j.restart > 0) {
                    if (todo == 0) {
                        j.restartMarker();
                        todo = j.restart;
                    }
                    todo -= 1;
                }
                for (sc[0..ns]) |c| {
                    for (0..c.v) |v| for (0..c.h) |hh| {
                        const bx: u32 = @intCast(mx * c.h + hh);
                        const by: u32 = @intCast(my * c.v + v);
                        try j.decodeBlock(c, j.block(c, bx, by), ss, se, ah, al);
                    };
                }
            };
        }
        j.skipScan(); // остаток скана (до следующего маркера)
    }

    fn decodeBlock(j: *Jpeg, c: *Comp, blk: []i16, ss: u32, se: u32, ah: u5, al: u5) Error!void {
        if (!j.progressive) return j.baselineBlock(c, blk);
        if (ss == 0) {
            if (ah == 0) return j.dcFirst(c, blk, al);
            return j.dcRefine(blk, al);
        }
        if (ah == 0) return j.acFirst(c, blk, ss, se, al);
        return j.acRefine(c, blk, ss, se, al);
    }
};

fn parseExif(d: []const u8) u8 {
    // "Exif\0\0" + TIFF: порядок байт, IFD0, тег 0x0112 (Orientation)
    if (d.len < 14 or !std.mem.eql(u8, d[0..6], "Exif\x00\x00")) return 1;
    const t = d[6..];
    const le = t[0] == 'I';
    if (!(le or t[0] == 'M')) return 1;
    const rd16 = struct {
        fn f(b: []const u8, p: usize, little: bool) ?u16 {
            if (p + 2 > b.len) return null;
            return std.mem.readInt(u16, b[p..][0..2], if (little) .little else .big);
        }
    }.f;
    if (t.len < 8) return 1;
    const ifd = std.mem.readInt(u32, t[4..8], if (le) .little else .big);
    const n = rd16(t, ifd, le) orelse return 1;
    for (0..n) |i| {
        const e = ifd + 2 + i * 12;
        const tag = rd16(t, e, le) orelse return 1;
        if (tag == 0x0112) {
            const v = rd16(t, e + 8, le) orelse return 1;
            return if (v >= 1 and v <= 8) @intCast(v) else 1;
        }
    }
    return 1;
}

// таблица косинусов для обратного DCT: c[u][x] = C(u)·cos((2x+1)uπ/16)/2
const cos_t = blk: {
    @setEvalBranchQuota(20000);
    var t: [8][8]f32 = undefined;
    for (0..8) |u| for (0..8) |x| {
        const cu: f32 = if (u == 0) 0.70710678 else 1.0;
        t[u][x] = cu * @cos(@as(f32, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16.0) / 2.0;
    };
    break :blk t;
};

fn clamp8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v + 128.5, 0, 255));
}

/// Блок → пиксели плоскости (с уменьшением в scale раз усреднением).
fn idctBlock(f: *[64]f32, out: []u8, stride: usize, scale: u32) void {
    const n = 8 / scale;
    var allzero = true;
    for (f[1..]) |v| {
        if (v != 0) {
            allzero = false;
            break;
        }
    }
    if (allzero or scale == 8) {
        const v = clamp8(f[0] / 8);
        for (0..n) |y| @memset(out[y * stride ..][0..n], v);
        return;
    }
    var tmp: [64]f32 = undefined;
    for (0..8) |v| for (0..8) |x| {
        var s: f32 = 0;
        for (0..8) |u| s += f[v * 8 + u] * cos_t[u][x];
        tmp[v * 8 + x] = s;
    };
    var px: [64]f32 = undefined;
    for (0..8) |y| for (0..8) |x| {
        var s: f32 = 0;
        for (0..8) |v| s += tmp[v * 8 + x] * cos_t[v][y];
        px[y * 8 + x] = s;
    };
    const inv: f32 = 1.0 / @as(f32, @floatFromInt(scale * scale));
    for (0..n) |oy| for (0..n) |ox| {
        var s: f32 = 0;
        for (0..scale) |dy| for (0..scale) |dx| {
            s += px[(oy * scale + dy) * 8 + ox * scale + dx];
        };
        out[oy * stride + ox] = clamp8(s * inv);
    };
}

fn decodeJpeg(d: []const u8, need_w0: u32, need_h0: u32) Error!Image {
    var j = Jpeg{ .d = d, .pos = 2 };
    defer for (j.comps[0..j.ncomp]) |*c| {
        free(i16, c.coefs);
        free(u8, c.plane);
    };
    var frame = false;
    var need_w = need_w0;
    var need_h = need_h0;
    // ---- маркеры
    while (true) {
        // ищем 0xFF, пропускаем заполняющие FF
        while (j.pos < d.len and d[j.pos] != 0xFF) j.pos += 1;
        while (j.pos < d.len and d[j.pos] == 0xFF) j.pos += 1;
        if (j.pos >= d.len) break;
        const m = d[j.pos];
        j.pos += 1;
        switch (m) {
            0xD8, 0x01, 0xD0...0xD7 => {},
            0xD9 => break, // EOI
            0xC0, 0xC1, 0xC2 => { // SOF0/1 — последовательный, SOF2 — прогрессивный
                if (frame) return error.Invalid;
                frame = true;
                j.progressive = m == 0xC2;
                const len = try j.u16be();
                const prec = try j.byte();
                if (prec != 8) return error.Unsupported;
                j.height = try j.u16be();
                j.width = try j.u16be();
                const nc = try j.byte();
                if (j.width == 0 or j.height == 0) return error.Unsupported; // DNL не поддерживаем
                if (nc == 4) return error.Unsupported; // CMYK
                if (nc != 1 and nc != 3) return error.Invalid;
                if (len != 8 + 3 * @as(u16, nc)) return error.Invalid;
                if (j.width > MAX_DIM or j.height > MAX_DIM or @as(u64, j.width) * j.height > MAX_PIXELS) return error.TooLarge;
                j.ncomp = nc;
                for (j.comps[0..nc]) |*c| {
                    c.id = try j.byte();
                    const hv = try j.byte();
                    c.h = hv >> 4;
                    c.v = hv & 15;
                    c.tq = try j.byte();
                    if (c.h < 1 or c.h > 4 or c.v < 1 or c.v > 4 or c.tq > 3) return error.Invalid;
                    j.hmax = @max(j.hmax, c.h);
                    j.vmax = @max(j.vmax, c.v);
                }
                if (nc == 1) { // одна компонента: MCU = блок
                    j.comps[0].h = 1;
                    j.comps[0].v = 1;
                    j.hmax = 1;
                    j.vmax = 1;
                }
                j.mcux = (j.width + 8 * @as(u32, j.hmax) - 1) / (8 * @as(u32, j.hmax));
                j.mcuy = (j.height + 8 * @as(u32, j.vmax) - 1) / (8 * @as(u32, j.vmax));
                // масштаб декодирования: наибольший 1/s, при котором картинка не меньше нужной
                if (j.orientation >= 5) std.mem.swap(u32, &need_w, &need_h);
                j.scale = 1;
                if (need_w > 0 and need_h > 0) {
                    for ([_]u32{ 8, 4, 2 }) |s| {
                        if ((j.width + s - 1) / s >= need_w and (j.height + s - 1) / s >= need_h) {
                            j.scale = s;
                            break;
                        }
                    }
                }
                j.ncoef = if (j.scale == 8) 1 else 64;
                for (j.comps[0..nc]) |*c| {
                    c.bw = j.mcux * c.h;
                    c.bh = j.mcuy * c.v;
                    c.coefs = try alloc(i16, @as(usize, c.bw) * c.bh * j.ncoef);
                    @memset(c.coefs, 0);
                }
            },
            0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return error.Unsupported, // lossless, арифметика
            0xC4 => { // DHT
                const len = try j.u16be();
                if (len < 2 or j.pos + len - 2 > d.len) return error.Invalid;
                const end = j.pos + len - 2;
                while (j.pos < end) {
                    const tc = try j.byte();
                    if (j.pos + 16 > end) return error.Invalid;
                    const counts = d[j.pos .. j.pos + 16];
                    j.pos += 16;
                    var total: usize = 0;
                    for (counts) |c| total += c;
                    if (total > 256 or j.pos + total > end) return error.Invalid;
                    const vals = d[j.pos .. j.pos + total];
                    j.pos += total;
                    const id = tc & 15;
                    if (id > 3) return error.Invalid;
                    if (tc >> 4 == 0) try j.dc[id].build(counts, vals) else try j.ac[id].build(counts, vals);
                }
            },
            0xDB => { // DQT
                const len = try j.u16be();
                if (len < 2 or j.pos + len - 2 > d.len) return error.Invalid;
                const end = j.pos + len - 2;
                while (j.pos < end) {
                    const pq = try j.byte();
                    const id = pq & 15;
                    if (id > 3) return error.Invalid;
                    for (0..64) |k| {
                        const v: u16 = if (pq >> 4 == 0) try j.byte() else try j.u16be();
                        j.qt[id][zz[k]] = v;
                    }
                }
            },
            0xDD => { // DRI
                _ = try j.u16be();
                j.restart = try j.u16be();
            },
            0xDA => {
                if (!frame) return error.Invalid;
                try j.scan();
            },
            else => { // APPn, COM и прочее: смотрим только EXIF и Adobe
                const len = try j.u16be();
                if (len < 2 or j.pos + len - 2 > d.len) return error.Invalid;
                const body = d[j.pos .. j.pos + len - 2];
                if (m == 0xE1 and !frame) j.orientation = parseExif(body);
                if (m == 0xEE and body.len >= 12 and std.mem.eql(u8, body[0..5], "Adobe")) j.adobe = body[11];
                j.pos += len - 2;
            },
        }
    }
    if (!frame) return error.Invalid;

    // ---- коэффициенты → плоскости
    const s = j.scale;
    const n = 8 / s;
    for (j.comps[0..j.ncomp]) |*c| {
        const pw = c.bw * n;
        c.plane = try alloc(u8, @as(usize, pw) * c.bh * n);
        const q = &j.qt[c.tq];
        var f: [64]f32 = undefined;
        for (0..c.bh) |by| for (0..c.bw) |bx| {
            const blk = j.block(c, @intCast(bx), @intCast(by));
            if (j.ncoef == 1) {
                @memset(&f, 0);
                f[0] = @as(f32, @floatFromInt(blk[0])) * @as(f32, @floatFromInt(q[0]));
            } else for (0..64) |k| {
                f[k] = @as(f32, @floatFromInt(blk[k])) * @as(f32, @floatFromInt(q[k]));
            }
            idctBlock(&f, c.plane[(by * n) * pw + bx * n ..], pw, s);
        };
    }

    // ---- цвет
    const ow = (j.width + s - 1) / s;
    const oh = (j.height + s - 1) / s;
    var img = try newImage(ow, oh);
    errdefer img.deinit();
    const rgb = j.ncomp == 3 and (j.adobe == 0 or (j.comps[0].id == 'R' and j.comps[1].id == 'G' and j.comps[2].id == 'B'));
    for (0..oh) |y| for (0..ow) |x| {
        var v: [3]i32 = .{ 0, 0, 0 };
        for (j.comps[0..j.ncomp], 0..) |*c, ci| v[ci] = sampleComp(&j, c, @intCast(x), @intCast(y));
        var r: i32 = v[0];
        var g: i32 = v[0];
        var b: i32 = v[0];
        if (j.ncomp == 3 and rgb) {
            g = v[1];
            b = v[2];
        } else if (j.ncomp == 3) {
            const cb = v[1] - 128;
            const cr = v[2] - 128;
            r = v[0] + ((91881 * cr) >> 16);
            g = v[0] - ((22554 * cb + 46802 * cr) >> 16);
            b = v[0] + ((116130 * cb) >> 16);
        }
        const R: u32 = @intCast(std.math.clamp(r, 0, 255));
        const G: u32 = @intCast(std.math.clamp(g, 0, 255));
        const B: u32 = @intCast(std.math.clamp(b, 0, 255));
        img.px[y * ow + x] = 0xff000000 | (R << 16) | (G << 8) | B;
    };
    if (j.orientation != 1) {
        const rot = try orient(&img, j.orientation);
        img.deinit();
        return rot;
    }
    return img;
}

/// Значение компоненты в точке выходного изображения (с билинейной подвыборкой цветности).
fn sampleComp(j: *const Jpeg, c: *const Comp, x: u32, y: u32) i32 {
    const n = 8 / j.scale;
    const pw = c.bw * n;
    const ph = c.bh * n;
    if (c.h == j.hmax and c.v == j.vmax) {
        return c.plane[@min(y, ph - 1) * pw + @min(x, pw - 1)];
    }
    const fx = (@as(f32, @floatFromInt(x)) + 0.5) * @as(f32, @floatFromInt(c.h)) / @as(f32, @floatFromInt(j.hmax)) - 0.5;
    const fy = (@as(f32, @floatFromInt(y)) + 0.5) * @as(f32, @floatFromInt(c.v)) / @as(f32, @floatFromInt(j.vmax)) - 0.5;
    const cx = std.math.clamp(fx, 0, @as(f32, @floatFromInt(pw - 1)));
    const cy = std.math.clamp(fy, 0, @as(f32, @floatFromInt(ph - 1)));
    const x0: u32 = @intFromFloat(@floor(cx));
    const y0: u32 = @intFromFloat(@floor(cy));
    const x1 = @min(x0 + 1, pw - 1);
    const y1 = @min(y0 + 1, ph - 1);
    const ax = cx - @as(f32, @floatFromInt(x0));
    const ay = cy - @as(f32, @floatFromInt(y0));
    const p = c.plane;
    const a = @as(f32, @floatFromInt(p[y0 * pw + x0])) * (1 - ax) + @as(f32, @floatFromInt(p[y0 * pw + x1])) * ax;
    const b = @as(f32, @floatFromInt(p[y1 * pw + x0])) * (1 - ax) + @as(f32, @floatFromInt(p[y1 * pw + x1])) * ax;
    return @intFromFloat(a * (1 - ay) + b * ay + 0.5);
}

/// Повернуть/отразить по EXIF Orientation (2–8).
fn orient(src: *const Image, o: u8) Error!Image {
    const W = src.w;
    const H = src.h;
    const swap = o >= 5;
    var dst = try newImage(if (swap) H else W, if (swap) W else H);
    for (0..dst.h) |y| for (0..dst.w) |x| {
        const X: u32 = @intCast(x);
        const Y: u32 = @intCast(y);
        const sx: u32, const sy: u32 = switch (o) {
            2 => .{ W - 1 - X, Y },
            3 => .{ W - 1 - X, H - 1 - Y },
            4 => .{ X, H - 1 - Y },
            5 => .{ Y, X },
            6 => .{ Y, H - 1 - X },
            7 => .{ W - 1 - Y, H - 1 - X },
            else => .{ W - 1 - Y, X }, // 8
        };
        dst.px[y * dst.w + x] = src.px[sy * W + sx];
    };
    return dst;
}

// ================================================================= масштабирование

pub const Fit = enum { fill, fit };

const Taps = struct {
    start: []u32,
    count: []u32,
    w: []i32, // веса, сумма = 1 << 14
    max: usize,

    fn deinit(t: *Taps) void {
        free(u32, t.start);
        free(u32, t.count);
        free(i32, t.w);
    }
};

/// Веса фильтра «треугольник», расширенного при уменьшении (качественное усреднение).
fn taps(n_src: u32, m: u32, k: f64, offset: f64) Error!Taps {
    const support = @max(1.0, 1.0 / k);
    const max: usize = @intFromFloat(@ceil(support * 2) + 2);
    var t = Taps{ .start = try alloc(u32, m), .count = try alloc(u32, m), .w = try alloc(i32, m * max), .max = max };
    errdefer t.deinit();
    var wf: [4096]f64 = undefined;
    if (max > wf.len) return error.TooLarge;
    for (0..m) |j| {
        const center = offset + (@as(f64, @floatFromInt(j)) + 0.5) / k;
        var lo: i64 = @intFromFloat(@floor(center - support));
        var hi: i64 = @intFromFloat(@ceil(center + support));
        lo = @max(lo, 0);
        hi = @min(hi, @as(i64, n_src));
        if (hi <= lo) {
            lo = std.math.clamp(@as(i64, @intFromFloat(center)), 0, @as(i64, n_src) - 1);
            hi = lo + 1;
        }
        var cnt: usize = @intCast(hi - lo);
        if (cnt > max) cnt = max;
        var sum: f64 = 0;
        for (0..cnt) |i| {
            const pos = @as(f64, @floatFromInt(lo + @as(i64, @intCast(i)))) + 0.5;
            const v = @max(0.0, 1.0 - @abs(pos - center) / support);
            wf[i] = v;
            sum += v;
        }
        if (sum <= 0) {
            wf[0] = 1;
            sum = 1;
            cnt = 1;
        }
        t.start[j] = @intCast(lo);
        t.count[j] = @intCast(cnt);
        var acc: i32 = 0;
        for (0..cnt) |i| {
            const q: i32 = @intFromFloat(@round(wf[i] / sum * 16384));
            t.w[j * max + i] = q;
            acc += q;
        }
        t.w[j * max] += 16384 - acc; // точная сумма
    }
    return t;
}

fn premulPx(c: u32) [4]i32 {
    const a: i32 = @intCast(c >> 24);
    if (a == 255) return .{ @intCast((c >> 16) & 255), @intCast((c >> 8) & 255), @intCast(c & 255), 255 }; // обычный случай
    return .{
        @divTrunc(@as(i32, @intCast((c >> 16) & 255)) * a + 127, 255),
        @divTrunc(@as(i32, @intCast((c >> 8) & 255)) * a + 127, 255),
        @divTrunc(@as(i32, @intCast(c & 255)) * a + 127, 255),
        a,
    };
}

/// Вписать картинку в dst (dw×dh): fill — заполнить с обрезкой, fit — целиком с полями цвета bg.
/// Результат непрозрачный: 0xFFRRGGBB (годится и как предумноженный ARGB для Wayland).
pub fn render(src: *const Image, dst: []u32, dw: u32, dh: u32, mode: Fit, bg: u32) Error!void {
    const sw: f64 = @floatFromInt(src.w);
    const sh: f64 = @floatFromInt(src.h);
    const fw: f64 = @floatFromInt(dw);
    const fh: f64 = @floatFromInt(dh);
    const k = if (mode == .fill) @max(fw / sw, fh / sh) else @min(fw / sw, fh / sh);
    // область назначения (для fit — по центру) и смещение в исходнике (для fill — обрезка)
    const rw: u32 = if (mode == .fill) dw else @max(1, @min(dw, @as(u32, @intFromFloat(@round(sw * k)))));
    const rh: u32 = if (mode == .fill) dh else @max(1, @min(dh, @as(u32, @intFromFloat(@round(sh * k)))));
    const rx = (dw - rw) / 2;
    const ry = (dh - rh) / 2;
    const ox = if (mode == .fill) (sw - fw / k) / 2 else 0;
    const oy = if (mode == .fill) (sh - fh / k) / 2 else 0;
    const kx = if (mode == .fill) k else @as(f64, @floatFromInt(rw)) / sw;
    const ky = if (mode == .fill) k else @as(f64, @floatFromInt(rh)) / sh;

    const opaque_bg = 0xff000000 | bg;
    @memset(dst[0 .. @as(usize, dw) * dh], opaque_bg);

    var tx = try taps(src.w, rw, kx, ox);
    defer tx.deinit();
    var ty = try taps(src.h, rh, ky, oy);
    defer ty.deinit();

    // нужные строки исходника
    var y0: u32 = src.h;
    var y1: u32 = 0;
    for (0..rh) |i| {
        y0 = @min(y0, ty.start[i]);
        y1 = @max(y1, ty.start[i] + ty.count[i]);
    }
    const rows = y1 - y0;
    // промежуточный буфер: rw × rows, 4 канала в предумноженном виде
    const tmp = try alloc([4]i16, @as(usize, rw) * rows);
    defer free([4]i16, tmp);
    for (0..rows) |r| {
        const srow = src.px[(y0 + r) * src.w ..][0..src.w];
        for (0..rw) |x| {
            var acc: [4]i32 = .{ 0, 0, 0, 0 };
            const st = tx.start[x];
            for (0..tx.count[x]) |i| {
                const wgt = tx.w[x * tx.max + i];
                const p = premulPx(srow[st + i]);
                inline for (0..4) |ch| acc[ch] += p[ch] * wgt;
            }
            var o: [4]i16 = undefined;
            inline for (0..4) |ch| o[ch] = @intCast(std.math.clamp((acc[ch] + 8192) >> 14, 0, 255));
            tmp[r * rw + x] = o;
        }
    }
    const br: i32 = @intCast((bg >> 16) & 255);
    const bgc: i32 = @intCast((bg >> 8) & 255);
    const bb: i32 = @intCast(bg & 255);
    for (0..rh) |y| {
        const st = ty.start[y] - y0;
        for (0..rw) |x| {
            var acc: [4]i32 = .{ 0, 0, 0, 0 };
            for (0..ty.count[y]) |i| {
                const wgt = ty.w[y * ty.max + i];
                const p = tmp[(st + i) * rw + x];
                inline for (0..4) |ch| acc[ch] += @as(i32, p[ch]) * wgt;
            }
            var c: [4]i32 = undefined;
            inline for (0..4) |ch| c[ch] = std.math.clamp((acc[ch] + 8192) >> 14, 0, 255);
            if (c[3] == 255) { // непрозрачный пиксель — фон не нужен
                dst[(ry + y) * dw + rx + x] = 0xff000000 | (@as(u32, @intCast(c[0])) << 16) | (@as(u32, @intCast(c[1])) << 8) | @as(u32, @intCast(c[2]));
                continue;
            }
            // поверх фона (альфа уже предумножена)
            const ia = 255 - c[3];
            const R: u32 = @intCast(@min(255, c[0] + @divTrunc(br * ia + 127, 255)));
            const G: u32 = @intCast(@min(255, c[1] + @divTrunc(bgc * ia + 127, 255)));
            const B: u32 = @intCast(@min(255, c[2] + @divTrunc(bb * ia + 127, 255)));
            dst[(ry + y) * dw + rx + x] = 0xff000000 | (R << 16) | (G << 8) | B;
        }
    }
}
