// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const enable_log_output: bool = false;

start_timestamp: i128,

pub fn start(self: *@This()) void {
    self.start_timestamp = std.time.nanoTimestamp();
}

pub fn duration(self: @This()) u64 {
    const stop_timestamp = std.time.nanoTimestamp();
    return @intCast(stop_timestamp - self.start_timestamp);
}

pub fn now() @This() {
    return .{
        .start_timestamp = std.time.nanoTimestamp(),
    };
}

pub inline fn durationLog(self: @This(), comptime label: []const u8) void {
    if (comptime enable_log_output) {
        const duration_timestamp = self.duration();
        std.log.info("Completed \"{s}\" in {}", .{ label, std.fmt.fmtDuration(duration_timestamp) });
    }
}
