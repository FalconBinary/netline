// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zrun — launcher for netline, in pure Zig, instead of rofi.
//!
//! Two tabs: "Apps" (.desktop files from the XDG folders, with translations) and "Commands"
//! (everything in PATH). Fuzzy search with match highlighting, frequently launched entries rank higher,
//! and a query typed in the wrong layout ("ашкуащч") is found too. Icons are PNG from the icon
//! theme; if there is none — a tile with the first letter.
//!
//! Everything is read before the sandbox. Programs are launched by a small broker process forked
//! right after the list is read: for an app it is given only the number in that list,
//! and it parses the Exec line itself and runs it without a shell.
//!
//! Keys: typing — search, ↑/↓ (Ctrl+P/N, Ctrl+K/J), PgUp/PgDn, Enter — launch,
//! Shift+Enter — in a terminal, Tab — the other tab, Esc — close.
//! In "Commands" Ctrl+Enter runs the typed line as is. `zrun run` opens "Commands" right away.

const std = @import("std");
const sys = @import("sys.zig");
const draw = @import("draw.zig");
const theme = @import("theme.zig");
const cfg = @import("config.zig");
const img = @import("img.zig");
const ui = @import("ui.zig");
const desk = @import("desktop.zig");
const rt = @import("rt.zig");

pub const panic = rt.panic;
pub const std_options = rt.std_options;

const PAD = ui.PAD;
const ROW_H: f32 = 52;
const TABS_Y: f32 = 16;
const FIELD_Y: f32 = 56;
const LIST_Y: f32 = 106;
const ICON: f32 = 32;

// ================================================================= strings

/// All strings (names, Exec, paths) live in one buffer: pages are committed as it fills.
var arena: [1 << 20]u8 = undefined;
var arena_n: usize = 0;

const Str = extern struct {
    off: u32 = 0,
    len: u32 = 0,

    fn get(s: Str) []const u8 {
        return arena[s.off..][0..s.len];
    }
    /// Only for strings saved via keepZ.
    fn z(s: Str) [:0]const u8 {
        return arena[s.off .. s.off + s.len :0];
    }
};

fn keep(s: []const u8) Str {
    if (arena_n + s.len > arena.len) return .{};
    @memcpy(arena[arena_n..][0..s.len], s);
    const r = Str{ .off = @intCast(arena_n), .len = @intCast(s.len) };
    arena_n += s.len;
    return r;
}

/// Zero-terminated — for paths and execve.
fn keepZ(s: []const u8) Str {
    if (arena_n + s.len + 1 > arena.len) return .{};
    const r = keep(s);
    arena[arena_n] = 0;
    arena_n += 1;
    return r;
}

/// Lowercased — for searching.
fn keepFold(s: []const u8) Str {
    if (arena_n + s.len > arena.len) return .{};
    const r = Str{ .off = @intCast(arena_n), .len = @intCast(s.len) };
    _ = desk.foldStr(s, arena[arena_n..][0..s.len]);
    arena_n += s.len;
    return r;
}

// ================================================================= data

const IconState = enum(u8) { unknown, none, ready };

const App = extern struct {
    id: Str = .{}, // org.mozilla.firefox.desktop
    file: Str = .{}, // path to the .desktop file (for %k)
    name: Str = .{},
    sub: Str = .{}, // GenericName or Comment
    exec: Str = .{}, // Exec after unescape
    icon: Str = .{},
    dir: Str = .{}, // Path=
    f_name: Str = .{},
    f_name_c: Str = .{},
    f_exec: Str = .{},
    f_sub: Str = .{},
    f_kw: Str = .{},
    f_id: Str = .{},
    visible: bool = false,
    terminal: bool = false,
    rank: u16 = 0, // alphabetical position
    uses: u32 = 0,
    icon_state: IconState = .unknown,
    icon_off: u32 = 0,
};

const MAX_APPS = 1024;
var apps: [MAX_APPS]App = undefined;
var napps: usize = 0;
var vis: [MAX_APPS]u16 = undefined; // visible apps in alphabetical order
var nvis: usize = 0;

const Exe = extern struct { name: Str, f_name: Str, uses: u32 = 0 };
const MAX_EXES = 8192;
var exes: [MAX_EXES]Exe = undefined;
var nexes: usize = 0;

// index hash tables (filled at most halfway): a cell holds index + 1, 0 is empty —
// so the tables are zeroed .bss and not 36 KB of 0xff in the file
var app_tab = [_]u16{0} ** (MAX_APPS * 2);
var exe_tab = [_]u16{0} ** (MAX_EXES * 2);

fn hash(s: []const u8) usize {
    var h: u32 = 2166136261;
    for (s) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return h;
}

fn appKey(i: u16) []const u8 {
    return apps[i].id.get();
}

fn exeKey(i: u16) []const u8 {
    return exes[i].name.get();
}

/// Find a key; if it isn't there, slot gets a free cell for it.
fn lookup(tab: []u16, key: []const u8, comptime keyOf: fn (u16) []const u8, slot: *usize) ?u16 {
    const mask = tab.len - 1;
    var i = hash(key) & mask;
    while (tab[i] != 0) : (i = (i + 1) & mask) {
        if (std.mem.eql(u8, keyOf(tab[i] - 1), key)) return tab[i] - 1;
    }
    slot.* = i;
    return null;
}

fn isExe(name: []const u8) bool {
    var slot: usize = 0;
    return lookup(&exe_tab, name, exeKey, &slot) != null;
}

// ================================================================= environment

var home: []const u8 = "";
var home_z: Str = .{};
var loc: desk.Locale = .{};
var desktops: []const u8 = "";
var data_dirs: [16][]const u8 = undefined;
var ndata: usize = 0;
var cache_dir: Str = .{};
var hist_dir: Str = .{};
var hist_path: Str = .{};
var list_path: Str = .{}; // cache of the app and command list
var icons_path: Str = .{}; // cache of prepared icons
var fbuf: [64 * 1024]u8 = undefined;

fn env(name: []const u8) ?[]const u8 {
    const v = sys.getenv(name) orelse return null;
    return if (v.len > 0) v else null;
}

fn addData(d0: []const u8) void {
    const d = std.mem.trimEnd(u8, d0, "/");
    if (d.len == 0 or ndata == data_dirs.len) return;
    for (data_dirs[0..ndata]) |x| {
        if (std.mem.eql(u8, x, d)) return;
    }
    data_dirs[ndata] = keep(d).get();
    ndata += 1;
}

