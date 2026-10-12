// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Тонкие обёртки над системными вызовами Linux. Без libc, без std.posix —
//! только сырые syscall'ы, чтобы код не зависел от изменений std между версиями Zig.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{ Interrupted, WouldBlock, Failed };

pub var last_errno: usize = 0;

fn check(rc: usize) Error!usize {
    if (rc > std.math.maxInt(usize) - 4096) {
        const e = 0 -% rc;
        last_errno = e;
        return switch (e) {
            4 => error.Interrupted,
            11 => error.WouldBlock,
            else => error.Failed,
        };
    }
    return rc;
}

pub inline fn ufd(fd: i32) usize {
    return @as(usize, @bitCast(@as(isize, fd)));
}

const AT_FDCWD: i32 = -100;
pub const O_CLOEXEC: usize = 0o2000000;
pub const O_NONBLOCK: usize = 0o4000;
const O_PATH: usize = 0o10000000;
const SOCK_CLOEXEC: usize = 0o2000000;
pub const MSG_NOSIGNAL: usize = 0x4000;
pub const ECANCELED: usize = 125;

// ---------------------------------------------------------------- файлы

pub fn openRead(path: [*:0]const u8) Error!i32 {
    const rc = try check(linux.syscall4(.openat, ufd(AT_FDCWD), @intFromPtr(path), O_CLOEXEC, 0));
    return @intCast(rc);
}

/// Открыть или создать файл (O_RDWR|O_CREAT, 0600).
pub fn openCreate(path: [*:0]const u8) Error!i32 {
    const rc = try check(linux.syscall4(.openat, ufd(AT_FDCWD), @intFromPtr(path), 2 | 0o100 | O_CLOEXEC, 0o600));
    return @intCast(rc);
}

/// Создать файл заново (O_WRONLY|O_CREAT|O_TRUNC, 0600).
pub fn createFile(path: [*:0]const u8) Error!i32 {
    const rc = try check(linux.syscall4(.openat, ufd(AT_FDCWD), @intFromPtr(path), 1 | 0o100 | 0o1000 | O_CLOEXEC, 0o600));
    return @intCast(rc);
}

/// mkdir 0700 (если уже есть — не ошибка).
pub fn mkdir(path: [*:0]const u8) void {
    _ = linux.syscall3(.mkdirat, ufd(AT_FDCWD), @intFromPtr(path), 0o700);
}

pub fn lseek(fd: i32, off: usize) Error!usize {
    return check(linux.syscall3(.lseek, ufd(fd), off, 0)); // SEEK_SET
}

/// accept4 без адреса; null — ошибка.
pub fn accept(fd: i32) ?i32 {
    const c = check(linux.syscall4(.accept4, ufd(fd), 0, 0, SOCK_CLOEXEC)) catch return null;
    return @intCast(c);
}

pub fn openRW(path: [*:0]const u8) Error!i32 {
    const rc = try check(linux.syscall4(.openat, ufd(AT_FDCWD), @intFromPtr(path), 2 | O_CLOEXEC, 0)); // O_RDWR
    return @intCast(rc);
}

/// O_PATH-дескриптор (для правил Landlock).
pub fn openPath(path: [*:0]const u8) Error!i32 {
    const rc = try check(linux.syscall4(.openat, ufd(AT_FDCWD), @intFromPtr(path), O_PATH | O_CLOEXEC, 0));
    return @intCast(rc);
}

pub fn read(fd: i32, buf: []u8) Error!usize {
    while (true) {
        return check(linux.syscall3(.read, ufd(fd), @intFromPtr(buf.ptr), buf.len)) catch |e| {
            if (e == error.Interrupted) continue;
            return e;
        };
    }
}

pub fn write(fd: i32, data: []const u8) Error!usize {
    return check(linux.syscall3(.write, ufd(fd), @intFromPtr(data.ptr), data.len));
}

/// Записать всё (в файл; для сокетов — sendAll).
pub fn writeAll(fd: i32, data: []const u8) Error!void {
    var off: usize = 0;
    while (off < data.len) {
        const n = write(fd, data[off..]) catch |e| {
            if (e == error.Interrupted) continue;
            return e;
        };
        if (n == 0) return error.Failed;
        off += n;
    }
}

