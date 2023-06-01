// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const Build = std.Build;
const Pkg = Build.Pkg;

const vkgen = @import("deps/vulkan-zig/generator/index.zig");
const ScanProtocolsStep = @import("deps/zig-wayland/build.zig").ScanProtocolsStep;
const zmath = @import("deps/zig-gamedev/libs/zmath/build.zig");

const Options = struct {
    have_wayland: bool,
};
var options: Options = undefined;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "reel",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    options.have_wayland = b.option(bool, "have_wayland", "Build with support for Wayland") orelse true;

    if (options.have_wayland) {
        const scanner = ScanProtocolsStep.create(b);
        scanner.addProtocolPath("deps/wayland-protocols/stable/xdg-shell/xdg-shell.xml");
        scanner.addProtocolPath("deps/wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
        scanner.addProtocolPath("deps/wayland-protocols/unstable/wlr-screencopy/wlr-screencopy-unstable-v1.xml");

        scanner.generate("wl_compositor", 4);
        scanner.generate("wl_seat", 5);
        scanner.generate("wl_shm", 1);
        scanner.generate("wl_output", 4);
        scanner.generate("xdg_wm_base", 2);
        scanner.generate("zwlr_screencopy_manager_v1", 3);
        scanner.generate("zxdg_decoration_manager_v1", 1);

        exe.step.dependOn(&scanner.step);

        const wayland_module = b.createModule(.{
            .source_file = .{ .generated = &scanner.result },
            .dependencies = &.{},
        });
        exe.addModule("wayland", wayland_module);
        scanner.addCSource(exe);

        exe.linkSystemLibrary("wayland-client");
        exe.linkSystemLibrary("wayland-cursor");
    }

    const options_step = b.addOptions();
    options_step.addOption(bool, "have_wayland", options.have_wayland);
    const options_module = options_step.createModule();

    exe.addModule("build_options", options_module);

    const gen = vkgen.VkGenerateStep.create(b, "deps/vk.xml");
    exe.addModule("vulkan", gen.getModule());

    const zmath_pkg = zmath.package(b, target, optimize, .{
        .options = .{ .enable_cross_platform_determinism = false },
    });
    zmath_pkg.link(exe);

    const shaders_module = b.createModule(.{
        .source_file = .{ .path = "shaders/shaders.zig" },
        .dependencies = &.{},
    });
    const fontana_module = b.createModule(.{
        .source_file = .{ .path = "deps/fontana/src/fontana.zig" },
        .dependencies = &.{},
    });
    exe.addModule("shaders", shaders_module);
    exe.addModule("fontana", fontana_module);

    const zigimg_module = b.createModule(.{
        .source_file = .{ .path = "deps/zigimg/zigimg.zig" },
        .dependencies = &.{},
    });
    exe.addModule("zigimg", zigimg_module);

    exe.linkLibC();

    //
    // Pipewire Screencast
    //
    // TODO: Remove header dependencies
    const flags = [_][]const u8{
        "-I/usr/include/pipewire-0.3",
        "-I/usr/include/spa-0.2",
    };
    exe.addCSourceFile("src/screencapture/pipewire/pipewire_stream_extra.c", &flags);

    //
    // TODO: Remove header dependencies
    // TODO: Use pkg-config when linking dbus and pipewire
    //
    exe.addIncludePath("/usr/include/pipewire-0.3/");
    exe.addIncludePath("/usr/include/spa-0.2/");

    exe.linkSystemLibrary("dbus-1");
    exe.linkSystemLibrary("pipewire-0.3");

    //
    // FFMPEG
    //
    exe.addIncludePath("/usr/include/ffmpeg");
    exe.linkSystemLibrary("avcodec");
    exe.linkSystemLibrary("avformat");
    exe.linkSystemLibrary("avutil");
    exe.linkSystemLibrary("avdevice");
    exe.linkSystemLibrary("avfilter");
    exe.linkSystemLibrary("swscale");

    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .name = "Reel Unit Tests",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    unit_tests.addModule("build_options", options_module);

    const run_test_cmd = b.addRunArtifact(unit_tests);

    const unit_test_step = b.step("test", "Run unit tests");
    unit_test_step.dependOn(&run_test_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run reel");
    run_step.dependOn(&run_cmd.step);
}
