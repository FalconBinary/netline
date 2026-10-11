// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Локальное время без libc: разбор /etc/localtime (TZif v1–v4) и POSIX-строки TZ
//! из его хвоста (нужно для «тонких» tzdata, где переходы на будущее не записаны).
//! Все смещения проверяются по длине файла; при неудачной перезагрузке остаются старые данные.

const std = @import("std");
const sys = @import("sys.zig");

const Rule = struct {
    // тип даты: 'M' — Mm.w.d, 'J' — Jn (без 29 февраля), 'N' — n (с нуля, с 29 февраля)
    kind: u8 = 'M',
    m: u8 = 0,
    w: u8 = 0,
    d: u8 = 0,
    n: u16 = 0,
    time: i32 = 7200, // секунды от полуночи (местное время)
};

const Posix = struct {
    valid: bool = false,
    std_off: i32 = 0, // смещение от UTC, сек (уже с «нормальным» знаком)
    has_dst: bool = false,
    dst_off: i32 = 0,
    start: Rule = .{},
    end: Rule = .{},
};

const State = struct {
    data: []const u8 = &[_]u8{},
    times_off: usize = 0,
    idx_off: usize = 0,
    types_off: usize = 0,
    timecnt: usize = 0,
    typecnt: usize = 0,
    tsize: usize = 4,
    posix: Posix = .{},
};

var cur: State = .{};
var active_buf: [64 * 1024]u8 = undefined;
var scratch: [64 * 1024]u8 = undefined;
var path_buf: [512]u8 = undefined;
/// Путь к файлу зоны, который читается (нужен для правил песочницы).
pub var path: [:0]const u8 = "/etc/localtime";
var loaded = false;

pub fn load() void {
    loaded = true;
    var st: State = .{};
    if (sys.getenv("TZ")) |tz_raw| {
        const tz = if (tz_raw.len > 0 and tz_raw[0] == ':') tz_raw[1..] else tz_raw;
        if (tz.len == 0) { // TZ="" — UTC
            cur = .{};
            return;
        }
        path = if (tz[0] == '/') sys.joinZ(&path_buf, &.{tz}) else sys.joinZ(&path_buf, &.{ "/usr/share/zoneinfo/", tz });
        if (sys.readFile(path, &scratch)) |d| {
            if (parseTzif(d, &st)) return commit(d, st);
        }
        // возможно, это сама POSIX-строка вида "CET-1CEST,M3.5.0,M10.5.0/3"
        const px = parsePosix(tz);
        if (px.valid) cur = .{ .posix = px };
        return;
    }
    path = "/etc/localtime";
    if (sys.readFile(path, &scratch)) |d| {
        if (parseTzif(d, &st)) commit(d, st);
    }
}

fn commit(d: []const u8, st0: State) void {
    var st = st0;
    @memcpy(active_buf[0..d.len], d);
    st.data = active_buf[0..d.len];
    cur = st;
}

fn be32(d: []const u8, p: usize) u32 {
    return std.mem.readInt(u32, d[p..][0..4], .big);
}

const Counts = struct { isutcnt: usize, isstdcnt: usize, leapcnt: usize, timecnt: usize, typecnt: usize, charcnt: usize };

fn readCounts(d: []const u8, hdr: usize) ?Counts {
    if (hdr > d.len or d.len - hdr < 44 or !std.mem.eql(u8, d[hdr..][0..4], "TZif")) return null;
    return .{
        .isutcnt = be32(d, hdr + 20),
        .isstdcnt = be32(d, hdr + 24),
        .leapcnt = be32(d, hdr + 28),
        .timecnt = be32(d, hdr + 32),
        .typecnt = be32(d, hdr + 36),
        .charcnt = be32(d, hdr + 40),
    };
}

fn blockSize(c: Counts, tsize: usize) usize {
    return c.timecnt * (tsize + 1) + c.typecnt * 6 + c.charcnt + c.leapcnt * (tsize + 4) + c.isstdcnt + c.isutcnt;
}

