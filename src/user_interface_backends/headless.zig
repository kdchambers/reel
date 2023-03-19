// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

pub fn init() void {
    std.log.info("headless init", .{});
}

pub fn update() void {
    std.log.info("headless update", .{});
}

pub fn deinit() void {
    std.log.info("headless deinit", .{});
}