// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const RequestBuffer = @import("RequestBuffer.zig");
const app_core = @import("app_core.zig");
const Request = app_core.Request;

buffer: [512]u8 = undefined,
used: usize = 0,

pub fn write(self: *@This(), request: Request) !void {
    if (self.used == self.buffer.len)
        return error.EndOfBuffer;
    assert(self.used < self.buffer.len);
    self.buffer[self.used] = @enumToInt(request);
    self.used += 1;
}

pub fn writeParam(self: *@This(), comptime T: type, value: T) !void {
    const alignment = @alignOf(T);
    const misaligment = self.used % alignment;
    if(misaligment > 0) {
        std.debug.assert(misaligment < alignment);
        const padding_required = alignment - misaligment;
        std.debug.assert(padding_required < alignment);
        self.used += padding_required;
        std.debug.assert(self.used % alignment == 0);
    }

    const bytes_to_read = @sizeOf(T);
    if (self.used + bytes_to_read > self.buffer.len)
        return error.EndOfBuffer;
    @ptrCast(*T, @alignCast(alignment, &self.buffer[self.used])).* = value;
    self.used += bytes_to_read;
}

pub fn toRequestBuffer(self: *@This()) RequestBuffer {
    return .{
        .buffer = self.buffer[0..self.used],
        .index = 0,
    };
}
