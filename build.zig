// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = optimize != .debug;
    // timing output (NETLINE_TRACE=1) only in a -Dtrace=true build; a normal build has none of that code
    const trace = b.option(bool, "trace", "compile in timing output: NETLINE_TRACE=1 prints wakeups and frame times") orelse false;
    const opts = b.addOptions();
    opts.addOption(bool, "trace", trace);

    // netline is the panel itself; menus open on icon clicks; zbg is the wallpaper daemon
    const apps = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "netline", .root = "src/main.zig" },
        .{ .name = "zwifi", .root = "src/wifi.zig" },
        .{ .name = "zbt", .root = "src/bt.zig" },
        .{ .name = "zwall", .root = "src/wall.zig" },
        .{ .name = "zbg", .root = "src/zbg.zig" },
        .{ .name = "zpower", .root = "src/power.zig" },
        .{ .name = "zcal", .root = "src/cal.zig" },
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
        exe.root_module.addOptions("build_options", opts);
        b.installArtifact(exe);
    }
}