/// XDG data folders by descending priority, language, desktop, history path.
fn setupEnv() void {
    home = env("HOME") orelse "";
    home_z = keepZ(if (home.len > 0) home else "/");
    loc = desk.locale(env("LC_ALL") orelse env("LC_MESSAGES") orelse env("LANG") orelse "");
    desktops = env("XDG_CURRENT_DESKTOP") orelse "";

    var b: [512]u8 = undefined;
    if (env("XDG_DATA_HOME")) |d| {
        addData(d);
    } else if (home.len > 0) addData(std.fmt.bufPrint(&b, "{s}/.local/share", .{home}) catch "");
    var it = std.mem.tokenizeScalar(u8, env("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share", ':');
    while (it.next()) |d| addData(d);
    // Flatpak apps — even if the session was started without its XDG_DATA_DIRS
    if (home.len > 0) addData(std.fmt.bufPrint(&b, "{s}/.local/share/flatpak/exports/share", .{home}) catch "");
    addData("/var/lib/flatpak/exports/share");

    const cache = if (env("XDG_CACHE_HOME")) |c| c else std.fmt.bufPrint(&b, "{s}/.cache", .{home}) catch "";
    if (cache.len > 0 and cache[0] == '/') {
        cache_dir = keepZ(cache);
        var b2: [512]u8 = undefined;
        hist_dir = keepZ(std.fmt.bufPrint(&b2, "{s}/netline", .{cache}) catch "");
        hist_path = keepZ(std.fmt.bufPrint(&b2, "{s}/netline/zrun-history", .{cache}) catch "");
        list_path = keepZ(std.fmt.bufPrint(&b2, "{s}/netline/zrun-cache", .{cache}) catch "");
        icons_path = keepZ(std.fmt.bufPrint(&b2, "{s}/netline/zrun-icons", .{cache}) catch "");
    }
}

// ================================================================= commands from PATH

fn loadExes() void {
    var b: [512]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, env("PATH") orelse "/usr/local/bin:/usr/bin:/bin", ':');
    while (it.next()) |d| {
        watch(d);
        var dir = sys.Dir.open(sys.joinZ(&b, &.{d})) orelse continue;
        defer dir.deinit();
        while (dir.next()) |name| {
            if (nexes == MAX_EXES) return;
            if (name[0] == '.') continue;
            var slot: usize = 0;
            if (lookup(&exe_tab, name, exeKey, &slot) != null) continue;
            const s = keep(name);
            if (s.len == 0) return; // the string buffer ran out
            const lower = for (name) |c| {
                if (c >= 'A' and c <= 'Z') break false;
            } else true;
            exes[nexes] = .{ .name = s, .f_name = if (lower) s else keepFold(name) };
            exe_tab[slot] = @intCast(nexes + 1);
            nexes += 1;
        }
    }
}

fn exeLess(_: void, a: Exe, b: Exe) bool {
    return std.mem.lessThan(u8, a.f_name.get(), b.f_name.get());
}

fn sortExes() void {
    std.sort.pdq(Exe, exes[0..nexes], {}, exeLess);
    @memset(&exe_tab, 0);
    for (0..nexes) |i| {
        var slot: usize = 0;
        if (lookup(&exe_tab, exes[i].name.get(), exeKey, &slot) == null) exe_tab[slot] = @intCast(i + 1);
    }
}

// ================================================================= applications

fn loadApps() void {
    var b: [512]u8 = undefined;
    for (data_dirs[0..ndata]) |d| scanApps(sys.joinZ(&b, &.{ d, "/applications" }), "", 0);
}

/// File ID per the spec: path from the applications folder, "/" → "-" (kde4/okular.desktop → kde4-okular.desktop).
fn scanApps(path: [:0]const u8, prefix: []const u8, depth: u32) void {
    watch(path); // nonexistent ones too: if the folder appears, the cache goes stale
    var dir = sys.Dir.open(path) orelse return;
    defer dir.deinit();
    var b: [512]u8 = undefined;
    var idb: [256]u8 = undefined;
    while (dir.next()) |name| {
        const sub = sys.joinZ(&b, &.{ path, "/", name });
        if (std.mem.endsWith(u8, name, ".desktop")) {
            addApp(sub, std.fmt.bufPrint(&idb, "{s}{s}", .{ prefix, name }) catch continue);
        } else if (depth < 2 and std.mem.indexOfScalar(u8, name, '.') == null and !std.mem.eql(u8, name, "screensavers")) {
            scanApps(sub, std.fmt.bufPrint(&idb, "{s}{s}-", .{ prefix, name }) catch continue, depth + 1);
        }
    }
}

fn addApp(path: [:0]const u8, id: []const u8) void {
    if (napps == MAX_APPS) return;
    var slot: usize = 0;
    // this ID was already in a higher-priority folder — that one wins (including Hidden=true)
    if (lookup(&app_tab, id, appKey, &slot) != null) return;
    watch(path); // editing a file in place doesn't change the folder's time
    const data = sys.readFile(path, &fbuf) orelse return;
    const e = desk.parse(data, loc);
    var a = App{ .id = keep(id) };
    if (a.id.len == 0) return;
    a.visible = e.app and !e.hidden and !e.no_display and e.exec.len > 0 and
        desk.shownIn(e.only_show_in, e.not_show_in, desktops) and tryExecOk(e.try_exec);
    if (a.visible) fill(&a, &e, path);
    apps[napps] = a;
    app_tab[slot] = @intCast(napps + 1);
    napps += 1;
}

/// TryExec: if the program is missing, the app is not shown.
fn tryExecOk(te: []const u8) bool {
    if (te.len == 0) return true;
    var b: [512]u8 = undefined;
    if (std.mem.indexOfScalar(u8, te, '/') != null) {
        watch(te);
        return sys.exists(sys.joinZ(&b, &.{te}));
    }
    return isExe(te);
}

fn fill(a: *App, e: *const desk.Entry, path: []const u8) void {
    var tmp: [4096]u8 = undefined;
    const name = desk.unescape(if (e.name.len > 0) e.name else e.name_c, &tmp);
    if (name.len == 0) {
        a.visible = false;
        return;
    }
    a.name = keep(name);
    a.f_name = keepFold(name);
    if (e.name_c.len > 0 and e.name_c.ptr != e.name.ptr) a.f_name_c = keepFold(desk.unescape(e.name_c, &tmp));
    const sub = desk.unescape(if (e.generic.len > 0) e.generic else e.comment, &tmp);
    a.sub = keep(sub);
    a.f_sub = keepFold(sub);
    a.f_kw = keepFold(desk.unescape(e.keywords, &tmp));
    for (arena[a.f_kw.off..][0..a.f_kw.len]) |*c| {
        if (c.* == ';') c.* = ' ';
    }
    const ex = desk.unescape(e.exec, &tmp);
    a.exec = keep(ex);
    var nb: [256]u8 = undefined;
    a.f_exec = keepFold(desk.execName(ex, &nb));
    a.icon = keepZ(desk.unescape(e.icon, &tmp));
    a.dir = keepZ(desk.unescape(e.path, &tmp));
    a.file = keep(path);
    const id = a.id.get();
    a.f_id = keepFold(if (std.mem.endsWith(u8, id, ".desktop")) id[0 .. id.len - 8] else id);
    a.terminal = e.terminal;
    if (a.exec.len == 0) a.visible = false; // the string buffer ran out
}

fn appLess(_: void, a: u16, b: u16) bool {
    return std.mem.lessThan(u8, apps[a].f_name.get(), apps[b].f_name.get());
}

fn sortApps() void {
    nvis = 0;
    for (apps[0..napps], 0..) |*a, i| {
        if (!a.visible) continue;
        vis[nvis] = @intCast(i);
        nvis += 1;
    }
    std.sort.pdq(u16, vis[0..nvis], {}, appLess);
    for (vis[0..nvis], 0..) |i, r| apps[i].rank = @intCast(r);
}

