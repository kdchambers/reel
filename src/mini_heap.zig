// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

// TODO: Benchmark

const std = @import("std");

const heap_alignment = 8;
pub const IndexUntyped = u16;

pub fn Index(comptime Type: type) type {
    return packed struct(u16) {
        const alignment = @alignOf(Type);

        pub const invalid = @This(){ .index = std.math.maxInt(u16) };

        index: u16,

        pub inline fn isNull(self: @This()) bool {
            return self.index == std.math.maxInt(u16);
        }

        pub inline fn get(self: @This()) Type {
            return @ptrCast(*Type, @alignCast(alignment, &heap_memory[self.index])).*;
        }

        pub inline fn getPtr(self: @This()) *Type {
            return @ptrCast(*Type, @alignCast(alignment, &heap_memory[self.index]));
        }

        pub inline fn toIndexAligned(self: @This()) IndexAligned(Type) {
            return .{ .index = @intCast(u14, @divExact(self.index, 8)) };
        }
    };
}

// Same as Index, but we can divide by 8 to save space (Must be on a 8 byte boundry)
pub fn IndexAligned(comptime Type: type) type {
    return packed struct(u14) {
        const alignment = @alignOf(Type);

        index: u14,

        pub inline fn get(self: @This()) Type {
            return @ptrCast(*Type, @alignCast(alignment, &heap_memory[self.index * 8])).*;
        }

        pub inline fn getPtr(self: @This()) *Type {
            return @ptrCast(*Type, @alignCast(alignment, &heap_memory[self.index * 8]));
        }
    };
}

pub fn SliceIndex(comptime Type: type) type {
    return packed struct(u32) {
        const alignment = @alignOf(Type);

        index: u16,
        count: u16,

        pub inline fn get(self: @This()) []Type {
            const index = self.index.index;
            return @ptrCast([*]Type, @alignCast(alignment, &heap_memory[index]))[0..self.count];
        }
    };
}

pub fn Cluster(comptime Type: type) type {
    return packed struct(u32) {
        const alignment = @alignOf(Type);

        base_index: Index(Type),
        capacity: u8,
        len: u8,

        pub inline fn remove(self: *@This(), index: u16) void {
            std.debug.assert(self.len > 0);
            std.debug.assert(index < self.len);
            self.len -= 1;
            self.atPtr(self.len).* = self.atPtr(index).*;
        }

        pub inline fn reserve(self: *@This()) Index(Type) {
            const index = self.base_index.index + self.len;
            self.len += 1;
            return .{ .index = index };
        }

        pub inline fn setZero(self: @This()) void {
            @memset(
                @ptrCast([*]u8, &heap_memory[self.base_index.index]),
                0,
                @sizeOf(Type) * @intCast(usize, self.capacity),
            );
        }

        pub inline fn write(self: *@This(), value: *const Type) Index(Type) {
            // TODO: Is memcpy faster?
            @ptrCast(*Type, @alignCast(alignment, &heap_memory[self.base_index.index + (@sizeOf(Type) * self.len)])).* = value.*;
            const index: u16 = self.base_index.index + self.len;
            self.len += 1;
            return .{ .index = index };
        }

        pub inline fn at(self: @This(), index: u8) Type {
            return @ptrCast([*]Type, @alignCast(alignment, &heap_memory[self.base_index.index]))[index];
        }

        pub inline fn atPtr(self: @This(), index: u8) *Type {
            const misalignment = (self.base_index.index + (index * @sizeOf(Type))) % alignment;
            if (misalignment != 0) {
                std.log.err("Base index: {d} Type: {s}, alignment: {d}, index: {d} is misaligned", .{
                    self.base_index.index,
                    @typeName(Type),
                    alignment,
                    index,
                });
            }
            return @ptrCast(*Type, @alignCast(alignment, &heap_memory[self.base_index.index + (index * @sizeOf(Type))]));
        }

        pub inline fn atIndex(self: @This(), index: u8) Index(Type) {
            return Index(Type){ .index = self.base_index.index + index };
        }

        pub inline fn isSpace(self: @This()) bool {
            return (self.len < self.capacity);
        }
    };
}

var heap_memory: [*]align(8) u8 = undefined;
var heap_index: u16 = undefined;

