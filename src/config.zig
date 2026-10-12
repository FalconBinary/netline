// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Настройки zpanel. Правите этот файл и пересобираете: `zig build -Doptimize=ReleaseSafe`.
//! Цвета можно менять и без пересборки — через файл темы (см. `theme_file` ниже и README).

const hex = @import("color.zig").hex;

pub const Position = enum { top, bottom };
pub const TagStyle = enum { dots, numbers };
pub const ClockFormat = enum { hm, hms, date_hm, full };

/// Элементы панели. Часы всегда по центру.
pub const Item = enum { launcher, tags, clock, wifi, bluetooth, wallpaper, power };

pub const left = [_]Item{ .launcher, .tags };
pub const right = [_]Item{ .wifi, .bluetooth, .wallpaper, .power };

// ---------------------------------------------------------------- геометрия (логические пиксели)

pub const position: Position = .top;
pub const height: u32 = 34;
pub const margin_edge: i32 = 6; // отступ от края экрана
pub const margin_side: i32 = 10; // отступы слева и справа
pub const radius: f32 = 12; // скругление панели (0 — прямые углы)
pub const border_width: f32 = 0; // толщина рамки (0 — без рамки), цвет — theme.border
pub const padding: f32 = 6; // внутренний отступ по краям
pub const spacing: f32 = 2; // расстояние между кнопками
pub const button: f32 = 26; // размер кнопки (область клика и подсветки)
pub const button_radius: f32 = 8;
pub const icon: f32 = 16; // размер иконки
pub const icon_stroke: f32 = 1.6; // толщина линий иконок
pub const hover_effect = true; // подсвечивать кнопку под курсором

pub const clock_size: f32 = 12; // высота цифр часов
/// .hm — 13:31, .hms — 13:31:05 (будит панель каждую секунду), .date_hm — 12.10  13:31,
/// .full — Пн, 12 октября 2026  13:31
pub const clock_format: ClockFormat = .full;

pub const tag_style: TagStyle = .dots;
pub const hide_empty_tags = false; // прятать пустые неактивные теги
pub const tag_dot_w: f32 = 16; // ширина ячейки тега (стиль dots)
pub const tag_active_w: f32 = 30; // ширина активного тега (стиль dots)
pub const tag_number_w: f32 = 24; // ширина ячейки тега (стиль numbers)
pub const tag_number_size: f32 = 10;

// ---------------------------------------------------------------- нагрузка и безопасность

/// Wi‑Fi/Bluetooth обновляются по событиям ядра (netlink). Этот опрос — только запасной:
/// уровень сигнала и включение адаптера через BlueZ событий ядра не дают.
pub const status_poll_s: u32 = 30;

/// Песочница: seccomp (запрет exec, сетевых сокетов, записи файлов) + Landlock (чтение только
/// /sys, /proc, tzdata и папки темы). Внешние команды запускает отдельный процесс-брокер,
/// и только из списка ниже. Выключать имеет смысл лишь для отладки.
pub const sandbox = true;

/// Файл темы относительно $XDG_CONFIG_HOME (или ~/.config). Перечитывается при сохранении.
pub const theme_file = "zpanel/theme";

// ---------------------------------------------------------------- цвета
// Формат: "#RRGGBB" или "#RRGGBBAA" (AA — прозрачность, ff — непрозрачный).
// Любое поле можно переопределить в файле темы строкой `имя = #цвет`.

pub const Theme = struct {
    // панель
    background: u32,
    border: u32,
    hover: u32,
    // лаунчер
    launcher: u32,
    // теги
    tag_active: u32,
    tag_occupied: u32,
    tag_empty: u32,
    tag_urgent: u32,
    tag_active_text: u32, // цифра на активном теге (стиль numbers)
    // часы
    clock: u32,
    // Wi‑Fi
    wifi: u32, // горящие дуги и точка
    wifi_inactive: u32, // негорящие дуги
    wifi_off: u32, // перечёркивание при выключенном радио
    // Bluetooth
    bluetooth_on: u32,
    bluetooth_connected: u32,
    bluetooth_off: u32,
    // обои и питание
    wallpaper: u32,
    power: u32,
    // меню Wi‑Fi (zwifi)
    menu_background: u32,
    menu_backdrop: u32, // затемнение экрана вокруг меню
    menu_text: u32,
    menu_muted: u32,
    menu_accent: u32,
    menu_accent_text: u32, // текст на акцентной кнопке
    menu_field: u32, // поля ввода и вторичные кнопки
    menu_border: u32,
    menu_hover: u32,
    menu_error: u32,
    // рабочий стол (zbg): цвет, пока обои не выбраны, и поля в режиме .fit
    desktop: u32,
};

