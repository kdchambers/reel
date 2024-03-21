// SPDX-License-Identifier: MIT
// Copyright (c) 2024 Keith Chambers

const std = @import("std");

const Build = std.Build;
const Pkg = Build.Pkg;

const Scanner = @import("deps/zig-wayland/build.zig").Scanner;

const Options = struct {
    have_wayland: bool,
};
var options: Options = undefined;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "reel",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    options.have_wayland = b.option(bool, "have_wayland", "Build with support for Wayland") orelse true;

    const options_step = b.addOptions();

    if (options.have_wayland) {
        const scanner = try Scanner.create(b, .{
            .target = target,
        });
        const wayland_module = b.createModule(.{ .root_source_file = scanner.result });

        scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
        scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");

        const have_wlr_screencopy = blk: {
            const process_result = std.ChildProcess.run(.{
                .allocator = b.allocator,
                .argv = &.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" },
            }) catch return error.MissingWaylandScanner;

            const was_success: bool = blk2: {
                switch (process_result.term) {
                    .Exited => |code| break :blk2 code == 0,
                    else => break :blk2 false,
                }
            };

            if (was_success) {
                const wayland_protocols_dir = std.mem.trim(u8, process_result.stdout, &std.ascii.whitespace);
                const protocal_path = b.pathJoin(&.{ wayland_protocols_dir, "/unstable/wlr-screencopy/wlr-screencopy-unstable-v1.xml" });
                std.fs.accessAbsolute(protocal_path, .{}) catch break :blk false;
            }

            scanner.addSystemProtocol("unstable/wlr-screencopy/wlr-screencopy-unstable-v1.xml");
            break :blk true;
        };

        scanner.generate("wl_compositor", 4);
        scanner.generate("wl_seat", 5);
        scanner.generate("wl_shm", 1);
        scanner.generate("wl_output", 4);
        scanner.generate("xdg_wm_base", 2);
        scanner.generate("zxdg_decoration_manager_v1", 1);

        if (have_wlr_screencopy) {
            scanner.generate("zwlr_screencopy_manager_v1", 3);
        }

        exe.root_module.addImport("wayland", wayland_module);

        exe.linkLibC();
        scanner.addCSource(exe);

        exe.linkSystemLibrary("wayland-client");
        exe.linkSystemLibrary("wayland-cursor");

        options_step.addOption(bool, "have_wlr_screencopy", have_wlr_screencopy);
    } else {
        options_step.addOption(bool, "have_wlr_screencopy", false);
    }

    options_step.addOption(bool, "have_wayland", options.have_wayland);
    const options_module = options_step.createModule();

    exe.root_module.addImport("build_options", options_module);

    const vkzig_dep = b.dependency("vulkan_zig", .{
        .registry = @as([]const u8, b.pathFromRoot("deps/vk.xml")),
    });
    const vkzig_bindings = vkzig_dep.module("vulkan-zig");
    exe.root_module.addImport("vulkan", vkzig_bindings);

    const shaders_module = b.createModule(.{
        .root_source_file = .{ .path = "shaders/shaders.zig" },
    });
    exe.root_module.addImport("shaders", shaders_module);

    const fontana_dep = b.dependency("fontana", .{
        .target = target,
        .optimize = optimize,
    });
    const fontana_module = fontana_dep.module("fontana");
    exe.root_module.addImport("fontana", fontana_module);

    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    const zigimg_module = zigimg_dep.module("zigimg");
    exe.root_module.addImport("zigimg", zigimg_module);

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
    unit_tests.root_module.addImport("build_options", options_module);

    const run_test_cmd = b.addRunArtifact(unit_tests);

    const unit_test_step = b.step("test", "Run unit tests");
    unit_test_step.dependOn(&run_test_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run reel");
    run_step.dependOn(&run_cmd.step);
}
