// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Всё «бумажное» для лаунчера zrun: разбор .desktop-файлов (freedesktop Desktop Entry),
//! строка Exec → argv, поиск без учёта регистра с нечётким совпадением и подсветкой,
//! исправление запроса, набранного не в той раскладке. Без системных вызовов — только std,
//! поэтому проверяется тестами на любой машине: `zig test src/desktop.zig`.

const std = @import("std");
const eql = std.mem.eql;

// ================================================================= .desktop

pub const Locale = struct {
    full: []const u8 = "", // ru_RU
    lang: []const u8 = "", // ru
};

/// Язык из значения LC_ALL / LC_MESSAGES / LANG: "ru_RU.UTF-8" → ru_RU и ru.
pub fn locale(v: []const u8) Locale {
    var s = v;
    if (std.mem.indexOfAny(u8, s, ".@")) |i| s = s[0..i];
    if (s.len == 0 or eql(u8, s, "C") or eql(u8, s, "POSIX")) return .{};
    const us = std.mem.indexOfScalar(u8, s, '_') orelse s.len;
    return .{ .full = s, .lang = s[0..us] };
}

/// Поля группы [Desktop Entry]. Значения — как в файле, с экранированием (см. unescape).
pub const Entry = struct {
    name: []const u8 = "",
    name_c: []const u8 = "", // без перевода — чтобы «files» находило и «Файлы»
    generic: []const u8 = "",
    comment: []const u8 = "",
    keywords: []const u8 = "",
    exec: []const u8 = "",
    try_exec: []const u8 = "",
    icon: []const u8 = "",
    path: []const u8 = "",
    only_show_in: []const u8 = "",
    not_show_in: []const u8 = "",
    app: bool = false,
    terminal: bool = false,
    no_display: bool = false,
    hidden: bool = false,
};

pub fn parse(data: []const u8, loc: Locale) Entry {
    var e = Entry{};
    var rank = [_]u8{0} ** 4; // Name, GenericName, Comment, Keywords: 1 — без языка, 2 — ru, 3 — ru_RU
    var in_group = false;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (in_group) break; // [Desktop Entry] — первая группа, дальше действия и прочее
            in_group = eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_group) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        var key = std.mem.trimEnd(u8, line[0..eq], " \t");
        const val = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
        var r: u8 = 1;
        if (std.mem.indexOfScalar(u8, key, '[')) |lb| {
            if (key[key.len - 1] != ']') continue;
            const l = key[lb + 1 .. key.len - 1];
            key = key[0..lb];
            if (loc.full.len > 0 and eql(u8, l, loc.full)) {
                r = 3;
            } else if (loc.lang.len > 0 and eql(u8, l, loc.lang)) {
                r = 2;
            } else continue;
        }
        const slot: ?usize = if (eql(u8, key, "Name")) 0 else if (eql(u8, key, "GenericName")) 1 else if (eql(u8, key, "Comment")) 2 else if (eql(u8, key, "Keywords")) 3 else null;
        if (slot) |k| {
            if (k == 0 and r == 1) e.name_c = val;
            if (r > rank[k]) {
                rank[k] = r;
                switch (k) {
                    0 => e.name = val,
                    1 => e.generic = val,
                    2 => e.comment = val,
                    else => e.keywords = val,
                }
            }
            continue;
        }
        if (r != 1) continue;
        if (eql(u8, key, "Type")) {
            e.app = eql(u8, val, "Application");
        } else if (eql(u8, key, "Exec")) {
            e.exec = val;
        } else if (eql(u8, key, "TryExec")) {
            e.try_exec = val;
        } else if (eql(u8, key, "Icon")) {
            e.icon = val;
        } else if (eql(u8, key, "Path")) {
            e.path = val;
        } else if (eql(u8, key, "OnlyShowIn")) {
            e.only_show_in = val;
        } else if (eql(u8, key, "NotShowIn")) {
            e.not_show_in = val;
        } else if (eql(u8, key, "Terminal")) {
            e.terminal = isTrue(val);
        } else if (eql(u8, key, "NoDisplay")) {
            e.no_display = isTrue(val);
        } else if (eql(u8, key, "Hidden")) {
            e.hidden = isTrue(val);
        }
    }
    return e;
}

