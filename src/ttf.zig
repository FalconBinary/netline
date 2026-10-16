// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Minimal TrueType engine: font parsing (cmap 4/12, glyf, loca, hmtx), composite glyphs,
//! quadratic curves and rasterization with exact coverage area accounting (no hinting).
//! Every read from the font file is bounds-checked — a broken font can't cause a buffer overrun.

const std = @import("std");
const sys = @import("sys.zig");
const draw = @import("draw.zig");

pub const Font = struct {
    data: []const u8,
    upem: f32,
    loca_long: bool,
    num_glyphs: u32,
    cmap: usize,
    cmap_fmt: u16,
    glyf: usize,
    glyf_len: usize,
    loca: usize,
    hmtx: usize,
    num_hmetrics: u32,
    ascender: f32,
    descender: f32,
    line_gap: f32,

    fn u8at(self: *const Font, off: usize) u8 {
        return if (off < self.data.len) self.data[off] else 0;
    }
    fn u16at(self: *const Font, off: usize) u16 {
        if (off + 2 > self.data.len) return 0;
        return std.mem.readInt(u16, self.data[off..][0..2], .big);
    }
    fn i16at(self: *const Font, off: usize) i16 {
        return @bitCast(self.u16at(off));
    }
    fn u32at(self: *const Font, off: usize) u32 {
        if (off + 4 > self.data.len) return 0;
        return std.mem.readInt(u32, self.data[off..][0..4], .big);
    }

    /// Open a font from memory. null — not TrueType (e.g. CFF/OTF) or a broken file.
    pub fn init(data: []const u8) ?Font {
        var f = Font{
            .data = data,
            .upem = 0,
            .loca_long = false,
            .num_glyphs = 0,
            .cmap = 0,
            .cmap_fmt = 0,
            .glyf = 0,
            .glyf_len = 0,
            .loca = 0,
            .hmtx = 0,
            .num_hmetrics = 0,
            .ascender = 0,
            .descender = 0,
            .line_gap = 0,
        };
        if (data.len < 12) return null;
        const ver = f.u32at(0);
        if (ver != 0x00010000 and ver != 0x74727565) return null; // 'true'; 'OTTO' (CFF) is not supported
        const n = f.u16at(4);
        var head: usize = 0;
        var maxp: usize = 0;
        var hhea: usize = 0;
        var cmap: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = 12 + i * 16;
            if (rec + 16 > data.len) return null;
            const tag = data[rec..][0..4];
            const off = f.u32at(rec + 8);
            const len = f.u32at(rec + 12);
            if (@as(usize, off) + len > data.len) return null;
            if (std.mem.eql(u8, tag, "head")) head = off;
            if (std.mem.eql(u8, tag, "maxp")) maxp = off;
            if (std.mem.eql(u8, tag, "hhea")) hhea = off;
            if (std.mem.eql(u8, tag, "hmtx")) f.hmtx = off;
            if (std.mem.eql(u8, tag, "loca")) f.loca = off;
            if (std.mem.eql(u8, tag, "cmap")) cmap = off;
            if (std.mem.eql(u8, tag, "glyf")) {
                f.glyf = off;
                f.glyf_len = len;
            }
        }
        if (head == 0 or maxp == 0 or hhea == 0 or f.hmtx == 0 or f.loca == 0 or cmap == 0 or f.glyf == 0) return null;
        f.upem = @floatFromInt(f.u16at(head + 18));
        if (f.upem < 16) return null;
        f.loca_long = f.i16at(head + 50) != 0;
        f.num_glyphs = f.u16at(maxp + 4);
        f.ascender = @floatFromInt(f.i16at(hhea + 4));
        f.descender = @floatFromInt(f.i16at(hhea + 6));
        f.line_gap = @floatFromInt(f.i16at(hhea + 8));
        f.num_hmetrics = f.u16at(hhea + 34);
        if (f.num_hmetrics == 0) return null;

        // pick the cmap subtable: full Unicode first (format 12), then BMP (format 4)
        const nsub = f.u16at(cmap + 2);
        var best: usize = 0;
        var best_rank: u8 = 0;
        var k: usize = 0;
        while (k < nsub) : (k += 1) {
            const r = cmap + 4 + k * 8;
            const pid = f.u16at(r);
            const eid = f.u16at(r + 2);
            const sub = cmap + f.u32at(r + 4);
            const fmt = f.u16at(sub);
            const rank: u8 = if (fmt == 12 and (pid == 0 or (pid == 3 and eid == 10))) 3 else if (fmt == 4 and (pid == 0 or (pid == 3 and eid == 1))) 2 else 0;
            if (rank > best_rank) {
                best_rank = rank;
                best = sub;
            }
        }
        if (best_rank == 0) return null;
        f.cmap = best;
        f.cmap_fmt = f.u16at(best);
        return f;
    }

    /// Glyph index for a Unicode character (0 — not in the font).
    pub fn glyphIndex(self: *const Font, cp: u32) u32 {
        const t = self.cmap;
        if (self.cmap_fmt == 12) {
            const ngroups = self.u32at(t + 12);
            var lo: usize = 0;
            var hi: usize = ngroups;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const g = t + 16 + mid * 12;
                const start = self.u32at(g);
                const end = self.u32at(g + 4);
                if (cp < start) hi = mid else if (cp > end) lo = mid + 1 else {
                    const gid = self.u32at(g + 8) + (cp - start);
                    return if (gid < self.num_glyphs) gid else 0;
                }
            }
            return 0;
        }
        // format 4
        if (cp > 0xffff) return 0;
        const segx2 = self.u16at(t + 6);
        const segs = segx2 / 2;
        const ends = t + 14;
        const starts = ends + segx2 + 2;
        const deltas = starts + segx2;
        const ranges = deltas + segx2;
        // the first segment whose end is ≥ cp (ends are ascending) — by binary search
        var lo: usize = 0;
        var hi: usize = segs;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.u16at(ends + mid * 2) < cp) lo = mid + 1 else hi = mid;
        }
        if (lo < segs) {
            const i = lo;
            const start = self.u16at(starts + i * 2);
            if (start > cp) return 0;
            const delta = self.u16at(deltas + i * 2);
            const ro = self.u16at(ranges + i * 2);
            var gid: u32 = 0;
            if (ro == 0) {
                gid = (cp +% delta) & 0xffff;
            } else {
                const addr = ranges + i * 2 + ro + (cp - start) * 2;
                const g = self.u16at(addr);
                if (g == 0) return 0;
                gid = (g +% delta) & 0xffff;
            }
            return if (gid < self.num_glyphs) gid else 0;
        }
        return 0;
    }

    /// Glyph advance in font units.
    pub fn advance(self: *const Font, gid: u32) f32 {
        const i = if (gid < self.num_hmetrics) gid else self.num_hmetrics - 1;
        return @floatFromInt(self.u16at(self.hmtx + i * 4));
    }

    fn glyphRange(self: *const Font, gid: u32) ?[2]usize {
        if (gid >= self.num_glyphs) return null;
        var a: usize = 0;
        var b: usize = 0;
        if (self.loca_long) {
            a = self.u32at(self.loca + gid * 4);
            b = self.u32at(self.loca + gid * 4 + 4);
        } else {
            a = @as(usize, self.u16at(self.loca + gid * 2)) * 2;
            b = @as(usize, self.u16at(self.loca + gid * 2 + 2)) * 2;
        }
        if (b <= a or b > self.glyf_len) return null; // empty glyph (space)
        return .{ self.glyf + a, self.glyf + b };
    }
};

