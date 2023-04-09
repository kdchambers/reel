// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const builtin = @import("builtin");

pub const SampleRange = struct {
    base_sample: usize,
    count: usize,
};

sample_buffer: []f32,
head_index: usize = 0,
sample_count: usize = 0,

total_sample_count: u64,

pub fn create(allocator: std.mem.Allocator, capacity_samples: usize) !@This() {
    return @This(){
        .sample_buffer = try allocator.alloc(f32, capacity_samples),
        .head_index = 0,
        .sample_count = 0,
        .total_sample_count = 0,
    };
}

pub fn init(self: *@This(), allocator: std.mem.Allocator, capacity_samples: usize) !void {
    self.* = .{
        .sample_buffer = try allocator.alloc(f32, capacity_samples),
        .head_index = 0,
        .sample_count = 0,
        .total_sample_count = 0,
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    allocator.free(self.sample_buffer);
    self.* = undefined;
}

pub fn appendOverwrite(self: *@This(), samples: []const i16) void {
    self.ensureCapacityFor(samples.len);

    var dst_index = self.tail();
    const contigious_space = self.sample_buffer.len - dst_index;
    var samples_to_write = @min(contigious_space, samples.len);

    var src_index: usize = 0;
    while (src_index < samples_to_write) {
        self.sample_buffer[dst_index] = @max(-1.0, @intToFloat(f32, samples[src_index]) / std.math.maxInt(i16));
        dst_index += 1;
        src_index += 1;
    }

    dst_index = 0;
    while (src_index < samples.len) {
        self.sample_buffer[dst_index] = @max(-1.0, @intToFloat(f32, samples[src_index]) / std.math.maxInt(i16));
        dst_index += 1;
        src_index += 1;
    }

    self.sample_count += samples.len;
    self.total_sample_count += samples.len;
}

pub fn hasSampleRange(self: @This(), sample_index: usize, sample_count: usize) bool {
    assert(sample_count > 0);
    const base_index = self.total_sample_count - self.sample_count;
    if (sample_index < base_index)
        return false;
    if (sample_index + sample_count > self.total_sample_count)
        return false;
    return true;
}

pub fn sampleRange(self: @This()) SampleRange {
    return .{
        .base_sample = self.total_sample_count - self.sample_count,
        .count = self.sample_count,
    };
}

pub inline fn lastNSample(self: @This(), sample_count: usize) usize {
    assert(sample_count <= self.sample_count);
    return self.total_sample_count - sample_count;
}

pub inline fn availableSamplesFrom(self: @This(), global_sample_index: usize) u64 {
    const global_base_index = self.total_sample_count - self.sample_count;
    if (global_sample_index < global_base_index)
        return 0;
    const sample_index = global_sample_index - global_base_index;
    return self.sample_count - sample_index;
}

pub fn samplesCopyIfRequired(self: @This(), global_sample_index: usize, sample_count: usize, out_buffer: []f32) []const f32 {
    assert(out_buffer.len >= sample_count);

    const start_global_sample_index = self.total_sample_count - self.sample_count;

    assert(global_sample_index >= start_global_sample_index);

    const head_offset = global_sample_index - start_global_sample_index;
    const src_index = (self.head_index + head_offset) % self.sample_buffer.len;
    const contigious_space = self.sample_buffer.len - src_index;
    if (contigious_space >= sample_count) {
        return self.sample_buffer[src_index .. src_index + sample_count];
    }

    mem.copy(f32, out_buffer[0..], self.sample_buffer[src_index .. src_index + contigious_space]);
    mem.copy(f32, out_buffer[contigious_space..], self.sample_buffer[0 .. sample_count - contigious_space]);
    return out_buffer[0..sample_count];
}

inline fn tail(self: @This()) usize {
    return (self.head_index + self.sample_count) % self.sample_buffer.len;
}

inline fn remainingSpace(self: @This()) usize {
    return self.sample_buffer.len - self.sample_count;
}

inline fn ensureCapacityFor(self: *@This(), sample_count: usize) void {
    const available_space = self.remainingSpace();
    if (sample_count > available_space) {
        const samples_to_delete: usize = sample_count - available_space;
        self.head_index = (self.head_index + samples_to_delete) % self.sample_buffer.len;
        self.sample_count -= samples_to_delete;
    }
}

test "writing & sample ranges" {
    const expect = std.testing.expect;

    var allocator = std.testing.allocator;
    var buffer = try @This().create(allocator, 4);
    defer buffer.deinit(allocator);

    const max = std.math.maxInt(i16);
    const min = std.math.minInt(i16);

    buffer.appendOverwrite(&[_]i16{ max, min, max });

    try expect(buffer.sample_count == 3);
    try expect(buffer.total_sample_count == 3);

    try expect(std.mem.eql(f32, &[_]f32{ 1.0, -1.0, 1.0 }, buffer.sample_buffer[0..3]));

    buffer.appendOverwrite(&[_]i16{min});

    try expect(buffer.sample_count == 4);
    try expect(buffer.total_sample_count == 4);

    try expect(std.mem.eql(f32, &[_]f32{ 1.0, -1.0, 1.0, -1.0 }, buffer.sample_buffer[0..4]));

    //
    // Now overflow and check that it's overriding the first values correctly
    //

    buffer.appendOverwrite(&[_]i16{ min, max });
    try expect(buffer.sample_count == 4);
    try expect(buffer.total_sample_count == 6);

    try expect(std.mem.eql(f32, &[_]f32{ -1.0, 1.0, 1.0, -1.0 }, buffer.sample_buffer[0..4]));

    buffer.appendOverwrite(&[_]i16{ min, max });
    try expect(buffer.sample_count == 4);
    try expect(buffer.total_sample_count == 8);

    try expect(std.mem.eql(f32, &[_]f32{ -1.0, 1.0, -1.0, 1.0 }, buffer.sample_buffer[0..4]));

    //
    // Override ALL values
    //
    buffer.appendOverwrite(&[_]i16{ max, max, max, max });
    try expect(buffer.sample_count == 4);
    try expect(buffer.total_sample_count == 12);

    try expect(std.mem.eql(f32, &[_]f32{ 1.0, 1.0, 1.0, 1.0 }, buffer.sample_buffer[0..4]));

    //
    // Check it's range reporting
    //

    const sample_range = buffer.sampleRange();
    try expect(sample_range.base_sample == 8);
    try expect(sample_range.count == 4);

    //
    // Sample range at this point is 8 -- 12
    //

    try expect(buffer.hasSampleRange(8, 1) == true);
    try expect(buffer.hasSampleRange(8, 4) == true);
    try expect(buffer.hasSampleRange(9, 3) == true);
    try expect(buffer.hasSampleRange(10, 2) == true);
    try expect(buffer.hasSampleRange(11, 1) == true);

    try expect(buffer.hasSampleRange(7, 1) == false);
    try expect(buffer.hasSampleRange(8, 5) == false);
    try expect(buffer.hasSampleRange(12, 1) == false);
    try expect(buffer.hasSampleRange(10, 3) == false);
}