fn isTrue(v: []const u8) bool {
    return eql(u8, v, "true") or eql(u8, v, "1");
}

/// Раскрыть экранирование строки: \s \n \t \r \\ \; (перевод строки и табуляция → пробел).
/// dst не короче src. Возвращает заполненную часть dst.
pub fn unescape(src: []const u8, dst: []u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len and n < dst.len) : (i += 1) {
        var c = src[i];
        if (c == '\\' and i + 1 < src.len) {
            const r: ?u8 = switch (src[i + 1]) {
                's', 'n', 't', 'r' => ' ',
                '\\' => '\\',
                ';' => ';',
                else => null,
            };
            if (r) |x| {
                c = x;
                i += 1;
            }
        }
        dst[n] = c;
        n += 1;
    }
    return dst[0..n];
}

/// Показывать ли в текущем окружении: OnlyShowIn / NotShowIn против XDG_CURRENT_DESKTOP.
pub fn shownIn(only: []const u8, not: []const u8, desktops: []const u8) bool {
    if (only.len > 0 and !anyCommon(only, desktops)) return false;
    if (not.len > 0 and anyCommon(not, desktops)) return false;
    return true;
}

fn anyCommon(list: []const u8, desktops: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ';');
    while (it.next()) |item| {
        var dt = std.mem.tokenizeScalar(u8, desktops, ':');
        while (dt.next()) |d| {
            if (std.ascii.eqlIgnoreCase(item, d)) return true;
        }
    }
    return false;
}

// ================================================================= Exec → argv

/// Аргументы в одном буфере, каждый с завершающим нулём (готовы для execve).
pub const Argv = struct {
    buf: [4096]u8 = undefined,
    n: usize = 0,
    start: [64]u16 = undefined,
    argc: usize = 0,
    cur: usize = 0, // начало аргумента, который сейчас собирается
    overflow: bool = false,

    fn put(a: *Argv, c: u8) void {
        if (a.n + 1 >= a.buf.len) {
            a.overflow = true;
            return;
        }
        a.buf[a.n] = c;
        a.n += 1;
    }
    fn putAll(a: *Argv, s: []const u8) void {
        for (s) |c| a.put(c);
    }
    fn end(a: *Argv) void {
        if (a.argc == a.start.len) {
            a.overflow = true;
            return;
        }
        a.put(0);
        a.start[a.argc] = @intCast(a.cur);
        a.argc += 1;
        a.cur = a.n;
    }
    /// Добавить готовый аргумент целиком.
    pub fn add(a: *Argv, s: []const u8) void {
        a.putAll(s);
        a.end();
    }
    pub fn arg(a: *const Argv, i: usize) [:0]const u8 {
        const s = a.start[i];
        const e = std.mem.indexOfScalarPos(u8, a.buf[0..a.n], s, 0) orelse a.n;
        return a.buf[s..e :0];
    }
};

pub const Info = struct { name: []const u8 = "", icon: []const u8 = "", file: []const u8 = "" };

