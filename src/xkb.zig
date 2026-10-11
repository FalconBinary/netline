// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Разбор текстовой раскладки XKB, которую присылает композитор (wl_keyboard.keymap):
//! только то, что нужно для ввода текста — коды клавиш, символы по группам (раскладкам)
//! и двум уровням (обычный/Shift), Caps Lock для букв. Латиница, кириллица, Uxxxx.

const std = @import("std");

pub const Keymap = struct {
    syms: [256][4][2]u32 = std.mem.zeroes([256][4][2]u32),
    ngroups: [256]u8 = [_]u8{0} ** 256,

    /// Символ (кодовая точка Юникода) для клавиши evdev, или 0.
    pub fn char(km: *const Keymap, evdev: u32, group: u32, shift: bool, caps: bool) u32 {
        const code = evdev + 8;
        if (code >= 256) return 0;
        const ng = km.ngroups[code];
        if (ng == 0) return 0;
        const g = group % ng;
        const row = km.syms[code][g];
        var level: usize = if (shift) 1 else 0;
        if (caps and isLower(row[0]) and row[1] != 0 and row[1] != row[0]) level ^= 1;
        const c = row[level];
        return if (c != 0) c else row[0];
    }
};

fn isLower(c: u32) bool {
    return (c >= 'a' and c <= 'z') or (c >= 0x430 and c <= 0x45f);
}

// ================================================================= токенайзер

const Tok = struct {
    kind: enum { ident, keyname, string, punct, end },
    s: []const u8,
};

const Lexer = struct {
    t: []const u8,
    i: usize = 0,

    fn next(l: *Lexer) Tok {
        while (l.i < l.t.len) {
            const c = l.t[l.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                l.i += 1;
            } else if (c == '/' and l.i + 1 < l.t.len and l.t[l.i + 1] == '/') {
                while (l.i < l.t.len and l.t[l.i] != '\n') l.i += 1;
            } else if (c == '#') {
                while (l.i < l.t.len and l.t[l.i] != '\n') l.i += 1;
            } else break;
        }
        if (l.i >= l.t.len) return .{ .kind = .end, .s = "" };
        const st = l.i;
        const c = l.t[l.i];
        if (c == '<') {
            while (l.i < l.t.len and l.t[l.i] != '>') l.i += 1;
            l.i = @min(l.i + 1, l.t.len);
            return .{ .kind = .keyname, .s = l.t[st + 1 .. @max(st + 1, l.i - 1)] };
        }
        if (c == '"') {
            l.i += 1;
            while (l.i < l.t.len and l.t[l.i] != '"') l.i += 1;
            l.i = @min(l.i + 1, l.t.len);
            return .{ .kind = .string, .s = l.t[st..l.i] };
        }
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '-' or c == '.') {
            while (l.i < l.t.len and (std.ascii.isAlphanumeric(l.t[l.i]) or l.t[l.i] == '_' or l.t[l.i] == '+' or l.t[l.i] == '-' or l.t[l.i] == '.')) l.i += 1;
            return .{ .kind = .ident, .s = l.t[st..l.i] };
        }
        l.i += 1;
        return .{ .kind = .punct, .s = l.t[st..l.i] };
    }

    fn peek(l: *Lexer) Tok {
        const save = l.i;
        const t = l.next();
        l.i = save;
        return t;
    }
};

fn isPunct(t: Tok, p: u8) bool {
    return t.kind == .punct and t.s[0] == p;
}

/// Найти блок `name ... { ... };` и вернуть его тело.
fn section(text: []const u8, name: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, name) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, text, at, '{') orelse return null;
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        if (text[i] == '{') depth += 1;
        if (text[i] == '}') {
            depth -= 1;
            if (depth == 0) return text[open + 1 .. i];
        }
    }
    return null;
}

// ================================================================= разбор

const MAX_NAMES = 768;

