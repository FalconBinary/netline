#!/usr/bin/env python3
# Copyright (c) 2026 Denys (FalconBinary)
# SPDX-License-Identifier: GPL-3.0-or-later
"""The panel and zctl under a real compositor (headless sway) and a real sound server, on a fake
/sys battery and backlight: zig build -Dtrace=true -Dtest_root=/tmp/netline-fake

Run as root in a throwaway container: it drops to `nobody` for the session itself, and root is only
kept to send the kernel-style device events the panel listens to.
"""

import argparse
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vpointer import Pointer, BTN_RIGHT  # noqa: E402

W, H = 1280, 720
FAKE = "/tmp/netline-fake"
RUN = "/tmp/netline-run"
UID = 65534
fails = []
passed = 0


def check(name, ok, detail=""):
    global passed
    if ok:
        passed += 1
        print(f"ok    {name}", flush=True)
    else:
        fails.append(name)
        print(f"FAIL  {name}: {detail}", flush=True)


def drop():
    os.setgroups([])
    os.setgid(UID)
    os.setuid(UID)


def env():
    return dict(os.environ, XDG_RUNTIME_DIR=RUN, HOME=RUN + "/home", WAYLAND_DISPLAY="wayland-netline",
                WLR_BACKENDS="headless", WLR_RENDERER="pixman", WLR_LIBINPUT_NO_DEVICES="1", LIBSEAT_BACKEND="noop",
                NETLINE_TRACE="1", PATH=f"{args.bin}:" + os.environ["PATH"], PULSE_SERVER=f"unix:{RUN}/pulse/native")


def spawn(*cmd, **kw):
    return subprocess.Popen(cmd, env=env(), preexec_fn=drop, **kw)


def run(*cmd):
    return subprocess.run(cmd, env=env(), preexec_fn=drop, capture_output=True, text=True, timeout=20)


def write_fake(path, value):
    with open(os.path.join(FAKE, path), "w") as f:
        f.write(str(value) + "\n")
    os.chown(os.path.join(FAKE, path), UID, UID)


def read_fake(path):
    with open(os.path.join(FAKE, path)) as f:
        return f.read().strip()


def make_fake():
    shutil.rmtree(FAKE, ignore_errors=True)
    bat = "sys/class/power_supply/BAT0"
    light = "sys/class/backlight/test"
    mouse = "sys/class/power_supply/hidpp_battery_0"
    for d in (bat, light, mouse, "sys/class/power_supply/AC"):
        os.makedirs(os.path.join(FAKE, d))
    for d, _, _ in os.walk(FAKE):
        os.chown(d, UID, UID)
    for k, v in dict(type="Battery", status="Discharging", capacity=64, present=1, energy_now=32000000,
                     energy_full=50000000, power_now=10000000).items():
        write_fake(f"{bat}/{k}", v)
    # a wireless mouse: a battery too, but not the one the panel is about
    for k, v in dict(type="Battery", scope="Device", status="Discharging", capacity=5).items():
        write_fake(f"{mouse}/{k}", v)
    write_fake("sys/class/power_supply/AC/type", "Mains")
    for k, v in dict(type="raw", brightness=2500, max_brightness=10000).items():
        write_fake(f"{light}/{k}", v)


def uevent(subsystem):
    """What the kernel sends for a device: the panel listens to this, with no udevd around."""
    s = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 15)
    s.sendto(f"change@/devices/test\0ACTION=change\0SUBSYSTEM={subsystem}\0".encode(), (0, 1))
    s.close()


def murmur2(data):
    """libudev's subsystem hash, written here apart from the panel's own."""
    m = 0x5bd1e995
    h = len(data) & 0xffffffff
    i = 0
    while len(data) - i >= 4:
        k = struct.unpack_from("<I", data, i)[0]
        k = (k * m) & 0xffffffff
        k ^= k >> 24
        k = (k * m) & 0xffffffff
        h = (h * m) & 0xffffffff
        h ^= k
        i += 4
    rest = data[i:]
    if len(rest) == 3:
        h ^= rest[2] << 16
    if len(rest) >= 2:
        h ^= rest[1] << 8
    if len(rest) >= 1:
        h ^= rest[0]
        h = (h * m) & 0xffffffff
    h ^= h >> 13
    h = (h * m) & 0xffffffff
    h ^= h >> 15
    return h