/// Строка Exec (уже после unescape) → аргументы по спецификации: двойные кавычки,
/// экранирование \" \` \$ \\ внутри них, коды %i %c %k %%. Файлов лаунчер не передаёт,
/// поэтому %f %F %u %U (и устаревшие %d %D %n %N %v %m) просто убираются.
/// false — Exec пустой или неверный (незакрытая кавычка, слишком длинный).
pub fn execArgv(exec: []const u8, info: Info, a: *Argv) bool {
    var i: usize = 0;
    while (true) {
        while (i < exec.len and (exec[i] == ' ' or exec[i] == '\t')) i += 1;
        if (i >= exec.len) break;
        var quoted = false;
        var had_quotes = false;
        while (i < exec.len) {
            const c = exec[i];
            if (!quoted and (c == ' ' or c == '\t')) break;
            if (c == '"') {
                quoted = !quoted;
                had_quotes = true;
                i += 1;
                continue;
            }
            if (quoted and c == '\\' and i + 1 < exec.len and std.mem.indexOfScalar(u8, "\"`$\\", exec[i + 1]) != null) {
                a.put(exec[i + 1]);
                i += 2;
                continue;
            }
            if (c == '%' and i + 1 < exec.len) {
                const code = exec[i + 1];
                i += 2;
                switch (code) {
                    '%' => a.put('%'),
                    'i' => if (info.icon.len > 0) {
                        if (a.n == a.cur) a.add("--icon");
                        a.putAll(info.icon);
                    },
                    'c' => a.putAll(info.name),
                    'k' => a.putAll(info.file),
                    else => {},
                }
                continue;
            }
            a.put(c);
            i += 1;
        }
        if (quoted) return false;
        // аргумент только из %U и т. п. исчезает целиком, а "" остаётся пустым аргументом
        if (a.n > a.cur or had_quotes) a.end();
    }
    return a.argc > 0 and !a.overflow;
}

/// Имя программы из Exec для поиска: «env FOO=1 /usr/bin/app %U» → «app».
/// Результат лежит в out.
pub fn execName(exec: []const u8, out: []u8) []const u8 {
    var a = Argv{};
    if (!execArgv(exec, .{}, &a)) return "";
    for (0..a.argc) |i| {
        const s = a.arg(i);
        if (eql(u8, s, "env") or std.mem.indexOfScalar(u8, s, '=') != null) continue;
        const base = if (std.mem.lastIndexOfScalar(u8, s, '/')) |k| s[k + 1 ..] else s;
        const n = @min(base.len, out.len);
        @memcpy(out[0..n], base[0..n]);
        return out[0..n];
    }
    return "";
}

// ================================================================= регистр и раскладка

/// Нижний регистр для латиницы, Latin-1 и кириллицы. Длина символа в UTF-8 не меняется —
/// поэтому позиции совпадений в сложенной строке годятся и для исходной (подсветка).
pub fn fold(cp: u21) u21 {
    const f: u21 = switch (cp) {
        'A'...'Z' => cp + 32,
        0xC0...0xD6, 0xD8...0xDE => cp + 32,
        0x410...0x42F => cp + 32,
        0x400...0x40F => cp + 80,
        else => cp,
    };
    return if (f == 0x451) 0x435 else f; // ё ищется как е
}

/// Для буквы на плитке-заглушке: первая буква прописной.
pub fn upper(cp: u21) u21 {
    return switch (cp) {
        'a'...'z' => cp - 32,
        0xE0...0xF6, 0xF8...0xFE => cp - 32,
        0x430...0x44F => cp - 32,
        0x450...0x45F => cp - 80,
        else => cp,
    };
}

/// Сложить регистр строки. dst не короче src; неверные байты UTF-8 копируются как есть.
pub fn foldStr(src: []const u8, dst: []u8) []u8 {
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c < 0x80) {
            dst[i] = @intCast(fold(c));
            i += 1;
        } else if (c >> 5 == 6 and i + 1 < src.len and src[i + 1] >> 6 == 2) {
            const cp: u21 = (@as(u21, c & 0x1f) << 6) | (src[i + 1] & 0x3f);
            const f = fold(cp);
            dst[i] = @intCast(0xC0 | (f >> 6));
            dst[i + 1] = @intCast(0x80 | (f & 0x3f));
            i += 2;
        } else {
            dst[i] = c;
            i += 1;
        }
    }
    return dst[0..src.len];
}