pub fn unlink(path: [*:0]const u8) void {
    _ = linux.syscall3(.unlinkat, ufd(AT_FDCWD), @intFromPtr(path), 0);
}

pub fn close(fd: i32) void {
    if (fd >= 0) _ = linux.syscall1(.close, ufd(fd));
}

/// Читает файл целиком (или сколько влезет в buf). null — если не открылся.
pub fn readFile(path: [*:0]const u8, buf: []u8) ?[]u8 {
    const fd = openRead(path) catch return null;
    defer close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = read(fd, buf[n..]) catch return null;
        if (r == 0) break;
        n += r;
    }
    return buf[0..n];
}

pub fn exists(path: [*:0]const u8) bool {
    const fd = openRead(path) catch return false;
    close(fd);
    return true;
}

pub fn getdents(fd: i32, buf: []u8) Error!usize {
    return check(linux.syscall3(.getdents64, ufd(fd), @intFromPtr(buf.ptr), buf.len));
}

/// Итератор по именам в директории (через getdents64).
pub const Dir = struct {
    fd: i32,
    buf: [4096]u8 align(8) = undefined,
    len: usize = 0,
    pos: usize = 0,

    pub fn open(path: [*:0]const u8) ?Dir {
        const fd = openRead(path) catch return null;
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Dir) void {
        close(self.fd);
    }

    pub fn next(self: *Dir) ?[]const u8 {
        while (true) {
            if (self.pos >= self.len) {
                self.len = getdents(self.fd, &self.buf) catch return null;
                self.pos = 0;
                if (self.len == 0) return null;
            }
            // struct linux_dirent64 { u64 ino; i64 off; u16 reclen; u8 type; char name[]; }
            if (self.len - self.pos < 20) return null;
            const rec = self.buf[self.pos..self.len];
            const reclen = std.mem.readInt(u16, rec[16..18], .little);
            if (reclen < 20 or reclen > rec.len) return null;
            self.pos += reclen;
            const name_full = rec[19..reclen];
            const name = name_full[0 .. std.mem.indexOfScalar(u8, name_full, 0) orelse name_full.len];
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return name;
        }
    }
};

// ---------------------------------------------------------------- сокеты

pub fn socket(domain: usize, kind: usize, proto: usize) Error!i32 {
    const rc = try check(linux.syscall3(.socket, domain, kind | SOCK_CLOEXEC, proto));
    return @intCast(rc);
}

pub fn connectUnix(path: []const u8) Error!i32 {
    const SockaddrUn = extern struct { family: u16, path: [108]u8 };
    if (path.len >= 108) return error.Failed;
    var addr = SockaddrUn{ .family = 1, .path = [_]u8{0} ** 108 };
    @memcpy(addr.path[0..path.len], path);
    const fd = try socket(1, 1, 0); // AF_UNIX, SOCK_STREAM
    _ = check(linux.syscall3(.connect, ufd(fd), @intFromPtr(&addr), 2 + path.len + 1)) catch |e| {
        close(fd);
        return e;
    };
    return fd;
}

/// Пара связанных сокетов AF_UNIX/SOCK_SEQPACKET (границы сообщений сохраняются).
pub fn socketpair() Error![2]i32 {
    var fds: [2]i32 = .{ -1, -1 };
    _ = try check(linux.syscall4(.socketpair, 1, 5 | SOCK_CLOEXEC, 0, @intFromPtr(&fds)));
    return fds;
}

/// Netlink-сокет, подписанный на multicast-группы `groups` (только чтение событий ядра).
pub fn netlink(proto: usize, groups: u32) Error!i32 {
    const fd = try socket(16, 3 | O_NONBLOCK, proto); // AF_NETLINK, SOCK_RAW
    const Addr = extern struct { family: u16 = 16, pad: u16 = 0, pid: u32 = 0, groups: u32 };
    const addr = Addr{ .groups = groups };
    _ = check(linux.syscall3(.bind, ufd(fd), @intFromPtr(&addr), @sizeOf(Addr))) catch |e| {
        close(fd);
        return e;
    };
    return fd;
}

