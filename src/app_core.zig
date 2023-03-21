// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const log = std.log;
const screencapture = @import("screencast.zig");
const build_options = @import("build_options");
const frontend = @import("frontend.zig");

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
        const alignment = @alignOf(T);
        const misaligment = self.index % alignment;
        if (misaligment > 0) {
            std.debug.assert(misaligment < alignment);
            const padding_required = alignment - misaligment;
            std.debug.assert(padding_required < alignment);
            self.index += padding_required;
            std.debug.assert(self.index % alignment == 0);
        }

        const bytes_to_read = @sizeOf(T);
        if (self.index + bytes_to_read > self.buffer.len)
            return error.EndOfBuffer;
        defer self.index += bytes_to_read;
        return @ptrCast(*T, @alignCast(alignment, &self.buffer[self.index])).*;
    }
};

pub const ScreenCaptureBackend = screencapture.Backend;

pub const InitOptions = struct {
    screencapture_order: []const ScreenCaptureBackend,
    frontend: frontend.InterfaceImplTag,
};

const State = enum {
    uninitialized,
    initialized,
    running,
    closed,
};

pub const InitError = error{
    IncorrectState,
    WaylandInitFail,
    NoScreencaptureBackend,
    FrontendInitFail,
};

var app_state: State = .uninitialized;
var screencapture_interface: screencapture.Interface = undefined;
var frontend_interface: frontend.Interface = undefined;

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

    frontend_interface = frontend.interface(options.frontend);
    frontend_interface.init(allocator) catch return error.FrontendInitFail;
}

pub fn run() !void {
    const input_fps = 120;
    const target_runtime_ns = std.time.ns_per_s * 8;
    const ns_per_frame = @divFloor(std.time.ns_per_s, input_fps);
    var runtime_ns: u64 = 0;

    while (runtime_ns <= target_runtime_ns) {
        var frame_start = std.time.nanoTimestamp();
        _ = wayland_core.sync();

        var request_buffer = frontend_interface.update() catch |err| {
            std.log.err("Runtime User Interface error. {}", .{err});
            return;
        };
        while (request_buffer.next()) |request| {
            switch (request) {
                .core_shutdown => {
                    std.log.info("core: shutdown request", .{});
                    return;
                },
                .screenshot_do => screencapture_interface.screenshot("screenshot.png"),
                .screenshot_display_set => {
                    const display_index = request_buffer.readParam(u16) catch 0;
                    const display_list = displayList();
                    std.log.info("Screenshot display set to: {s}", .{display_list[display_index]});
                },
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

    frontend_interface.deinit();
    log.info("Shutting down app core", .{});
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
