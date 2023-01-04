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
    const mode = b.standardReleaseOptions();

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

    const exe = b.addExecutable("reel", "src/main.zig");

    exe.setTarget(target);
    exe.setBuildMode(mode);

    const gen = vkgen.VkGenerateStep.create(b, "deps/vk.xml", "vk.zig");
    const vulkan_pkg = gen.getPackage("vulkan");

    exe.addPackage(.{
        .name = "shaders",
        .source = .{ .path = "shaders/shaders.zig" },
    });

    exe.addPackage(.{
        .name = "fontana",
        .source = .{ .path = "deps/fontana/src/fontana.zig" },
    });

    exe.addPackage(.{
        .name = "wayland",
        .source = .{ .generated = &scanner.result },
    });
    exe.step.dependOn(&scanner.step);

    exe.addPackagePath("zigimg", "deps/zigimg/zigimg.zig");

    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("wayland-cursor");

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

    exe.addPackage(vulkan_pkg);

    exe.install();

    const run_cmd = exe.run();
    if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run reel");
    run_step.dependOn(&run_cmd.step);
}