pub const theme = Theme{
    .background = hex("#1e1e2eeb"),
    .border = hex("#45475a"),
    .hover = hex("#ffffff1f"),
    .launcher = hex("#cdd6f4"),
    .tag_active = hex("#89b4fa"),
    .tag_occupied = hex("#cdd6f4"),
    .tag_empty = hex("#585b70"),
    .tag_urgent = hex("#f38ba8"),
    .tag_active_text = hex("#1e1e2e"),
    .clock = hex("#cdd6f4"),
    .wifi = hex("#cdd6f4"),
    .wifi_inactive = hex("#585b70"),
    .wifi_off = hex("#f38ba8"),
    .bluetooth_on = hex("#cdd6f4"),
    .bluetooth_connected = hex("#89b4fa"),
    .bluetooth_off = hex("#585b70"),
    .wallpaper = hex("#cdd6f4"),
    .power = hex("#f38ba8"),
    .menu_background = hex("#1e1e2ef2"),
    .menu_backdrop = hex("#00000059"),
    .menu_text = hex("#cdd6f4"),
    .menu_muted = hex("#7f849c"),
    .menu_accent = hex("#89b4fa"),
    .menu_accent_text = hex("#1e1e2e"),
    .menu_field = hex("#313244"),
    .menu_border = hex("#45475a"),
    .menu_hover = hex("#ffffff14"),
    .menu_error = hex("#f38ba8"),
    .desktop = hex("#11111b"),
};

// ---------------------------------------------------------------- меню (zwifi, zbt, zwall, zpower, zcal)

/// Шрифты TrueType (.ttf, контуры glyf) — берётся первый найденный.
/// CFF/OTF не поддерживаются. Вставьте свой путь первой строкой.
pub const font_paths = [_][]const u8{
    "/usr/share/fonts/noto/NotoSans-Regular.ttf", // Arch
    "/usr/share/fonts/TTF/DejaVuSans.ttf", // Arch
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf", // Debian/Ubuntu
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", // Debian/Ubuntu
    "/usr/share/fonts/google-noto/NotoSans-Regular.ttf", // Fedora
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf", // Fedora
    "/usr/share/fonts/TTF/Inter-Regular.ttf",
};
/// Размер карточек Wi‑Fi и Bluetooth (у питания, календаря и обоев — свой).
pub const menu_width: u32 = 400;
pub const menu_height: u32 = 500;
pub const menu_radius: f32 = 16;

/// Питание: спрашивать подтверждение для выхода, перезагрузки и выключения.
pub const power_confirm = true;
/// Перед сном блокировать экран командой lock_cmd.
pub const lock_before_suspend = true;

/// Папка с обоями (~ — домашняя папка). Поддерживаются JPEG и PNG.
pub const wallpaper_dir = "~/Pictures/wallpapers";
/// Как вписывать обои: .fill — заполнить экран с обрезкой краёв, .fit — целиком, с полями.
pub const wallpaper_mode: enum { fill, fit } = .fill;

pub const lock_cmd = "swaylock -f";

// ---------------------------------------------------------------- лаунчер (zrun)

/// Ширина карточки и сколько строк видно в списке.
pub const launcher_width: u32 = 520;
pub const launcher_rows: u32 = 7;
/// Иконки приложений (PNG из темы иконок). false — только плитки с буквой.
pub const launcher_icons = true;
/// Тема иконок; "" — как в GTK (gtk-icon-theme-name в ~/.config/gtk-3.0/settings.ini).
/// Читаются только PNG: у тем из одних SVG (Papirus и т. п.) иконки берутся из hicolor,
/// а если и там нет — рисуется плитка с буквой.
pub const icon_theme = "";
/// Терминал для приложений с Terminal=true и для Shift+Enter: команда дописывается в конец.
/// foot, kitty — как есть; alacritty, xterm, ghostty — .{ "alacritty", "-e" }; wezterm — .{ "wezterm", "start", "--" }.
pub const terminal = [_][:0]const u8{"foot"};

// ---------------------------------------------------------------- действия
// Команды выполняет процесс-брокер: простые («zwifi toggle») — сразу, без shell,
// со спецсимволами (кавычки, |, ;, $, ~ …) — через /bin/sh -c. Сама панель запускать
// программы не может — брокер исполняет только команды, вшитые сюда при сборке.
// zrun, zwifi, zbt, zwall, zpower и zcal лежат рядом с zpanel — брокер находит их сам.
// null — ничего не делать.

pub const Action = struct {
    left: ?[*:0]const u8 = null,
    right: ?[*:0]const u8 = null,
    middle: ?[*:0]const u8 = null,
};

pub const launcher = Action{
    .left = "zrun", // приложения; rofi тоже можно: "rofi -show drun"
    .right = "zrun run", // команды из PATH
};

pub const clock = Action{ .left = "zcal" };
pub const wifi = Action{ .left = "zwifi", .right = "zwifi toggle" };
pub const bluetooth = Action{ .left = "zbt", .right = "zbt toggle" };
pub const wallpaper = Action{ .left = "zwall", .right = "zwall random" };
pub const power = Action{ .left = "zpower", .right = lock_cmd };
