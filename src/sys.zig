// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Thin wrappers over Linux system calls. No libc, no std.posix —
//! only raw syscalls, so the code doesn't depend on std changes between Zig versions.

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

// ---------------------------------------------------------------- files

pub fn openRead(path: [*:0]const u8) Error!i32 {
    const rc = try check(linux.syscall4(.openat, ufd(AT_FDCWD), @intFromPtr(path), O_CLOEXEC, 0));
    return @intCast(rc);
}

/// Open or create a file (O_RDWR|O_CREAT, 0600).
pub fn openCreate(path: [*:0]const u8) Error!i32 {
    const rc = try check(linux.syscall4(.openat, ufd(AT_FDCWD), @intFromPtr(path), 2 | 0o100 | O_CLOEXEC, 0o600));
    return @intCast(rc);
}

/// Create a file anew (O_WRONLY|O_CREAT|O_TRUNC, 0600).
pub fn createFile(path: [*:0]const u8) Error!i32 {
    const rc = try check(linux.syscall4(.openat, ufd(AT_FDCWD), @intFromPtr(path), 1 | 0o100 | 0o1000 | O_CLOEXEC, 0o600));
    return @intCast(rc);
}

/// mkdir 0700 (already existing is not an error).
pub fn mkdir(path: [*:0]const u8) void {
    _ = linux.syscall3(.mkdirat, ufd(AT_FDCWD), @intFromPtr(path), 0o700);
}

pub fn lseek(fd: i32, off: usize) Error!usize {
    return check(linux.syscall3(.lseek, ufd(fd), off, 0)); // SEEK_SET
}

/// accept4 without an address; null — error.
pub fn accept(fd: i32) ?i32 {
    const c = check(linux.syscall4(.accept4, ufd(fd), 0, 0, SOCK_CLOEXEC)) catch return null;
    return @intCast(c);
}

pub fn openRW(path: [*:0]const u8) Error!i32 {
    const rc = try check(linux.syscall4(.openat, ufd(AT_FDCWD), @intFromPtr(path), 2 | O_CLOEXEC, 0)); // O_RDWR
    return @intCast(rc);
}

/// An O_PATH descriptor (for Landlock rules).
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

/// Write everything (to a file; for sockets — sendAll).
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

/// Reads a whole file (or as much as fits in buf). null — if it didn't open.
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

/// Whether anything exists at the path (file, folder, socket) — without opening it (faccessat F_OK).
pub fn pathExists(path: [*:0]const u8) bool {
    return linux.syscall4(.faccessat, ufd(AT_FDCWD), @intFromPtr(path), 0, 0) == 0;
}

/// "Fingerprint" of a file or folder: modification time (ns), size and inode (a replaced file has
/// a new inode even if its time is the same, as with Flatpak/OSTree). Zeros — no such path.
pub const Stamp = extern struct { mtime: u64 = 0, size: u64 = 0, ino: u64 = 0 };

pub fn stamp(path: [*:0]const u8) Stamp {
    // statx(AT_FDCWD, path, 0, STATX_INO | STATX_MTIME | STATX_SIZE) — one struct on all architectures
    var b: [256]u8 align(8) = undefined;
    const rc = linux.syscall5(.statx, ufd(AT_FDCWD), @intFromPtr(path), 0, 0x100 | 0x40 | 0x200, @intFromPtr(&b));
    if (rc != 0) return .{};
    const sec = std.mem.readInt(i64, b[0x70..0x78], .little);
    const nsec = std.mem.readInt(u32, b[0x78..0x7c], .little);
    return .{
        .mtime = @as(u64, @bitCast(sec)) *% 1_000_000_000 +% nsec,
        .size = std.mem.readInt(u64, b[0x28..0x30], .little),
        .ino = std.mem.readInt(u64, b[0x20..0x28], .little),
    };
}

pub fn getdents(fd: i32, buf: []u8) Error!usize {
    return check(linux.syscall3(.getdents64, ufd(fd), @intFromPtr(buf.ptr), buf.len));
}

/// Iterator over the names in a directory (via getdents64).
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

// ---------------------------------------------------------------- sockets

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