// ================================================================= outlines

const Pt = struct { x: f32, y: f32 };

/// Glyph point transform: scale + offset (+ the composite glyph matrix).
const Xf = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    dx: f32 = 0,
    dy: f32 = 0,

    fn apply(t: Xf, x: f32, y: f32) Pt {
        return .{ .x = t.a * x + t.c * y + t.dx, .y = t.b * x + t.d * y + t.dy };
    }
};

/// Segment sink: rasterizes straight into the accumulation buffer.
const Raster = struct {
    acc: []f32,
    w: usize,
    h: usize,
    sx: f32, // pixels per font unit
    ox: f32, // offset: pixel = (x*sx - ox, oy - y*sx)
    oy: f32,
    // how many more outlines a glyph may consist of: composites referring to composites
    // could otherwise multiply into billions of walks (the depth limit alone doesn't stop that)
    budget: u32 = 64,

    fn toPx(r: *const Raster, p: Pt) Pt {
        return .{ .x = p.x * r.sx - r.ox, .y = r.oy - p.y * r.sx };
    }

    fn quad(r: *Raster, p0: Pt, p1: Pt, p2: Pt) void {
        const a = r.toPx(p0);
        const b = r.toPx(p1);
        const c = r.toPx(p2);
        // number of segments — by the curve's "bend"
        const ddx = a.x - 2 * b.x + c.x;
        const ddy = a.y - 2 * b.y + c.y;
        const dd = @sqrt(ddx * ddx + ddy * ddy);
        const n: u32 = @intFromFloat(std.math.clamp(@ceil(@sqrt(dd * 4)), 1, 24));
        var prev = a;
        var i: u32 = 1;
        while (i <= n) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const mt = 1 - t;
            const q = Pt{
                .x = mt * mt * a.x + 2 * mt * t * b.x + t * t * c.x,
                .y = mt * mt * a.y + 2 * mt * t * b.y + t * t * c.y,
            };
            r.line(prev, q);
            prev = q;
        }
    }

    fn lineFont(r: *Raster, p0: Pt, p1: Pt) void {
        r.line(r.toPx(p0), r.toPx(p1));
    }

    /// Add a segment (in pixels) to the area accumulation buffer.
    fn line(r: *Raster, p0: Pt, p1: Pt) void {
        if (p0.y == p1.y) return;
        var a = p0;
        var b = p1;
        var dir: f32 = 1;
        if (a.y > b.y) {
            const t = a;
            a = b;
            b = t;
            dir = -1;
        }
        const hf: f32 = @floatFromInt(r.h);
        const wf: f32 = @floatFromInt(r.w);
        const dxdy = (b.x - a.x) / (b.y - a.y);
        var x = a.x;
        var y0 = a.y;
        if (y0 < 0) {
            x -= y0 * dxdy;
            y0 = 0;
        }
        const y1 = @min(b.y, hf);
        if (y0 >= y1) return;
        var y: usize = @intFromFloat(@floor(y0));
        const yend: usize = @intFromFloat(@ceil(y1));
        while (y < yend) : (y += 1) {
            const fy: f32 = @floatFromInt(y);
            const dy = @min(fy + 1, y1) - @max(fy, y0);
            const xnext = x + dxdy * dy;
            const d = dy * dir;
            const xa = std.math.clamp(@min(x, xnext), 0, wf - 0.001);
            const xb = std.math.clamp(@max(x, xnext), 0, wf - 0.001);
            const row = y * r.w;
            const x0f = @floor(xa);
            const x0i: usize = @intFromFloat(x0f);
            const x1c = @ceil(xb);
            const x1i: usize = @intFromFloat(x1c);
            if (x1i <= x0i + 1) {
                const xmf = 0.5 * (xa + xb) - x0f;
                r.add(row + x0i, d - d * xmf);
                r.add(row + x0i + 1, d * xmf);
            } else {
                const s = 1 / (xb - xa);
                const fx0 = xa - x0f;
                const a0 = 0.5 * s * (1 - fx0) * (1 - fx0);
                const fx1 = xb - x1c + 1;
                const am = 0.5 * s * fx1 * fx1;
                r.add(row + x0i, d * a0);
                if (x1i == x0i + 2) {
                    r.add(row + x0i + 1, d * (1 - a0 - am));
                } else {
                    const a1 = s * (1.5 - fx0);
                    r.add(row + x0i + 1, d * (a1 - a0));
                    var xi = x0i + 2;
                    while (xi < x1i - 1) : (xi += 1) r.add(row + xi, d * s);
                    const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                    r.add(row + x1i - 1, d * (1 - a2 - am));
                }
                r.add(row + x1i, d * am);
            }
            x = xnext;
        }
    }

    fn add(r: *Raster, i: usize, v: f32) void {
        if (i < r.acc.len) r.acc[i] += v;
    }
};