pub fn init() !void {
    heap_memory = (try std.heap.page_allocator.alignedAlloc(u8, heap_alignment, std.math.maxInt(u16))).ptr;
    heap_index = 0;
}

pub fn deinit() void {
    std.heap.page_allocator.free(heap_memory[0..std.math.maxInt(u16)]);
}

pub inline fn reset() void {
    heap_index = 0;
}

pub inline fn freeBytesCount() u16 {
    return heap_memory.len - heap_index;
}

pub inline fn usedBytesCount() u16 {
    return heap_index;
}

pub inline fn reserve(comptime Type: type, count: u16, comptime options: WriteOptions) SliceIndex(Type) {
    const allocation_size = @sizeOf(Type) * @intCast(u16, count);
    const misalignment = allocation_size % heap_alignment;
    //
    // Even if `check_alignment` is false, we still want to check alignment in debug mode
    //
    std.debug.assert(misalignment == 0);
    const result_index = heap_index;
    heap_index += allocation_size;
    if (options.check_alignment) {
        const alignment_padding = heap_alignment - misalignment;
        heap_index += alignment_padding;
    }
    std.debug.assert(heap_index % heap_alignment == 0);
    return .{ .index = result_index, .count = count };
}

pub fn allocateCluster(comptime Type: type, capacity: u8) Cluster(Type) {
    const is_aligned = ((@alignOf(Type) * @intCast(usize, capacity)) % heap_alignment) == 0;
    // TODO: Do proper tests for non-aligned types, for now be safe and disable
    if (!is_aligned) {
        std.log.err("cluster allocation of {s} x {d} is not aligned", .{
            @typeName(Type),
            capacity,
        });
        std.debug.assert(is_aligned);
    }
    const slice = reserve(Type, capacity, .{ .check_alignment = false });
    return .{
        .base_index = .{ .index = slice.index },
        .capacity = capacity,
        .len = 0,
    };
}

pub inline fn write(comptime Type: type, value: *const Type) Index(Type) {
    std.debug.assert(@alignOf(Type) <= heap_alignment);
    const type_align = @alignOf(Type);
    const alignment_padding = comptime heap_alignment - type_align;
    const type_size = @sizeOf(Type);
    @ptrCast(*Type, @alignCast(type_align, &heap_memory[heap_index])).* = value.*;
    const result_index = heap_index;
    heap_index += type_size + alignment_padding;
    std.debug.assert(heap_index % heap_alignment == 0);
    return .{ .index = result_index };
}

pub const WriteOptions = struct {
    check_alignment: bool = false,
};

pub inline fn writeSlice(comptime Type: type, slice: []const Type, comptime options: WriteOptions) SliceIndex(Type) {
    const type_size = @sizeOf(Type);
    if (!options.check_alignment) {
        std.debug.assert(@alignOf(Type) == heap_alignment);
        const bytes_count = type_size * slice.len;
        @memcpy(
            @ptrCast([*]u8, &heap_memory[heap_index]),
            @ptrCast([*]const u8, slice.ptr),
            bytes_count,
        );
        const result_index = heap_index;
        heap_index += bytes_count;
        return result_index;
    }
    comptime std.debug.assert(@alignOf(Type) <= heap_alignment);
    std.debug.assert(slice.len <= std.math.maxInt(u16));
    const allocation_size = type_size * slice.len;
    // TODO: This is a hefty calculation for this function
    const alignment_padding: u16 = @mod(heap_alignment - @mod(allocation_size, heap_alignment), heap_alignment);
    @memcpy(
        @ptrCast([*]u8, &heap_memory[heap_index]),
        @ptrCast([*]const u8, slice.ptr),
        allocation_size,
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

    const write_options = WriteOptions{ .check_alignment = true };

    const string1: []const u8 = "1234567";
    const string1_index = writeSlice(u8, string1, write_options);
    try expect(usedBytesCount() == heap_alignment * 1);

    const string2 = "12345678";
    const string2_index = writeSlice(u8, string2, write_options);
    try expect(usedBytesCount() == heap_alignment * 2);

    const string3 = "123456789";
    const string3_index = writeSlice(u8, string3, write_options);
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
