// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

pub fn Profiler(comptime profile_enabled: bool, comptime Action: type) type {
    return struct {
        const Entry = struct {
            action: Action,
            parent: u16,
            start_ns: u64,
        };

        const Stats = struct {
            slowest_ns: u64,
            fastest_ns: u64,
            times_called: u32,
        };

        base_timestamp: i128,
        entry_buffer: [64]Entry,
        stats_buffer: [8]Stats,
        entry_count: usize = 0,
        entry_index: usize = 0,

        pub fn init(self: *@This()) void {
            for (&self.stats_buffer) |*stat| {
                stat.*.slowest_ns = 0;
                stat.*.fastest_ns = std.math.maxInt(u64);
                stat.*.times_called = 0;
            }
        }

        pub fn reset(self: *@This()) void {
            self.entry_count = 0;
            self.entry_index = std.math.maxInt(u16);
            self.base_timestamp = std.time.nanoTimestamp();
            for (&self.stats_buffer) |*stat| {
                stat.*.slowest_ns = 0;
                stat.*.fastest_ns = std.math.maxInt(u64);
                stat.*.times_called = 0;
            }
        }

        pub fn log(self: *@This(), root_index: u16, indent: u16, threshold_us: u64) void {
            const duration_us = @divFloor(self.entry_buffer[root_index].start_ns, std.time.ns_per_us);
            if (duration_us < threshold_us)
                return;
            for (0..indent) |_|
                std.debug.print("  ", .{});
            std.debug.print("{s} :: {d}us\n", .{
                @tagName(self.entry_buffer[root_index].action),
                duration_us,
            });
            for (self.entry_buffer[0..self.entry_count], 0..) |entry, i| {
                if (entry.parent == root_index)
                    self.log(@intCast(u16, i), indent + 1, threshold_us);
            }
        }

        pub fn push(self: *@This(), comptime action: Action) usize {
            if (comptime !profile_enabled)
                return;
            const current = std.time.nanoTimestamp();
            const start = @intCast(u64, current - self.base_timestamp);
            self.entry_buffer[self.entry_count] = .{
                .start_ns = start,
                .action = action,
                .parent = @intCast(u16, self.entry_index),
            };
            const action_index = @intFromEnum(action);
            self.stats_buffer[action_index].times_called += 1;
            self.entry_index = self.entry_count;
            self.entry_count += 1;

            return self.entry_count - 1;
        }

        pub fn pop(self: *@This(), comptime matched_action: Action) void {
            if (comptime !profile_enabled)
                return;
            const current = @intCast(u64, std.time.nanoTimestamp() - self.base_timestamp);
            const entry_index = self.entry_index;
            const duration: u64 = current - self.entry_buffer[entry_index].start_ns;
            const action = self.entry_buffer[entry_index].action;
            self.entry_buffer[entry_index].start_ns = current - self.entry_buffer[entry_index].start_ns;
            assert(matched_action == action);
            const action_index = @intFromEnum(action);
            self.stats_buffer[action_index].slowest_ns = @max(self.stats_buffer[action_index].slowest_ns, duration);
            self.stats_buffer[action_index].fastest_ns = @min(self.stats_buffer[action_index].fastest_ns, duration);

            self.entry_index = self.entry_buffer[entry_index].parent;
        }
    };
}
