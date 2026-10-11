// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Процесс-брокер — разделение привилегий.
//!
//! Он отделяется (fork) самым первым, ещё до подключения к Wayland и до песочницы,
//! и умеет ровно три вещи:
//!   'C' <номер>   — запустить команду из вшитой при сборке таблицы (config.zig);
//!   'D' <команда> — отправить в mango `dispatch` строго проверенного вида;
//!   'W'           — подключиться к IPC mango и передать панели готовый сокет.
//! Сама панель после этого живёт в песочнице без exec, fork, socket и connect:
//! даже если её взломать, запустить можно только то, что вы сами вписали в конфиг.

const std = @import("std");
const sys = @import("sys.zig");

var sock: i32 = -1;

pub fn start(cmds: []const ?[*:0]const u8) bool {
    const pair = sys.socketpair() catch return false;
    const pid = sys.fork() catch {
        sys.close(pair[0]);
        sys.close(pair[1]);
        return false;
    };
    if (pid == 0) {
        sys.close(pair[0]);
        sys.prependExeDirToPath(); // zwifi рядом с zpanel найдётся без настройки PATH
        serve(pair[1], cmds);
    }
    sys.close(pair[1]);
    sock = pair[0];
    return true;
}

// ---------------------------------------------------------------- сторона панели

pub fn run(slot: u8) void {
    const m = [2]u8{ 'C', slot };
    sys.sendAll(sock, &m) catch {};
}

pub fn dispatch(cmd: []const u8) void {
    var buf: [200]u8 = undefined;
    if (cmd.len + 1 > buf.len) return;
    buf[0] = 'D';
    @memcpy(buf[1..][0..cmd.len], cmd);
    sys.sendAll(sock, buf[0 .. cmd.len + 1]) catch {};
}

/// Попросить у брокера сокет `watch all-tags`. -1 — mango недоступен.
pub fn requestWatch() i32 {
    sys.sendAll(sock, "W") catch return -1;
    var pfd = [1]sys.PollFd{.{ .fd = sock, .events = sys.POLLIN }};
    const ready = sys.poll(&pfd, 1500) catch return -1;
    if (ready == 0) return -1;
    var buf: [16]u8 = undefined;
    var fd: i32 = -1;
    _ = sys.recvmsgFd(sock, &buf, &fd) catch return -1;
    return fd;
}

// ---------------------------------------------------------------- сторона брокера

fn serve(fd: i32, cmds: []const ?[*:0]const u8) noreturn {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf) catch sys.exit(0);
        if (n == 0) sys.exit(0); // панель завершилась
        const msg = buf[0..n];
        switch (msg[0]) {
            'C' => if (n == 2 and msg[1] < cmds.len) {
                if (cmds[msg[1]]) |c| sys.spawnShell(c);
            },
            'D' => if (validDispatch(msg[1..])) mangoDispatch(msg[1..]),
            'W' => sendWatch(fd),
            else => {},
        }
    }
}

fn mangoPath() ?[]const u8 {
    return sys.getenv("MANGO_INSTANCE_SIGNATURE");
}

fn mangoDispatch(cmd: []const u8) void {
    const s = sys.connectUnix(mangoPath() orelse return) catch return;
    defer sys.close(s);
    var b: [256]u8 = undefined;
    sys.sendAll(s, sys.joinZ(&b, &.{ "dispatch ", cmd, "\n" })) catch return;
    // ждём ответ, чтобы не закрыть сокет раньше, чем mango его отправит
    var pfd = [1]sys.PollFd{.{ .fd = s, .events = sys.POLLIN }};
    _ = sys.poll(&pfd, 300) catch return;
    var tmp: [256]u8 = undefined;
    _ = sys.read(s, &tmp) catch {};
}

fn sendWatch(fd: i32) void {
    const s = sys.connectUnix(mangoPath() orelse "") catch {
        _ = sys.sendmsgFds(fd, "W", &.{}) catch {};
        return;
    };
    defer sys.close(s);
    sys.sendAll(s, "watch all-tags\n") catch {
        _ = sys.sendmsgFds(fd, "W", &.{}) catch {};
        return;
    };
    _ = sys.sendmsgFds(fd, "W", &.{s}) catch {};
}

fn isNum(s: []const u8) bool {
    if (s.len == 0 or s.len > 2) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

pub fn isMonName(s: []const u8) bool {
    if (s.len == 0 or s.len > 63) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

/// Разрешены только: viewcrossmon,N,МОНИТОР | view,N,0 | toggleview,N
fn validDispatch(s: []const u8) bool {
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |p| {
        if (n == parts.len) return false;
        parts[n] = p;
        n += 1;
    }
    const eql = std.mem.eql;
    if (n == 3 and eql(u8, parts[0], "viewcrossmon")) return isNum(parts[1]) and isMonName(parts[2]);
    if (n == 3 and eql(u8, parts[0], "view")) return isNum(parts[1]) and eql(u8, parts[2], "0");
    if (n == 2 and eql(u8, parts[0], "toggleview")) return isNum(parts[1]);
    return false;
}