/// A pair of connected AF_UNIX/SOCK_SEQPACKET sockets (message boundaries are preserved).
pub fn socketpair() Error![2]i32 {
    var fds: [2]i32 = .{ -1, -1 };
    _ = try check(linux.syscall4(.socketpair, 1, 5 | SOCK_CLOEXEC, 0, @intFromPtr(&fds)));
    return fds;
}

/// A netlink socket subscribed to multicast groups `groups` (read-only kernel events).
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

/// Send without SIGPIPE.
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

/// sendmsg passing file descriptors (SCM_RIGHTS). Returns the number of bytes sent.
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

/// recvmsg that accepts at most one descriptor. `out_fd` = -1 if there was none.
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
            // close extra descriptors (if any were sent)
            var off: usize = CMSG_HDR + 4;
            while (off + 4 <= len and off + 4 <= cbuf.len) : (off += 4) close(std.mem.readInt(i32, cbuf[off..][0..4], .little));
        }
    }
    return n;
}

/// recvmsg collecting up to out_fds.len descriptors (extra ones are closed).
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
    @memcpy(out.path[1 .. 1 + k], name[0..k]); // path[0] = 0 — an abstract name
    return 2 + 1 + k;
}

/// A listening socket in the abstract namespace (no file on disk).
pub fn listenAbstract(name: []const u8) Error!i32 {
    var addr: SockaddrAbs = undefined;
    const len = abstractAddr(name, &addr);
    const fd = try socket(1, 1, 0);
    errdefer close(fd);
    _ = try check(linux.syscall3(.bind, ufd(fd), @intFromPtr(&addr), len));
    _ = try check(linux.syscall2(.listen, ufd(fd), 1));
    return fd;
}

/// uid of whoever listens on an abstract socket (null — nobody). Abstract names are shared by all
/// users of the network namespace: a name can be taken by someone else, so the owner is checked.
pub fn abstractOwner(name: []const u8) ?u32 {
    const fd = connectAbstractFd(name) catch return null;
    defer close(fd);
    return peerUid(fd) orelse 0xffffffff;
}

/// Connect to an abstract unix socket; returns the descriptor.
pub fn connectAbstractFd(name: []const u8) Error!i32 {
    var addr: SockaddrAbs = undefined;
    const len = abstractAddr(name, &addr);
    const fd = try socket(1, 1, 0);
    errdefer close(fd);
    _ = try check(linux.syscall3(.connect, ufd(fd), @intFromPtr(&addr), len));
    return fd;
}

/// A classic BPF instruction (socket filters and seccomp).
pub const SockFilter = extern struct { code: u16, jt: u8 = 0, jf: u8 = 0, k: u32 };
pub const SockFprog = extern struct { len: u16, filter: [*]const SockFilter };

/// A socket filter (SO_ATTACH_FILTER): the kernel drops unneeded messages —
/// the process doesn't even wake up for them.
pub fn attachFilter(fd: i32, prog: []const SockFilter) Error!void {
    const fp = SockFprog{ .len = @intCast(prog.len), .filter = prog.ptr };
    _ = try check(linux.syscall5(.setsockopt, ufd(fd), 1, 26, @intFromPtr(&fp), @sizeOf(SockFprog))); // SOL_SOCKET, SO_ATTACH_FILTER
}

/// bind to an arbitrary address (Bluetooth sockets etc.).
pub fn bindRaw(fd: i32, addr: []const u8) Error!void {
    _ = try check(linux.syscall3(.bind, ufd(fd), @intFromPtr(addr.ptr), addr.len));
}

pub fn ioctl(fd: i32, req: usize, arg: usize) Error!usize {
    return check(linux.syscall3(.ioctl, ufd(fd), req, arg));
}

// ---------------------------------------------------------------- memory

/// Shared memory for frame buffers. MFD_NOEXEC_SEAL (Linux 6.3+) seals it non-executable for good;
/// with vm.memfd_noexec = 2 a memfd without that flag is refused outright. Older kernels don't know
/// the flag (EINVAL) — then plain MFD_CLOEXEC.
pub fn memfd(name: [*:0]const u8) Error!i32 {
    const MFD_CLOEXEC = 1;
    const MFD_NOEXEC_SEAL = 8;
    if (check(linux.syscall2(.memfd_create, @intFromPtr(name), MFD_CLOEXEC | MFD_NOEXEC_SEAL))) |rc| {
        return @intCast(rc);
    } else |e| if (last_errno != 22) return e; // EINVAL
    return @intCast(try check(linux.syscall2(.memfd_create, @intFromPtr(name), MFD_CLOEXEC)));
}