/// Отправка без SIGPIPE.
pub fn sendAll(fd: i32, data: []const u8) Error!void {
    var off: usize = 0;
    while (off < data.len) {
        const n = check(linux.syscall6(.sendto, ufd(fd), @intFromPtr(data[off..].ptr), data.len - off, MSG_NOSIGNAL, 0, 0)) catch |e| {
            if (e == error.Interrupted) continue;
            return e;
        };
        off += n;
    }
}

const Iovec = extern struct { base: [*]const u8, len: usize };
const Msghdr = extern struct {
    name: ?*anyopaque = null,
    namelen: u32 = 0,
    iov: [*]const Iovec,
    iovlen: usize,
    control: ?*anyopaque,
    controllen: usize,
    flags: u32 = 0,
};
const CMSG_HDR = 2 * @sizeOf(usize); // cmsg_len (size_t) + level + type

/// sendmsg с передачей файловых дескрипторов (SCM_RIGHTS). Возвращает число отправленных байт.
pub fn sendmsgFds(fd: i32, data: []const u8, fds: []const i32) Error!usize {
    const iov = [1]Iovec{.{ .base = data.ptr, .len = data.len }};
    var cbuf: [CMSG_HDR + 8 * 4 + 8]u8 align(8) = undefined;
    var msg = Msghdr{ .iov = &iov, .iovlen = 1, .control = null, .controllen = 0 };
    if (fds.len > 0) {
        const n: usize = @min(fds.len, 8);
        const cmsg_len = CMSG_HDR + n * 4;
        const space = (cmsg_len + @sizeOf(usize) - 1) & ~@as(usize, @sizeOf(usize) - 1);
        @memset(cbuf[0..space], 0);
        std.mem.writeInt(usize, cbuf[0..@sizeOf(usize)], cmsg_len, .little);
        std.mem.writeInt(i32, cbuf[@sizeOf(usize)..][0..4], 1, .little); // SOL_SOCKET
        std.mem.writeInt(i32, cbuf[@sizeOf(usize) + 4 ..][0..4], 1, .little); // SCM_RIGHTS
        for (fds[0..n], 0..) |f, i| std.mem.writeInt(i32, cbuf[CMSG_HDR + i * 4 ..][0..4], f, .little);
        msg.control = &cbuf;
        msg.controllen = space;
    }
    while (true) {
        return check(linux.syscall3(.sendmsg, ufd(fd), @intFromPtr(&msg), MSG_NOSIGNAL)) catch |e| {
            if (e == error.Interrupted) continue;
            return e;
        };
    }
}

/// recvmsg, принимающий не более одного дескриптора. `out_fd` = -1, если его не было.
pub fn recvmsgFd(fd: i32, buf: []u8, out_fd: *i32) Error!usize {
    out_fd.* = -1;
    const iov = [1]Iovec{.{ .base = buf.ptr, .len = buf.len }};
    var cbuf: [CMSG_HDR + 16]u8 align(8) = [_]u8{0} ** (CMSG_HDR + 16);
    var msg = Msghdr{ .iov = &iov, .iovlen = 1, .control = &cbuf, .controllen = cbuf.len };
    const MSG_CMSG_CLOEXEC = 0x40000000;
    const n = try check(linux.syscall3(.recvmsg, ufd(fd), @intFromPtr(&msg), MSG_CMSG_CLOEXEC));
    if (msg.controllen >= CMSG_HDR + 4) {
        const level = std.mem.readInt(i32, cbuf[@sizeOf(usize)..][0..4], .little);
        const kind = std.mem.readInt(i32, cbuf[@sizeOf(usize) + 4 ..][0..4], .little);
        const len = std.mem.readInt(usize, cbuf[0..@sizeOf(usize)], .little);
        if (level == 1 and kind == 1 and len >= CMSG_HDR + 4) {
            out_fd.* = std.mem.readInt(i32, cbuf[CMSG_HDR..][0..4], .little);
            // лишние дескрипторы (если их прислали) закрываем
            var off: usize = CMSG_HDR + 4;
            while (off + 4 <= len and off + 4 <= cbuf.len) : (off += 4) close(std.mem.readInt(i32, cbuf[off..][0..4], .little));
        }
    }
    return n;
}

