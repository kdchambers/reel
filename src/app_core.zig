// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const log = std.log;
const screencapture = @import("screencast.zig");
const build_options = @import("build_options");

const wayland_core = if (build_options.have_wayland) @import("wayland_core.zig") else void;

pub const Request = enum(u8) {
    record_start,
    record_pause,
    record_stop,
    record_quality_set,
    record_format_set,
};

pub const RequestBuffer = struct {
    buffer: []u8,
    index: usize,

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

pub const UIBackend = enum {
    headless,
    cli,
    wayland_vulkan,
    wayland_opengl,
    wayland_software,
};

pub const ScreenCaptureBackend = screencapture.Backend;

pub const InitOptions = struct {
    screencapture_order: []const ScreenCaptureBackend,
    ui_backend: UIBackend,
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
    ScreenCaptureInitFail,
    NoScreencaptureBackend
};

var app_state: State = .uninitialized;

pub fn init(options: InitOptions) InitError!void {
    if (app_state != .uninitialized)
        return error.IncorrectState;

    std.debug.assert(options.screencapture_order.len != 0);

    if (comptime build_options.have_wayland) {
        wayland_core.init() catch |err| {
            log.err("Failed to initialize Wayland. Error: {}", .{err});
            return error.WaylandInitFail;
        };
    }

    const supported_screencapture_backends = screencapture.detectBackends();
    const screencapture_interface = blk: for (options.screencapture_order) |ordered_backend| {
        for(supported_screencapture_backends) |supported_backend| {
            if(ordered_backend == supported_backend) break :blk screencapture.createInterface(supported_backend, onFrameReadyCallback) catch |err| {
                log.err("Failed to create interface to screencapture backend ({s}). Error: {}", .{
                    @tagName(supported_backend),
                    err,
                });
                return error.ScreenCaptureInitFail;
            };
        }
        return error.NoScreencaptureBackend;
    } else unreachable;

    _ = screencapture_interface;
}

pub fn run() !void {
    // const input_fps = 240;
    std.time.sleep(std.time.ns_per_s * 1);
}

pub fn deinit() void {
    if (comptime build_options.have_wayland) wayland_core.deinit();

    std.time.sleep(std.time.ns_per_s * 1);
}

fn onFrameReadyCallback(width: u32, height: u32, pixels: [*]const screencapture.PixelType) void {
    _ = pixels;
    log.info("width {d}, height {d}", .{ width, height });
}