/// Walk the glyph outlines (including composites) and feed them to the rasterizer.
fn walkGlyph(f: *const Font, gid: u32, xf: Xf, r: *Raster, depth: u32) void {
    if (depth > 6 or r.budget == 0) return;
    r.budget -= 1;
    const range = f.glyphRange(gid) orelse return;
    const g = range[0];
    const end = range[1];
    const ncont = f.i16at(g);
    if (ncont >= 0) {
        simpleGlyph(f, g, end, @intCast(ncont), xf, r);
        return;
    }
    // composite glyph
    var p = g + 10;
    while (p + 4 <= end) {
        const flags = f.u16at(p);
        const sub = f.u16at(p + 2);
        p += 4;
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (flags & 0x1 != 0) { // ARG_1_AND_2_ARE_WORDS
            if (flags & 0x2 != 0) {
                dx = @floatFromInt(f.i16at(p));
                dy = @floatFromInt(f.i16at(p + 2));
            }
            p += 4;
        } else {
            if (flags & 0x2 != 0) {
                dx = @floatFromInt(@as(i8, @bitCast(f.u8at(p))));
                dy = @floatFromInt(@as(i8, @bitCast(f.u8at(p + 1))));
            }
            p += 2;
        }
        var m = Xf{ .dx = dx, .dy = dy };
        if (flags & 0x8 != 0) { // WE_HAVE_A_SCALE
            const s = f2dot14(f.i16at(p));
            m.a = s;
            m.d = s;
            p += 2;
        } else if (flags & 0x40 != 0) { // X_AND_Y_SCALE
            m.a = f2dot14(f.i16at(p));
            m.d = f2dot14(f.i16at(p + 2));
            p += 4;
        } else if (flags & 0x80 != 0) { // TWO_BY_TWO
            m.a = f2dot14(f.i16at(p));
            m.b = f2dot14(f.i16at(p + 2));
            m.c = f2dot14(f.i16at(p + 4));
            m.d = f2dot14(f.i16at(p + 6));
            p += 8;
        }
        // resulting matrix: xf ∘ m
        const comb = Xf{
            .a = xf.a * m.a + xf.c * m.b,
            .b = xf.b * m.a + xf.d * m.b,
            .c = xf.a * m.c + xf.c * m.d,
            .d = xf.b * m.c + xf.d * m.d,
            .dx = xf.a * m.dx + xf.c * m.dy + xf.dx,
            .dy = xf.b * m.dx + xf.d * m.dy + xf.dy,
        };
        walkGlyph(f, sub, comb, r, depth + 1);
        if (flags & 0x20 == 0) break; // MORE_COMPONENTS
    }
}