/// recvmsg, собирающий до out_fds.len дескрипторов (лишние закрываются).
pub fn recvmsgFds(fd: i32, buf: []u8, out_fds: []i32, nfds: *usize) Error!usize {
    nfds.* = 0;
    const iov = [1]Iovec{.{ .base = buf.ptr, .len = buf.len }};
    var cbuf: [CMSG_HDR + 4 * 16]u8 align(8) = [_]u8{0} ** (CMSG_HDR + 4 * 16);
    var msg = Msghdr{ .iov = &iov, .iovlen = 1, .control = &cbuf, .controllen = cbuf.len };
    const MSG_CMSG_CLOEXEC = 0x40000000;
    const n = try check(linux.syscall3(.recvmsg, ufd(fd), @intFromPtr(&msg), MSG_CMSG_CLOEXEC));
    var off: usize = 0;
    while (off + CMSG_HDR <= msg.controllen and off + CMSG_HDR <= cbuf.len) {
        const len = std.mem.readInt(usize, cbuf[off..][0..@sizeOf(usize)], .little);
        const level = std.mem.readInt(i32, cbuf[off + @sizeOf(usize) ..][0..4], .little);
        const kind = std.mem.readInt(i32, cbuf[off + @sizeOf(usize) + 4 ..][0..4], .little);
        if (len < CMSG_HDR or off + len > cbuf.len) break;
        if (level == 1 and kind == 1) {
            var p = off + CMSG_HDR;
            while (p + 4 <= off + len) : (p += 4) {
                const f = std.mem.readInt(i32, cbuf[p..][0..4], .little);
                if (nfds.* < out_fds.len) {
                    out_fds[nfds.*] = f;
                    nfds.* += 1;
                } else close(f);
            }
        }
        off += (len + @sizeOf(usize) - 1) & ~@as(usize, @sizeOf(usize) - 1);
    }
    return n;
}

pub fn pipe() Error![2]i32 {
    var fds: [2]i32 = .{ -1, -1 };
    _ = try check(linux.syscall2(.pipe2, @intFromPtr(&fds), O_CLOEXEC));
    return fds;
}

const SockaddrAbs = extern struct { family: u16, path: [108]u8 };

fn abstractAddr(name: []const u8, out: *SockaddrAbs) usize {
    out.* = .{ .family = 1, .path = [_]u8{0} ** 108 };
    const k = @min(name.len, 100);
    @memcpy(out.path[1 .. 1 + k], name[0..k]); // path[0] = 0 — абстрактное имя
    return 2 + 1 + k;
}

/// Слушающий сокет в абстрактном пространстве имён (без файла на диске).
pub fn listenAbstract(name: []const u8) Error!i32 {
    var addr: SockaddrAbs = undefined;
    const len = abstractAddr(name, &addr);
    const fd = try socket(1, 1, 0);
    errdefer close(fd);
    _ = try check(linux.syscall3(.bind, ufd(fd), @intFromPtr(&addr), len));
    _ = try check(linux.syscall2(.listen, ufd(fd), 1));
    return fd;
}

pub fn connectAbstract(name: []const u8) bool {
    const fd = connectAbstractFd(name) catch return false;
    close(fd);
    return true;
}

/// Подключение к абстрактному unix-сокету; возвращает дескриптор.
pub fn connectAbstractFd(name: []const u8) Error!i32 {
    var addr: SockaddrAbs = undefined;
    const len = abstractAddr(name, &addr);
    const fd = try socket(1, 1, 0);
    errdefer close(fd);
    _ = try check(linux.syscall3(.connect, ufd(fd), @intFromPtr(&addr), len));
    return fd;
}

pub fn ioctl(fd: i32, req: usize, arg: usize) Error!usize {
    return check(linux.syscall3(.ioctl, ufd(fd), req, arg));
}

// ---------------------------------------------------------------- память

pub fn memfd(name: [*:0]const u8) Error!i32 {
    const rc = try check(linux.syscall2(.memfd_create, @intFromPtr(name), 1)); // MFD_CLOEXEC
    return @intCast(rc);
}

