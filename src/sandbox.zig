// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Песочница процесса панели (вызывается один раз, когда всё нужное уже открыто).
//!
//! 1. PR_SET_NO_NEW_PRIVS и PR_SET_DUMPABLE=0.
//! 2. Landlock: файловая система только на чтение и только в перечисленных местах,
//!    TCP запрещён, сигналы и абстрактные unix-сокеты — только внутри песочницы.
//! 3. seccomp-bpf: белый список системных вызовов. Нет exec, fork, socket, connect,
//!    ptrace, mprotect; mmap без PROT_EXEC; openat только на чтение; ioctl — только
//!    HCIGETDEVINFO. Всё остальное — немедленное завершение процесса.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const sys = @import("sys.zig");
const status = @import("status.zig");

pub fn apply(read_paths: []const [:0]const u8) void {
    _ = sys.prctl(38, 1, 0) catch sys.log("PR_SET_NO_NEW_PRIVS не удался", .{}); // PR_SET_NO_NEW_PRIVS
    _ = sys.prctl(4, 0, 0) catch {}; // PR_SET_DUMPABLE = 0: нельзя подключиться ptrace'ом и снять дамп
    landlock(read_paths);
    seccomp();
}

// ================================================================= Landlock

const FS_READ_FILE: u64 = 1 << 2;
const FS_READ_DIR: u64 = 1 << 3;

fn landlock(read_paths: []const [:0]const u8) void {
    const abi_rc = sys.raw(.landlock_create_ruleset, 0, 0, 1) catch { // LANDLOCK_CREATE_RULESET_VERSION
        sys.log("Landlock недоступен в ядре — только seccomp", .{});
        return;
    };
    const abi: u32 = @intCast(abi_rc);

    var fs: u64 = (1 << 13) - 1; // ABI 1: EXECUTE..MAKE_SYM
    if (abi >= 2) fs |= 1 << 13; // REFER
    if (abi >= 3) fs |= 1 << 14; // TRUNCATE
    if (abi >= 5) fs |= 1 << 15; // IOCTL_DEV
    const Attr = extern struct { fs: u64, net: u64, scoped: u64 };
    const attr = Attr{
        .fs = fs,
        .net = 3, // BIND_TCP | CONNECT_TCP (без правил — запрещено всё)
        .scoped = 3, // ABSTRACT_UNIX_SOCKET | SIGNAL
    };
    const size: usize = if (abi < 4) 8 else if (abi < 6) 16 else 24;
    const rs_rc = sys.raw(.landlock_create_ruleset, @intFromPtr(&attr), size, 0) catch {
        sys.log("Landlock: не удалось создать набор правил", .{});
        return;
    };
    const rs: i32 = @intCast(rs_rc);
    defer sys.close(rs);

    for (read_paths) |p| {
        const fd = sys.openPath(p) catch continue;
        defer sys.close(fd);
        // для каталога — чтение файлов и списка, для файла — только чтение
        if (!addRule(rs, fd, FS_READ_FILE | FS_READ_DIR)) _ = addRule(rs, fd, FS_READ_FILE);
    }
    _ = sys.raw(.landlock_restrict_self, @intCast(rs), 0, 0) catch {
        sys.log("Landlock: не удалось применить правила", .{});
    };
}

fn addRule(rs: i32, fd: i32, access: u64) bool {
    // struct landlock_path_beneath_attr { u64 allowed_access; s32 parent_fd; } __packed
    var a: [12]u8 = undefined;
    std.mem.writeInt(u64, a[0..8], access, .little);
    std.mem.writeInt(i32, a[8..12], fd, .little);
    _ = linuxAddRule(rs, &a) catch return false;
    return true;
}

fn linuxAddRule(rs: i32, attr: *const [12]u8) sys.Error!usize {
    const rc = linux.syscall4(.landlock_add_rule, sys.ufd(rs), 1, @intFromPtr(attr), 0); // RULE_PATH_BENEATH
    if (rc > std.math.maxInt(usize) - 4096) return error.Failed;
    return rc;
}

// ================================================================= seccomp

const SockFilter = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
const SockFprog = extern struct { len: u16, filter: [*]const SockFilter };

const LD_W_ABS: u16 = 0x20;
const JEQ: u16 = 0x15;
const JGE: u16 = 0x35;
const JSET: u16 = 0x45;
const RET: u16 = 0x06;
const RET_KILL_PROCESS: u32 = 0x80000000;
const RET_ALLOW: u32 = 0x7fff0000;

const audit_arch: ?u32 = switch (builtin.cpu.arch) {
    .x86_64 => 0xC000003E,
    .aarch64 => 0xC00000B7,
    .riscv64 => 0xC00000F3,
    else => null,
};