// ================================================================= launch history
// The file ~/.cache/netline/zrun-history: lines "count<TAB>a:id.desktop" or "count<TAB>r:program".
// The broker writes it; the window only reads it at startup.

fn loadHistory() void {
    if (hist_path.len == 0) return;
    const data = sys.readFile(hist_path.z(), &fbuf) orelse return;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const n = std.fmt.parseInt(u32, line[0..tab], 10) catch continue;
        const k = line[tab + 1 ..];
        if (k.len < 3) continue;
        var slot: usize = 0;
        if (std.mem.startsWith(u8, k, "a:")) {
            if (lookup(&app_tab, k[2..], appKey, &slot)) |i| apps[i].uses = n;
        } else if (std.mem.startsWith(u8, k, "r:")) {
            if (lookup(&exe_tab, k[2..], exeKey, &slot)) |i| exes[i].uses = n;
        }
    }
}

var obuf: [72 * 1024]u8 = undefined;

fn bumpHistory(kind: []const u8, key: []const u8) void {
    if (hist_path.len == 0) return;
    var kb: [300]u8 = undefined;
    const fk = std.fmt.bufPrint(&kb, "{s}{s}", .{ kind, key }) catch return;
    if (std.mem.indexOfAny(u8, fk, "\t\n") != null) return;

    const Rec = struct { n: u32, k: []const u8 };
    var recs: [320]Rec = undefined;
    var nrec: usize = 0;
    var found = false;
    if (sys.readFile(hist_path.z(), &fbuf)) |data| {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            var n = std.fmt.parseInt(u32, line[0..tab], 10) catch continue;
            const k = line[tab + 1 ..];
            if (k.len == 0 or nrec == recs.len) continue;
            if (std.mem.eql(u8, k, fk)) {
                n +|= 1;
                found = true;
            }
            recs[nrec] = .{ .n = n, .k = k };
            nrec += 1;
        }
    }
    const S = struct {
        fn more(_: void, a: Rec, b: Rec) bool {
            return a.n > b.n;
        }
    };
    std.sort.pdq(Rec, recs[0..nrec], {}, S.more);
    if (!found) {
        if (nrec == recs.len) nrec -= 1; // the rarest entry makes room for the new one
        recs[nrec] = .{ .n = 1, .k = fk };
        nrec += 1;
    }
    // old habits are gradually forgotten
    if (recs[0].n > 5000) {
        for (recs[0..nrec]) |*r| r.n = @max(1, r.n / 2);
    }
    var o: usize = 0;
    for (recs[0..@min(nrec, 300)]) |r| {
        const line = std.fmt.bufPrint(obuf[o..], "{d}\t{s}\n", .{ r.n, r.k }) catch break;
        o += line.len;
    }
    sys.mkdir(cache_dir.z());
    sys.mkdir(hist_dir.z());
    var tb: [600]u8 = undefined;
    const tmp = sys.joinZ(&tb, &.{ hist_path.get(), ".tmp" });
    const fd = sys.createFile(tmp) catch return;
    sys.writeAll(fd, obuf[0..o]) catch {
        sys.close(fd);
        sys.unlink(tmp);
        return;
    };
    sys.close(fd);
    sys.rename(tmp, hist_path.z()) catch sys.unlink(tmp);
}

// ================================================================= list cache
// Building the list means reading all .desktop files (with translations — tens of KB each),
// all of PATH and hundreds of icon folder checks. The result is written to ~/.cache/netline/zrun-cache
// in one block together with "fingerprints" (modification time, size, inode) of everything that was read:
// the PATH and applications folders, every .desktop file, the icon theme folders. At startup
// the fingerprints are compared — if anything changed, the list is rebuilt.

const Watch = extern struct { path: Str, st: sys.Stamp };
const MAX_WATCH = 4096;
var watches: [MAX_WATCH]Watch = undefined;
var nwatch: usize = 0;
var watch_full = false;

/// Remember a path's fingerprint (before reading: an edit during the read won't go unnoticed).
fn watch(path: []const u8) void {
    if (list_path.len == 0) return; // nowhere to cache — no fingerprints needed either
    if (nwatch == MAX_WATCH) {
        watch_full = true;
        return;
    }
    const p = keepZ(path);
    if (p.len != path.len) {
        watch_full = true;
        return;
    }
    watches[nwatch] = .{ .path = p, .st = sys.stamp(p.z()) };
    nwatch += 1;
}

const CACHE_MAGIC: u64 = 0x3143_4e55_525a_7a01; // format version in the last byte

/// Fingerprint of the struct layout: another binary with other fields won't read a foreign cache.
const layout_key: u64 = blk: {
    @setEvalBranchQuota(100000);
    var h: u64 = 0xcbf29ce484222325;
    for (.{ Str, App, Exe, IconDir, Watch, sys.Stamp }) |T| {
        h = (h ^ @sizeOf(T)) *% 0x100000001b3;
        for (std.meta.fields(T)) |f| {
            for (f.name) |c| h = (h ^ c) *% 0x100000001b3;
            h = (h ^ @offsetOf(T, f.name)) *% 0x100000001b3;
        }
    }
    break :blk h;
};

const Header = extern struct {
    magic: u64,
    layout: u64,
    env: u64, // the environment and settings the list depends on
    gen: u64, // number of this cache: the icon cache refers to it
    base: u32, // the cache strings live in arena[base..end]
    end: u32,
    nwatch: u32,
    napps: u32,
    nexes: u32,
    nicon: u32,
    npix: u32,
    nread: u32,
};

var list_gen: u64 = 0;
var arena_base: usize = 0;

fn fnv(h0: u64, s: []const u8) u64 {
    var h = h0;
    for (s) |c| h = (h ^ c) *% 0x100000001b3;
    return h;
}

fn envKey() u64 {
    var h: u64 = 0xcbf29ce484222325;
    const names = [_][]const u8{ "HOME", "PATH", "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_CURRENT_DESKTOP", "LC_ALL", "LC_MESSAGES", "LANG" };
    for (names) |n| {
        h = fnv(h, n);
        h = fnv(h, sys.getenv(n) orelse "\x00");
        h = fnv(h, "\n");
    }
    h = fnv(h, cfg.icon_theme);
    return fnv(h, if (cfg.launcher_icons) "+" else "-");
}

fn validStr(x: Str, end: usize) bool {
    return @as(usize, x.off) + x.len <= end;
}

/// A zero-terminated string. An empty field ({0, 0}: hidden apps have no icon and folder)
/// is fine too — z() isn't called for empty ones.
fn validZ(x: Str, end: usize) bool {
    if (x.len == 0 and x.off == 0) return true;
    return @as(usize, x.off) + x.len < end and arena[x.off + x.len] == 0;
}

/// A path: a non-empty zero-terminated string (z() is taken from it later).
fn validPath(x: Str, end: usize) bool {
    return x.len > 0 and validZ(x, end);
}

fn readExact(fd: i32, buf: []u8) bool {
    var n: usize = 0;
    while (n < buf.len) {
        const k = sys.read(fd, buf[n..]) catch return false;
        if (k == 0) return false;
        n += k;
    }
    return true;
}

