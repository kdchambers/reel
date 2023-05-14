// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const Model = @import("../Model.zig");

const app_core = @import("../app_core.zig");
const CoreUpdateDecoder = app_core.UpdateDecoder;
const CoreRequestEncoder = app_core.CoreRequestEncoder;
const CoreRequestDecoder = app_core.CoreRequestDecoder;

pub const InitError = error{};
pub const UpdateError = error{};

pub fn init(_: std.mem.Allocator) InitError!void {
    std.log.info("headless init", .{});
}

pub fn update(_: *const Model, _: *CoreUpdateDecoder) UpdateError!CoreRequestDecoder {
    std.log.info("headless update", .{});
    return .{
        .buffer = undefined,
        .index = 0,
    };
}

pub fn deinit() void {
    std.log.info("headless deinit", .{});
}
