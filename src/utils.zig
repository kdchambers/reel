// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const c = @cImport({
    @cInclude("time.h");
});

pub const RingBuffer = @import("utils/RingBuffer.zig").RingBuffer;
pub const Timer = @import("utils/Timer.zig");

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

//   time_t t = time(NULL);
//   struct tm tm = *localtime(&t);
//   printf("now: %d-%02d-%02d %02d:%02d:%02d\n", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);