pub fn parse(text: []const u8) Keymap {
    var km = Keymap{};
    var names: [MAX_NAMES][8]u8 = undefined;
    var name_len: [MAX_NAMES]u8 = undefined;
    var codes: [MAX_NAMES]u16 = undefined;
    var nn: usize = 0;

    // --- xkb_keycodes: <NAME> = N;  alias <A> = <B>;
    if (section(text, "xkb_keycodes")) |body| {
        var l = Lexer{ .t = body };
        while (true) {
            const t = l.next();
            if (t.kind == .end) break;
            if (t.kind == .keyname) {
                if (!isPunct(l.next(), '=')) continue;
                const v = l.next();
                if (v.kind != .ident) continue;
                const code = std.fmt.parseInt(u16, v.s, 10) catch continue;
                if (nn < MAX_NAMES and t.s.len <= 8) {
                    @memcpy(names[nn][0..t.s.len], t.s);
                    name_len[nn] = @intCast(t.s.len);
                    codes[nn] = code;
                    nn += 1;
                }
            } else if (t.kind == .ident and std.mem.eql(u8, t.s, "alias")) {
                const a = l.next();
                if (!isPunct(l.next(), '=')) continue;
                const b = l.next();
                if (a.kind != .keyname or b.kind != .keyname or a.s.len > 8) continue;
                const code = lookupName(names[0..nn], name_len[0..nn], codes[0..nn], b.s) orelse continue;
                if (nn < MAX_NAMES) {
                    @memcpy(names[nn][0..a.s.len], a.s);
                    name_len[nn] = @intCast(a.s.len);
                    codes[nn] = code;
                    nn += 1;
                }
            }
        }
    }

    // --- xkb_symbols: key <NAME> { ... };
    const sym_body = section(text, "xkb_symbols") orelse return km;
    var l = Lexer{ .t = sym_body };
    while (true) {
        const t = l.next();
        if (t.kind == .end) break;
        if (t.kind != .ident or !std.mem.eql(u8, t.s, "key")) continue;
        const kn = l.next();
        if (kn.kind != .keyname) continue;
        if (!isPunct(l.next(), '{')) continue;
        const code = lookupName(names[0..nn], name_len[0..nn], codes[0..nn], kn.s);
        var implicit: u8 = 0;
        // тело клавиши до закрывающей '}'
        while (true) {
            const x = l.next();
            if (x.kind == .end or isPunct(x, '}')) break;
            if (x.kind == .ident) {
                // name[GroupN] = value  |  name = value
                var group: u8 = 0;
                if (isPunct(l.peek(), '[')) {
                    _ = l.next();
                    const gtok = l.next();
                    group = groupNum(gtok.s);
                    _ = l.next(); // ']'
                }
                if (!isPunct(l.peek(), '=')) continue;
                _ = l.next();
                const is_syms = std.ascii.eqlIgnoreCase(x.s, "symbols");
                if (isPunct(l.peek(), '[')) {
                    _ = l.next();
                    if (is_syms and group >= 1 and group <= 4) {
                        if (code) |c| readList(&km, c, group, &l) else skipList(&l);
                    } else skipList(&l);
                } else {
                    _ = l.next(); // строка или идентификатор
                }
            } else if (isPunct(x, '[')) {
                implicit += 1;
                if (code != null and implicit <= 4) readList(&km, code.?, implicit, &l) else skipList(&l);
            }
        }
    }
    return km;
}

fn groupNum(s: []const u8) u8 {
    // "Group2" / "group2" / "2"
    var i: usize = 0;
    while (i < s.len and !std.ascii.isDigit(s[i])) i += 1;
    return std.fmt.parseInt(u8, s[i..], 10) catch 0;
}

fn lookupName(names: []const [8]u8, lens: []const u8, codes: []const u16, s: []const u8) ?u16 {
    for (names, lens, codes) |n, len, c| {
        if (std.mem.eql(u8, n[0..len], s)) return c;
    }
    return null;
}

fn skipList(l: *Lexer) void {
    while (true) {
        const t = l.next();
        if (t.kind == .end or isPunct(t, ']')) return;
    }
}

fn readList(km: *Keymap, code: u16, group: u8, l: *Lexer) void {
    if (code >= 256) return skipList(l);
    var level: usize = 0;
    while (true) {
        const t = l.next();
        if (t.kind == .end or isPunct(t, ']')) break;
        if (t.kind != .ident) continue;
        if (level < 2) km.syms[code][group - 1][level] = keysymChar(t.s);
        level += 1;
    }
    km.ngroups[code] = @max(km.ngroups[code], group);
}

// ================================================================= имена keysym -> Юникод

const Named = struct { n: []const u8, c: u21 };

