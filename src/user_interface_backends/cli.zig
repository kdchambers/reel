// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

pub fn init() void {
    std.log.info("cli init", .{});
}

pub fn update() void {
    std.log.info("cli update", .{});
}

pub fn deinit() void {
    std.log.info("cli deinit", .{});
}