fn f2dot14(v: i16) f32 {
    return @as(f32, @floatFromInt(v)) / 16384.0;
}

const MAX_PTS = 2048;

fn simpleGlyph(f: *const Font, g: usize, end: usize, ncont: usize, xf: Xf, r: *Raster) void {
    if (ncont == 0) return;
    const ends_off = g + 10;
    const npts_u = @as(usize, f.u16at(ends_off + (ncont - 1) * 2)) + 1;
    if (npts_u > MAX_PTS) return;
    const npts = npts_u;
    const ilen = f.u16at(ends_off + ncont * 2);
    var p = ends_off + ncont * 2 + 2 + ilen;

    var flags: [MAX_PTS]u8 = undefined;
    var i: usize = 0;
    while (i < npts) {
        if (p >= end) return;
        const fl = f.u8at(p);
        p += 1;
        flags[i] = fl;
        i += 1;
        if (fl & 0x8 != 0) { // REPEAT
            if (p >= end) return;
            var rep = f.u8at(p);
            p += 1;
            while (rep > 0 and i < npts) : (rep -= 1) {
                flags[i] = fl;
                i += 1;
            }
        }
    }
    var pts: [MAX_PTS]Pt = undefined;
    var v: i32 = 0;
    for (0..npts) |k| {
        const fl = flags[k];
        if (fl & 0x2 != 0) {
            const d: i32 = f.u8at(p);
            p += 1;
            v += if (fl & 0x10 != 0) d else -d;
        } else if (fl & 0x10 == 0) {
            v += f.i16at(p);
            p += 2;
        }
        pts[k].x = @floatFromInt(v);
    }
    v = 0;
    for (0..npts) |k| {
        const fl = flags[k];
        if (fl & 0x4 != 0) {
            const d: i32 = f.u8at(p);
            p += 1;
            v += if (fl & 0x20 != 0) d else -d;
        } else if (fl & 0x20 == 0) {
            v += f.i16at(p);
            p += 2;
        }
        pts[k].y = @floatFromInt(v);
    }
    if (p > end + 1) return;
    for (0..npts) |k| pts[k] = xf.apply(pts[k].x, pts[k].y);

    var start: usize = 0;
    for (0..ncont) |ci| {
        const last = @as(usize, f.u16at(ends_off + ci * 2));
        if (last < start or last >= npts) return;
        contour(pts[start .. last + 1], flags[start .. last + 1], r);
        start = last + 1;
    }
}

