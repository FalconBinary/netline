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
        if (s.cnt > 56) return;
        if (s.src.len - s.pos >= 8) {
            // сразу 8 байт: лишние старшие биты — это те же следующие байты, повторное OR их не портит
            s.buf |= std.mem.readInt(u64, s.src[s.pos..][0..8], .little) << @intCast(s.cnt);
            const n = (63 - s.cnt) >> 3;
            s.pos += n;
            s.cnt += n * 8;
            return;
        }
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
                const o = s.olen;
                if (dist >= len) {
                    @memcpy(s.out[o..][0..len], s.out[o - dist ..][0..len]);
                } else if (dist == 1) {
                    @memset(s.out[o..][0..len], s.out[o - 1]);
                } else {
                    for (o..o + len) |i| s.out[i] = s.out[i - dist]; // перекрытие: строго по байту
                }
                s.olen += len;
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
            const dst = img.px[@as(usize, dy) * w + pass[0] ..];
            pngRow(row, @intCast(pw), dst, pass[2], ctype, depth, &pal, trns_key);
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
    const head = @min(bpp, row.len); // у первых bpp байт нет соседа слева
    switch (ft) {
        0 => {},
        1 => for (head..row.len) |i| {
            row[i] +%= row[i - bpp];
        },
        2 => if (prev) |up| {
            for (row, up[0..row.len]) |*b, u| b.* +%= u;
        },
        3 => if (prev) |up| {
            for (0..head) |i| row[i] +%= up[i] >> 1;
            for (head..row.len) |i| row[i] +%= @intCast((@as(u16, row[i - bpp]) + up[i]) >> 1);
        } else for (head..row.len) |i| {
            row[i] +%= row[i - bpp] >> 1;
        },
        4 => if (prev) |up| {
            for (0..head) |i| row[i] +%= up[i]; // paeth(0, up, 0) = up
            for (head..row.len) |i| row[i] +%= paeth(row[i - bpp], up[i], up[i - bpp]);
        } else for (head..row.len) |i| {
            row[i] +%= row[i - bpp]; // paeth(a, 0, 0) = a
        },
        else => return error.Invalid,
    }
}