pub fn ftruncate(fd: i32, len: usize) Error!void {
    _ = try check(linux.syscall2(.ftruncate, ufd(fd), len));
}

pub fn mmap(len: usize, fd: i32) Error![*]u8 {
    // PROT_READ|PROT_WRITE, MAP_SHARED
    const rc = try check(linux.syscall6(.mmap, 0, len, 3, 1, ufd(fd), 0));
    return @ptrFromInt(rc);
}

/// Анонимная память (PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS).
pub fn mmapAnon(len: usize) Error![*]u8 {
    const rc = try check(linux.syscall6(.mmap, 0, len, 3, 0x22, ufd(-1), 0));
    return @ptrFromInt(rc);
}

/// Только чтение, MAP_PRIVATE (шрифты, keymap от композитора).
pub fn mmapRead(len: usize, fd: i32) Error![*]const u8 {
    const rc = try check(linux.syscall6(.mmap, 0, len, 1, 2, ufd(fd), 0));
    return @ptrFromInt(rc);
}

pub fn fileSize(fd: i32) Error!usize {
    return check(linux.syscall3(.lseek, ufd(fd), 0, 2)); // SEEK_END
}

pub fn munmap(ptr: [*]u8, len: usize) void {
    _ = linux.syscall2(.munmap, @intFromPtr(ptr), len);
}

// ---------------------------------------------------------------- время, таймеры, poll

pub const Timespec = extern struct { sec: isize, nsec: isize };

fn clockTs(clock: usize) Timespec {
    var ts: Timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.syscall2(.clock_gettime, clock, @intFromPtr(&ts));
    return ts;
}

pub fn realtime() i64 {
    return clockTs(0).sec; // CLOCK_REALTIME
}

/// Монотонное время в миллисекундах.
pub fn monoMs() u64 {
    const ts = clockTs(1); // CLOCK_MONOTONIC
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1000000;
}

pub const PollFd = extern struct { fd: i32, events: i16, revents: i16 = 0 };
pub const POLLIN: i16 = 1;

pub fn poll(fds: []PollFd, timeout_ms: i32) Error!usize {
    var ts = Timespec{ .sec = @divTrunc(timeout_ms, 1000), .nsec = @rem(timeout_ms, 1000) * 1_000_000 };
    const tsp: usize = if (timeout_ms < 0) 0 else @intFromPtr(&ts);
    return check(linux.syscall5(.ppoll, @intFromPtr(fds.ptr), fds.len, tsp, 0, 8));
}

pub const CLOCK_REALTIME = 0;
pub const CLOCK_MONOTONIC = 1;
pub const TFD_TIMER_ABSTIME = 1;
pub const TFD_TIMER_CANCEL_ON_SET = 2;

pub fn timerfdCreate(clock: usize) Error!i32 {
    return @intCast(try check(linux.syscall2(.timerfd_create, clock, O_CLOEXEC | O_NONBLOCK)));
}

/// Взвести таймер: первое срабатывание через/в `value_s`, затем каждые `interval_s` секунд.
pub fn timerfdArm(fd: i32, flags: usize, value_s: i64, interval_s: u32) Error!void {
    const Its = extern struct { interval: Timespec, value: Timespec };
    const its = Its{
        .interval = .{ .sec = interval_s, .nsec = 0 },
        .value = .{ .sec = @intCast(value_s), .nsec = 0 },
    };
    _ = try check(linux.syscall4(.timerfd_settime, ufd(fd), flags, @intFromPtr(&its), 0));
}

/// Взвести монотонный таймер: первое срабатывание через first_ms, затем каждые every_ms (0 — один раз).
pub fn timerfdArmMs(fd: i32, first_ms: u32, every_ms: u32) void {
    const Its = extern struct { interval: Timespec, value: Timespec };
    const its = Its{
        .interval = .{ .sec = every_ms / 1000, .nsec = @as(isize, every_ms % 1000) * 1_000_000 },
        .value = .{ .sec = first_ms / 1000, .nsec = @as(isize, first_ms % 1000) * 1_000_000 },
    };
    _ = linux.syscall4(.timerfd_settime, ufd(fd), 0, @intFromPtr(&its), 0);
}