const lay_en = "qwertyuiop[]asdfghjkl;'zxcvbnm,.`";
const lay_ru = [_]u21{ 'й', 'ц', 'у', 'к', 'е', 'н', 'г', 'ш', 'щ', 'з', 'х', 'ъ', 'ф', 'ы', 'в', 'а', 'п', 'р', 'о', 'л', 'д', 'ж', 'э', 'я', 'ч', 'с', 'м', 'и', 'т', 'ь', 'б', 'ю', 'ё' };

/// Запрос, набранный не в той раскладке: «ашкуащч» → «firefox», «ntktuhfv» → «телеграм».
/// null — менять нечего.
pub fn swapLayout(src: []const u8, dst: []u8) ?[]u8 {
    var n: usize = 0;
    var changed = false;
    var view = std.unicode.Utf8View.init(src) catch return null;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        var out = cp;
        if (std.mem.indexOfScalar(u21, &lay_ru, cp)) |k| {
            out = lay_en[k];
        } else if (cp < 0x80) {
            if (std.mem.indexOfScalar(u8, lay_en, @intCast(cp))) |k| out = lay_ru[k];
        }
        if (out == 0x451) out = 0x435;
        if (out != cp) changed = true;
        const len = std.unicode.utf8CodepointSequenceLength(out) catch return null;
        if (n + len > dst.len) return null;
        _ = std.unicode.utf8Encode(out, dst[n..][0..len]) catch return null;
        n += len;
    }
    return if (changed) dst[0..n] else null;
}

// ================================================================= поиск

/// Подсвеченные байты (первые байты совпавших символов) — первые 256 байт строки.
pub const Hl = [4]u64;

fn mark(hl: *Hl, i: usize) void {
    if (i < 256) hl[i / 64] |= @as(u64, 1) << @intCast(i % 64);
}

pub fn marked(hl: *const Hl, i: usize) bool {
    return i < 256 and hl[i / 64] & (@as(u64, 1) << @intCast(i % 64)) != 0;
}

fn isSep(c: u8) bool {
    return switch (c) {
        ' ', '-', '_', '.', '/', '(', ')', ':', ',', ';', '+' => true,
        else => false,
    };
}

fn wordStart(h: []const u8, i: usize) bool {
    return i == 0 or isSep(h[i - 1]);
}

fn cpLen(c: u8) usize {
    return if (c < 0x80) 1 else if (c >> 5 == 6) 2 else if (c >> 4 == 14) 3 else if (c >> 3 == 30) 4 else 1;
}

/// Оценка совпадения слова запроса w с полем h (оба уже в нижнем регистре); 0 — не найдено.
/// Подстрока (лучше всего — с начала строки или слова) всегда выше нечёткого совпадения
/// (буквы по порядку, с пропусками: «gte» → «GNOME Text Editor»).
pub fn scoreWord(h: []const u8, w: []const u8, fuzzy: bool, hl: ?*Hl) u32 {
    if (w.len == 0) return 1;
    if (std.mem.indexOf(u8, h, w)) |first| {
        var at = first;
        var j: ?usize = first;
        while (j) |p| : (j = std.mem.indexOfPos(u8, h, p + 1, w)) {
            if (wordStart(h, p)) {
                at = p;
                break;
            }
        }
        var s: i32 = 1000;
        if (at == 0) {
            s += 600;
        } else if (wordStart(h, at)) {
            s += 400;
        } else s -= @intCast(@min(at, 50) * 4);
        if (w.len == h.len) s += 300;
        s -= @intCast(@min(h.len - w.len, 100));
        if (hl) |m| {
            var k = at;
            while (k < at + w.len) : (k += cpLen(h[k])) mark(m, k);
        }
        return @intCast(@max(s, 1));
    }
    if (!fuzzy) return 0;
    var tmp: Hl = .{ 0, 0, 0, 0 };
    var s: i32 = 500;
    var hi: usize = 0;
    var wi: usize = 0;
    var last_end: ?usize = null;
    while (wi < w.len) {
        const l = @min(cpLen(w[wi]), w.len - wi);
        const p = std.mem.indexOfPos(u8, h, hi, w[wi..][0..l]) orelse return 0;
        if (wordStart(h, p)) s += 15;
        if (last_end) |e| {
            if (p == e) s += 10 else s -= @intCast(@min(p - e, 10) * 3);
        }
        mark(&tmp, p);
        last_end = p + l;
        hi = p + l;
        wi += l;
    }
    s -= @intCast(@min(h.len, 100) / 4);
    if (hl) |m| {
        for (m, tmp) |*a, b| a.* |= b;
    }
    return @intCast(@max(s, 1));
}