fn parseTzif(d: []const u8, st: *State) bool {
    var cnt = readCounts(d, 0) orelse return false;
    const version = d[4];
    var hdr: usize = 0;
    st.tsize = 4;
    if (version >= '2') {
        // пропускаем блок v1 и берём 64-битный блок v2+
        hdr = 44 + blockSize(cnt, 4);
        cnt = readCounts(d, hdr) orelse return false;
        st.tsize = 8;
    }
    if (cnt.typecnt == 0 or cnt.typecnt > 256 or cnt.timecnt > 8192) return false;
    const end = hdr + 44 + blockSize(cnt, st.tsize);
    if (end > d.len) return false;
    st.timecnt = cnt.timecnt;
    st.typecnt = cnt.typecnt;
    st.times_off = hdr + 44;
    st.idx_off = st.times_off + cnt.timecnt * st.tsize;
    st.types_off = st.idx_off + cnt.timecnt;
    // индексы типов должны указывать на существующие типы
    for (d[st.idx_off..st.types_off]) |ti| if (ti >= cnt.typecnt) return false;
    // хвост: "\n<POSIX TZ>\n"
    if (version >= '2' and end + 1 < d.len and d[end] == '\n') {
        const rest = d[end + 1 ..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        st.posix = parsePosix(rest[0..nl]);
    }
    st.data = d;
    return true;
}

fn transition(i: usize) i64 {
    const p = cur.times_off + i * cur.tsize;
    if (cur.tsize == 8) return std.mem.readInt(i64, cur.data[p..][0..8], .big);
    return @as(i32, @bitCast(be32(cur.data, p)));
}

fn typeOffset(t: usize) i32 {
    return @bitCast(be32(cur.data, cur.types_off + t * 6));
}

/// Смещение местного времени от UTC (в секундах) в момент `t`.
pub fn offsetAt(t: i64) i32 {
    if (!loaded) load();
    if (cur.typecnt > 0) {
        if (cur.timecnt == 0 or t < transition(0)) {
            if (cur.timecnt == 0 and cur.posix.valid) return posixOffset(t);
            return typeOffset(0);
        }
        if (t >= transition(cur.timecnt - 1) and cur.posix.valid) return posixOffset(t);
        // двоичный поиск последнего перехода <= t
        var lo: usize = 0;
        var hi: usize = cur.timecnt;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (transition(mid) <= t) lo = mid else hi = mid;
        }
        return typeOffset(cur.data[cur.idx_off + lo]);
    }
    if (cur.posix.valid) return posixOffset(t);
    return 0;
}

// ---------------------------------------------------------------- календарь

/// Дни от 1970-01-01 (алгоритм Х. Хиннанта).
pub fn daysFromCivil(y0: i64, m: u32, d: u32) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @intCast((m + 9) % 12);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Date = struct { year: i64, month: u32, day: u32 };

pub fn civilFromDays(z0: i64) Date {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0), .month = m, .day = d };
}

fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn daysInMonth(y: i64, m: u32) u32 {
    const t = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (m == 2 and isLeap(y)) return 29;
    return t[m - 1];
}

/// Момент (в «локальных секундах» от эпохи) срабатывания правила в году y.
fn ruleTime(r: Rule, y: i64) i64 {
    const jan1 = daysFromCivil(y, 1, 1);
    var day: i64 = 0;
    switch (r.kind) {
        'J' => {
            day = jan1 + @as(i64, r.n) - 1;
            if (isLeap(y) and r.n >= 60) day += 1;
        },
        'N' => day = jan1 + r.n,
        else => {
            const first = daysFromCivil(y, r.m, 1);
            const wd: i64 = @mod(first + 4, 7); // 1970-01-01 — четверг
            var md: i64 = 1 + @mod(@as(i64, r.d) - wd + 7, 7) + (@as(i64, r.w) - 1) * 7;
            while (md > daysInMonth(y, r.m)) md -= 7;
            day = first + md - 1;
        },
    }
    return day * 86400 + r.time;
}

fn posixOffset(t: i64) i32 {
    const px = cur.posix;
    if (!px.has_dst) return px.std_off;
    const y = civilFromDays(@divFloor(t + px.std_off, 86400)).year;
    const start = ruleTime(px.start, y) - px.std_off; // в UTC
    const end = ruleTime(px.end, y) - px.dst_off;
    const dst = if (start < end) (t >= start and t < end) else !(t >= end and t < start);
    return if (dst) px.dst_off else px.std_off;
}