/// Read the list cache. false — missing, stale or broken (then the strings that
/// already landed in arena are dropped and the list is rebuilt).
fn loadList() bool {
    arena_base = arena_n;
    if (list_path.len == 0) return false;
    const fd = sys.openRead(list_path.z()) catch return false;
    defer sys.close(fd);
    const ok = readList(fd);
    if (!ok) {
        arena_n = arena_base;
        napps = 0;
        nexes = 0;
        nicon = 0;
        npix = 0;
        nread = 0;
        nwatch = 0;
    }
    return ok;
}

fn readList(fd: i32) bool {
    var h: Header = undefined;
    if (!readExact(fd, std.mem.asBytes(&h))) return false;
    if (h.magic != CACHE_MAGIC or h.layout != layout_key or h.env != envKey() or h.base != arena_base) return false;
    if (h.end < h.base or h.end > arena.len or h.nwatch > MAX_WATCH or h.napps > MAX_APPS or h.nexes > MAX_EXES or
        h.nicon > icon_dirs.len or h.npix > pix_dirs.len or h.nread > read_paths.len) return false;
    const end: usize = h.end;
    if (!readExact(fd, arena[h.base..end])) return false;

    // fingerprints first: if anything changed, there's no point reading the rest
    if (!readExact(fd, std.mem.sliceAsBytes(watches[0..h.nwatch]))) return false;
    for (watches[0..h.nwatch]) |w| {
        if (!validPath(w.path, end)) return false;
        const now = sys.stamp(w.path.z());
        if (!std.meta.eql(now, w.st)) {
            sys.tracef("list cache is stale: {s}", .{w.path.get()});
            return false;
        }
    }

    if (!readExact(fd, std.mem.sliceAsBytes(apps[0..h.napps]))) return false;
    if (!readExact(fd, std.mem.sliceAsBytes(exes[0..h.nexes]))) return false;
    if (!readExact(fd, std.mem.sliceAsBytes(icon_dirs[0..h.nicon]))) return false;
    if (!readExact(fd, std.mem.sliceAsBytes(pix_dirs[0..h.npix]))) return false;
    var rp: [read_paths.len]Str = undefined;
    if (!readExact(fd, std.mem.sliceAsBytes(rp[0..h.nread]))) return false;

    // reference checks: a broken file means a rebuild, not a buffer overrun
    for (apps[0..h.napps]) |*a| {
        inline for (std.meta.fields(App)) |f| {
            if (f.type == Str) {
                if (!validStr(@field(a, f.name), end)) return false;
            }
        }
        if (!validZ(a.icon, end) or !validZ(a.dir, end)) return false;
        if (@as(*const u8, @ptrCast(&a.visible)).* > 1 or @as(*const u8, @ptrCast(&a.terminal)).* > 1) return false;
        a.uses = 0;
        a.icon_state = .unknown;
    }
    for (exes[0..h.nexes]) |*e| {
        if (!validStr(e.name, end) or !validStr(e.f_name, end)) return false;
        e.uses = 0;
    }
    for (icon_dirs[0..h.nicon]) |d| if (!validPath(d.path, end)) return false;
    for (pix_dirs[0..h.npix]) |d| if (!validPath(d, end)) return false;
    for (rp[0..h.nread], 0..) |x, i| {
        if (!validPath(x, end)) return false;
        read_paths[i] = x.z();
    }

    arena_n = end;
    nwatch = h.nwatch;
    napps = h.napps;
    nexes = h.nexes;
    nicon = h.nicon;
    npix = h.npix;
    nread = h.nread;
    list_gen = h.gen;
    // hash tables — from the lists (faster than storing them)
    @memset(&app_tab, 0);
    for (0..napps) |i| {
        var slot: usize = 0;
        if (lookup(&app_tab, apps[i].id.get(), appKey, &slot) == null) app_tab[slot] = @intCast(i + 1);
    }
    @memset(&exe_tab, 0);
    for (0..nexes) |i| {
        var slot: usize = 0;
        if (lookup(&exe_tab, exes[i].name.get(), exeKey, &slot) == null) exe_tab[slot] = @intCast(i + 1);
    }
    return true;
}

/// Write the list cache (before the sandbox; via a temporary file — a half-written one won't be read).
fn saveList() void {
    if (list_path.len == 0 or watch_full) return;
    list_gen = sys.random();
    var rp: [read_paths.len]Str = undefined;
    for (read_paths[0..nread], 0..) |x, i| rp[i] = .{ .off = @intCast(@intFromPtr(x.ptr) - @intFromPtr(&arena)), .len = @intCast(x.len) };
    const h = Header{
        .magic = CACHE_MAGIC,
        .layout = layout_key,
        .env = envKey(),
        .gen = list_gen,
        .base = @intCast(arena_base),
        .end = @intCast(arena_n),
        .nwatch = @intCast(nwatch),
        .napps = @intCast(napps),
        .nexes = @intCast(nexes),
        .nicon = @intCast(nicon),
        .npix = @intCast(npix),
        .nread = @intCast(nread),
    };
    sys.mkdir(cache_dir.z());
    sys.mkdir(hist_dir.z());
    var tb: [600]u8 = undefined;
    const tmp = sys.joinZ(&tb, &.{ list_path.get(), ".tmp" });
    const fd = sys.createFile(tmp) catch return;
    const parts = [_][]const u8{
        std.mem.asBytes(&h),
        arena[arena_base..arena_n],
        std.mem.sliceAsBytes(watches[0..nwatch]),
        std.mem.sliceAsBytes(apps[0..napps]), // launch counters are still zero: history is read afterwards
        std.mem.sliceAsBytes(exes[0..nexes]),
        std.mem.sliceAsBytes(icon_dirs[0..nicon]),
        std.mem.sliceAsBytes(pix_dirs[0..npix]),
        std.mem.sliceAsBytes(rp[0..nread]),
    };
    for (parts) |part| {
        sys.writeAll(fd, part) catch {
            sys.close(fd);
            sys.unlink(tmp);
            return;
        };
    }
    sys.close(fd);
    sys.rename(tmp, list_path.z()) catch sys.unlink(tmp);
}

// ================================================================= launch broker
// Forks after the lists are read, before connecting to Wayland and the sandbox. Messages:
//   'A' <number u16> <flags> — an app from the list (Exec is parsed here, without a shell);
//   'R' <flags> <line>       — a command via /bin/sh -c (the "Commands" tab).

const F_TERM: u8 = 1;
var broker_fd: i32 = -1;

fn startBroker() void {
    const pair = sys.socketpair() catch return;
    const pid = sys.fork() catch {
        sys.close(pair[0]);
        sys.close(pair[1]);
        return;
    };
    if (pid == 0) serve(sys.keepOnlyFd(pair[1]));
    sys.close(pair[1]);
    broker_fd = pair[0];
}

fn serve(fd: i32) noreturn {
    var b: [512]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &b) catch sys.exit(0);
        if (n == 0) sys.exit(0); // the window closed
        const m = b[0..n];
        if (m.len == 4 and m[0] == 'A') {
            const i = std.mem.readInt(u16, m[1..3], .little);
            if (i < napps and apps[i].visible) launchApp(&apps[i], m[3] & F_TERM != 0);
        } else if (m.len >= 3 and m[0] == 'R') {
            runCommand(m[2..], m[1] & F_TERM != 0);
        }
    }
}