pub fn ftruncate(fd: i32, len: usize) Error!void {
    _ = try check(linux.syscall2(.ftruncate, ufd(fd), len));
}

pub fn mmap(len: usize, fd: i32) Error![*]u8 {
    // PROT_READ|PROT_WRITE, MAP_SHARED
    const rc = try check(linux.syscall6(.mmap, 0, len, 3, 1, ufd(fd), 0));
    return @ptrFromInt(rc);
}

/// Anonymous memory (PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS).
pub fn mmapAnon(len: usize) Error![*]u8 {
    const rc = try check(linux.syscall6(.mmap, 0, len, 3, 0x22, ufd(-1), 0));
    return @ptrFromInt(rc);
}

/// Read only, MAP_PRIVATE (fonts, the keymap from the compositor).
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

// ---------------------------------------------------------------- time, timers, poll

pub const Timespec = extern struct { sec: isize, nsec: isize };

fn clockTs(clock: usize) Timespec {
    var ts: Timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.syscall2(.clock_gettime, clock, @intFromPtr(&ts));
    return ts;
}

pub fn realtime() i64 {
    return clockTs(0).sec; // CLOCK_REALTIME
}

/// Monotonic time in milliseconds.
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

/// Arm a timer: first expiry after/at `value_s`, then every `interval_s` seconds.
pub fn timerfdArm(fd: i32, flags: usize, value_s: i64, interval_s: u32) Error!void {
    const Its = extern struct { interval: Timespec, value: Timespec };
    const its = Its{
        .interval = .{ .sec = interval_s, .nsec = 0 },
        .value = .{ .sec = @intCast(value_s), .nsec = 0 },
    };
    _ = try check(linux.syscall4(.timerfd_settime, ufd(fd), flags, @intFromPtr(&its), 0));
}

/// Arm a monotonic timer: first expiry after first_ms, then every every_ms (0 — once).
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

// ---------------------------------------------------------------- processes and privileges

pub fn exit(code: u8) noreturn {
    _ = linux.syscall1(.exit_group, code);
    unreachable;
}

pub fn fork() Error!usize {
    // clone(SIGCHLD, 0, ...) == fork(); works on both x86_64 and aarch64
    return check(linux.syscall5(.clone, 17, 0, 0, 0, 0));
}

/// Close all descriptors except 0–2 and `fd` (which is moved to number 3). Returns 3.
pub fn keepOnlyFd(fd: i32) i32 {
    if (fd != 3) {
        _ = linux.syscall3(.dup3, ufd(fd), 3, O_CLOEXEC);
        close(fd);
    }
    // close_range(4, ~0, 0); on old kernels — one by one
    const rc = linux.syscall3(.close_range, 4, std.math.maxInt(u32), 0);
    if (rc > std.math.maxInt(usize) - 4096) {
        var i: i32 = 4;
        while (i < 1024) : (i += 1) close(i);
    }
    return 3;
}

/// A random number from the kernel (getrandom); on error — from the clock.
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

/// Runs `/bin/sh -c cmd` fully detached (double fork + setsid),
/// so no zombies remain and SIGCHLD needs no handling.
pub fn spawnShell(cmd: [*:0]const u8) void {
    const pid = fork() catch return;
    if (pid == 0) {
        _ = linux.syscall0(.setsid);
        const pid2 = fork() catch exit(1);
        if (pid2 == 0) {
            const sh_argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd };
            _ = linux.syscall3(.execve, @intFromPtr("/bin/sh"), @intFromPtr(&sh_argv), @intFromPtr(envp()));
            exit(127);
        }
        exit(0);
    }
    var status: u32 = 0;
    _ = linux.syscall4(.wait4, pid, @intFromPtr(&status), 0, 0);
}

