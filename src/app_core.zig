// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const log = std.log;
const screencapture = @import("screencast.zig");
const build_options = @import("build_options");

comptime {
    std.debug.assert(build_options.have_wayland == false);
}

const wayland_core = if(build_options.have_wayland) @import("wayland_core.zig") else void;

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

pub const ScreenCaptureBackend = enum {
    pipewire,
    wlroots,
};

var screencapture_order = [_]ScreenCaptureBackend {
    .pipewire,
    .wlroots,
};

pub const InitOptions = struct {
    screencapture_order: [2]ScreenCaptureBackend,
    ui_backend: UIBackend,
};

const State = enum {
    uninitialized,
    initialized,
    running,
    closed,
};

pub const InitError = error {
    IncorrectState,
    WaylandInitFail,
};

var app_state: State = .uninitialized;

pub fn init(options: InitOptions) InitError!void {
    if(app_state != .uninitialized)
        return error.IncorrectState;

    if(comptime build_options.have_wayland) {
        wayland_core.init() catch |err| {
            log.err("Failed to initialize Wayland. Error: {}", .{err});
            return error.WaylandInitFail;
        };
    }

    const supported_screencapture_backends = screencapture.detectBackends();
    log.info("Supported screencapture backends", .{});
    for(supported_screencapture_backends) |backend| {
        log.info("{s}", .{@tagName(backend)});
    }

    _ = options;
}

pub fn run() !void {
    std.time.sleep(std.time.ns_per_s * 3);
}

pub fn deinit() void {
    if(comptime build_options.have_wayland) wayland_core.deinit();
    
    std.time.sleep(std.time.ns_per_s * 1);
}