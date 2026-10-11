// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = optimize != .Debug;

    const exe = b.addExecutable(.{
        .name = "zpanel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
            .single_threaded = true,
            // в релизе — без отладочной информации и таблиц раскрутки: бинарник меньше
            .strip = if (release) true else null,
            .unwind_tables = if (release) .none else null,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Запустить панель").dependOn(&run.step);
}
