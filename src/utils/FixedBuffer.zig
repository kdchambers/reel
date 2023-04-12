// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

pub fn FixedBuffer(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        buffer: [capacity]T = undefined,
        len: usize = 0,

        pub fn append(self: *@This(), item: T) !void {
            assert(self.len < capacity);
            if (self.len >= capacity)
                return error.OutOfSpace;
            self.buffer[self.len] = item;
            self.len += 1;
        }
    };
}
