// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! The broker process — privilege separation.
//!
//! It forks off first of all, before connecting to Wayland and before the sandbox,
//! and can do exactly three things:
//!   'C' <number>  — run a command from the table built in at compile time (config.zig):
//!                   a simple one ("zwifi toggle") directly via execve, one with shell
//!                   special characters (quotes, |, ;, $ …) via /bin/sh -c;
//!   'D' <command> — send mango a `dispatch` of a strictly checked form;
//!   'W'           — connect to the mango IPC and hand the panel the ready socket.
//! After that the panel itself lives in a sandbox without exec, fork, socket and connect:
//! even if it is compromised, it can only run what you wrote into the config yourself.

const std = @import("std");
const sys = @import("sys.zig");

var sock: i32 = -1;

/// A command parsed at compile time.
pub const Cmd = struct {
    argv: ?[*:null]const ?[*:0]const u8 = null, // simple: words separated by spaces
    shell: ?[*:0]const u8 = null, // with special characters — passed whole to /bin/sh -c
};

/// Characters with which a string is just space-separated words and needs no shell.
fn plain(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', ' ', '-', '_', '.', '/', '=', ',', '+', ':', '@', '%' => true,
        else => false,
    };
}

/// Parse a command from config.zig at compile time. Simple commands run without a shell:
/// one process fewer per click (and no libc load for /bin/sh).
pub fn compile(comptime s: ?[*:0]const u8) ?Cmd {
    const z = s orelse return null;
    comptime {
        const str = std.mem.span(z);
        for (str) |c| if (!plain(c)) return .{ .shell = z };
        var words: [32]?[*:0]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, str, ' ');
        while (it.next()) |w| : (n += 1) {
            // "FOO=bar program" is a variable assignment, only a shell understands that
            if (n == 0 and std.mem.indexOfScalar(u8, w, '=') != null) return .{ .shell = z };
            words[n] = std.fmt.comptimePrint("{s}", .{w});
        }
        if (n == 0) return null;
        var av: [n:null]?[*:0]const u8 = undefined;
        for (0..n) |i| av[i] = words[i];
        const final = av;
        return .{ .argv = &final };
    }
}

pub fn start(cmds: []const ?Cmd) bool {
    const pair = sys.socketpair() catch return false;
    const pid = sys.fork() catch {
        sys.close(pair[0]);
        sys.close(pair[1]);
        return false;
    };
    if (pid == 0) {
        // the broker needs none of the other descriptors ("menu open" socket, Wayland, D-Bus) —
        // keep only our end of the pair and stdin/stdout/stderr
        const own = sys.keepOnlyFd(pair[1]);
        sys.prependExeDirToPath(); // menus and zbg next to netline are found without PATH setup
        serve(own, cmds);
    }
    sys.close(pair[1]);
    sock = pair[0];
    return true;
}

// ---------------------------------------------------------------- panel side

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

/// Ask the broker for a `watch all-tags` socket. -1 — mango is unavailable.
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

// ---------------------------------------------------------------- broker side

fn serve(fd: i32, cmds: []const ?Cmd) noreturn {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf) catch sys.exit(0);
        if (n == 0) sys.exit(0); // the panel has exited
        const msg = buf[0..n];
        switch (msg[0]) {
            'C' => if (n == 2 and msg[1] < cmds.len) {
                if (cmds[msg[1]]) |c| {
                    if (c.argv) |av| sys.spawnArgv(av, null) else if (c.shell) |sh| sys.spawnShell(sh);
                }
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
    // wait for the reply so the socket isn't closed before mango sends it
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

/// Allowed only: viewcrossmon,N,MONITOR | view,N,0 | toggleview,N
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
