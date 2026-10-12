// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = optimize != .Debug;

    // zpanel — сама панель; меню запускаются кликом по значкам; zbg — демон обоев
    const apps = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "zpanel", .root = "src/main.zig" },
        .{ .name = "zwifi", .root = "src/wifi.zig" },
        .{ .name = "zbt", .root = "src/bt.zig" },
        .{ .name = "zwall", .root = "src/wall.zig" },
        .{ .name = "zbg", .root = "src/zbg.zig" },
        .{ .name = "zpower", .root = "src/power.zig" },
        .{ .name = "zcal", .root = "src/cal.zig" },
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
                // в релизе — без отладочной информации и таблиц раскрутки: бинарники меньше
                .strip = if (release) true else null,
                .unwind_tables = if (release) .none else null,
            }),
        });
        b.installArtifact(exe);
    }
}
