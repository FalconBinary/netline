// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! netline settings. Edit this file and rebuild: `zig build -Doptimize=ReleaseSafe`.
//! Colors can also be changed without rebuilding — through the theme file (see `theme_file` below and the README).

const hex = @import("color.zig").hex;

pub const Position = enum { top, bottom };
pub const TagStyle = enum { dots, numbers };
pub const ClockFormat = enum { hm, hms, date_hm, short, full };
pub const PanelMode = enum { always, autohide };

/// Panel items. The clock is always in the center. An item with nothing to show takes no
/// room: no battery on a desktop, no backlight on an external monitor, no sound server running.
pub const Item = enum { launcher, tags, clock, sound, brightness, battery, wifi, bluetooth, wallpaper, power };

pub const left = [_]Item{ .launcher, .tags };
pub const right = [_]Item{ .sound, .brightness, .battery, .wifi, .bluetooth, .wallpaper, .power };

/// Whether the panel has this item: the code and the events for an unused one are not there at all.
pub fn hasItem(comptime item: Item) bool {
    for (left) |it| if (it == item) return true;
    for (right) |it| if (it == item) return true;
    return false;
}

// ---------------------------------------------------------------- how the panel appears

/// .autohide — like the macOS menu bar: windows get the whole screen, and the panel slides out
/// when the pointer reaches the screen edge, slides back when it leaves. It also comes out for a
/// moment when the volume, brightness or power source changes, and stays while its menu is open.
/// .always — always on screen, windows are placed below it.
pub const panel_mode: PanelMode = .autohide;
/// Duration of the slide in ms (0 — no animation). It follows the display's refresh and costs one
/// small message per frame: the picture itself is not redrawn.
pub const slide_ms: u32 = 260;
/// Same for the menus that come out from under the panel.
pub const menu_slide_ms: u32 = 200;
/// Pointer on the edge for this long before the panel comes out: reaching for a browser tab doesn't flash it.
pub const reveal_delay_ms: u32 = 40;
/// Pointer gone for this long before the panel goes back.
pub const hide_delay_ms: u32 = 400;
/// How long the panel and the level bar stay out after a change of volume or brightness.
pub const peek_ms: u32 = 1500;
/// The invisible strip of the hidden panel on the screen edge that catches the pointer (logical pixels).
pub const edge_strip: u32 = 2;
/// Over a fullscreen window (a game, a video), with .autohide: the panel stays hidden, and pushing the
/// pointer against the screen edge brings it out above the window, which keeps the whole screen.
/// mango draws fullscreen windows above the panel's usual layer, so while one is on the screen the
/// panel moves to the layer above (its strip, too, catches the pointer there); learned from the mango IPC.
/// false — the panel stays under fullscreen windows.
pub const over_fullscreen = true;
/// Pointer on the edge for this long before the panel comes out over a fullscreen window: a game or a
/// player used near the edge doesn't keep bringing it out.
pub const fullscreen_reveal_delay_ms: u32 = 250;

/// The percent next to the battery icon.
pub const battery_percent = true;
/// At or below this charge, while on battery, the icon turns red and the panel comes out once.
pub const battery_low: u8 = 15;

// ---------------------------------------------------------------- geometry (logical pixels)

pub const position: Position = .top;
pub const height: u32 = 34;
pub const margin_edge: i32 = 6; // gap from the screen edge
pub const margin_side: i32 = 10; // gaps on the left and right
pub const radius: f32 = 12; // panel corner rounding (0 — square corners)
pub const border_width: f32 = 0; // border thickness (0 — no border), color — theme.border
pub const padding: f32 = 6; // inner padding at the ends
pub const spacing: f32 = 2; // space between buttons
pub const button: f32 = 26; // button size (click and highlight area)
pub const button_radius: f32 = 8;
pub const icon: f32 = 16; // icon size
pub const icon_stroke: f32 = 1.6; // icon line thickness
pub const hover_effect = true; // highlight the button under the pointer

pub const clock_size: f32 = 12; // height of the clock digits
/// Font for the date and time — the first file found is used (TrueType .ttf with glyf outlines).
/// Put your own path first. Monospaced digits keep the clock from shifting as minutes change:
/// Noto Sans and DejaVu Sans already have them. If none is found, the clock is drawn with the
/// panel's vector digits and the date in numbers.
pub const clock_font_paths = [_][]const u8{
    "/usr/share/fonts/noto/NotoSans-Regular.ttf", // Arch
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf", // Debian/Ubuntu
    "/usr/share/fonts/google-noto/NotoSans-Regular.ttf", // Fedora
    "/usr/share/fonts/TTF/DejaVuSans.ttf", // Arch
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", // Debian/Ubuntu
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf", // Fedora
};
/// .hm — 13:31, .hms — 13:31:05 (wakes the panel every second), .date_hm — 12.10  13:31,
/// .short — Mon 12 Oct  13:31, .full — Mon, 12 October 2026  13:31
pub const clock_format: ClockFormat = .short;

