// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        mutex: std.Thread.Mutex,
        buffer: [capacity]T,
        head: u16,
        len: u16,

        pub const init = @This(){
            .head = 0,
            .len = 0,
            .buffer = undefined,
            .mutex = undefined,
        };

        pub fn peek(self: @This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len == 0)
                return null;

            return self.buffer[self.head];
        }

        pub fn push(self: *@This(), value: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len == capacity) {
                return error.Full;
            }

            const dst_index: usize = @intCast(@mod(self.head + self.len, capacity));
            self.buffer[dst_index] = value;
            self.len += 1;
        }

        pub fn pop(self: *@This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len == 0)
                return null;

            const index = self.head;
            self.head = @intCast(@mod(self.head + 1, capacity));
            self.len -= 1;
            return self.buffer[index];
        }
    };
}
