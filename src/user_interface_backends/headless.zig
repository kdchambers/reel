// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const app_core = @import("../app_core.zig");
const RequestBuffer = app_core.RequestBuffer;

pub const InitError = error {};
pub const UpdateError = error {};

pub fn init(_: std.mem.Allocator) InitError!void {
    std.log.info("headless init", .{});
}

pub fn update() UpdateError!RequestBuffer {
    std.log.info("headless update", .{});
    return .{
        .buffer = undefined,
        .index = 0,
    };
}

pub fn deinit() void {
    std.log.info("headless deinit", .{});
}