/// One closed contour of on-curve and control points (with implied midpoints).
fn contour(pts: []const Pt, flags: []const u8, r: *Raster) void {
    const n = pts.len;
    if (n < 2) return;
    const on = struct {
        fn f(fl: u8) bool {
            return fl & 1 != 0;
        }
    }.f;
    // the start point is on the curve
    var first: Pt = undefined;
    var si: usize = 0;
    if (on(flags[0])) {
        first = pts[0];
        si = 1;
    } else if (on(flags[n - 1])) {
        first = pts[n - 1];
        si = 0;
    } else {
        first = midpoint(pts[n - 1], pts[0]);
        si = 0;
    }
    var cur = first;
    var ctrl: ?Pt = null;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const idx = (si + k) % n;
        const pt = pts[idx];
        if (on(flags[idx])) {
            if (ctrl) |c| {
                r.quad(cur, c, pt);
                ctrl = null;
            } else r.lineFont(cur, pt);
            cur = pt;
        } else {
            if (ctrl) |c| {
                const m = midpoint(c, pt);
                r.quad(cur, c, m);
                cur = m;
            }
            ctrl = pt;
        }
    }
    if (ctrl) |c| r.quad(cur, c, first) else r.lineFont(cur, first);
}

fn midpoint(a: Pt, b: Pt) Pt {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}

// ================================================================= glyph cache and text

pub const Glyph = struct {
    gid: u32 = 0,
    size: u16 = 0, // 0 — an empty slot (so the zeroed table lives in .bss, not in the file)
    w: u16 = 0,
    h: u16 = 0,
    left: i16 = 0, // bitmap offset from the pen position along X
    top: i16 = 0, // offset of the top edge from the baseline (positive is up)
    off: u32 = 0,
    adv: f32 = 0,
};

const CACHE_N = 512;
var cache: [CACHE_N]Glyph = @as([CACHE_N]Glyph, @splat(.{}));
var pool: [512 * 1024]u8 = undefined;
var pool_used: usize = 0;
var acc_buf: [128 * 128]f32 = undefined;

pub var font: ?Font = null;

fn fnt() ?*const Font {
    return if (font) |*f| f else null;
}

/// Load the first suitable font from the list (the file is memory-mapped).
pub fn load(paths: []const []const u8) bool {
    var buf: [512]u8 = undefined;
    for (paths) |p| {
        const z = sys.joinZ(&buf, &.{p});
        const fd = sys.openRead(z) catch continue;
        defer sys.close(fd);
        const size = sys.fileSize(fd) catch continue;
        if (size < 1024 or size > 64 * 1024 * 1024) continue;
        const mem = sys.mmapRead(size, fd) catch continue;
        const data = mem[0..size];
        if (Font.init(data)) |f| {
            font = f;
            return true;
        }
        sys.munmap(@constCast(mem), size);
    }
    return false;
}

/// A glyph of the given size (in pixels per em) — from the cache or freshly rasterized.
pub fn glyph(gid: u32, size: u16) ?*const Glyph {
    const f = fnt() orelse return null;
    if (size == 0) return null;
    const slot = &cache[@as(usize, (gid *% 2654435761) ^ (@as(u32, size) *% 40503)) % CACHE_N];
    if (slot.gid == gid and slot.size == size) return slot;

    const sx = @as(f32, @floatFromInt(size)) / f.upem;
    var g = Glyph{ .gid = gid, .size = size, .adv = f.advance(gid) * sx };
    if (f.glyphRange(gid)) |range| {
        const xmin: f32 = @floatFromInt(f.i16at(range[0] + 2));
        const ymin: f32 = @floatFromInt(f.i16at(range[0] + 4));
        const xmax: f32 = @floatFromInt(f.i16at(range[0] + 6));
        const ymax: f32 = @floatFromInt(f.i16at(range[0] + 8));
        const left = @floor(xmin * sx) - 1;
        const top = @ceil(ymax * sx) + 1;
        const w_f = @ceil(xmax * sx) + 1 - left + 1;
        const h_f = top - (@floor(ymin * sx) - 1) + 1;
        // a broken bounding box (or a huge one) gets no bitmap, rather than an overflow below
        if (w_f > 0 and h_f > 0 and w_f <= 128 and h_f <= 128 and @abs(left) < 16384 and @abs(top) < 16384) {
            const w: usize = @intFromFloat(w_f);
            const h: usize = @intFromFloat(h_f);
            if (pool_used + w * h > pool.len) { // cache is full — start over
                pool_used = 0;
                for (&cache) |*c| c.* = .{};
            }
            const acc = acc_buf[0 .. w * h];
            @memset(acc, 0);
            var r = Raster{ .acc = acc, .w = w, .h = h, .sx = sx, .ox = left, .oy = top };
            walkGlyph(f, gid, .{}, &r, 0);
            // accumulated areas -> coverage 0..255 (slightly "bolder" for small text)
            const out = pool[pool_used .. pool_used + w * h];
            var s: f32 = 0;
            for (acc, out) |a, *o| {
                s += a;
                const cov = @min(1.0, @abs(s));
                o.* = @intFromFloat(@sqrt(cov) * 0.35 * 255 + cov * 0.65 * 255);
            }
            g.w = @intCast(w);
            g.h = @intCast(h);
            g.left = @intFromFloat(left);
            g.top = @intFromFloat(top);
            g.off = @intCast(pool_used);
            pool_used += w * h;
        }
    }
    slot.* = g;
    return slot;
}