pub const Field = struct { text: []const u8, weight: u32, fuzzy: bool = false };

/// Каждое слово запроса должно найтись хоть в одном поле; итог — сумма лучших оценок
/// (с весом поля). 0 — запись не подходит.
pub fn scoreFields(fields: []const Field, words: []const []const u8) u32 {
    var total: u32 = 0;
    for (words) |w| {
        var best: u32 = 0;
        for (fields) |f| {
            if (f.text.len == 0) continue;
            best = @max(best, scoreWord(f.text, w, f.fuzzy, null) * f.weight / 100);
        }
        if (best == 0) return 0;
        total += best;
    }
    return total;
}

/// Разбить запрос на слова (по пробелам).
pub fn splitWords(q: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, q, ' ');
    while (it.next()) |w| {
        if (n == out.len) break;
        out[n] = w;
        n += 1;
    }
    return n;
}

/// Какие байты названия подсветить для этих слов запроса.
pub fn highlight(h: []const u8, words: []const []const u8) Hl {
    var hl: Hl = .{ 0, 0, 0, 0 };
    for (words) |w| _ = scoreWord(h, w, true, &hl);
    return hl;
}

// ================================================================= тесты

const tt = std.testing;

test "разбор .desktop с переводами" {
    const data =
        \\# комментарий
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Files
        \\Name[ru]=Файлы
        \\Name[de]=Dateien
        \\GenericName[ru_RU]=Файловый менеджер
        \\GenericName[ru]=Менеджер файлов
        \\Keywords=folder;manager;
        \\Exec=nautilus --new-window %U
        \\Icon = org.gnome.Nautilus
        \\Terminal=false
        \\NoDisplay=true
        \\
        \\[Desktop Action new-window]
        \\Name=New Window
        \\Exec=nautilus --new-window
    ;
    const e = parse(data, locale("ru_RU.UTF-8"));
    try tt.expect(e.app);
    try tt.expectEqualStrings("Файлы", e.name);
    try tt.expectEqualStrings("Files", e.name_c);
    try tt.expectEqualStrings("Файловый менеджер", e.generic);
    try tt.expectEqualStrings("nautilus --new-window %U", e.exec);
    try tt.expectEqualStrings("org.gnome.Nautilus", e.icon);
    try tt.expect(e.no_display and !e.terminal and !e.hidden);
}

test "язык из LANG" {
    const l = locale("ru_RU.UTF-8@euro");
    try tt.expectEqualStrings("ru_RU", l.full);
    try tt.expectEqualStrings("ru", l.lang);
    try tt.expectEqualStrings("", locale("C.UTF-8").full);
}

test "unescape" {
    var b: [64]u8 = undefined;
    try tt.expectEqualStrings("a b\\c;d", unescape("a\\sb\\\\c\\;d", &b));
}

fn argvOf(exec: []const u8, info: Info, a: *Argv) !void {
    var b: [512]u8 = undefined;
    try tt.expect(execArgv(unescape(exec, &b), info, a));
}