/// Runs a program without a shell, also detached. argv[0] without '/' is looked up in PATH;
/// dir — working directory (null — don't change).
pub fn spawnArgv(av: [*:null]const ?[*:0]const u8, dir: ?[*:0]const u8) void {
    const pid = fork() catch return;
    if (pid == 0) {
        _ = linux.syscall0(.setsid);
        const pid2 = fork() catch exit(1);
        if (pid2 == 0) {
            if (dir) |d| _ = linux.syscall1(.chdir, @intFromPtr(d));
            execvp(av);
            exit(127);
        }
        exit(0);
    }
    var status: u32 = 0;
    _ = linux.syscall4(.wait4, pid, @intFromPtr(&status), 0, 0);
}

fn execvp(av: [*:null]const ?[*:0]const u8) void {
    const a0 = std.mem.span(av[0] orelse return);
    if (std.mem.indexOfScalar(u8, a0, '/') != null) {
        _ = linux.syscall3(.execve, @intFromPtr(a0.ptr), @intFromPtr(av), @intFromPtr(envp()));
        return;
    }
    var buf: [1024]u8 = undefined;
    // PATH comes from the launch environment: for the broker the netline folder comes first in it
    var it = std.mem.tokenizeScalar(u8, envpGet("PATH") orelse "/usr/local/bin:/usr/bin:/bin", ':');
    while (it.next()) |d| {
        const z = joinZ(&buf, &.{ d, "/", a0 });
        _ = linux.syscall3(.execve, @intFromPtr(z.ptr), @intFromPtr(av), @intFromPtr(envp()));
    }
}

/// Rename (atomic file replacement). renameat2 with no flags: riscv64 has no plain renameat.
pub fn rename(from: [*:0]const u8, to: [*:0]const u8) Error!void {
    _ = try check(linux.syscall5(.renameat2, ufd(AT_FDCWD), @intFromPtr(from), ufd(AT_FDCWD), @intFromPtr(to), 0));
}

// ---------------------------------------------------------------- environment and arguments
// In Zig 0.16 the startup code hands argv and envp straight to main (std.process.Init.Minimal) —
// the same strings the kernel put on the stack: nothing is copied or read from /proc.