fn spawn(av: *const desk.Argv, dir: [:0]const u8) void {
    var ptrs: [64:null]?[*:0]const u8 = undefined;
    for (0..av.argc) |i| ptrs[i] = av.arg(i).ptr;
    if (av.argc < ptrs.len) ptrs[av.argc] = null;
    sys.spawnArgv(&ptrs, dir);
}

fn addTerminal(av: *desk.Argv) void {
    for (cfg.terminal) |t| av.add(t);
}

fn launchApp(a: *const App, term: bool) void {
    var av = desk.Argv{};
    if (a.terminal or term) addTerminal(&av);
    if (!desk.execArgv(a.exec.get(), .{ .name = a.name.get(), .icon = a.icon.get(), .file = a.file.get() }, &av)) return;
    spawn(&av, if (a.dir.len > 0) a.dir.z() else home_z.z());
    bumpHistory("a:", a.id.get());
}

fn runCommand(cmd: []const u8, term: bool) void {
    var av = desk.Argv{};
    if (term) addTerminal(&av);
    av.add("/bin/sh");
    av.add("-c");
    av.add(cmd);
    if (av.overflow) return;
    spawn(&av, home_z.z());
    // only program names go into the history: typed lines with arguments may contain passwords
    if (isExe(cmd)) bumpHistory("r:", cmd);
}

// ================================================================= icons
// PNG only: the theme from config.zig or GTK, its Inherits, then hicolor; the size is exactly the
// screen's or larger (scaled down). Icons are loaded when a row is first shown.

const IconDir = extern struct { path: Str, size: u16, rank: u8 };
var icon_dirs: [64]IconDir = undefined;
var nicon: usize = 0;
var dir_order: [64]u8 = undefined;
var pix_dirs: [4]Str = undefined;
var npix: usize = 0;
var read_paths: [20][:0]const u8 = undefined;
var nread: usize = 0;

const sizes = [_]u16{ 16, 22, 24, 32, 48, 64, 96, 128, 192, 256, 512 };

const POOL = 1 << 20; // pixels: 4 MB for all shown icons, pages committed as needed
var pool: ?[*]u32 = null;
var pool_n: usize = 0;
var icon_t: u32 = 0;

fn addRead(p: [:0]const u8) void {
    if (nread == read_paths.len or !sys.exists(p)) return;
    for (read_paths[0..nread]) |x| {
        if (std.mem.startsWith(u8, p, x) and (p.len == x.len or p[x.len] == '/')) return;
    }
    read_paths[nread] = p;
    nread += 1;
}