// ---------------------------------------------------------------- inotify

pub fn inotifyInit() Error!i32 {
    return @intCast(try check(linux.syscall1(.inotify_init1, O_CLOEXEC | O_NONBLOCK)));
}

pub fn inotifyWatch(fd: i32, path: [*:0]const u8, mask: u32) Error!void {
    _ = try check(linux.syscall3(.inotify_add_watch, ufd(fd), @intFromPtr(path), mask));
}

// ---------------------------------------------------------------- процессы и права

pub fn exit(code: u8) noreturn {
    _ = linux.syscall1(.exit_group, code);
    unreachable;
}

pub fn fork() Error!usize {
    // clone(SIGCHLD, 0, ...) == fork(); работает и на x86_64, и на aarch64
    return check(linux.syscall5(.clone, 17, 0, 0, 0, 0));
}

/// Закрыть все дескрипторы, кроме 0–2 и `fd` (он переносится на номер 3). Возвращает 3.
pub fn keepOnlyFd(fd: i32) i32 {
    if (fd != 3) {
        _ = linux.syscall3(.dup3, ufd(fd), 3, O_CLOEXEC);
        close(fd);
    }
    // close_range(4, ~0, 0); на старых ядрах — по одному
    const rc = linux.syscall3(.close_range, 4, std.math.maxInt(u32), 0);
    if (rc > std.math.maxInt(usize) - 4096) {
        var i: i32 = 4;
        while (i < 1024) : (i += 1) close(i);
    }
    return 3;
}

/// Случайное число от ядра (getrandom); при ошибке — от часов.
pub fn random() u64 {
    var v: u64 = 0;
    const rc = linux.syscall3(.getrandom, @intFromPtr(&v), 8, 0);
    if (rc != 8) v = @bitCast(clockTs(1).nsec *% 2654435761 +% clockTs(0).sec);
    return v;
}

pub fn getuid() usize {
    return linux.syscall0(.getuid);
}

pub fn prctl(option: usize, a2: usize, a3: usize) Error!usize {
    return check(linux.syscall5(.prctl, option, a2, a3, 0, 0));
}

pub fn raw(comptime nr: linux.SYS, a1: usize, a2: usize, a3: usize) Error!usize {
    return check(linux.syscall3(nr, a1, a2, a3));
}

/// Запускает `/bin/sh -c cmd` полностью отвязанным (double fork + setsid),
/// поэтому зомби не остаются и SIGCHLD обрабатывать не нужно.
pub fn spawnShell(cmd: [*:0]const u8) void {
    const pid = fork() catch return;
    if (pid == 0) {
        _ = linux.syscall0(.setsid);
        const pid2 = fork() catch exit(1);
        if (pid2 == 0) {
            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd };
            _ = linux.syscall3(.execve, @intFromPtr("/bin/sh"), @intFromPtr(&argv), @intFromPtr(envp()));
            exit(127);
        }
        exit(0);
    }
    var status: u32 = 0;
    _ = linux.syscall4(.wait4, pid, @intFromPtr(&status), 0, 0);
}

// ---------------------------------------------------------------- окружение
// Читаем /proc/self/environ сами — так не зависим от того, как std отдаёт environ.

var env_buf: [64 * 1024]u8 = undefined;
var env_ptrs: [1024:null]?[*:0]const u8 = undefined;
var env_count: usize = 0;

var proc_ready = false;
var arg_buf: [8 * 1024]u8 = undefined;
var arg_list: [64][]const u8 = undefined;
var arg_count: usize = 0;

