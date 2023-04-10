// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const log = std.log;
const builtin = @import("builtin");
const Timer = @import("utils.zig").Timer;
const app_core = @import("app_core.zig");

var stdlib_gpa: if (builtin.mode == .Debug) std.heap.GeneralPurposeAllocator(.{}) else void = .{};
var gpa: std.mem.Allocator = undefined;

pub fn main() !void {
    const runtime_timer = Timer.now();

    gpa = if (builtin.mode == .Debug) stdlib_gpa.allocator() else std.heap.c_allocator;

    const app_options = app_core.InitOptions{
        .screencapture_order = &[_]app_core.ScreenCaptureBackend{ .pipewire, .wlroots },
        .frontend = .wayland,
    };
    app_core.init(gpa, app_options) catch |err| {
        log.err("Failed to initialized app core. Error: {}", .{err});
        return err;
    };

    try app_core.run();
    app_core.deinit();

    const runtime_duration = runtime_timer.duration();
    log.info("Runtime: {s}", .{std.fmt.fmtDuration(runtime_duration)});
}

comptime {
    if (builtin.os.tag != .linux)
        @panic("Linux is the only supported operating system");
}