pub const tag_style: TagStyle = .dots;
pub const hide_empty_tags = false; // hide empty inactive tags
pub const tag_dot_w: f32 = 16; // tag cell width (dots style)
pub const tag_active_w: f32 = 30; // active tag width (dots style)
pub const tag_number_w: f32 = 24; // tag cell width (numbers style)
pub const tag_number_size: f32 = 10;

// ---------------------------------------------------------------- load and security

/// Wi‑Fi, Bluetooth, power and backlight are updated on kernel events (netlink), and what sends no
/// events (Wi‑Fi signal, battery percent on many laptops) is read when the clock wakes the panel anyway.
/// This poll is only for reconnecting to mango and the sound server, and for kernels without the events.
pub const status_poll_s: u32 = 60;

/// Sandbox: seccomp (no exec, network sockets or file writes) + Landlock (read-only access to
/// the device folders of /sys, the panel's own /proc entry, tzdata and the theme folder). External commands are run by a separate broker process,
/// and only from the list below. Turning it off only makes sense for debugging.
pub const sandbox = true;

/// Theme file relative to $XDG_CONFIG_HOME (or ~/.config). Reread when saved.
pub const theme_file = "netline/theme";

// ---------------------------------------------------------------- colors
// Format: "#RRGGBB" or "#RRGGBBAA" (AA is opacity, ff — opaque).
// Any field can be overridden in the theme file with a `name = #color` line.