// ---------------------------------------------------------------- POSIX TZ

const P = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(self: *P) u8 {
        return if (self.i < self.s.len) self.s[self.i] else 0;
    }
    fn name(self: *P) bool {
        if (self.peek() == '<') {
            while (self.i < self.s.len and self.s[self.i] != '>') self.i += 1;
            if (self.peek() != '>') return false;
            self.i += 1;
            return true;
        }
        const st = self.i;
        while (std.ascii.isAlphabetic(self.peek())) self.i += 1;
        return self.i - st >= 3;
    }
    fn num(self: *P) ?i32 {
        var v: i32 = 0;
        const st = self.i;
        while (std.ascii.isDigit(self.peek())) {
            v = (v *| 10) +| (self.peek() - '0');
            self.i += 1;
        }
        return if (self.i == st) null else v;
    }
    /// [+-]hh[:mm[:ss]] -> секунды (часы ограничены 167, как в POSIX)
    fn hms(self: *P) ?i32 {
        var sign: i32 = 1;
        if (self.peek() == '+') self.i += 1 else if (self.peek() == '-') {
            sign = -1;
            self.i += 1;
        }
        const h = self.num() orelse return null;
        if (h > 167) return null;
        var v = h * 3600;
        if (self.peek() == ':') {
            self.i += 1;
            v += @min(self.num() orelse return null, 59) * 60;
            if (self.peek() == ':') {
                self.i += 1;
                v += @min(self.num() orelse return null, 59);
            }
        }
        return sign * v;
    }
    fn rule(self: *P) ?Rule {
        var r = Rule{};
        if (self.peek() == 'M') {
            self.i += 1;
            const m = self.num() orelse return null;
            if (self.peek() != '.') return null;
            self.i += 1;
            const w = self.num() orelse return null;
            if (self.peek() != '.') return null;
            self.i += 1;
            const d = self.num() orelse return null;
            if (m < 1 or m > 12 or w < 1 or w > 5 or d > 6) return null;
            r.m = @intCast(m);
            r.w = @intCast(w);
            r.d = @intCast(d);
        } else if (self.peek() == 'J') {
            self.i += 1;
            r.kind = 'J';
            const n = self.num() orelse return null;
            if (n < 1 or n > 365) return null;
            r.n = @intCast(n);
        } else {
            r.kind = 'N';
            const n = self.num() orelse return null;
            if (n > 365) return null;
            r.n = @intCast(n);
        }
        if (self.peek() == '/') {
            self.i += 1;
            r.time = self.hms() orelse return null;
        }
        return r;
    }
};

fn parsePosix(s: []const u8) Posix {
    var p = P{ .s = s };
    var r = Posix{};
    if (!p.name()) return r;
    r.std_off = -(p.hms() orelse return r); // в POSIX знак инвертирован
    r.valid = true;
    if (p.peek() == 0) return r;
    if (!p.name()) return r;
    r.has_dst = true;
    r.dst_off = r.std_off + 3600;
    if (p.peek() != ',' and p.peek() != 0) {
        if (p.hms()) |o| r.dst_off = -o;
    }
    const std_only = Posix{ .valid = true, .std_off = r.std_off };
    if (p.peek() == ',') {
        p.i += 1;
        r.start = p.rule() orelse return std_only;
        if (p.peek() != ',') return std_only;
        p.i += 1;
        r.end = p.rule() orelse return std_only;
    } else {
        // правило по умолчанию (США)
        r.start = .{ .m = 3, .w = 2, .d = 0 };
        r.end = .{ .m = 11, .w = 1, .d = 0 };
    }
    return r;
}

// ---------------------------------------------------------------- API

pub const Local = struct { hour: u32, min: u32, sec: u32, day: u32, month: u32, year: i64 };

pub fn now() Local {
    const t = sys.realtime();
    const lt = t + offsetAt(t);
    const days = @divFloor(lt, 86400);
    const secs: u32 = @intCast(lt - days * 86400);
    const date = civilFromDays(days);
    return .{
        .hour = secs / 3600,
        .min = (secs / 60) % 60,
        .sec = secs % 60,
        .day = date.day,
        .month = date.month,
        .year = date.year,
    };
}