const ascii_names = [_]Named{
    .{ .n = "space", .c = ' ' },        .{ .n = "exclam", .c = '!' },       .{ .n = "quotedbl", .c = '"' },
    .{ .n = "numbersign", .c = '#' },   .{ .n = "dollar", .c = '$' },       .{ .n = "percent", .c = '%' },
    .{ .n = "ampersand", .c = '&' },    .{ .n = "apostrophe", .c = '\'' },  .{ .n = "quoteright", .c = '\'' },
    .{ .n = "parenleft", .c = '(' },    .{ .n = "parenright", .c = ')' },   .{ .n = "asterisk", .c = '*' },
    .{ .n = "plus", .c = '+' },         .{ .n = "comma", .c = ',' },        .{ .n = "minus", .c = '-' },
    .{ .n = "period", .c = '.' },       .{ .n = "slash", .c = '/' },        .{ .n = "colon", .c = ':' },
    .{ .n = "semicolon", .c = ';' },    .{ .n = "less", .c = '<' },         .{ .n = "equal", .c = '=' },
    .{ .n = "greater", .c = '>' },      .{ .n = "question", .c = '?' },     .{ .n = "at", .c = '@' },
    .{ .n = "bracketleft", .c = '[' },  .{ .n = "backslash", .c = '\\' },   .{ .n = "bracketright", .c = ']' },
    .{ .n = "asciicircum", .c = '^' },  .{ .n = "underscore", .c = '_' },   .{ .n = "grave", .c = '`' },
    .{ .n = "quoteleft", .c = '`' },    .{ .n = "braceleft", .c = '{' },    .{ .n = "bar", .c = '|' },
    .{ .n = "braceright", .c = '}' },   .{ .n = "asciitilde", .c = '~' },   .{ .n = "numerosign", .c = 0x2116 },
    .{ .n = "section", .c = 0xa7 },     .{ .n = "degree", .c = 0xb0 },      .{ .n = "EuroSign", .c = 0x20ac },
    .{ .n = "plusminus", .c = 0xb1 },   .{ .n = "multiply", .c = 0xd7 },    .{ .n = "division", .c = 0xf7 },
    .{ .n = "guillemotleft", .c = 0xab }, .{ .n = "guillemotright", .c = 0xbb }, .{ .n = "sterling", .c = 0xa3 },
};

// строчные кириллические буквы по суффиксу имени Cyrillic_*
const cyr = [_]Named{
    .{ .n = "a", .c = 0x430 },  .{ .n = "be", .c = 0x431 },        .{ .n = "ve", .c = 0x432 },
    .{ .n = "ghe", .c = 0x433 }, .{ .n = "de", .c = 0x434 },       .{ .n = "ie", .c = 0x435 },
    .{ .n = "zhe", .c = 0x436 }, .{ .n = "ze", .c = 0x437 },       .{ .n = "i", .c = 0x438 },
    .{ .n = "shorti", .c = 0x439 }, .{ .n = "ka", .c = 0x43a },    .{ .n = "el", .c = 0x43b },
    .{ .n = "em", .c = 0x43c },  .{ .n = "en", .c = 0x43d },       .{ .n = "o", .c = 0x43e },
    .{ .n = "pe", .c = 0x43f },  .{ .n = "er", .c = 0x440 },       .{ .n = "es", .c = 0x441 },
    .{ .n = "te", .c = 0x442 },  .{ .n = "u", .c = 0x443 },        .{ .n = "ef", .c = 0x444 },
    .{ .n = "ha", .c = 0x445 },  .{ .n = "tse", .c = 0x446 },      .{ .n = "che", .c = 0x447 },
    .{ .n = "sha", .c = 0x448 }, .{ .n = "shcha", .c = 0x449 },    .{ .n = "hardsign", .c = 0x44a },
    .{ .n = "yeru", .c = 0x44b }, .{ .n = "softsign", .c = 0x44c }, .{ .n = "e", .c = 0x44d },
    .{ .n = "yu", .c = 0x44e },  .{ .n = "ya", .c = 0x44f },       .{ .n = "io", .c = 0x451 },
};

pub fn keysymChar(name: []const u8) u32 {
    if (name.len == 1) {
        const c = name[0];
        if (c >= 0x20 and c < 0x7f) return c;
        return 0;
    }
    // Uxxxx — символ Юникода
    if (name.len >= 5 and name[0] == 'U' and std.ascii.isHex(name[1])) {
        return std.fmt.parseInt(u21, name[1..], 16) catch 0;
    }
    // 0x1000xxxx — числовой keysym Юникода, 0x20..0xff — Latin-1
    if (std.mem.startsWith(u8, name, "0x")) {
        const v = std.fmt.parseInt(u32, name[2..], 16) catch return 0;
        if (v >= 0x01000000 and v <= 0x0110ffff) return v - 0x01000000;
        if (v >= 0x20 and v <= 0xff and v != 0x7f) return v;
        return 0;
    }
    for (ascii_names) |e| if (std.mem.eql(u8, e.n, name)) return e.c;
    if (std.mem.startsWith(u8, name, "Cyrillic_")) {
        const suf = name[9..];
        if (suf.len == 0) return 0;
        const upper = std.ascii.isUpper(suf[0]);
        for (cyr) |e| {
            if (std.ascii.eqlIgnoreCase(e.n, suf)) {
                if (!upper) return e.c;
                return if (e.c == 0x451) 0x401 else e.c - 0x20;
            }
        }
    }
    return 0;
}