test "Exec: коды, кавычки, экранирование" {
    var a = Argv{};
    try argvOf("firefox %u", .{}, &a);
    try tt.expectEqual(1, a.argc);
    try tt.expectEqualStrings("firefox", a.arg(0));

    a = .{};
    try argvOf("app --icon-arg %i --title=%c \"100%%\" %F", .{ .name = "My App", .icon = "app-icon" }, &a);
    try tt.expectEqual(6, a.argc);
    try tt.expectEqualStrings("--icon-arg", a.arg(1));
    try tt.expectEqualStrings("--icon", a.arg(2));
    try tt.expectEqualStrings("app-icon", a.arg(3));
    try tt.expectEqualStrings("--title=My App", a.arg(4));
    try tt.expectEqualStrings("100%", a.arg(5));

    // в файле \\ — после unescape \, внутри кавычек \" и \$ — буквальные символы
    a = .{};
    try argvOf("sh -c \"echo \\\\\"hi\\\\\" \\\\$HOME\" \"\"", .{}, &a);
    try tt.expectEqual(4, a.argc);
    try tt.expectEqualStrings("echo \"hi\" $HOME", a.arg(2));
    try tt.expectEqualStrings("", a.arg(3));

    a = .{};
    try tt.expect(!execArgv("app \"unterminated", .{}, &a));
    a = .{};
    try tt.expect(!execArgv("  %U ", .{}, &a));
}

test "имя программы из Exec" {
    var b: [64]u8 = undefined;
    try tt.expectEqualStrings("app", execName("env FOO=1 /usr/bin/app %U", &b));
    try tt.expectEqualStrings("code", execName("\"/opt/vs code/code\" --new", &b));
}

test "OnlyShowIn / NotShowIn" {
    try tt.expect(shownIn("", "", "mango"));
    try tt.expect(!shownIn("GNOME;KDE;", "", "mango"));
    try tt.expect(shownIn("GNOME;", "", "ubuntu:GNOME"));
    try tt.expect(!shownIn("", "Mango;", "mango"));
}

test "регистр складывается без смены длины" {
    var b: [64]u8 = undefined;
    const src = "Ёлка ТЕКСТ Àb Firefox";
    const f = foldStr(src, &b);
    try tt.expectEqualStrings("елка текст àb firefox", f);
    try tt.expectEqual(src.len, f.len);
    try tt.expectEqual(@as(u21, 'Ф'), upper('ф'));
}

test "не та раскладка" {
    var b: [64]u8 = undefined;
    try tt.expectEqualStrings("firefox", swapLayout("ашкуащч", &b).?);
    try tt.expectEqualStrings("телеграм", swapLayout("ntktuhfv", &b).?);
    try tt.expect(swapLayout("123", &b) == null);
}

test "порядок оценок" {
    const exact = scoreWord("firefox", "firefox", true, null);
    const prefix = scoreWord("firefox web browser", "fire", true, null);
    const word = scoreWord("mozilla firefox", "fire", true, null);
    const inner = scoreWord("campfire", "fire", true, null);
    const fuzzy = scoreWord("gnome text editor", "gte", true, null);
    try tt.expect(exact > prefix and prefix > word and word > inner and inner > fuzzy and fuzzy > 0);
    try tt.expectEqual(0, scoreWord("gnome text editor", "gte", false, null));
    try tt.expectEqual(0, scoreWord("firefox", "xyz", true, null));
}

test "слова запроса и подсветка" {
    var words: [8][]const u8 = undefined;
    const n = splitWords("  text  ed ", &words);
    try tt.expectEqual(2, n);
    const fields = [_]Field{ .{ .text = "gnome text editor", .weight = 100, .fuzzy = true }, .{ .text = "", .weight = 50 } };
    try tt.expect(scoreFields(&fields, words[0..n]) > 0);
    try tt.expectEqual(0, scoreFields(&fields, &.{ "text", "zzz" }));

    const hl = highlight("файлы", &.{"фа"});
    try tt.expect(marked(&hl, 0) and marked(&hl, 2) and !marked(&hl, 1) and !marked(&hl, 4));
}
