// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

pub const RingBuffer = @import("utils/RingBuffer.zig").RingBuffer;
pub const Timer = @import("utils/Timer.zig");
pub const FixedBuffer = @import("utils/FixedBuffer.zig").FixedBuffer;

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
