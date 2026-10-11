// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Настройки zpanel. Правите этот файл и пересобираете: `zig build -Doptimize=ReleaseSmall`.
//! Цвета можно менять и без пересборки — через файл темы (см. `theme_file` ниже и README).

const hex = @import("color.zig").hex;

pub const Position = enum { top, bottom };
pub const TagStyle = enum { dots, numbers };
pub const ClockFormat = enum { hm, hms, date_hm };

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
pub const clock_format: ClockFormat = .hm; // .hms будит панель каждую секунду, .hm — раз в минуту

pub const tag_style: TagStyle = .dots;
pub const hide_empty_tags = false; // прятать пустые неактивные теги
pub const tag_dot_w: f32 = 16; // ширина ячейки тега (стиль dots)
pub const tag_active_w: f32 = 30; // ширина активного тега (стиль dots)
pub const tag_number_w: f32 = 24; // ширина ячейки тега (стиль numbers)
pub const tag_number_size: f32 = 10;

// ---------------------------------------------------------------- нагрузка и безопасность

/// Wi‑Fi/Bluetooth обновляются по событиям ядра (netlink). Этот опрос — только запасной:
/// уровень сигнала и включение Bluetooth через bluetoothctl событий не дают.
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
};

// ---------------------------------------------------------------- действия
// Команды выполняются через /bin/sh -c процессом-брокером. Сама панель запускать
// программы не может — брокер исполняет только команды, вшитые сюда при сборке.
// null — ничего не делать.

pub const Action = struct {
    left: ?[*:0]const u8 = null,
    right: ?[*:0]const u8 = null,
    middle: ?[*:0]const u8 = null,
};

pub const wallpaper_dir = "$HOME/Pictures/wallpapers";
pub const lock_cmd = "swaylock -f";

pub const launcher = Action{
    .left = "rofi -show drun",
    .right = "rofi -show run",
};

pub const clock = Action{};

pub const wifi = Action{ .left = wifi_menu, .right = wifi_toggle };
pub const bluetooth = Action{ .left = bt_menu, .right = bt_toggle };
pub const wallpaper = Action{ .left = wall_random, .right = wall_pick };
pub const power = Action{ .left = power_menu, .right = lock_cmd };

// Wi‑Fi: список сетей через nmcli → rofi; пароль спрашивается, только если он нужен.
// Имена сетей приходят из эфира, поэтому везде в кавычках.
const wifi_menu =
    \\list=$(nmcli -t -f IN-USE,SIGNAL,SSID dev wifi list --rescan auto 2>/dev/null |
    \\  awk -F: '{ s=$0; sub(/^[^:]*:[^:]*:/, "", s); gsub(/\\:/, ":", s)
    \\             if (s != "" && !seen[s]++) printf "%s %3d%%  %s\n", ($1 == "*" ? "*" : " "), $2, s }')
    \\[ -n "$list" ] || exit 0
    \\sel=$(printf '%s\n' "$list" | rofi -dmenu -i -p wifi) || exit 0
    \\ssid=${sel#*%  }
    \\nmcli dev wifi connect "$ssid" >/dev/null 2>&1 || {
    \\  pass=$(rofi -dmenu -password -p "$ssid") || exit 0
    \\  nmcli dev wifi connect "$ssid" password "$pass"
    \\}
;

const wifi_toggle =
    \\if [ "$(nmcli radio wifi)" = enabled ]; then nmcli radio wifi off; else nmcli radio wifi on; fi
;

// Bluetooth: список сопряжённых устройств, «*» — подключено; выбор подключает/отключает.
const bt_menu =
    \\bluetoothctl show | grep -q 'Powered: yes' || { rfkill unblock bluetooth 2>/dev/null; bluetoothctl power on >/dev/null; }
    \\list=$(bluetoothctl devices | while read -r _ mac name; do
    \\  if bluetoothctl info "$mac" | grep -q 'Connected: yes'; then printf '* %s %s\n' "$mac" "$name"
    \\  else printf '  %s %s\n' "$mac" "$name"; fi
    \\done)
    \\[ -n "$list" ] || exit 0
    \\sel=$(printf '%s\n' "$list" | rofi -dmenu -i -p bluetooth) || exit 0
    \\mac=$(printf '%s' "$sel" | awk '{ print ($1 == "*") ? $2 : $1 }')
    \\case $sel in \**) bluetoothctl disconnect "$mac" ;; *) bluetoothctl connect "$mac" ;; esac
;

const bt_toggle =
    \\if bluetoothctl show | grep -q 'Powered: yes'; then bluetoothctl power off
    \\else rfkill unblock bluetooth 2>/dev/null; bluetoothctl power on; fi
;

// Обои: swaybg. Новый процесс стартует раньше, чем гасится старый, — без мигания.
// Последние обои — ссылка ~/.cache/zpanel-wallpaper (удобно восстанавливать при старте).
const wall_common = "dir=\"" ++ wallpaper_dir ++ "\"\n" ++
    \\set_wall() {
    \\  mkdir -p "$HOME/.cache" && ln -sf "$1" "$HOME/.cache/zpanel-wallpaper"
    \\  old=$(pgrep -u "$(id -u)" -x swaybg)
    \\  swaybg -m fill -i "$1" >/dev/null 2>&1 &
    \\  sleep 0.4; [ -n "$old" ] && kill $old
    \\}
    \\images() { find "$dir" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \); }
    \\
;

const wall_random = wall_common ++
    \\f=$(images | shuf -n 1)
    \\[ -n "$f" ] && set_wall "$f"
;

const wall_pick = wall_common ++
    \\f=$(images | sed "s|^$dir/||" | sort | rofi -dmenu -i -p wallpaper) || exit 0
    \\[ -n "$f" ] && set_wall "$dir/$f"
;

// Питание: блокировка, выход из mango, сон, перезагрузка, выключение (с подтверждением).
const power_menu = "lock='" ++ lock_cmd ++ "'\n" ++
    \\confirm() { [ "$(printf 'Нет\nДа\n' | rofi -dmenu -i -p "$1?")" = "Да" ]; }
    \\case $(printf 'Заблокировать\nВыйти\nСон\nПерезагрузить\nВыключить\n' | rofi -dmenu -i -p power) in
    \\  Заблокировать) $lock ;;
    \\  Выйти) confirm "Выйти" && { mmsg dispatch quit || pkill -u "$(id -u)" -x mango; } ;;
    \\  Сон) $lock & sleep 0.5; systemctl suspend ;;
    \\  Перезагрузить) confirm "Перезагрузить" && systemctl reboot ;;
    \\  Выключить) confirm "Выключить" && systemctl poweroff ;;
    \\esac
;
