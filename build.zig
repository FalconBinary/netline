// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = optimize != .debug;
    // timing output (NETLINE_TRACE=1) only in a -Dtrace=true build; a normal build has none of that code
    const trace = b.option(bool, "trace", "compile in timing output: NETLINE_TRACE=1 prints wakeups and frame times") orelse false;
    const test_root = b.option([]const u8, "test_root", "for tests: read the battery and backlight below this folder instead of /sys") orelse "";
    const opts = b.addOptions();
    opts.addOption(bool, "trace", trace);
    opts.addOption([:0]const u8, "test_root", b.allocator.dupeSentinel(u8, test_root, 0) catch @panic("out of memory"));

    // netline is the panel itself; menus open on icon clicks; zbg is the wallpaper daemon
    const apps = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "netline", .root = "src/main.zig" },
        .{ .name = "zwifi", .root = "src/wifi.zig" },
        .{ .name = "zbt", .root = "src/bt.zig" },
        .{ .name = "zwall", .root = "src/wall.zig" },
        .{ .name = "zbg", .root = "src/zbg.zig" },
        .{ .name = "zpower", .root = "src/power.zig" },
        .{ .name = "zcal", .root = "src/cal.zig" },
        .{ .name = "zctl", .root = "src/ctl.zig" },
        .{ .name = "zrun", .root = "src/run.zig" },
    };
    for (apps) |app| {
        const exe = b.addExecutable(.{
            .name = app.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(app.root),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
                .single_threaded = true,
                // release builds carry no debug info or unwind tables: smaller binaries
                .strip = if (release) true else null,
                .unwind_tables = if (release) .none else null,
            }),
        });
        // loaded at a random address on every start: an attacker who finds a memory bug
        // doesn't know where the code to reuse is
        exe.pie = true;
        exe.root_module.addOptions("build_options", opts);
        b.installArtifact(exe);
    }

    // zig build test: the parts that can be checked without a compositor
    const test_step = b.step("test", "run the unit tests");
    const test_bin_step = b.step("test-bin", "only build them, into zig-out/bin (to run them on another machine)");
    for ([_][]const u8{ "anim", "audio", "status", "desktop", "sandbox" }) |name| {
        const t = b.addTest(.{
            .name = b.fmt("test-{s}", .{name}),
            .root_module = b.createModule(.{ .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})), .target = target, .optimize = optimize }),
        });
        t.root_module.addOptions("build_options", opts);
        test_step.dependOn(&b.addRunArtifact(t).step);
        test_bin_step.dependOn(&b.addInstallArtifact(t, .{}).step);
    }
}