/// UTF-8 decoder (invalid bytes are replaced by U+FFFD).
pub const Utf8 = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(it: *Utf8) ?u32 {
        if (it.i >= it.s.len) return null;
        const c = it.s[it.i];
        const len: usize = if (c < 0x80) 1 else if (c >> 5 == 6) 2 else if (c >> 4 == 14) 3 else if (c >> 3 == 30) 4 else 0;
        if (len == 0 or it.i + len > it.s.len) {
            it.i += 1;
            return 0xfffd;
        }
        var cp: u32 = if (len == 1) c else c & (@as(u8, 0x7f) >> @intCast(len));
        for (1..len) |k| {
            const cc = it.s[it.i + k];
            if (cc >> 6 != 2) {
                it.i += 1;
                return 0xfffd;
            }
            cp = (cp << 6) | (cc & 0x3f);
        }
        it.i += len;
        return cp;
    }
};

/// "Character → glyph index" cache: a cmap lookup for every character of every frame.
/// The slot holds cp + 1 so that the empty (zero) table lives in .bss rather than in the file.
const CpSlot = struct { cp1: u32 = 0, gid: u32 = 0 };
var cp_cache: [512]CpSlot = @as([512]CpSlot, @splat(.{}));

fn glyphFor(cp: u32) u32 {
    const f = fnt() orelse return 0;
    const slot = &cp_cache[(cp *% 2654435761) >> 23];
    if (slot.cp1 == cp +% 1) return slot.gid;
    const g0 = f.glyphIndex(cp);
    const g = if (g0 != 0 or cp == '?') g0 else f.glyphIndex('?');
    slot.* = .{ .cp1 = cp +% 1, .gid = g };
    return g;
}

/// String width in pixels.
pub fn width(s: []const u8, size: u16) f32 {
    var it = Utf8{ .s = s };
    var w: f32 = 0;
    while (it.next()) |cp| {
        if (glyph(glyphFor(cp), size)) |g| w += g.adv;
    }
    return w;
}

/// Height of lowercase/capitals above the baseline (for vertical centering).
pub fn ascent(size: u16) f32 {
    const f = fnt() orelse return @floatFromInt(size);
    return f.ascender * @as(f32, @floatFromInt(size)) / f.upem;
}

/// Draw a string: (x, baseline) is the pen position on the baseline. Returns the new X.
pub fn drawText(cv: *draw.Canvas, s: []const u8, x: f32, baseline: f32, size: u16, color: u32, clip_x1: f32) f32 {
    var it = Utf8{ .s = s };
    var pen = x;
    const by: i32 = @intFromFloat(@round(baseline));
    while (it.next()) |cp| {
        const g = glyph(glyphFor(cp), size) orelse continue;
        if (pen + g.adv > clip_x1) break;
        const gx: i32 = @as(i32, @intFromFloat(@round(pen))) + g.left;
        const gy: i32 = by - g.top;
        if (g.w > 0) {
            const bmp = pool[g.off .. g.off + @as(usize, g.w) * g.h];
            cv.blit(bmp, g.w, g.h, gx, gy, color);
        }
        pen += g.adv;
    }
    return pen;
}