def udev_event(subsystem):
    """What udevd broadcasts: the panel takes these when udevd is running, through a filter in the kernel."""
    props = f"ACTION=change\0SUBSYSTEM={subsystem}\0".encode()
    header = b"libudev\0" + struct.pack(">I", 0xfeedcafe) + struct.pack("<III", 40, 40, len(props))
    header += struct.pack(">I", murmur2(subsystem.encode())) + struct.pack(">III", 0, 0, 0)
    s = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 15)
    s.sendto(header + props, (0, 2))
    s.close()


class Screen:
    """A screenshot as rows of (r, g, b)."""

    def __init__(self):
        out = subprocess.run(["grim", "-t", "ppm", "-"], env=env(), preexec_fn=drop, capture_output=True, timeout=20).stdout
        m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", out)
        self.w, self.h, self.d = int(m[1]), int(m[2]), out[m.end():]

    def px(self, x, y):
        i = (y * args.scale * self.w + x * args.scale) * 3
        return tuple(self.d[i:i + 3])

    def band(self, x0, x1, y0, y1):
        """Logical pixels, as everything else in this test."""
        k = args.scale
        return b"".join(self.d[(y * self.w + x0 * k) * 3:(y * self.w + x1 * k) * 3] for y in range(y0 * k, y1 * k))

    def save(self, name):
        with open(os.path.join(args.out, name + ".ppm"), "wb") as f:
            f.write(b"P6\n%d %d\n255\n" % (self.w, self.h) + self.d)


# the panel's body, at its shown position, away from the items
PROBE = (560, 23)


def panel_out():
    s = Screen()
    return s.px(*PROBE) != desktop


def wait_for(cond, seconds, step=0.03):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(step)
    return False


class Log:
    """Everything the panel writes (a -Dtrace=true build reports its slides and items)."""

    def __init__(self, path):
        self.path = path

    def text(self):
        with open(self.path, errors="replace") as f:
            return f.read()

    def mark(self):
        return len(self.text())

    def since(self, mark):
        return self.text()[mark:]


def items(log):
    found = {}
    for m in re.finditer(r"item (\w+) (-?\d+) (\d+)", log.text()):
        found[m[1]] = (int(m[2]), int(m[3]))
    return found


def item_x(name):
    """Panel coordinates to screen coordinates, the middle of the item."""
    x, w = items(log)[name]
    return 10 + x + w // 2


def sink_volume():
    out = run("pactl", "get-sink-volume", "@DEFAULT_SINK@").stdout
    m = re.search(r"(\d+)%", out)
    return int(m[1]) if m else None


def sink_mute():
    return "yes" in run("pactl", "get-sink-mute", "@DEFAULT_SINK@").stdout


def wakeups(pid):
    with open(f"/proc/{pid}/status") as f:
        st = f.read()
    return int(re.search(r"voluntary_ctxt_switches:\s+(\d+)", st)[1])


def cpu_ticks(pid):
    with open(f"/proc/{pid}/stat") as f:
        rest = f.read().rsplit(")", 1)[1].split()
    return int(rest[11]) + int(rest[12])


def rss_kb(pid):
    with open(f"/proc/{pid}/status") as f:
        return int(re.search(r"VmRSS:\s+(\d+)", f.read())[1])


def zctl_running():
    """A finished one may linger as a zombie where PID 1 doesn't collect them, as in a CI container."""
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/stat") as f:
                comm, state = re.match(r"\d+ \((.*)\) (\S)", f.read()).groups()
        except OSError:
            continue
        if comm == "zctl" and state != "Z":
            return True
    return False


