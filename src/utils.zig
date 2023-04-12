// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

pub const RingBuffer = @import("utils/RingBuffer.zig").RingBuffer;
pub const Timer = @import("utils/Timer.zig");
pub const FixedBuffer = @import("utils/FixedBuffer.zig").FixedBuffer;

const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    pub fn now() @This() {
        const time = c.time(null);
        const time_info = c.localtime(&time).*;
        return .{
            .year = @intCast(u16, time_info.tm_year + 1900),
            .month = @intCast(u8, time_info.tm_mon + 1),
            .day = @intCast(u8, time_info.tm_mday),
            .hour = @intCast(u8, time_info.tm_hour),
            .minute = @intCast(u8, time_info.tm_min),
            .second = @intCast(u8, time_info.tm_sec),
        };
    }
};

pub const Duration = struct {
    hours: u8,
    minutes: u8,
    seconds: u8,
    milliseconds: u16,

    pub fn fromNanoseconds(ns: u64) @This() {
        return .{
            .hours = @intCast(u8, @divFloor(ns, std.time.ns_per_hour) % 24),
            .minutes = @intCast(u8, @divFloor(ns, std.time.ns_per_min) % 60),
            .seconds = @intCast(u8, @divFloor(ns, std.time.ns_per_s) % 60),
            .milliseconds = @intCast(u16, @divFloor(ns, std.time.ns_per_ms) % 1000),
        };
    }
};

test "Duration" {
    const expect = std.testing.expect;
    const time = std.time;
    const ts: u64 = (time.ns_per_hour * 2) + (time.ns_per_min * 25) + (time.ns_per_s * 33) + (time.ns_per_ms * 345);
    const duration = Duration.fromNanoseconds(ts);
    try expect(duration.hours == 2);
    try expect(duration.minutes == 25);
    try expect(duration.seconds == 33);
    try expect(duration.milliseconds == 345);
}
