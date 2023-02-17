// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const Builder = std.build.Builder;
const Build = std.build;
const Pkg = Build.Pkg;

const vkgen = @import("deps/vulkan-zig/generator/index.zig");
const ScanProtocolsStep = @import("deps/zig-wayland/build.zig").ScanProtocolsStep;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const exe = b.addExecutable(.{
        .name = "reel",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const gen = vkgen.VkGenerateStep.create(b, "deps/vk.xml", "vk.zig");
    exe.addModule("vulkan", gen.getModule());

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

    const wayland_module = b.createModule(.{
        .source_file = .{ .generated = &scanner.result },
        .dependencies = &.{},
    });
    exe.addModule("wayland", wayland_module);

    exe.step.dependOn(&scanner.step);

    const zigimg_module = b.createModule(.{
        .source_file = .{ .path = "deps/zigimg/zigimg.zig" },
        .dependencies = &.{},
    });
    exe.addModule("zigimg", zigimg_module);

    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("wayland-cursor");

    exe.linkSystemLibrary("pulse");

    //
    // Pipewire Screencast
    //
    // TODO: Remove header dependencies
    const flags = [_][]const u8{
        "-I/usr/include/pipewire-0.3",
        "-I/usr/include/spa-0.2",
    };
    exe.addCSourceFile("src/screencast_backends/pipewire/pipewire_stream_extra.c", &flags);

    //
    // TODO: Remove header dependencies
    // TODO: Use pkg-config when linking dbus and pipewire
    //
    exe.addIncludePath("/usr/include/dbus-1.0/");
    exe.addIncludePath("/usr/include/pipewire-0.3/");
    exe.addIncludePath("/usr/include/spa-0.2/");
    exe.linkSystemLibrary("dbus-1");
    exe.linkSystemLibrary("pipewire-0.3");

    //
    // FFMPEG
    //
    exe.linkSystemLibrary("avcodec");
    exe.linkSystemLibrary("avformat");
    exe.linkSystemLibrary("avutil");
    exe.linkSystemLibrary("avdevice");
    exe.linkSystemLibrary("avfilter");
    exe.linkSystemLibrary("swscale");

    scanner.addCSource(exe);

    exe.install();

    const run_cmd = exe.run();
    if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run reel");
    run_step.dependOn(&run_cmd.step);
}