pub const Theme = struct {
    // panel
    background: u32,
    border: u32,
    hover: u32,
    // launcher
    launcher: u32,
    // tags
    tag_active: u32,
    tag_occupied: u32,
    tag_empty: u32,
    tag_urgent: u32,
    tag_active_text: u32, // digit on the active tag (numbers style)
    // clock
    clock: u32,
    // Wi‑Fi
    wifi: u32, // lit arcs and dot
    wifi_inactive: u32, // unlit arcs
    wifi_off: u32, // strike-through when the radio is off
    // Bluetooth
    bluetooth_on: u32,
    bluetooth_connected: u32,
    bluetooth_off: u32,
    // wallpaper and power
    wallpaper: u32,
    power: u32,
    // sound
    sound: u32,
    sound_muted: u32,
    // brightness
    brightness: u32,
    // battery
    battery: u32,
    battery_low: u32,
    battery_charging: u32,
    // the level bar that shows up with a change of volume or brightness
    level_track: u32,
    level_fill: u32,
    // Wi‑Fi menu (zwifi)
    menu_background: u32,
    menu_backdrop: u32, // screen dimming around the menu
    menu_text: u32,
    menu_muted: u32,
    menu_accent: u32,
    menu_accent_text: u32, // text on the accent button
    menu_field: u32, // input fields and secondary buttons
    menu_border: u32,
    menu_hover: u32,
    menu_error: u32,
    // desktop (zbg): color until a wallpaper is chosen, and the borders in .fit mode
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
    .sound = hex("#cdd6f4"),
    .sound_muted = hex("#f38ba8"),
    .brightness = hex("#cdd6f4"),
    .battery = hex("#cdd6f4"),
    .battery_low = hex("#f38ba8"),
    .battery_charging = hex("#a6e3a1"),
    .level_track = hex("#585b70"),
    .level_fill = hex("#cdd6f4"),
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

// ---------------------------------------------------------------- menus (zctl, zwifi, zbt, zwall, zpower, zcal)

/// TrueType fonts (.ttf, glyf outlines) — the first one found is used.
/// CFF/OTF are not supported. Put your own path first.
pub const font_paths = [_][]const u8{
    "/usr/share/fonts/noto/NotoSans-Regular.ttf", // Arch
    "/usr/share/fonts/TTF/DejaVuSans.ttf", // Arch
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf", // Debian/Ubuntu
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", // Debian/Ubuntu
    "/usr/share/fonts/google-noto/NotoSans-Regular.ttf", // Fedora
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf", // Fedora
    "/usr/share/fonts/TTF/Inter-Regular.ttf",
};
/// Size of the Wi‑Fi and Bluetooth cards (power, calendar and wallpaper have their own).
pub const menu_width: u32 = 400;
pub const menu_height: u32 = 500;
pub const menu_radius: f32 = 16;
/// Gap between the panel and a menu that comes out from under it.
pub const menu_gap: i32 = 6;

/// Power: ask for confirmation to log out, reboot and power off.
pub const power_confirm = true;
/// Lock the screen with lock_cmd before sleeping.
pub const lock_before_suspend = true;

/// Wallpaper folder (~ is the home folder). JPEG and PNG are supported.
pub const wallpaper_dir = "~/Pictures/wallpapers";
/// How to fit the wallpaper: .fill — fill the screen cropping the edges, .fit — whole, with borders.
pub const wallpaper_mode: enum { fill, fit } = .fill;

pub const lock_cmd = "swaylock -f";
/// Without systemd-logind (e.g. Void with runit) zpower reboots and powers off with these commands;
/// -n: fail instead of asking for a password nobody can type. The *_fallback command runs only if
/// doas isn't installed — in the same process, no shell. Needs a narrow rule without a password:
///   /etc/doas.conf:         permit nopass youruser as root cmd /usr/bin/poweroff args
///   /etc/sudoers.d/netline: youruser ALL=(root) NOPASSWD: /usr/bin/reboot, /usr/bin/poweroff
/// (If doas is installed but the rule is for sudo, put the sudo command in reboot_cmd/poweroff_cmd.)
/// null — the button is hidden when logind is absent.
pub const reboot_cmd: ?[*:0]const u8 = "doas -n /usr/bin/reboot";
pub const reboot_fallback: ?[*:0]const u8 = "sudo -n /usr/bin/reboot";
pub const poweroff_cmd: ?[*:0]const u8 = "doas -n /usr/bin/poweroff";
pub const poweroff_fallback: ?[*:0]const u8 = "sudo -n /usr/bin/poweroff";

/// Bluetooth on demand: when bluetoothd isn't running, zbt's toggle (and `zbt toggle`) runs
/// bt_service_on_cmd and waits for the service; turning Bluetooth off runs bt_service_off_cmd.
/// For void-hardened: "doas -n /usr/local/sbin/vh-bluetooth on" / "… off" (or the same with sudo -n). null — not used.
pub const bt_service_on_cmd: ?[*:0]const u8 = null;
pub const bt_service_off_cmd: ?[*:0]const u8 = null;

// ---------------------------------------------------------------- launcher (zrun)

/// Card width and how many rows of the list are visible.
pub const launcher_width: u32 = 520;
pub const launcher_rows: u32 = 7;
/// Application icons (PNG from the icon theme). false — only letter tiles.
pub const launcher_icons = true;
/// Icon theme; "" — same as GTK (gtk-icon-theme-name in ~/.config/gtk-3.0/settings.ini).
/// Only PNG is read: for SVG-only themes (Papirus etc.) icons come from hicolor,
/// and if they aren't there either, a letter tile is drawn.
pub const icon_theme = "";
/// Terminal for apps with Terminal=true and for Shift+Enter: the command is appended at the end.
/// foot, kitty — as is; alacritty, xterm, ghostty — .{ "alacritty", "-e" }; wezterm — .{ "wezterm", "start", "--" }.
pub const terminal = [_][:0]const u8{"foot"};

// ---------------------------------------------------------------- actions
// Commands are run by the broker process: simple ones ("zwifi toggle") directly, without a shell,
// ones with special characters (quotes, |, ;, $, ~ …) via /bin/sh -c. The panel itself cannot
// launch programs — the broker only runs commands built in here at compile time.
// zrun, zctl, zwifi, zbt, zwall, zpower and zcal live next to netline — the broker finds them itself.
// null — do nothing.

pub const Action = struct {
    left: ?[*:0]const u8 = null,
    right: ?[*:0]const u8 = null,
    middle: ?[*:0]const u8 = null,
    /// the wheel over the item
    up: ?[*:0]const u8 = null,
    down: ?[*:0]const u8 = null,
    /// `left` opens a menu: an auto-hiding panel stays out until the menu closes. false for a
    /// program that runs for long, otherwise the panel would stay out all that time.
    left_is_menu: bool = true,
};

pub const launcher = Action{
    .left = "zrun", // applications; rofi works too: "rofi -show drun"
    .right = "zrun run", // commands from PATH
};

pub const clock = Action{ .left = "zcal" };
pub const wifi = Action{ .left = "zwifi", .right = "zwifi toggle" };
pub const bluetooth = Action{ .left = "zbt", .right = "zbt toggle" };
pub const wallpaper = Action{ .left = "zwall", .right = "zwall random" };
pub const power = Action{ .left = "zpower", .right = lock_cmd };
pub const sound = Action{ .left = "zctl", .right = "zctl mute", .up = "zctl vol +5", .down = "zctl vol -5" };
pub const brightness = Action{ .left = "zctl", .up = "zctl bright +5", .down = "zctl bright -5" };
pub const battery = Action{ .left = "zctl" };