var argv: []const [*:0]const u8 = &.{};
var environ: [:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{};

/// Called as the first line of main: `pub fn main(init: std.process.Init.Minimal) void`.
pub fn init(m: std.process.Init.Minimal) void {
    argv = m.args.vector;
    environ = m.environ.block.slice;
    if (trace_built) {
        if (getenv("NETLINE_TRACE")) |v| trace = v.len > 0 and !std.mem.eql(u8, v, "0");
        tracef("start", .{});
    }
}

/// Environment for execve with PATH starting with the executable's folder
/// (menus and zbg next to netline are found without PATH setup). Only the broker needs it.
var env_ptrs: [1024:null]?[*:0]const u8 = undefined;
var env_ready = false;
var path_env: [4096]u8 = undefined;

pub fn prependExeDirToPath() void {
    var n: usize = 0;
    var path_at: ?usize = null;
    for (environ) |p| {
        if (n == env_ptrs.len) break;
        if (std.mem.startsWith(u8, std.mem.span(p.?), "PATH=")) path_at = n;
        env_ptrs[n] = p;
        n += 1;
    }
    env_ptrs[n] = null;
    env_ready = true;

    var exe: [512]u8 = undefined;
    const rc = linux.syscall4(.readlinkat, ufd(AT_FDCWD), @intFromPtr("/proc/self/exe"), @intFromPtr(&exe), exe.len);
    const len = check(rc) catch return;
    const dir_end = std.mem.lastIndexOfScalar(u8, exe[0..len], '/') orelse return;
    const old = getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    const z = joinZ(&path_env, &.{ "PATH=", exe[0..dir_end], ":", old });
    if (path_at) |i| {
        env_ptrs[i] = z.ptr;
    } else if (n < env_ptrs.len) {
        env_ptrs[n] = z.ptr;
        env_ptrs[n + 1] = null;
    }
}

pub fn envp() [*:null]const ?[*:0]const u8 {
    if (env_ready) return &env_ptrs;
    return environ.ptr;
}

pub fn getenv(name: []const u8) ?[]const u8 {
    for (environ) |p| {
        if (envMatch(std.mem.span(p.?), name)) |v| return v;
    }
    return null;
}

/// A variable from the environment the launched programs will get (envp()).
fn envpGet(name: []const u8) ?[]const u8 {
    const e = envp();
    var i: usize = 0;
    while (e[i]) |p| : (i += 1) {
        if (envMatch(std.mem.span(p), name)) |v| return v;
    }
    return null;
}

fn envMatch(s: []const u8, name: []const u8) ?[]const u8 {
    if (s.len > name.len and s[name.len] == '=' and std.mem.eql(u8, s[0..name.len], name)) return s[name.len + 1 ..];
    return null;
}

// ---------------------------------------------------------------- tracing
// With a -Dtrace=true build and NETLINE_TRACE=1 the programs write to stderr when and why
// they wake up and how long a frame and startup took. The stamp is monotonic time in ms: it can
// be compared across processes (click in the panel → first frame of the menu).

/// Timing is compiled in (zig build -Dtrace=true). Otherwise all tracing code is dropped
/// at compile time: tracing() is the constant false.
const trace_built = @import("build_options").trace;
var trace = false;

pub inline fn tracing() bool {
    return trace_built and trace;
}

fn monoUs() u64 {
    const ts = clockTs(1);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

/// Time stamp for measurements (µs), 0 — tracing is off.
pub fn traceStart() u64 {
    return if (tracing()) monoUs() else 0;
}

/// How many µs have passed since the traceStart() stamp.
pub fn traceSince(t0: u64) u64 {
    return if (tracing()) monoUs() -% t0 else 0;
}

pub fn tracef(comptime fmt: []const u8, args: anytype) void {
    if (!tracing()) return;
    const now = monoUs();
    const a0 = if (argv.len > 0) std.mem.span(argv[0]) else "netline";
    const name = a0[if (std.mem.lastIndexOfScalar(u8, a0, '/')) |i| i + 1 else 0..];
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} [{d}.{d:0>3}] " ++ fmt ++ "\n", .{ name, now / 1000, now % 1000 } ++ args) catch return;
    _ = write(2, s) catch {};
}

// ---------------------------------------------------------------- arguments and secrets

/// argv[i] == s ?
pub fn argIs(i: usize, s: []const u8) bool {
    const a = argAt(i) orelse return false;
    return std.mem.eql(u8, a, s);
}

pub fn argAt(i: usize) ?[]const u8 {
    if (i >= argv.len) return null;
    return std.mem.span(argv[i]);
}

/// Wipe memory so that the compiler can't drop the write.
pub fn secureZero(b: []u8) void {
    const v: []volatile u8 = b;
    for (v) |*c| c.* = 0;
}

/// Accept a connection and return the peer's uid (SO_PEERCRED). The connection is closed right away.
pub fn acceptPeerUid(fd: i32) ?u32 {
    const c = check(linux.syscall4(.accept4, ufd(fd), 0, 0, SOCK_CLOEXEC)) catch return null;
    const cfd: i32 = @intCast(c);
    defer close(cfd);
    return peerUid(cfd);
}

/// uid of the process at the other end of a unix socket.
pub fn peerUid(fd: i32) ?u32 {
    var cred: [3]u32 = undefined; // pid, uid, gid
    var len: u32 = @sizeOf([3]u32);
    _ = check(linux.syscall5(.getsockopt, ufd(fd), 1, 17, @intFromPtr(&cred), @intFromPtr(&len))) catch return null; // SOL_SOCKET, SO_PEERCRED
    return cred[1];
}

// ---------------------------------------------------------------- output

pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "netline: " ++ fmt ++ "\n", args) catch return;
    _ = write(2, s) catch {};
}

/// A message from string pieces, without std.fmt: every distinct log() format string compiles
/// into its own copy of the formatting code (kilobytes per message), this costs nothing extra.
pub fn say(parts: []const []const u8) void {
    var buf: [512]u8 = undefined;
    const head = "netline: ";
    @memcpy(buf[0..head.len], head);
    const s = joinZ(buf[head.len .. buf.len - 1], parts);
    buf[head.len + s.len] = '\n';
    _ = write(2, buf[0 .. head.len + s.len + 1]) catch {};
}

/// Join pieces into a zero-terminated buffer (excess is truncated).
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