fn iniValue(path: [:0]const u8, key: []const u8, buf: []u8) ?[]const u8 {
    const data = sys.readFile(path, buf) orelse return null;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = std.mem.trimStart(u8, line[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        return std.mem.trim(u8, rest[1..], " \t\"'");
    }
    return null;
}

fn userTheme() []const u8 {
    if (cfg.icon_theme.len > 0) return cfg.icon_theme;
    var b: [512]u8 = undefined;
    var vb: [4096]u8 = undefined;
    const conf = env("XDG_CONFIG_HOME") orelse (std.fmt.bufPrint(&b, "{s}/.config", .{home}) catch return "");
    var pb: [600]u8 = undefined;
    for ([_][]const u8{ "/gtk-3.0/settings.ini", "/gtk-4.0/settings.ini" }) |f| {
        const path = sys.joinZ(&pb, &.{ conf, f });
        watch(path);
        if (iniValue(path, "gtk-icon-theme-name", &vb)) |v| {
            if (v.len > 0) return keep(v).get();
        }
    }
    return "";
}

fn iconSetup() void {
    if (!cfg.launcher_icons) return;
    var b: [512]u8 = undefined;
    var roots: [18]Str = undefined;
    var nroots: usize = 0;
    if (ndata > 0) {
        roots[nroots] = keepZ(std.fmt.bufPrint(&b, "{s}/icons", .{data_dirs[0]}) catch "");
        nroots += 1;
    }
    if (home.len > 0) {
        roots[nroots] = keepZ(std.fmt.bufPrint(&b, "{s}/.icons", .{home}) catch "");
        nroots += 1;
    }
    for (data_dirs[1..ndata]) |d| {
        if (nroots == roots.len) break;
        roots[nroots] = keepZ(std.fmt.bufPrint(&b, "{s}/icons", .{d}) catch "");
        nroots += 1;
    }

    // themes in order: our own, what it inherits from, hicolor
    var themes: [5][]const u8 = undefined;
    var nthemes: usize = 0;
    const own = userTheme();
    if (own.len > 0 and !std.mem.eql(u8, own, "hicolor")) {
        themes[0] = own;
        nthemes = 1;
        var vb: [8192]u8 = undefined;
        for (roots[0..nroots]) |r| {
            const idx = sys.joinZ(&b, &.{ r.get(), "/", own, "/index.theme" });
            watch(idx);
            const inh = iniValue(idx, "Inherits", &vb) orelse continue;
            var it = std.mem.tokenizeScalar(u8, inh, ',');
            while (it.next()) |x| {
                const th = std.mem.trim(u8, x, " ");
                if (nthemes == themes.len - 1 or th.len == 0 or std.mem.eql(u8, th, "hicolor")) continue;
                themes[nthemes] = keep(th).get();
                nthemes += 1;
            }
            break;
        }
    }
    themes[nthemes] = "hicolor";
    nthemes += 1;

    for (themes[0..nthemes], 0..) |th, rank| {
        for (roots[0..nroots]) |r| {
            if (r.len == 0) continue;
            const tp = sys.joinZ(&b, &.{ r.get(), "/", th });
            watch(tp); // a new size folder in the theme changes this folder's time
            if (!sys.exists(tp)) continue;
            for (sizes) |s| {
                if (nicon == icon_dirs.len) break;
                var pb: [600]u8 = undefined;
                const p = std.fmt.bufPrint(&pb, "{s}/{s}/{d}x{d}/apps", .{ r.get(), th, s, s }) catch continue;
                if (!sys.exists(sys.joinZ(&b, &.{p}))) continue;
                watch(p); // new icons (a program was installed)
                icon_dirs[nicon] = .{ .path = keepZ(p), .size = s, .rank = @intCast(rank) };
                nicon += 1;
            }
        }
    }
    for (data_dirs[0..ndata]) |d| {
        if (npix == pix_dirs.len) break;
        const p = keepZ(std.fmt.bufPrint(&b, "{s}/pixmaps", .{d}) catch continue);
        if (p.len == 0) continue;
        watch(p.get());
        if (!sys.exists(p.z())) continue;
        pix_dirs[npix] = p;
        npix += 1;
    }

    // what the window may read in the sandbox: theme roots, pixmaps and icon folders with absolute paths
    for (roots[0..nroots]) |r| {
        if (r.len > 0) addRead(r.z());
    }
    for (pix_dirs[0..npix]) |p| addRead(p.z());
    for (vis[0..nvis]) |i| {
        const ic = apps[i].icon.get();
        if (ic.len == 0 or ic[0] != '/') continue;
        const slash = std.mem.lastIndexOfScalar(u8, ic, '/') orelse continue;
        if (slash < 2) continue;
        addRead(keepZ(ic[0..slash]).z());
    }
}

fn sizeKey(s: u16, t: u32) u32 {
    return if (s >= t) s - t else 10000 + t - s;
}

fn dirBefore(t: u32, a: u8, b: u8) bool {
    const da = icon_dirs[a];
    const db = icon_dirs[b];
    if (da.rank != db.rank) return da.rank < db.rank;
    return sizeKey(da.size, t) < sizeKey(db.size, t);
}

/// The screen scale changed (or the first frame): redo the icons for the new size.
fn resetIcons(t: u32) void {
    icon_t = t;
    pool_n = 0;
    for (apps[0..napps]) |*a| a.icon_state = .unknown;
    for (0..nicon) |i| dir_order[i] = @intCast(i);
    std.sort.pdq(u8, dir_order[0..nicon], t, dirBefore);
    loadIconCache(t);
}

fn iconOf(a: *App) ?[]const u32 {
    if (!cfg.launcher_icons) return null;
    const t: u32 = @intFromFloat(@round(ICON * ui.S));
    if (t != icon_t) resetIcons(t);
    if (a.icon_state == .unknown) {
        a.icon_state = if (loadIcon(a, t)) .ready else .none;
        icons_dirty = true;
    }
    if (a.icon_state != .ready) return null;
    return pool.?[a.icon_off..][0 .. t * t];
}

// ---------------------------------------------------------------- cache of prepared icons
// ~/.cache/netline/zrun-icons: icons already scaled for the screen, plus a note of which have no
// icon (so dozens of paths aren't tried on every launch). The file is opened before the sandbox;
// it's read at the first frame and appended to on close if new icons appeared.
// It is valid until the list is rebuilt (list_gen number) or the scale changes.

var icons_fd: i32 = -1;
var icons_dirty = false;

const IconHeader = extern struct { magic: u64, gen: u64, t: u32, napps: u32, pool_n: u32, pad: u32 = 0 };
const IconRec = extern struct { state: u8, pad: [3]u8 = .{ 0, 0, 0 }, off: u32 };

fn loadIconCache(t: u32) void {
    if (icons_fd < 0 or list_gen == 0) return;
    _ = sys.lseek(icons_fd, 0) catch return;
    var h: IconHeader = undefined;
    if (!readExact(icons_fd, std.mem.asBytes(&h))) return;
    if (h.magic != CACHE_MAGIC or h.gen != list_gen or h.t != t or h.napps != napps or h.pool_n > POOL) return;
    var recs: [MAX_APPS]IconRec = undefined;
    if (!readExact(icons_fd, std.mem.sliceAsBytes(recs[0..napps]))) return;
    const need = @as(usize, t) * t;
    if (h.pool_n > 0) {
        if (pool == null) pool = @ptrCast(@alignCast(sys.mmapAnon(POOL * 4) catch return));
        if (!readExact(icons_fd, std.mem.sliceAsBytes(pool.?[0..h.pool_n]))) return;
    }
    for (apps[0..napps], recs[0..napps]) |*a, r| {
        switch (r.state) {
            @intFromEnum(IconState.ready) => if (@as(usize, r.off) + need <= h.pool_n) {
                a.icon_state = .ready;
                a.icon_off = r.off;
            },
            @intFromEnum(IconState.none) => a.icon_state = .none,
            else => {},
        }
    }
    pool_n = h.pool_n;
    sys.tracef("icons from cache: {d} KB", .{pool_n * 4 / 1024});
}

/// On close: append to the icon cache if new icons appeared during this run.
fn saveIconCache() void {
    if (icons_fd < 0 or !icons_dirty or list_gen == 0 or icon_t == 0) return;
    const h = IconHeader{ .magic = CACHE_MAGIC, .gen = list_gen, .t = icon_t, .napps = @intCast(napps), .pool_n = @intCast(pool_n) };
    var recs: [MAX_APPS]IconRec = undefined;
    for (apps[0..napps], recs[0..napps]) |a, *r| r.* = .{ .state = @intFromEnum(a.icon_state), .off = a.icon_off };
    _ = sys.lseek(icons_fd, 0) catch return;
    sys.writeAll(icons_fd, std.mem.asBytes(&h)) catch return;
    sys.writeAll(icons_fd, std.mem.sliceAsBytes(recs[0..napps])) catch return;
    if (pool_n > 0) sys.writeAll(icons_fd, std.mem.sliceAsBytes(pool.?[0..pool_n])) catch return;
    sys.ftruncate(icons_fd, @sizeOf(IconHeader) + napps * @sizeOf(IconRec) + pool_n * 4) catch {};
}

fn loadIcon(a: *App, t: u32) bool {
    const name = a.icon.get();
    if (name.len == 0) return false;
    if (name[0] == '/') return tryIcon(a, a.icon.z(), t);
    var base = name;
    for ([_][]const u8{ ".png", ".svg", ".xpm" }) |ext| {
        if (std.mem.endsWith(u8, base, ext)) base = base[0 .. base.len - ext.len];
    }
    var b: [600]u8 = undefined;
    for (dir_order[0..nicon]) |di| {
        if (tryIcon(a, sys.joinZ(&b, &.{ icon_dirs[di].path.get(), "/", base, ".png" }), t)) return true;
    }
    for (pix_dirs[0..npix]) |d| {
        if (tryIcon(a, sys.joinZ(&b, &.{ d.get(), "/", base, ".png" }), t)) return true;
    }
    return false;
}

fn tryIcon(a: *App, path: [*:0]const u8, t: u32) bool {
    var im = img.load(path, 0, 0) catch return false;
    defer im.deinit();
    const need = @as(usize, t) * t;
    if (pool == null) pool = @ptrCast(@alignCast(sys.mmapAnon(POOL * 4) catch return false));
    if (pool_n + need > POOL) return false;
    img.renderAlpha(&im, pool.?[pool_n..][0..need], t, t) catch return false;
    a.icon_off = @intCast(pool_n);
    pool_n += need;
    return true;
}

// ================================================================= search

const Mode = enum(u8) { apps, cmds };
var mode: Mode = .apps;
var query: ui.Field = .{};
var last_q: [256]u8 = undefined;
var last_len: usize = 0;
var last_mode: ?Mode = null;

const Hit = struct { idx: u16, alt: bool = false, score: u32 = 0 };
const TYPED: u16 = 0xffff; // the "run what was typed" row in the "Commands" tab
var hits: [MAX_EXES + 1]Hit = undefined;
var nhits: usize = 0;
var list: ui.List = .{};

var qfold: [256]u8 = undefined;
var words: [16][]const u8 = undefined;
var nwords: usize = 0;
var alt_buf: [512]u8 = undefined;
var alt_words: [16][]const u8 = undefined;
var nalt: usize = 0;

fn boost(uses: u32) u32 {
    if (uses == 0) return 0;
    return @min(400, 40 * (@as(u32, std.math.log2_int(u32, uses)) + 1));
}

fn appFields(a: *const App) [6]desk.Field {
    return .{
        .{ .text = a.f_name.get(), .weight = 100, .fuzzy = true },
        .{ .text = a.f_name_c.get(), .weight = 90, .fuzzy = true },
        .{ .text = a.f_exec.get(), .weight = 80 },
        .{ .text = a.f_sub.get(), .weight = 60 },
        .{ .text = a.f_kw.get(), .weight = 50 },
        .{ .text = a.f_id.get(), .weight = 40 },
    };
}

/// Score by the query words and by the same words in the other layout (slightly lower).
fn rate(fields: []const desk.Field, h: *Hit) void {
    h.score = desk.scoreFields(fields, words[0..nwords]);
    if (nalt > 0) {
        const s = desk.scoreFields(fields, alt_words[0..nalt]) * 9 / 10;
        if (s > h.score) {
            h.score = s;
            h.alt = true;
        }
    }
}

fn hitWords(h: Hit) []const []const u8 {
    return if (h.alt) alt_words[0..nalt] else words[0..nwords];
}

fn usesOf(h: Hit) u32 {
    if (mode == .apps) return apps[h.idx].uses;
    return if (h.idx == TYPED) 0 else exes[h.idx].uses;
}

fn rankOf(h: Hit) u32 {
    return if (mode == .apps) apps[h.idx].rank else h.idx;
}

fn better(_: void, a: Hit, b: Hit) bool {
    if (a.score != b.score) return a.score > b.score;
    const ua = usesOf(a);
    const ub = usesOf(b);
    if (ua != ub) return ua > ub;
    return rankOf(a) < rankOf(b);
}

fn refilter() void {
    @memcpy(last_q[0..query.len], query.text());
    last_len = query.len;
    last_mode = mode;
    const q = std.mem.trim(u8, query.text(), " ");
    const fq = desk.foldStr(q, &qfold);
    nwords = desk.splitWords(fq, &words);
    nalt = 0;
    if (desk.swapLayout(fq, &alt_buf)) |a| nalt = desk.splitWords(a, &alt_words);

    nhits = 0;
    switch (mode) {
        .apps => for (vis[0..nvis]) |i| {
            const a = &apps[i];
            var h = Hit{ .idx = i };
            if (nwords > 0) {
                rate(&appFields(a), &h);
                if (h.score == 0) continue;
                h.score += boost(a.uses);
            }
            hits[nhits] = h;
            nhits += 1;
        },
        .cmds => {
            if (q.len > 0 and !isExe(q)) {
                hits[0] = .{ .idx = TYPED, .score = std.math.maxInt(u32) };
                nhits = 1;
            }
            for (exes[0..nexes], 0..) |*e, i| {
                var h = Hit{ .idx = @intCast(i) };
                if (nwords > 0) {
                    rate(&.{.{ .text = e.f_name.get(), .weight = 100, .fuzzy = true }}, &h);
                    if (h.score == 0) continue;
                    h.score += boost(e.uses);
                }
                hits[nhits] = h;
                nhits += 1;
            }
        },
    }
    std.sort.pdq(Hit, hits[0..nhits], {}, better);
    list.sel = 0;
    list.scroll = 0;
    list.setCount(nhits);
    ui.kbd_nav = true; // the first row is highlighted — Enter launches it
}

fn setMode(m: Mode) void {
    mode = m;
    ui.clearMsg();
    ui.redraw();
}

// ================================================================= launching

/// The highlighted row: under the mouse or selected with the arrows.
fn current() usize {
    if (!ui.kbd_nav and ui.hover.id == @intFromEnum(Wid.row)) return ui.hover.idx;
    return list.sel;
}

fn launch(pos: usize, term: bool, raw: bool) void {
    if (broker_fd < 0) return ui.setMsg("Could not start the launch process");
    const flags: u8 = if (term) F_TERM else 0;
    switch (mode) {
        .apps => {
            if (pos >= nhits) return;
            var m = [4]u8{ 'A', 0, 0, flags };
            std.mem.writeInt(u16, m[1..3], hits[pos].idx, .little);
            sys.sendAll(broker_fd, &m) catch return ui.setMsg("The launch process is not responding");
        },
        .cmds => {
            const q = std.mem.trim(u8, query.text(), " ");
            const cmd = if (raw or pos >= nhits or hits[pos].idx == TYPED) q else exes[hits[pos].idx].name.get();
            if (cmd.len == 0) return;
            var m: [2 + 256]u8 = undefined;
            m[0] = 'R';
            m[1] = flags;
            @memcpy(m[2..][0..cmd.len], cmd);
            sys.sendAll(broker_fd, m[0 .. 2 + cmd.len]) catch return ui.setMsg("The launch process is not responding");
        },
    }
    ui.quit();
}

// ================================================================= window

const Wid = enum(u8) { none, tab, field, row };
const tab_labels = [_][]const u8{ "Apps", "Commands" };

fn wid(w: ui.Widget) Wid {
    return @enumFromInt(w.id);
}

pub fn main(init: std.process.Init.Minimal) void {
    sys.init(init);
    img.max_pixels = 4 << 20; // icons: 2048×2048 at most
    if (sys.argIs(1, "run")) mode = .cmds;
    ui.begin("zrun");
    setupEnv();
    if (loadList()) {
        sys.tracef("list from cache: {d} apps, {d} commands", .{ napps, nexes });
    } else {
        loadExes();
        sortExes();
        loadApps();
        sortApps();
        iconSetup();
        saveList();
        sys.tracef("list built: {d} apps, {d} commands", .{ napps, nexes });
    }
    sortApps(); // visible ones alphabetically (from the cache too: it's fast)
    loadHistory();
    if (cfg.launcher_icons and icons_path.len > 0) {
        icons_fd = sys.openCreate(icons_path.z()) catch -1; // written from inside the sandbox
    }
    startBroker();

    const rows: f32 = @floatFromInt(cfg.launcher_rows);
    ui.run(.{
        .width = cfg.launcher_width,
        .height = @intFromFloat(LIST_Y + rows * ROW_H + 6),
        .layout = layout,
        .paint = paint,
        .activate = activate,
        .back = close,
        .key = onKey,
        .scroll = onScroll,
        .field = fieldOf,
        .start = start,
        .cleanup = saveIconCache,
    }, .{ .read = read_paths[0..nread] }, .{ .extra = &.{.lseek} });
}

fn start() void {
    list.visible = cfg.launcher_rows;
    ui.resetFocus(false); // focus is in the search field and stays there
}

fn close() void {
    ui.quit();
}

fn fieldOf(idx: u16) ?*ui.Field {
    _ = idx;
    return &query;
}

fn onScroll(dir: i32) void {
    list.scrollBy(dir);
}

fn activate(w: ui.Widget, right: bool) void {
    _ = right;
    switch (wid(w)) {
        .tab => setMode(@enumFromInt(w.idx)),
        .row => launch(w.idx, false, false),
        else => {},
    }
}

fn onKey(k: ui.Key) bool {
    const page: i32 = @intCast(list.visible);
    switch (k.code) {
        ui.K_TAB => setMode(if (mode == .apps) .cmds else .apps),
        ui.K_UP => list.move(-1),
        ui.K_DOWN => list.move(1),
        ui.K_PGUP => list.move(-page),
        ui.K_PGDN => list.move(page),
        ui.K_ENTER, ui.K_KPENTER => launch(current(), k.shift, k.ctrl),
        else => {
            if (!k.ctrl) return false;
            switch (k.code) {
                25, 37 => list.move(-1), // Ctrl+P, Ctrl+K
                49, 36 => list.move(1), // Ctrl+N, Ctrl+J
                else => return false,
            }
        },
    }
    return true;
}

fn tabW(i: usize) f32 {
    return ui.textW(tab_labels[i], 13) + 28;
}

fn layout() void {
    // the field changed (typing, paste, Ctrl+U) or the tab — recompute the list
    if (last_mode != mode or last_len != query.len or !std.mem.eql(u8, last_q[0..last_len], query.text())) refilter();
    ui.nwid = 0;
    const W = ui.W();
    var x = PAD;
    for (0..tab_labels.len) |i| {
        const w = tabW(i);
        ui.add(Wid.tab, i, .plain, x, TABS_Y, w, 30);
        x += w + 4;
    }
    ui.add(Wid.field, 0, .field, PAD, FIELD_Y, W - 2 * PAD, 38);
    var i = list.scroll;
    var y = LIST_Y;
    while (i < list.n and i < list.scroll + list.visible) : (i += 1) {
        ui.add(Wid.row, i, .row, PAD - 8, y, W - 2 * PAD + 16, ROW_H - 4);
        y += ROW_H;
    }
}

const ic_prompt = [_]draw.Prim{
    .{ .seg = .{ .x0 = 3.5, .y0 = 4, .x1 = 7.5, .y1 = 8 } },
    .{ .seg = .{ .x0 = 7.5, .y0 = 8, .x1 = 3.5, .y1 = 12 } },
    .{ .seg = .{ .x0 = 9, .y0 = 12.5, .x1 = 13, .y1 = 12.5 } },
};

fn plural(n: usize, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

fn countLabel(b: []u8) []const u8 {
    const n = if (mode == .cmds and nhits > 0 and hits[0].idx == TYPED) nhits - 1 else nhits;
    const word = if (mode == .apps) plural(n, "app", "apps") else plural(n, "command", "commands");
    return std.fmt.bufPrint(b, "{d} {s}", .{ n, word }) catch "";
}

fn paint(cv: *draw.Canvas) void {
    const t = &theme.t;
    const W = ui.W();
    for (ui.widgets[0..ui.nwid]) |w| {
        switch (wid(w)) {
            .tab => {
                const on = @intFromEnum(mode) == w.idx;
                if (on) {
                    ui.rrect(cv, w.x, w.y, w.w, w.h, w.h / 2, t.menu_field);
                } else if (ui.isHover(w)) ui.rrect(cv, w.x, w.y, w.w, w.h, w.h / 2, t.menu_hover);
                ui.centered(cv, tab_labels[w.idx], w.x + w.w / 2, ui.mid(w.y, w.h, 13), 13, if (on) t.menu_text else t.menu_muted);
            },
            .field => ui.field(cv, w, &query, if (mode == .apps) "Search apps" else "Command or program", false, 0),
            .row => paintRow(cv, w),
            .none => {},
        }
    }
    // to the right of the tabs — how many were found (or an error)
    var b: [48]u8 = undefined;
    const err = ui.msg().len > 0;
    const info = if (err) ui.msg() else countLabel(&b);
    _ = ui.text(cv, info, W - PAD - ui.textW(info, 12), ui.mid(TABS_Y, 30, 12), 12, if (err) t.menu_error else t.menu_muted, W - PAD);

    if (nhits == 0) {
        const cy = LIST_Y + @as(f32, @floatFromInt(list.visible)) * ROW_H / 2;
        const empty_all = (mode == .apps and nvis == 0) or (mode == .cmds and nexes == 0);
        const title = if (empty_all) (if (mode == .apps) "No apps found" else "No commands found") else "Nothing found";
        const hint = if (empty_all)
            (if (mode == .apps) "No .desktop files in the applications folders" else "PATH is empty")
        else if (mode == .apps) "Tab — search commands" else "";
        ui.centered(cv, title, W / 2, cy - 4, 15, t.menu_text);
        if (hint.len > 0) ui.centered(cv, hint, W / 2, cy + 18, 12, t.menu_muted);
    }
    ui.scrollbar(cv, &list, LIST_Y, ROW_H);
}

fn tile(cv: *draw.Canvas, x: f32, y: f32) void {
    ui.rrect(cv, x, y, ICON, ICON, 9, theme.t.menu_field);
}

fn paintAppIcon(cv: *draw.Canvas, a: *App, x: f32, y: f32) void {
    if (iconOf(a)) |px| {
        cv.argb(px, icon_t, icon_t, @intFromFloat(@round(x * ui.S)), @intFromFloat(@round(y * ui.S)));
        return;
    }
    // placeholder: a tile with the first letter of the name
    tile(cv, x, y);
    const name = a.name.get();
    const len = @min(std.unicode.utf8ByteSequenceLength(name[0]) catch 1, name.len);
    const cp = std.unicode.utf8Decode(name[0..len]) catch name[0];
    var lb: [4]u8 = undefined;
    const ln = std.unicode.utf8Encode(desk.upper(cp), &lb) catch 0;
    ui.centered(cv, lb[0..ln], x + ICON / 2, ui.mid(y, ICON, 15), 15, theme.t.menu_accent);
}

fn paintRow(cv: *draw.Canvas, w: ui.Widget) void {
    const t = &theme.t;
    if (list.lit(w)) ui.rrect(cv, w.x, w.y, w.w, w.h, 10, t.menu_hover);
    const h = hits[w.idx];
    const ix = w.x + 8;
    const iy = w.y + (w.h - ICON) / 2;
    const tx = ix + ICON + 12;
    const right = w.x + w.w - 12;
    switch (mode) {
        .apps => {
            const a = &apps[h.idx];
            paintAppIcon(cv, a, ix, iy);
            const hl = desk.highlight(a.f_name.get(), hitWords(h));
            const sub = a.sub.get();
            const base = if (sub.len > 0) w.y + 20 else ui.mid(w.y, w.h, 14);
            _ = ui.textMarked(cv, a.name.get(), tx, base, 14, t.menu_text, t.menu_accent, right, &hl);
            if (sub.len > 0) _ = ui.text(cv, sub, tx, w.y + 37, 11.5, t.menu_muted, right);
        },
        .cmds => {
            const typed = h.idx == TYPED;
            tile(cv, ix, iy);
            ui.icon(cv, &ic_prompt, ix + 8, iy + 8, 16, 1.6, if (typed) t.menu_accent else t.menu_muted);
            if (typed) {
                _ = ui.text(cv, std.mem.trim(u8, query.text(), " "), tx, w.y + 20, 14, t.menu_text, right);
                _ = ui.text(cv, "Run · Shift+Enter — in a terminal", tx, w.y + 37, 11.5, t.menu_muted, right);
            } else {
                const e = exes[h.idx];
                const hl = desk.highlight(e.f_name.get(), hitWords(h));
                _ = ui.textMarked(cv, e.name.get(), tx, ui.mid(w.y, w.h, 14), 14, t.menu_text, t.menu_accent, right, &hl);
            }
        },
    }
}
