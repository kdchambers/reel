// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

pub const RingBuffer = @import("utils/RingBuffer.zig").RingBuffer;
pub const Timer = @import("utils/Timer.zig");
pub const FixedBuffer = @import("utils/FixedBuffer.zig").FixedBuffer;
pub const math = @import("utils/zmath.zig");

const profile = @import("utils/profile.zig");

const std = @import("std");
const assert = std.debug.assert;
const c = @cImport({
    @cInclude("time.h");
});

pub const Profiler = profile.Profiler;

/// Removes element in buffer at index `index` by moving all right-side elements to the left
pub inline fn leftShiftRemove(comptime Type: type, buffer: []Type, index: usize) void {
    assert(index < buffer.len);
    var src_index: usize = index + 1;
    assert(src_index > 0);
    while (src_index < buffer.len) : (src_index += 1) {
        buffer[src_index - 1] = buffer[src_index];
    }
}

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

pub fn Encoder(comptime Encoding: type, comptime buffer_size: comptime_int) type {
    return struct {
        pub const Decoder = struct {
            buffer: []u8,
            index: usize,

            pub fn next(self: *@This()) ?Encoding {
                if (self.index == self.buffer.len)
                    return null;
                assert(self.index < self.buffer.len);
                defer self.index += 1;
                return @enumFromInt(Encoding, self.buffer[self.index]);
            }

            pub fn readString(self: *@This()) []const u8 {
                const len = self.readInt(u16);
                const index_start = self.index;
                const index_end = index_start + len;
                self.index += len;
                return self.buffer[index_start..index_end];
            }

            pub fn readInt(self: *@This(), comptime T: type) !T {
                const alignment = @alignOf(T);
                const misaligment = self.index % alignment;
                if (misaligment > 0) {
                    std.debug.assert(misaligment < alignment);
                    const padding_required = alignment - misaligment;
                    std.debug.assert(padding_required < alignment);
                    self.index += padding_required;
                    std.debug.assert(self.index % alignment == 0);
                }

                const bytes_to_read = @sizeOf(T);
                if (self.index + bytes_to_read > self.buffer.len)
                    return error.EndOfBuffer;
                defer self.index += bytes_to_read;
                return @ptrCast(*T, @alignCast(alignment, &self.buffer[self.index])).*;
            }
        };

        buffer: [buffer_size]u8 = undefined,
        used: usize = 0,

        pub inline fn reset(self: *@This()) void {
            self.used = 0;
        }

        pub fn write(self: *@This(), request: Encoding) !void {
            if (self.used == self.buffer.len)
                return error.EndOfBuffer;
            assert(self.used < self.buffer.len);
            self.buffer[self.used] = @intFromEnum(request);
            self.used += 1;
        }

        pub fn writeString(self: *@This(), bytes: []const u8) !void {
            if ((self.used + bytes.len + @sizeOf(u16)) >= self.buffer.len)
                return error.EndOfBuffer;
            self.writeInt(u16, @intCast(u16, bytes.len)) catch unreachable;
            var i: usize = self.used;
            for (bytes) |char| {
                self.buffer[i] = char;
                i += 1;
            }
            self.used += bytes.len;
        }

        pub fn writeInt(self: *@This(), comptime T: type, value: T) !void {
            const alignment = @alignOf(T);
            const misaligment = self.used % alignment;
            if (misaligment > 0) {
                assert(misaligment < alignment);
                const padding_required = alignment - misaligment;
                assert(padding_required < alignment);
                self.used += padding_required;
                assert(self.used % alignment == 0);
            }

            const bytes_to_read = @sizeOf(T);
            if (self.used + bytes_to_read > self.buffer.len)
                return error.EndOfBuffer;
            @ptrCast(*T, @alignCast(alignment, &self.buffer[self.used])).* = value;
            self.used += bytes_to_read;
        }

        pub fn decoder(self: *@This()) Decoder {
            return .{
                .buffer = self.buffer[0..self.used],
                .index = 0,
            };
        }
    };
}
