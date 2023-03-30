// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const app_core = @import("app_core.zig");
const Request = app_core.Request;

buffer: []u8,
index: usize,

//
// TODO: Implement readArray, readArraySentinal
// Probably better to write size of array, then array contents
// Using 0 as terminator would be problamatic
//

pub fn next(self: *@This()) ?Request {
    if (self.index == self.buffer.len)
        return null;
    std.debug.assert(self.index < self.buffer.len);
    defer self.index += 1;
    return @intToEnum(Request, self.buffer[self.index]);
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