fn nr(comptime name: linux.SYS) u32 {
    return @intCast(@intFromEnum(name));
}

/// Простые разрешённые вызовы (без проверки аргументов).
const simple = [_]linux.SYS{
    .read,          .write,       .close,           .getdents64,
    .ppoll,         .clock_gettime, .timerfd_settime, .sendto,
    .sendmsg,       .recvmsg,     .memfd_create,    .ftruncate,
    .munmap,        .exit,        .exit_group,      .rt_sigreturn,
    .restart_syscall,
};

const PROT_EXEC: u32 = 4;
// O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND | __O_TMPFILE
const OPEN_WRITE_MASK: u32 = 1 | 2 | 0o100 | 0o1000 | 0o2000 | 0o20000000;

fn arg(i: u32) u32 {
    return 16 + 8 * i; // seccomp_data.args[i], младшие 32 бита (little-endian)
}

fn seccomp() void {
    const arch = audit_arch orelse {
        sys.log("seccomp: архитектура не поддерживается фильтром", .{});
        return;
    };
    // Метки: KILL, ALLOW и проверки аргументов. Переходы считаются после сборки.
    const L = enum { none, kill, allow, mmap, ioctl, openat };
    const Ins = struct { code: u16, k: u32, t: L = .none, f: L = .none };
    var p: [64]Ins = undefined;
    var n: usize = 0;
    var at = std.EnumArray(L, usize).initFill(0);

    p[n] = .{ .code = LD_W_ABS, .k = 4 }; // arch
    n += 1;
    p[n] = .{ .code = JEQ, .k = arch, .f = .kill };
    n += 1;
    p[n] = .{ .code = LD_W_ABS, .k = 0 }; // nr
    n += 1;
    if (builtin.cpu.arch == .x86_64) {
        p[n] = .{ .code = JGE, .k = 0x40000000, .t = .kill }; // x32 ABI
        n += 1;
    }
    inline for (simple) |s| {
        p[n] = .{ .code = JEQ, .k = nr(s), .t = .allow };
        n += 1;
    }
    p[n] = .{ .code = JEQ, .k = nr(.mmap), .t = .mmap };
    n += 1;
    p[n] = .{ .code = JEQ, .k = nr(.ioctl), .t = .ioctl };
    n += 1;
    p[n] = .{ .code = JEQ, .k = nr(.openat), .t = .openat };
    n += 1;
    p[n] = .{ .code = RET, .k = RET_KILL_PROCESS }; // всё, чего нет в списке
    n += 1;

    // В BPF переходы только вперёд, поэтому проверки аргументов идут до общих RET.
    // mmap: prot не содержит PROT_EXEC и старшие 32 бита пусты
    at.set(.mmap, n);
    p[n] = .{ .code = LD_W_ABS, .k = arg(2) };
    n += 1;
    p[n] = .{ .code = JSET, .k = PROT_EXEC, .t = .kill };
    n += 1;
    p[n] = .{ .code = LD_W_ABS, .k = arg(2) + 4 };
    n += 1;
    p[n] = .{ .code = JEQ, .k = 0, .t = .allow, .f = .kill };
    n += 1;

    // ioctl: только HCIGETDEVINFO (состояние Bluetooth)
    at.set(.ioctl, n);
    p[n] = .{ .code = LD_W_ABS, .k = arg(1) };
    n += 1;
    p[n] = .{ .code = JEQ, .k = status.HCIGETDEVINFO, .t = .allow, .f = .kill };
    n += 1;

    // openat: только на чтение
    at.set(.openat, n);
    p[n] = .{ .code = LD_W_ABS, .k = arg(2) };
    n += 1;
    p[n] = .{ .code = JSET, .k = OPEN_WRITE_MASK, .t = .kill, .f = .allow };
    n += 1;

    at.set(.kill, n);
    p[n] = .{ .code = RET, .k = RET_KILL_PROCESS };
    n += 1;
    at.set(.allow, n);
    p[n] = .{ .code = RET, .k = RET_ALLOW };
    n += 1;

    var prog: [64]SockFilter = undefined;
    for (p[0..n], 0..) |ins, i| {
        prog[i] = .{ .code = ins.code, .jt = jump(at, ins.t, i), .jf = jump(at, ins.f, i), .k = ins.k };
    }
    const fprog = SockFprog{ .len = @intCast(n), .filter = &prog };
    _ = sys.prctl(22, 2, @intFromPtr(&fprog)) catch { // PR_SET_SECCOMP, SECCOMP_MODE_FILTER
        sys.log("seccomp: фильтр не установлен", .{});
    };
}

fn jump(at: anytype, l: anytype, i: usize) u8 {
    if (l == .none) return 0;
    return @intCast(at.get(l) - (i + 1));
}
