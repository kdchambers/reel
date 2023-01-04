// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

// TODO: Benchmark

const std = @import("std");

pub fn Index(comptime Type: type) type {
    return packed struct(u16) {
        const alignment = @alignOf(Type);

        index: u16,

        pub inline fn get(self: @This()) Type {
            return @ptrCast(*Type, @alignCast(alignment, &heap_memory[self.index])).*;
        }

        pub inline fn getPtr(self: @This()) *Type {
            return @ptrCast(*Type, @alignCast(alignment, &heap_memory[self.index]));
        }
    };
}

pub fn SliceIndex(comptime Type: type) type {
    return packed struct(u32) {
        const alignment = @alignOf(Type);

        index: u16,
        count: u16,

        pub inline fn get(self: @This()) []Type {
            return @ptrCast([*]Type, @alignCast(alignment, &heap_memory[self.index]))[0..self.count];
        }
    };
}

const heap_alignment = 8;

var heap_memory: [*]align(8) u8 = undefined;
var heap_index: u16 = undefined;

pub fn init() !void {
    heap_memory = (try std.heap.page_allocator.alignedAlloc(u8, heap_alignment, std.math.maxInt(u16))).ptr;
    heap_index = 0;
}

pub fn deinit() void {
    std.heap.page_allocator.free(heap_memory[0..std.math.maxInt(u16)]);
}

pub inline fn freeBytesCount() u16 {
    return heap_memory.len - heap_index;
}

pub inline fn usedBytesCount() u16 {
    return heap_index;
}

pub inline fn write(comptime Type: type, value: *const Type) Index(Type) {
    std.debug.assert(@alignOf(Type) <= heap_alignment);
    const alignment_padding = comptime heap_alignment - @alignOf(Type);
    const type_size = @sizeOf(Type);
    @memcpy(
        @ptrCast([*]u8, &heap_memory[heap_index]),
        @ptrCast([*]const u8, value),
        type_size,
    );
    const result_index = heap_index;
    heap_index += type_size + alignment_padding;
    std.debug.assert(heap_index % heap_alignment == 0);
    return .{ .index = result_index };
}

pub inline fn writeSlice(comptime Type: type, slice: []const Type) SliceIndex(Type) {
    comptime std.debug.assert(@alignOf(Type) <= heap_alignment);
    std.debug.assert(slice.len <= std.math.maxInt(u16));
    const type_size = @sizeOf(Type);
    const type_align = @alignOf(Type);
    // TODO: This is a hefty calculation for this function
    const alignment_padding: u16 = @mod(heap_alignment - @mod(type_align * slice.len, heap_alignment), heap_alignment);
    @memcpy(
        @ptrCast([*]u8, &heap_memory[heap_index]),
        @ptrCast([*]const u8, slice.ptr),
        type_size * slice.len,
    );
    const result_index = heap_index;
    heap_index += @intCast(u16, type_size * slice.len) + alignment_padding;
    std.debug.assert(heap_index % heap_alignment == 0);
    return .{ .index = result_index, .count = @intCast(u16, slice.len) };
}

test "mini_heap write values" {
    const expect = std.testing.expect;

    const float16: f16 = 0.1;
    const float32: f32 = 0.2;
    const float64: f64 = 0.3;

    try init();

    const float16_index = write(f16, &float16);
    const float32_index = write(f32, &float32);
    const float64_index = write(f64, &float64);

    try expect(float16_index.get() == float16);
    try expect(float32_index.get() == float32);
    try expect(float64_index.get() == float64);

    try expect(usedBytesCount() == heap_alignment * 3);

    const Struct = struct {
        flag: u8,
        count: u16,
        value: *const f32,
    };

    const s_index = blk: {
        const s = Struct{
            .flag = 4,
            .count = 10,
            .value = &float32,
        };
        break :blk write(Struct, &s);
    };

    try expect(s_index.get().flag == 4);
    try expect(s_index.get().count == 10);
    try expect(s_index.get().value == &float32);

    // Struct will be rounded up to 16 bytes
    try expect(usedBytesCount() == heap_alignment * 5);

    deinit();
}

test "mini_heap write slices" {
    const expect = std.testing.expect;

    try init();

    const string1: []const u8 = "1234567";
    const string1_index = writeSlice(u8, string1);
    try expect(usedBytesCount() == heap_alignment * 1);

    const string2 = "12345678";
    const string2_index = writeSlice(u8, string2);
    try expect(usedBytesCount() == heap_alignment * 2);

    const string3 = "123456789";
    const string3_index = writeSlice(u8, string3);
    try expect(usedBytesCount() == heap_alignment * 4);

    const indexed_string_1 = string1_index.get();
    const indexed_string_2 = string2_index.get();
    const indexed_string_3 = string3_index.get();

    try expect(indexed_string_1.len == string1.len);
    try expect(indexed_string_2.len == string2.len);
    try expect(indexed_string_3.len == string3.len);

    try expect(std.mem.eql(u8, indexed_string_1, string1));
    try expect(std.mem.eql(u8, indexed_string_2, string2));
    try expect(std.mem.eql(u8, indexed_string_3, string3));
}