/// Окружение и аргументы — прямо из /proc/self, без std.os.argv/environ
/// (их нет без libc в новых версиях Zig). Повторный вызов ничего не делает.
pub fn initEnv() void {
    if (proc_ready) return;
    proc_ready = true;
    const data = readFile("/proc/self/environ", env_buf[0 .. env_buf.len - 1]) orelse &[_]u8{};
    env_buf[data.len] = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == 0) {
            if (i > start and env_count < env_ptrs.len) {
                env_ptrs[env_count] = @ptrCast(&env_buf[start]);
                env_count += 1;
            }
            start = i + 1;
        }
    }
    if (start < data.len and env_count < env_ptrs.len) {
        env_ptrs[env_count] = @ptrCast(&env_buf[start]);
        env_count += 1;
    }
    env_ptrs[env_count] = null;

    // аргументы: строки через \0
    const args = readFile("/proc/self/cmdline", &arg_buf) orelse &[_]u8{};
    var it = std.mem.splitScalar(u8, args, 0);
    while (it.next()) |a| {
        if (arg_count == arg_list.len) break;
        if (it.index == null and a.len == 0) break; // хвостовой \0
        arg_list[arg_count] = a;
        arg_count += 1;
    }
}

var path_env: [4096]u8 = undefined;

/// Добавить папку исполняемого файла в начало PATH (для дочерних процессов).
pub fn prependExeDirToPath() void {
    var exe: [512]u8 = undefined;
    const rc = linux.syscall4(.readlinkat, ufd(AT_FDCWD), @intFromPtr("/proc/self/exe"), @intFromPtr(&exe), exe.len);
    const n = check(rc) catch return;
    const dir_end = std.mem.lastIndexOfScalar(u8, exe[0..n], '/') orelse return;
    const dir = exe[0..dir_end];
    const old = getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    const z = joinZ(&path_env, &.{ "PATH=", dir, ":", old });
    for (env_ptrs[0..env_count]) |*p| {
        if (std.mem.startsWith(u8, std.mem.span(p.*.?), "PATH=")) {
            p.* = z.ptr;
            return;
        }
    }
    if (env_count < env_ptrs.len) {
        env_ptrs[env_count] = z.ptr;
        env_count += 1;
        env_ptrs[env_count] = null;
    }
}

pub fn envp() [*:null]const ?[*:0]const u8 {
    return &env_ptrs;
}

pub fn getenv(name: []const u8) ?[]const u8 {
    for (env_ptrs[0..env_count]) |p| {
        const s = std.mem.span(p.?);
        if (s.len > name.len and s[name.len] == '=' and std.mem.eql(u8, s[0..name.len], name))
            return s[name.len + 1 ..];
    }
    return null;
}

// ---------------------------------------------------------------- аргументы и секреты

/// argv[i] == s ?
pub fn argIs(i: usize, s: []const u8) bool {
    const a = argAt(i) orelse return false;
    return std.mem.eql(u8, a, s);
}

pub fn argAt(i: usize) ?[]const u8 {
    initEnv();
    if (i >= arg_count) return null;
    return arg_list[i];
}

/// Затереть память так, чтобы компилятор не выбросил запись.
pub fn secureZero(b: []u8) void {
    const v: []volatile u8 = b;
    for (v) |*c| c.* = 0;
}

/// Принять соединение и вернуть uid собеседника (SO_PEERCRED). Соединение сразу закрывается.
pub fn acceptPeerUid(fd: i32) ?u32 {
    const c = check(linux.syscall4(.accept4, ufd(fd), 0, 0, SOCK_CLOEXEC)) catch return null;
    const cfd: i32 = @intCast(c);
    defer close(cfd);
    return peerUid(cfd);
}

/// uid процесса на другом конце unix-сокета.
pub fn peerUid(fd: i32) ?u32 {
    var cred: [3]u32 = undefined; // pid, uid, gid
    var len: u32 = @sizeOf([3]u32);
    _ = check(linux.syscall5(.getsockopt, ufd(fd), 1, 17, @intFromPtr(&cred), @intFromPtr(&len))) catch return null; // SOL_SOCKET, SO_PEERCRED
    return cred[1];
}

// ---------------------------------------------------------------- вывод

pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "zpanel: " ++ fmt ++ "\n", args) catch return;
    _ = write(2, s) catch {};
}

/// Склейка кусков в буфер с завершающим нулём (лишнее обрезается).
pub fn joinZ(buf: []u8, parts: []const []const u8) [:0]const u8 {
    var n: usize = 0;
    for (parts) |p| {
        const k = @min(p.len, buf.len - 1 - n);
        @memcpy(buf[n..][0..k], p[0..k]);
        n += k;
    }
    buf[n] = 0;
    return buf[0..n :0];
}
