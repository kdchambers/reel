// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const Build = std.Build;
const Pkg = Build.Pkg;

const vkgen = @import("deps/vulkan-zig/generator/index.zig");

const Scanner = @import("deps/zig-wayland/build.zig").Scanner;

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
        const scanner = Scanner.create(b, .{
            .wayland_protocols_path = "deps/wayland-protocols",
            .wayland_xml_path = "deps/wayland-protocols/wayland.xml",
        });
        const wayland_module = b.createModule(.{ .source_file = scanner.result });

        scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
        scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
        scanner.addSystemProtocol("unstable/wlr-screencopy/wlr-screencopy-unstable-v1.xml");

        scanner.generate("wl_compositor", 4);
        scanner.generate("wl_seat", 5);
        scanner.generate("wl_shm", 1);
        scanner.generate("wl_output", 4);
        scanner.generate("xdg_wm_base", 2);
        scanner.generate("zwlr_screencopy_manager_v1", 3);
        scanner.generate("zxdg_decoration_manager_v1", 1);

        exe.addModule("wayland", wayland_module);
        exe.linkLibC();
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
    {
        const flags = [_][]const u8{
            "-I/usr/include/pipewire-0.3",
            "-I/usr/include/spa-0.2",
        };
        exe.addCSourceFile(.{ .file = .{ .path = "src/screencapture/pipewire/pipewire_stream_extra.c" }, .flags = &flags });
    }

    {
        //
        // spa header contains a bunch of inline functions and macros, and zig isn't
        // able to translate / import it atm. Therefore I'm using this c file to basically
        // un-inline those functions and make them available to fix.
        //
        const flags = [_][]const u8{"-I/usr/include/spa-0.2"};
        exe.addCSourceFile(.{ .file = .{ .path = "src/bindings/spa/wrapper.c" }, .flags = &flags });
    }

    //
    // TODO: Remove header dependencies
    // TODO: Use pkg-config when linking dbus and pipewire
    //
    exe.addIncludePath(.{ .path = "/usr/include/pipewire-0.3/" });
    exe.addIncludePath(.{ .path = "/usr/include/spa-0.2/" });

    exe.linkSystemLibrary("dbus-1");
    exe.linkSystemLibrary("pipewire-0.3");

    //
    // FFMPEG
    //
    exe.addIncludePath(.{ .path = "/usr/include/ffmpeg" });
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
