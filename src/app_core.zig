// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const log = std.log;
const screencapture = @import("screencast.zig");
const build_options = @import("build_options");
const user_interface = @import("user_interface.zig");

const wayland_core = if (build_options.have_wayland) @import("wayland_core.zig") else void;

pub const Request = enum(u8) {
    core_shutdown,

    record_start,
    record_pause,
    record_stop,
    record_quality_set,
    record_format_set,

    screenshot_output_set,
    screenshot_region_set,
    screenshot_display_set,
    screenshot_do,
};

pub const RequestBuffer = struct {
    buffer: []u8,
    index: usize,

    //
    // TODO: Implement readArray, readArraySentinal
    // Probably better to write size of array, then array contents
    // Using 0 as terminator would be problamatic
    //

    pub fn next(self: *@This()) ?Request {
        if (self.index == self.buffer.len)
            return null;
        std.debug.assert(self.index < self.buffer.len);
        defer self.index += 1;
        return @intToEnum(Request, self.buffer[self.index]);
    }

    pub fn readParam(self: *@This(), comptime T: type) !T {
        const bytes_to_read = @sizeOf(T);
        if (self.index + bytes_to_read > self.buffer.len)
            return error.EndOfBuffer;
        defer self.index += bytes_to_read;
        return @ptrCast(*T, &self.buffer[self.index]).*;
    }
};

pub const ScreenCaptureBackend = screencapture.Backend;

pub const InitOptions = struct {
    screencapture_order: []const ScreenCaptureBackend,
    ui_backend: user_interface.Backend,
};

const State = enum {
    uninitialized,
    initialized,
    running,
    closed,
};

pub const InitError = error{ IncorrectState, WaylandInitFail, NoScreencaptureBackend };

var app_state: State = .uninitialized;
var screencapture_interface: screencapture.Interface = undefined;
var ui_interface: user_interface.Interface = undefined;

pub fn init(allocator: std.mem.Allocator, options: InitOptions) InitError!void {
    if (app_state != .uninitialized)
        return error.IncorrectState;

    std.debug.assert(options.screencapture_order.len != 0);

    if (comptime build_options.have_wayland) {
        wayland_core.init(allocator) catch |err| {
            log.err("Failed to initialize Wayland. Error: {}", .{err});
            return error.WaylandInitFail;
        };
    }

    const supported_screencapture_backends = screencapture.detectBackends();
    screencapture_interface = blk: for (options.screencapture_order) |ordered_backend| {
        inner: for (supported_screencapture_backends) |supported_backend| {
            if (ordered_backend == supported_backend) {
                log.info("Screencapture backend: {s}", .{@tagName(supported_backend)});
                break :blk screencapture.createInterface(supported_backend, onFrameReadyCallback) catch |err| {
                    log.err("Failed to create interface to screencapture backend ({s}). Error: {}", .{
                        @tagName(supported_backend),
                        err,
                    });
                    continue :inner;
                };
            }
        }
    } else return error.NoScreencaptureBackend;

    _ = wayland_core.sync();

    ui_interface = user_interface.interface(options.ui_backend);
    ui_interface.init();
}

pub fn run() !void {
    const input_fps = 120;
    const target_runtime_ns = std.time.ns_per_s * 8;
    const ns_per_frame = @divFloor(std.time.ns_per_s, input_fps);
    var runtime_ns: u64 = 0;

    while (runtime_ns <= target_runtime_ns) {
        var frame_start = std.time.nanoTimestamp();
        _ = wayland_core.sync();

        var request_buffer = ui_interface.update();
        while (request_buffer.next()) |request| {
            switch (request) {
                .core_shutdown => {
                    std.log.info("core: shutdown request", .{});
                    return;
                },
                .screenshot_do => screencapture_interface.screenshot("screenshot.png"),
                else => std.log.err("Invalid core request", .{}),
            }
        }

        const frame_duration = @intCast(u64, std.time.nanoTimestamp() - frame_start);
        if (frame_duration < ns_per_frame) {
            std.time.sleep(ns_per_frame - frame_duration);
        }
        runtime_ns += ns_per_frame;
    }

    std.time.sleep(std.time.ns_per_s * 1);
}

pub fn deinit() void {
    if (comptime build_options.have_wayland) wayland_core.deinit();

    ui_interface.deinit();

    log.info("Shutting down app core", .{});
    std.time.sleep(std.time.ns_per_s * 1);
}

pub fn displayList() [][]const u8 {
    if (comptime build_options.have_wayland) {
        return wayland_core.display_list.items;
    }
    unreachable;
}

fn onFrameReadyCallback(width: u32, height: u32, pixels: [*]const screencapture.PixelType) void {
    _ = pixels;
    log.info("width {d}, height {d}", .{ width, height });
}