/// Строка PNG → пиксели (каждый step-й, начиная с dst[0]). 8 бит без прозрачного ключа —
/// отдельными циклами, остальное — общим путём.
fn pngRow(row: []const u8, n: usize, dst: []u32, step: usize, ctype: u8, depth: u8, pal: *const [256]u32, key: ?[3]u16) void {
    if (depth == 8 and key == null) {
        switch (ctype) {
            6 => for (0..n) |x| {
                const p = row[x * 4 ..][0..4];
                dst[x * step] = (@as(u32, p[3]) << 24) | (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | p[2];
            },
            2 => for (0..n) |x| {
                const p = row[x * 3 ..][0..3];
                dst[x * step] = 0xff000000 | (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | p[2];
            },
            0 => for (0..n) |x| {
                dst[x * step] = 0xff000000 | @as(u32, row[x]) * 0x010101;
            },
            4 => for (0..n) |x| {
                dst[x * step] = (@as(u32, row[x * 2 + 1]) << 24) | @as(u32, row[x * 2]) * 0x010101;
            },
            else => for (0..n) |x| {
                dst[x * step] = pal[row[x]];
            },
        }
        return;
    }
    for (0..n) |x| dst[x * step] = pngPixel(row, x, ctype, depth, pal, key);
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
    // AC целиком за один просмотр: (коэффициент << 8) | (пробег << 4) | (длина кода + биты значения)
    fast_ac: [512]i16 = [_]i16{0} ** 512,
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
        // короткий код и следующие за ним биты значения целиком в 9 битах — значение готово заранее
        for (&h.fast_ac, h.fast, 0..) |*fa, e, i| {
            if (e == 0) continue;
            const len: u32 = e >> 8;
            const rs: u32 = e & 255;
            const mag = rs & 15;
            if (mag == 0 or len + mag > 9) continue;
            const v = ((@as(u32, @intCast(i)) << @intCast(len)) & 511) >> @intCast(9 - mag);
            const val = Jpeg.extend(v, mag);
            if (val >= -128 and val <= 127) fa.* = @intCast(val * 256 + @as(i32, @intCast((rs >> 4) * 16 + len + mag)));
        }
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
    coefs: []i16 = &[_]i16{}, // только для progressive: коэффициенты копятся по сканам
    pred: i32 = 0,
    plane: []u8 = &[_]u8{}, // пиксели компоненты (уже в масштабе 1/scale)
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
    // чтение битов: 64-битный буфер, старший бит — следующий
    bits: u64 = 0,
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
        while (j.cnt <= 56) {
            j.bits |= @as(u64, j.nextByte()) << @intCast(56 - j.cnt);
            j.cnt += 8;
        }
    }
    fn get(j: *Jpeg, n: u32) u32 {
        if (n == 0) return 0;
        if (j.cnt < n) j.fill();
        const v: u32 = @intCast(j.bits >> @intCast(64 - n));
        j.bits <<= @intCast(n);
        j.cnt -= n;
        return v;
    }
    fn decode(j: *Jpeg, h: *const JHuff) Error!u8 {
        if (!h.ok) return error.Invalid;
        if (j.cnt < 16) j.fill();
        const e = h.fast[@intCast(j.bits >> 55)];
        if (e != 0) {
            const l = e >> 8;
            j.bits <<= @intCast(l);
            j.cnt -= l;
            return @truncate(e);
        }
        var l: u32 = 10;
        while (l <= 16) : (l += 1) {
            const code: i32 = @intCast(j.bits >> @intCast(64 - l));
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
        const ac = &j.ac[c.ta];
        if (!ac.ok) return error.Invalid;
        var k: u32 = 1;
        while (k < 64) {
            if (j.cnt < 16) j.fill();
            const fa = ac.fast_ac[@intCast(j.bits >> 55)];
            if (fa != 0) { // частый случай: код и значение за один просмотр
                const len: u6 = @intCast(fa & 15);
                j.bits <<= len;
                j.cnt -= len;
                k += @intCast((fa >> 4) & 15);
                if (k > 63) return error.Invalid;
                if (j.ncoef == 64) blk[zz[k]] = fa >> 8;
                k += 1;
                continue;
            }
            const rs = try j.decode(ac);
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
        const ac = &j.ac[c.ta];
        if (!ac.ok) return error.Invalid;
        var k = ss;
        while (k <= se) {
            if (j.cnt < 16) j.fill();
            const fa = ac.fast_ac[@intCast(j.bits >> 55)];
            if (fa != 0) { // код и значение за один просмотр
                const len: u6 = @intCast(fa & 15);
                j.bits <<= len;
                j.cnt -= len;
                k += @intCast((fa >> 4) & 15);
                if (k > 63) return error.Invalid;
                blk[zz[k]] = @truncate(@as(i32, fa >> 8) * (@as(i32, 1) << al));
                k += 1;
                continue;
            }
            const rs = try j.decode(ac);
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
                try j.unit(c, @intCast(bx), @intCast(by), ss, se, ah, al);
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
                        try j.unit(c, bx, by, ss, se, ah, al);
                    };
                }
            };
        }
        j.skipScan(); // остаток скана (до следующего маркера)
    }

    /// Один блок скана. Baseline — сразу в пиксели (коэффициенты всего кадра не храним:
    /// для 24-мегапиксельного фото это 72 МБ), progressive — в накопитель коэффициентов.
    fn unit(j: *Jpeg, c: *Comp, bx: u32, by: u32, ss: u32, se: u32, ah: u5, al: u5) Error!void {
        if (!j.progressive) {
            var blk = [_]i16{0} ** 64;
            try j.baselineBlock(c, &blk);
            j.putBlock(c, &blk, bx, by);
            return;
        }
        return j.decodeBlock(c, j.block(c, bx, by), ss, se, ah, al);
    }

    /// Коэффициенты блока (обычный порядок) → пиксели плоскости в масштабе 1/scale.
    fn putBlock(j: *const Jpeg, c: *Comp, blk: []const i16, bx: u32, by: u32) void {
        const q = &j.qt[c.tq];
        const n = 8 / j.scale;
        const pw = c.bw * n;
        const out = c.plane[(@as(usize, by) * n) * pw + @as(usize, bx) * n ..];
        if (j.ncoef == 1) { // 1/8 — нужен только DC
            out[0] = dcPixel(dequant(blk[0], q[0]));
            return;
        }
        var d: [64]i32 = undefined;
        for (&d, blk[0..64], q) |*o, v, qq| o.* = dequant(v, qq);
        var ac: i32 = 0;
        for (d[1..]) |v| ac |= v;
        if (ac == 0) { // только DC — блок одного цвета
            const v = dcPixel(d[0]);
            for (0..n) |y| @memset(out[y * pw ..][0..n], v);
            return;
        }
        var px: [64]u8 = undefined;
        idct8(&d, &px);
        if (n == 8) {
            for (0..8) |y| @memcpy(out[y * pw ..][0..8], px[y * 8 ..][0..8]);
            return;
        }
        // уменьшение в scale раз — усреднением квадратов scale×scale
        const sc = j.scale;
        const half = sc * sc / 2;
        for (0..n) |oy| for (0..n) |ox| {
            var sum: u32 = 0;
            for (0..sc) |dy| for (0..sc) |dx| {
                sum += px[(oy * sc + dy) * 8 + ox * sc + dx];
            };
            out[oy * pw + ox] = @intCast((sum + half) / (sc * sc));
        };
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

// ---- обратное DCT: целочисленная схема jidctint (libjpeg) в варианте stb_image —
// около 80 умножений на блок вместо 1024. Арифметика с переносом (+%, *%): специально
// испорченный файл даст мусор в пикселях, но не панику.

fn dequant(v: i16, q: u16) i32 {
    return std.math.clamp(@as(i32, v) * q, -32768, 32767);
}

fn clampU8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// Пиксель блока, у которого есть только DC (как его посчитал бы idct8).
fn dcPixel(dc: i32) u8 {
    return clampU8(((dc *% 16384) +% (65536 + (128 << 17))) >> 17);
}

fn f2f(comptime x: f32) i32 {
    return @intFromFloat(x * 4096 + 0.5);
}

const V8 = @Vector(8, i32);

fn k8(comptime x: f32) V8 {
    return @splat(f2f(x));
}

/// Одномерное 8-точечное обратное DCT сразу для восьми независимых линий (по линии на элемент
/// вектора). Выход: out[0..8] — значения 0..7 (ещё не сдвинутые вниз).
inline fn idct1v(s: [8]V8, out: *[8]V8, bias: i32, comptime shift: u5) void {
    var p1 = (s[2] +% s[6]) *% k8(0.5411961);
    var t2 = p1 +% s[6] *% k8(-1.847759065);
    var t3 = p1 +% s[2] *% k8(0.765366865);
    var t0 = (s[0] +% s[4]) *% @as(V8, @splat(4096));
    var t1 = (s[0] -% s[4]) *% @as(V8, @splat(4096));
    const b: V8 = @splat(bias);
    const x0 = t0 +% t3 +% b;
    const x3 = t0 -% t3 +% b;
    const x1 = t1 +% t2 +% b;
    const x2 = t1 -% t2 +% b;
    t0 = s[7];
    t1 = s[5];
    t2 = s[3];
    t3 = s[1];
    var p3 = t0 +% t2;
    var p4 = t1 +% t3;
    p1 = t0 +% t3;
    var p2 = t1 +% t2;
    const p5 = (p3 +% p4) *% k8(1.175875602);
    t0 = t0 *% k8(0.298631336);
    t1 = t1 *% k8(2.053119869);
    t2 = t2 *% k8(3.072711026);
    t3 = t3 *% k8(1.501321110);
    p1 = p5 +% p1 *% k8(-0.899976223);
    p2 = p5 +% p2 *% k8(-2.562915447);
    p3 = p3 *% k8(-1.961570560);
    p4 = p4 *% k8(-0.390180644);
    t3 = t3 +% p1 +% p4;
    t2 = t2 +% p2 +% p3;
    t1 = t1 +% p2 +% p4;
    t0 = t0 +% p1 +% p3;
    const sh: @Vector(8, u5) = @splat(shift);
    out[0] = (x0 +% t3) >> sh;
    out[7] = (x0 -% t3) >> sh;
    out[1] = (x1 +% t2) >> sh;
    out[6] = (x1 -% t2) >> sh;
    out[2] = (x2 +% t1) >> sh;
    out[5] = (x2 -% t1) >> sh;
    out[3] = (x3 +% t0) >> sh;
    out[4] = (x3 -% t0) >> sh;
}

fn transpose(m: *[8]V8) void {
    var a: [8][8]i32 = undefined;
    for (0..8) |r| a[r] = m[r];
    for (0..8) |r| {
        var v: [8]i32 = undefined;
        for (0..8) |c| v[c] = a[c][r];
        m[r] = v;
    }
}

/// Коэффициенты (обычный порядок, после квантования) → 8×8 пикселей.
/// Сначала все столбцы сразу (строка блока — вектор), потом, после транспонирования, все строки.
fn idct8(d: *const [64]i32, out: *[64]u8) void {
    var rows: [8]V8 = undefined;
    for (0..8) |r| rows[r] = d[r * 8 ..][0..8].*;
    var v: [8]V8 = undefined;
    idct1v(rows, &v, 512, 10); // столбцы: оставляем 2 лишних бита точности
    transpose(&v);
    var o: [8]V8 = undefined;
    idct1v(v, &o, 65536 + (128 << 17), 17); // строки: масштаб 1 << 17 и сдвиг на +128
    transpose(&o); // o[r] — строка r
    const lo: V8 = @splat(0);
    const hi: V8 = @splat(255);
    for (0..8) |r| {
        const px: @Vector(8, u8) = @intCast(@max(lo, @min(hi, o[r])));
        out[r * 8 ..][0..8].* = px;
    }
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
                const n = 8 / j.scale;
                for (j.comps[0..nc]) |*c| {
                    c.bw = j.mcux * c.h;
                    c.bh = j.mcuy * c.v;
                    if (j.progressive) {
                        c.coefs = try alloc(i16, @as(usize, c.bw) * c.bh * j.ncoef);
                        @memset(c.coefs, 0);
                    }
                    c.plane = try alloc(u8, @as(usize, c.bw) * n * c.bh * n);
                    @memset(c.plane, 128); // блоки, которых не было в файле, — серые, как раньше
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

    // ---- progressive: накопленные коэффициенты → плоскости (baseline уже там)
    if (j.progressive) {
        for (j.comps[0..j.ncomp]) |*c| {
            for (0..c.bh) |by| for (0..c.bw) |bx| {
                const blk = j.block(c, @intCast(bx), @intCast(by));
                if (j.ncoef == 1) {
                    var b64 = [_]i16{0} ** 64;
                    b64[0] = blk[0];
                    j.putBlock(c, &b64, @intCast(bx), @intCast(by));
                } else j.putBlock(c, blk, @intCast(bx), @intCast(by));
            };
            free(i16, c.coefs); // до выделения картинки — пиковая память меньше
            c.coefs = &[_]i16{};
        }
    }

    // ---- цвет, построчно
    const s = j.scale;
    const ow = (j.width + s - 1) / s;
    const oh = (j.height + s - 1) / s;
    var img = try newImage(ow, oh);
    errdefer img.deinit();
    var up: [3]Upsample = .{ .{}, .{}, .{} };
    defer for (&up) |*u| u.deinit();
    for (j.comps[0..j.ncomp], 0..) |*c, ci| try up[ci].init(&j, c, ow);
    const rgb = j.ncomp == 3 and (j.adobe == 0 or (j.comps[0].id == 'R' and j.comps[1].id == 'G' and j.comps[2].id == 'B'));
    for (0..oh) |y| {
        const dst = img.px[y * ow ..][0..ow];
        const r0 = up[0].row(&j.comps[0], @intCast(y));
        if (j.ncomp == 1) {
            for (dst, r0) |*o, v| o.* = 0xff000000 | @as(u32, v) * 0x010101;
            continue;
        }
        const r1 = up[1].row(&j.comps[1], @intCast(y));
        const r2 = up[2].row(&j.comps[2], @intCast(y));
        if (rgb) {
            for (dst, r0, r1, r2) |*o, a, b, c| o.* = 0xff000000 | (@as(u32, a) << 16) | (@as(u32, b) << 8) | c;
            continue;
        }
        var x: usize = 0;
        while (x + 8 <= ow) : (x += 8) {
            const Y: V8 = @as(@Vector(8, u8), r0[x..][0..8].*);
            const cb = @as(V8, @as(@Vector(8, u8), r1[x..][0..8].*)) - @as(V8, @splat(128));
            const cr = @as(V8, @as(@Vector(8, u8), r2[x..][0..8].*)) - @as(V8, @splat(128));
            const half: V8 = @splat(32768);
            const sh: @Vector(8, u5) = @splat(16);
            const lo: V8 = @splat(0);
            const hi: V8 = @splat(255);
            const R = @max(lo, @min(hi, Y + ((@as(V8, @splat(91881)) * cr + half) >> sh)));
            const G = @max(lo, @min(hi, Y + ((@as(V8, @splat(-22554)) * cb - @as(V8, @splat(46802)) * cr + half) >> sh)));
            const B = @max(lo, @min(hi, Y + ((@as(V8, @splat(116130)) * cb + half) >> sh)));
            const U = @Vector(8, u32);
            const px = @as(U, @splat(0xff000000)) | (@as(U, @intCast(R)) << @splat(16)) | (@as(U, @intCast(G)) << @splat(8)) | @as(U, @intCast(B));
            dst[x..][0..8].* = px;
        }
        for (dst[x..], r0[x..ow], r1[x..ow], r2[x..ow]) |*o, yy, cbv, crv| {
            const Y: i32 = yy;
            const cb = @as(i32, cbv) - 128;
            const cr = @as(i32, crv) - 128;
            // коэффициенты JFIF в 1/65536, с округлением (как в libjpeg)
            const R: u32 = @intCast(std.math.clamp(Y + ((91881 * cr + 32768) >> 16), 0, 255));
            const G: u32 = @intCast(std.math.clamp(Y + ((-22554 * cb - 46802 * cr + 32768) >> 16), 0, 255));
            const B: u32 = @intCast(std.math.clamp(Y + ((116130 * cb + 32768) >> 16), 0, 255));
            o.* = 0xff000000 | (R << 16) | (G << 8) | B;
        }
    }
    if (j.orientation != 1) {
        const rot = try orient(&img, j.orientation);
        img.deinit();
        return rot;
    }
    return img;
}

/// Строки компоненты на ширине выходной картинки. Полное разрешение — прямо из плоскости,
/// подвыборка цветности — билинейно (центры отсчётов совмещены), веса в 1/256.
const Upsample = struct {
    full: bool = true,
    half: bool = false, // цветность вдвое уже — частый случай 4:2:0 и 4:2:2
    ow: u32 = 0,
    pw: u32 = 0,
    ph: u32 = 0,
    fy: u32 = 0, // шаг по вертикали: v / vmax в 1/65536
    xmap: []u32 = &[_]u32{}, // (x0 << 8) | вес x1
    vrow: []u16 = &[_]u16{},
    out: []u8 = &[_]u8{},

    fn init(u: *Upsample, j: *const Jpeg, c: *const Comp, ow: u32) Error!void {
        const n = 8 / j.scale;
        u.pw = c.bw * n;
        u.ph = c.bh * n;
        u.ow = ow;
        u.full = c.h == j.hmax and c.v == j.vmax;
        if (u.full) return;
        u.fy = (@as(u32, c.v) << 16) / j.vmax;
        u.xmap = try alloc(u32, ow);
        u.vrow = try alloc(u16, u.pw);
        u.out = try alloc(u8, ow);
        const fx = (@as(u32, c.h) << 16) / j.hmax;
        for (u.xmap, 0..) |*m, x| m.* = coord(@intCast(x), fx, u.pw);
        u.half = @as(u32, c.h) * 2 == j.hmax;
    }

    fn deinit(u: *Upsample) void {
        free(u32, u.xmap);
        free(u16, u.vrow);
        free(u8, u.out);
    }

    /// (x + 0,5)·f − 0,5, зажатое в [0, n − 1]: целая часть << 8 | дробная (0..255).
    fn coord(x: u32, f: u32, n: u32) u32 {
        const v: i64 = ((@as(i64, x) * 2 + 1) * f >> 1) - 32768; // в 1/65536
        if (v <= 0) return 0;
        const max = @as(i64, n - 1) << 16;
        const c = @min(v, max);
        return @intCast(((c >> 16) << 8) | ((c >> 8) & 255));
    }

    fn row(u: *Upsample, c: *const Comp, y: u32) []const u8 {
        const p = c.plane;
        if (u.full) return p[@as(usize, @min(y, u.ph - 1)) * u.pw ..][0..u.ow]; // ow ≤ pw: плоскость дополнена до MCU
        const cy = coord(y, u.fy, u.ph);
        const y0 = cy >> 8;
        const wy: u16 = @intCast(cy & 255);
        const r0 = p[@as(usize, y0) * u.pw ..][0..u.pw];
        const r1 = p[@as(usize, @min(y0 + 1, u.ph - 1)) * u.pw ..][0..u.pw];
        for (u.vrow, r0, r1) |*o, a, b| o.* = @as(u16, a) * (256 - wy) + @as(u16, b) * wy;
        if (u.half) {
            // те же веса, что дала бы карта столбцов: 1/4·левый + 3/4·свой и 3/4·свой + 1/4·правый
            const v = u.vrow;
            var i: usize = 0;
            while (2 * i < u.out.len) : (i += 1) {
                const m: u32 = v[i];
                const l: u32 = v[if (i > 0) i - 1 else 0];
                const r: u32 = v[@min(i + 1, v.len - 1)];
                u.out[2 * i] = @intCast((if (i > 0) l * 64 + m * 192 else m * 256) + 32768 >> 16);
                if (2 * i + 1 < u.out.len) u.out[2 * i + 1] = @intCast(m * 192 + r * 64 + 32768 >> 16);
            }
            return u.out;
        }
        for (u.out, u.xmap) |*o, m| {
            const x0 = m >> 8;
            const wx = m & 255;
            const x1 = @min(x0 + 1, u.pw - 1);
            o.* = @intCast((@as(u32, u.vrow[x0]) * (256 - wx) + @as(u32, u.vrow[x1]) * wx + 32768) >> 16);
        }
        return u.out;
    }
};

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

const V4 = @Vector(4, i32);

/// Пиксель → вектор каналов в порядке байтов (B, G, R, A) с предумноженной альфой.
inline fn premulVec(c: u32) V4 {
    const v: V4 = @as(@Vector(4, u8), @bitCast(c));
    if (c >> 24 == 255) return v; // обычный случай — непрозрачный
    const a: V4 = @splat(@intCast(c >> 24));
    var r = @divTrunc(v * a + @as(V4, @splat(127)), @as(V4, @splat(255)));
    r[3] = v[3];
    return r;
}

inline fn pack(v: V4) u32 {
    return @bitCast(@as(@Vector(4, u8), @intCast(v)));
}

/// (acc + 0,5) / 16384, зажатое в 0..255.
inline fn norm(acc: V4) V4 {
    const r = (acc + @as(V4, @splat(8192))) >> @splat(14);
    return @max(@as(V4, @splat(0)), @min(r, @as(V4, @splat(255))));
}

/// Строка исходника → строка ширины rw (горизонтальный проход фильтра), предумноженные пиксели.
fn hpass(srow: []const u32, tx: *const Taps, out: []u32) void {
    for (out, 0..) |*o, x| {
        var acc: V4 = @splat(0);
        const st = tx.start[x];
        const ws = tx.w[x * tx.max ..][0..tx.count[x]];
        for (ws, srow[st..][0..ws.len]) |wgt, p| acc += premulVec(p) * @as(V4, @splat(wgt));
        o.* = pack(norm(acc));
    }
}

/// Вписать картинку в dst (dw×dh): fill — заполнить с обрезкой, fit — целиком с полями цвета bg.
/// Результат непрозрачный: 0xFFRRGGBB (годится и как предумноженный ARGB для Wayland).
///
/// Фильтр разделимый: сначала по строкам, потом по столбцам. Горизонтально отфильтрованные
/// строки живут в маленьком кольце (сколько строк нужно одному выходному пикселю), а не во
/// временном буфере на всю картинку — для 4K это ~200 КБ вместо ~100 МБ.
pub fn render(src: *const Image, dst: []u32, dw: u32, dh: u32, mode: Fit, bg: u32) Error!void {
    return resize(src, dst, dw, dh, mode, bg, false);
}

/// Для иконок: вписать целиком, поля прозрачные, на выходе — предумноженный ARGB с альфой
/// (накладывается через Canvas.argb).
pub fn renderAlpha(src: *const Image, dst: []u32, dw: u32, dh: u32) Error!void {
    return resize(src, dst, dw, dh, .fit, 0, true);
}

fn resize(src: *const Image, dst: []u32, dw: u32, dh: u32, mode: Fit, bg: u32, keep_alpha: bool) Error!void {
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
    if (rw != dw or rh != dh) @memset(dst[0 .. @as(usize, dw) * dh], if (keep_alpha) 0 else opaque_bg); // поля

    var tx = try taps(src.w, rw, kx, ox);
    defer tx.deinit();
    var ty = try taps(src.h, rh, ky, oy);
    defer ty.deinit();

    // кольцо строк: ty.max строк по rw пикселей; slot_row — какая строка исходника в слоте
    const nring = ty.max;
    const ring = try alloc(u32, @as(usize, rw) * nring);
    defer free(u32, ring);
    const slot_row = try alloc(u32, nring);
    defer free(u32, slot_row);
    @memset(slot_row, std.math.maxInt(u32));
    const rows = try alloc([]const u32, nring);
    defer free([]const u32, rows);

    const bgv: V4 = .{ @intCast(bg & 255), @intCast((bg >> 8) & 255), @intCast((bg >> 16) & 255), 0 };
    for (0..rh) |y| {
        const st = ty.start[y];
        const cnt = ty.count[y];
        // нужные строки исходника: каждая фильтруется по горизонтали один раз
        for (0..cnt) |i| {
            const r: u32 = st + @as(u32, @intCast(i));
            const slot = r % nring;
            const line = ring[slot * rw ..][0..rw];
            if (slot_row[slot] != r) {
                hpass(src.px[@as(usize, r) * src.w ..][0..src.w], &tx, line);
                slot_row[slot] = r;
            }
            rows[i] = line;
        }
        const ws = ty.w[y * ty.max ..][0..cnt];
        const out = dst[(ry + y) * dw + rx ..][0..rw];
        for (out, 0..) |*o, x| {
            var acc: V4 = @splat(0);
            for (ws, rows[0..cnt]) |wgt, line| {
                acc += @as(V4, @as(@Vector(4, u8), @bitCast(line[x]))) * @as(V4, @splat(wgt));
            }
            var c = norm(acc);
            if (keep_alpha) {
                c = @min(c, @as(V4, @splat(c[3]))); // предумноженный цвет не ярче альфы
                o.* = pack(c);
                continue;
            }
            if (c[3] != 255) { // полупрозрачный пиксель — поверх фона (альфа уже предумножена)
                const ia: V4 = @splat(255 - c[3]);
                c = @min(c + @divTrunc(bgv * ia + @as(V4, @splat(127)), @as(V4, @splat(255))), @as(V4, @splat(255)));
            }
            o.* = pack(c) | 0xff000000;
        }
    }
}