def start_sound():
    if args.server == "pulse":
        p = spawn("pulseaudio", "-n", "--exit-idle-time=-1", "--daemonize=no", "--disable-shm=yes",
                  "-L", "module-native-protocol-unix", "-L", "module-null-sink sink_name=test sink_properties=device.description=Test-Speakers",
                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        procs = [p]
    else:
        procs = [spawn("pipewire", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)]
        time.sleep(0.6)
        procs.append(spawn("pipewire-pulse", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        procs.append(spawn("wireplumber", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))  # the default sink is its job
    if not wait_for(lambda: run("pactl", "info").returncode == 0, 10, 0.2):
        raise SystemExit("the sound server did not start")
    if args.server != "pulse":
        run("pactl", "load-module", "module-null-sink", "sink_name=test", "sink_properties=device.description=Test-Speakers")
    run("pactl", "set-default-sink", "test")
    if not wait_for(lambda: sink_volume() is not None, 10, 0.2):
        raise SystemExit("the sound server has no default output")
    run("pactl", "set-sink-volume", "@DEFAULT_SINK@", "50%")
    run("pactl", "set-sink-mute", "@DEFAULT_SINK@", "0")
    return procs


parser = argparse.ArgumentParser()
parser.add_argument("--bin", required=True)
parser.add_argument("--out", default="/tmp/netline-e2e")
parser.add_argument("--server", choices=["pulse", "pipewire"], default="pulse")
parser.add_argument("--scale", type=int, default=1)
args = parser.parse_args()

os.makedirs(args.out, exist_ok=True)
shutil.rmtree(RUN, ignore_errors=True)
os.makedirs(RUN + "/home/.config/netline", mode=0o700)
for d, _, _ in os.walk(RUN):
    os.chown(d, UID, UID)
os.chmod(RUN, 0o700)
os.chmod(args.out, 0o777)
make_fake()

with open(RUN + "/sway.conf", "w") as f:
    f.write(f"output HEADLESS-1 mode {W * args.scale}x{H * args.scale} scale {args.scale}\nseat * hide_cursor 0\n")
os.chown(RUN + "/sway.conf", UID, UID)

procs = []
try:
    sway_log = open(RUN + "/sway.log", "w")
    os.chown(RUN + "/sway.log", UID, UID)
    env_sway = env()
    sock = None
    sway = spawn("sway", "-c", RUN + "/sway.conf", stdout=sway_log, stderr=sway_log)
    procs.append(sway)
    wait_for(lambda: any(n.startswith("wayland-") and not n.endswith(".lock") for n in os.listdir(RUN)), 15, 0.1)
    display = [n for n in os.listdir(RUN) if n.startswith("wayland-") and not n.endswith(".lock")][0]
    os.environ["WAYLAND_DISPLAY"] = display
    _env = env
    env = lambda: dict(_env(), WAYLAND_DISPLAY=display)  # noqa: E731

    procs += start_sound()
    # a surface above the plain background makes screenshots of the "desktop" meaningful
    desktop = Screen().px(*PROBE)
    os.environ["XDG_RUNTIME_DIR"] = RUN
    pointer = Pointer(display, W, H)
    pointer.move(W // 2, H // 2)

    log_path = RUN + "/panel.log"
    panel_log = open(log_path, "w")
    os.chmod(log_path, 0o666)
    log = Log(log_path)
    panel = spawn(os.path.join(args.bin, "netline"), stdout=panel_log, stderr=panel_log)
    procs.append(panel)
    pid = panel.pid

    # ------------------------------------------------------------ first appearance
    check("the panel comes out at start", wait_for(panel_out, 3), "no panel on screen")
    Screen().save("1-start")
    check("the panel goes back on its own", wait_for(lambda: not panel_out(), 4), "still out after the first look")
    time.sleep(0.4)
    Screen().save("2-hidden")
    check("the panel is running in its sandbox", panel.poll() is None, f"exit {panel.poll()}")
    text = log.text()
    check("the sandbox is on", "seccomp: filter not installed" not in text, text[-300:])

    ys = [int(m) for m in re.findall(r"slide 0: y (-?\d+)", text)]
    out = []
    for y in ys:
        out.append(y)
        if y == 6:
            break
    check("the slide out passes through many positions", len(set(out)) >= 8, out)
    check("the slide out only moves one way", out == sorted(out), out)
    check("the slide ends at its place", out[-1:] == [6], out)
    check("the slide back ends off screen", ys[-1:] == [-34], ys[-5:])

    # ------------------------------------------------------------ pointer
    moved = log.mark()
    t0 = time.monotonic()
    pointer.move(W // 2, 0)
    check("touching the screen edge brings the panel out", wait_for(panel_out, 1.5), "no reaction to the edge")
    took = time.monotonic() - t0
    check("it comes out quickly", took < 0.6, f"{took:.2f} s")
    time.sleep(0.4)
    steps = re.findall(r"\[(\d+)\.(\d+)\] slide 0: y (-?\d+)", log.since(moved))
    times = [int(a) * 1000 + int(b) for a, b, _ in steps]  # the log counts ms and µs
    span = (times[-1] - times[0]) / 1_000_000 if times else 0
    check("the slide takes the configured time", 0.2 <= span <= 0.35, f"{span:.3f} s, {len(steps)} steps")
    check("the frames follow the display", len(steps) >= 10, f"{len(steps)} steps in {span:.3f} s")

    pointer.move(W // 2, 20)
    time.sleep(0.8)
    check("it stays while the pointer is on it", panel_out(), "went away under the pointer")
    pointer.move(W // 2, H // 2)
    check("it goes back after the pointer leaves", wait_for(lambda: not panel_out(), 1.5), "still out")

    # ------------------------------------------------------------ what the panel shows
    pointer.move(W // 2, 0)
    wait_for(panel_out, 1.5)
    time.sleep(0.4)
    pointer.move(W // 2, 20)
    found = items(log)
    for name in ("sound", "brightness", "battery"):
        check(f"the {name} item is on the panel", name in found, found)
    check("the battery item has room for its percent", found.get("battery", (0, 0))[1] > 26, found.get("battery"))
    s = Screen()
    s.save("3-panel")

    def item_band(name):
        x = 10 + items(log)[name][0]
        return Screen().band(x, x + items(log)[name][1], 6, 40)

    before = item_band("battery")
    write_fake("sys/class/power_supply/BAT0/capacity", 7)
    uevent("power_supply")
    time.sleep(0.4)
    check("a kernel event updates the battery", item_band("battery") != before, "same pixels")

    before = item_band("battery")
    write_fake("sys/class/power_supply/BAT0/status", "Charging")
    uevent("power_supply")
    time.sleep(0.4)
    check("plugging in changes the icon", item_band("battery") != before, "same pixels")
    Screen().save("4-charging")

    before = item_band("sound")
    run("pactl", "set-sink-mute", "@DEFAULT_SINK@", "1")
    time.sleep(0.4)
    check("mute shows at once", item_band("sound") != before, "same pixels")
    run("pactl", "set-sink-mute", "@DEFAULT_SINK@", "0")
    time.sleep(0.3)

    # the wheel over an icon
    x = item_x("sound")
    pointer.move(x, 20)
    time.sleep(0.2)
    start = sink_volume()
    pointer.wheel(-2)
    check("the wheel over the sound icon raises the volume", wait_for(lambda: sink_volume() == start + 10, 2), f"{start} -> {sink_volume()}")
    pointer.wheel(1)
    check("and lowers it", wait_for(lambda: sink_volume() == start + 5, 2), f"{start} -> {sink_volume()}")

    pointer.click(x, 20, BTN_RIGHT)
    check("right click mutes", wait_for(sink_mute, 2), "still on")
    time.sleep(0.5)  # the panel ignores the same command twice within 400 ms: a shaky double click
    pointer.click(x, 20, BTN_RIGHT)
    check("right click again unmutes", wait_for(lambda: not sink_mute(), 2), "still muted")

    light0 = int(read_fake("sys/class/backlight/test/brightness"))
    pointer.move(item_x("brightness"), 20)
    time.sleep(0.2)
    pointer.wheel(-1)
    check("the wheel over the sun raises the brightness", wait_for(lambda: int(read_fake("sys/class/backlight/test/brightness")) > light0, 2), read_fake("sys/class/backlight/test/brightness"))

    # ------------------------------------------------------------ peek
    pointer.move(W // 2, H // 2)
    wait_for(lambda: not panel_out(), 2.5)
    check("back in hiding", not panel_out(), "still out")
    time.sleep(0.3)
    run("pactl", "set-sink-volume", "@DEFAULT_SINK@", "33%")
    check("a volume change brings the panel out", wait_for(panel_out, 1.5), "stayed hidden")
    time.sleep(0.35)
    s = Screen()
    s.save("5-level")
    lx = 10 + min(v[0] for k, v in items(log).items() if k == "sound") - 8 - 72
    bar = s.band(lx, lx + 72, 23, 24)
    check("with the level bar", len({bar[i:i + 3] for i in range(0, len(bar), 3)}) >= 2, "plain row")
    check("then it goes back", wait_for(lambda: not panel_out(), 3), "still out")

    before = wakeups(pid)
    write_fake("sys/class/backlight/test/brightness", 4000)
    uevent("backlight")
    check("a brightness key brings it out too", wait_for(panel_out, 1.5), "stayed hidden")
    check("that took an event, not a poll", wakeups(pid) > before, "no wakeup")
    wait_for(lambda: not panel_out(), 3)

    # an unrelated event: the filter on a socket without udevd is in the program, so it wakes,
    # but it must not draw or come out
    time.sleep(0.6)
    mark = log.mark()
    uevent("usb")
    time.sleep(0.3)
    check("an unrelated device event changes nothing", not panel_out() and "frame" not in log.since(mark), log.since(mark)[-400:])

    # ------------------------------------------------------------ the menu
    pointer.move(W // 2, 0)
    wait_for(panel_out, 1.5)
    time.sleep(0.35)
    mark = log.mark()
    pointer.click(item_x("battery"), 20)
    check("clicking the battery opens zctl", wait_for(zctl_running, 2), "not running")
    time.sleep(0.05)
    midway = Screen()
    midway.save("6-menu-opening")
    time.sleep(0.5)
    menu = Screen()
    menu.save("7-menu")
    pointer.move(W // 2, H // 2)
    time.sleep(1.0)
    check("the panel stays out while its menu is open", panel_out(), "went away from under its menu")
    card_px = menu.px(W - 10 - 160, 46 + 6 + 2)
    check("the card is below the panel, at the right", card_px != desktop, card_px)
    check("no dimming around the card", menu.px(100, 400) == desktop, menu.px(100, 400))

    # sliders: the card is at x = W - 10 - 320, y = 46; sound tile first
    card_x, card_y = W - 10 - 320, 6 + 34 + 6
    track_x = card_x + 22
    track_w = 320 - 44
    sy = card_y + 10 + 34 + 14
    low = track_x + 30 + 14
    high = track_x + track_w - 14
    pointer.drag((low + high) // 2, sy, low + (high - low) // 4)
    check("dragging the sound slider sets the volume", wait_for(lambda: abs((sink_volume() or 0) - 25) <= 2, 2), sink_volume())
    Screen().save("8-slider")
    pointer.click(track_x + 12, sy)
    check("the icon in the slider mutes", wait_for(sink_mute, 2), "still on")
    pointer.click(track_x + 12, sy)
    time.sleep(0.4)
    check("and unmutes", not sink_mute(), "still muted")

    ly = card_y + 10 + 74 + 8 + 34 + 14
    pointer.drag((low + high) // 2, ly, high)
    check("dragging the display slider to the end", wait_for(lambda: read_fake("sys/class/backlight/test/brightness") == "10000", 2), read_fake("sys/class/backlight/test/brightness"))
    pointer.drag(high, ly, track_x - 40)
    time.sleep(0.2)
    value = int(read_fake("sys/class/backlight/test/brightness"))
    check("and to the start: dim, but never off", 1 <= value < 200, value)
    write_fake("sys/class/backlight/test/brightness", 4000)

    mark = log.mark()
    pointer.click(100, 400)
    check("a click outside closes the menu", wait_for(lambda: not zctl_running(), 2), "still running")
    check("the panel goes back once the menu is closed", wait_for(lambda: not panel_out(), 2.5), "stays out")

    # opening it again with no leftovers
    run(os.path.join(args.bin, "zctl"), "status")
    out = run(os.path.join(args.bin, "zctl"), "status").stdout
    print(out, flush=True)
    check("zctl status: sound", re.search(r"^sound \d+ on Test-Speakers", out, re.M), out)
    check("zctl status: brightness", re.search(r"^brightness 63 4000/10000 test", out, re.M), out)
    check("zctl status: battery, not the mouse", re.search(r"^battery 7 charging", out, re.M), out)

    # ------------------------------------------------------------ the command
    zctl = os.path.join(args.bin, "zctl")
    run("pactl", "set-sink-volume", "@DEFAULT_SINK@", "40%")
    time.sleep(0.2)
    check("zctl vol +5", run(zctl, "vol", "+5").returncode == 0 and wait_for(lambda: sink_volume() == 45, 1), sink_volume())
    check("zctl vol -10", run(zctl, "vol", "-10").returncode == 0 and wait_for(lambda: sink_volume() == 35, 1), sink_volume())
    check("zctl vol 70", run(zctl, "vol", "70").returncode == 0 and wait_for(lambda: sink_volume() == 70, 1), sink_volume())
    run(zctl, "vol", "100")
    run(zctl, "vol", "+5")
    time.sleep(0.2)
    check("the volume stops at 100", sink_volume() == 100, sink_volume())
    run(zctl, "mute")
    check("zctl mute", wait_for(sink_mute, 1), "not muted")
    run(zctl, "vol", "+5")
    check("raising the volume unmutes", wait_for(lambda: not sink_mute(), 1), "still muted")
    run(zctl, "bright", "50")
    check("zctl bright 50", read_fake("sys/class/backlight/test/brightness") == "2500", read_fake("sys/class/backlight/test/brightness"))
    check("zctl refuses nonsense", run(zctl, "vol", "banana").returncode == 1 and run(zctl, "bright", "500").returncode == 1 and run(zctl, "nope").returncode == 1)

    # a server that goes away and comes back
    wait_for(lambda: not panel_out(), 3)
    time.sleep(0.2)
    for p in procs[:]:
        if p.args[0] in ("pulseaudio", "pipewire", "pipewire-pulse", "wireplumber"):
            p.terminate()
            p.wait(5)
            procs.remove(p)
    time.sleep(0.4)
    check("the panel survives the sound server stopping", panel.poll() is None, panel.poll())
    procs += start_sound()
    mark = log.mark()
    # the panel retries once a second for a while after losing it
    wait_for(lambda: "broker" in log.since(mark) or panel.poll() is not None, 3)
    time.sleep(12)
    check("and finds the new server", "item sound" in log.since(mark), log.since(mark)[-300:])

    # ------------------------------------------------------------ cost
    wait_for(lambda: not panel_out(), 3)
    time.sleep(1.5)
    w0, c0 = wakeups(pid), cpu_ticks(pid)
    time.sleep(6)
    w1, c1 = wakeups(pid), cpu_ticks(pid)
    print(f"idle: {w1 - w0} wakeups, {c1 - c0} CPU ticks in 6 s, RSS {rss_kb(pid)} KiB", flush=True)
    # at most one: the clock, if a minute boundary falls inside
    check("hidden and idle, the panel sleeps", w1 - w0 <= 1 and c1 - c0 <= 1, f"{w1 - w0} wakeups, {c1 - c0} ticks")
    check("it stays small", rss_kb(pid) < 4096, rss_kb(pid))
    check("the panel is still running", panel.poll() is None, panel.poll())
    # the sandbox is really on: the kernel knows
    with open(f"/proc/{pid}/status") as f:
        st = f.read()
    check("seccomp is active", re.search(r"Seccomp:\s+2", st), "not in filter mode")
    check("no new privileges", re.search(r"NoNewPrivs:\s+1", st), "off")
    try:
        open(f"/proc/{pid}/maps").close()
        closed = False
    except PermissionError:
        closed = True
    check("its memory map is closed even to root", closed, "readable")
    with open(os.path.join(args.bin, "netline"), "rb") as f:
        check("it loads at a random address (PIE)", f.read(18)[16] == 3, "fixed address")

    t0 = time.monotonic()
    for _ in range(50):
        run(zctl, "vol", "50")
    print(f"zctl vol, through this test's process start: {(time.monotonic() - t0) * 1000 / 50:.1f} ms each", flush=True)

    # ------------------------------------------------------------ with udevd, as on a real system
    panel.terminate()
    panel.wait(5)
    procs.remove(panel)
    os.makedirs("/run/udev", exist_ok=True)
    open("/run/udev/control", "w").close()  # how the panel knows udevd is running
    panel_log.close()
    log_path = RUN + "/panel-udev.log"
    panel_log = open(log_path, "w")
    os.chmod(log_path, 0o666)
    log = Log(log_path)
    panel = spawn(os.path.join(args.bin, "netline"), stdout=panel_log, stderr=panel_log)
    procs.append(panel)
    pid = panel.pid
    wait_for(panel_out, 3)
    check("with udevd: the panel starts", wait_for(lambda: not panel_out(), 4), "not hidden")
    time.sleep(0.4)

    before = wakeups(pid)
    for _ in range(20):
        udev_event("usb")
        udev_event("sound")
        uevent("power_supply")  # the kernel's own form: udevd's listeners don't take these
    time.sleep(0.5)
    check("the kernel's filter drops other subsystems: not one wakeup", wakeups(pid) == before, wakeups(pid) - before)

    pointer.move(W // 2, 0)
    wait_for(panel_out, 1.5)
    time.sleep(0.4)
    pointer.move(W // 2, 20)
    before = item_band("battery")
    write_fake("sys/class/power_supply/BAT0/capacity", 42)
    udev_event("power_supply")
    time.sleep(0.4)
    check("a battery event from udevd reaches the icon", item_band("battery") != before, "same pixels")
    pointer.move(W // 2, H // 2)
    wait_for(lambda: not panel_out(), 2.5)
    time.sleep(0.3)
    write_fake("sys/class/backlight/test/brightness", 7000)
    udev_event("backlight")
    check("a backlight event from udevd brings the panel out", wait_for(panel_out, 1.5), "stayed hidden")
    wait_for(lambda: not panel_out(), 3)
    before = wakeups(pid)
    udev_event("rfkill")
    time.sleep(0.2)
    check("and rfkill still passes the filter", wakeups(pid) > before, "no wakeup")
    check("the panel is running at the end", panel.poll() is None, panel.poll())
finally:
    for p in reversed(procs):
        if p.poll() is None:
            p.terminate()
    for p in procs:
        try:
            p.wait(5)
        except subprocess.TimeoutExpired:
            p.kill()
    for name in ("panel.log", "panel-udev.log", "sway.log"):
        if os.path.exists(os.path.join(RUN, name)):
            shutil.copy(os.path.join(RUN, name), args.out)

print(f"{passed} passed, {len(fails)} failed", flush=True)
sys.exit(1 if fails else 0)
