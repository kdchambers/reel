// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

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

        pub inline fn isValid(self: @This()) bool {
            if (self.index % @alignOf(Type) != 0)
                return false;
            return true;
        }

        pub inline fn get(self: @This()) Type {
            assert(self.index != std.math.maxInt(u16));
            assert(self.index % alignment == 0);
            return @ptrCast(*Type, @alignCast(alignment, &heap_memory[self.index])).*;
        }

        pub inline fn getPtr(self: @This()) *Type {
            assert(self.index != std.math.maxInt(u16));
            assert(self.index % alignment == 0);
            return @ptrCast(*Type, @alignCast(alignment, &heap_memory[self.index]));
        }

        pub inline fn toIndexAligned(self: @This()) IndexAligned(Type) {
            assert(self.index != std.math.maxInt(u16));
            assert(self.index % alignment == 0);
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

        pub inline fn toIndex(self: @This(), index: u16) Index(Type) {
            assert(index < self.count);
            return .{ .index = self.index + (index * @sizeOf(Type)) };
        }

        pub inline fn get(self: @This()) []Type {
            const index = self.index;
            return @ptrCast([*]Type, @alignCast(alignment, &heap_memory[index]))[0..self.count];
        }

        pub inline fn makeSlice(self: @This(), index: u16, count: u16) SliceIndex(Type) {
            assert(index < self.count);
            assert(index + count < self.count);
            return .{ .index = self.index + (index * @sizeOf(Type)), .count = count };
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
            assert(self.len > 0);
            assert(index < self.len);
            self.len -= 1;
            self.atPtr(self.len).* = self.atPtr(index).*;
        }

        pub inline fn reserve(self: *@This()) Index(Type) {
            const index = self.base_index.index + self.len;
            self.len += 1;
            return .{ .index = index };
        }

        pub inline fn setZero(self: @This()) void {
            const start_index: usize = self.base_index.index;
            const end_index: usize = start_index + (@sizeOf(Type) * @intCast(usize, self.capacity));
            @memset(heap_memory[start_index..end_index], 0);
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

var heap_memory: []align(heap_alignment) u8 = undefined;
var heap_index: u16 = undefined;

pub fn init() !void {
    heap_memory = (try std.heap.page_allocator.alignedAlloc(u8, heap_alignment, std.math.maxInt(u16)));
    heap_index = 0;
}

pub fn deinit() void {
    std.heap.page_allocator.free(heap_memory);
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
    _ = options;
    assert(heap_index % heap_alignment == 0);
    assert(@alignOf(Type) <= heap_alignment);
    const result_index: u16 = heap_index;
    const allocation_size = @sizeOf(Type) * @intCast(u16, count);
    heap_index += allocation_size;
    heap_index = roundUp(heap_index, heap_alignment);
    assert(heap_index % heap_alignment == 0);
    assert(result_index % @alignOf(Type) == 0);
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
        assert(is_aligned);
    }
    const slice = reserve(Type, capacity, .{ .pad_to_alignment = false });
    return .{
        .base_index = .{ .index = slice.index },
        .capacity = capacity,
        .len = 0,
    };
}

pub inline fn write(comptime Type: type, value: *const Type) Index(Type) {
    assert(heap_index % heap_alignment == 0);
    assert(@alignOf(Type) <= heap_alignment);
    const alignment_padding = comptime heap_alignment - @alignOf(Type);
    @ptrCast(*Type, @alignCast(@alignOf(Type), &heap_memory[heap_index])).* = value.*;
    const result_index: u16 = heap_index;
    heap_index += @sizeOf(Type) + alignment_padding;
    assert(heap_index % heap_alignment == 0);
    assert(result_index % @alignOf(Type) == 0);
    return .{ .index = result_index };
}

pub inline fn writeString(bytes: []const u8) []const u8 {
    const handle = writeSlice(u8, bytes, .{ .pad_to_alignment = true });
    return heap_memory[handle.index .. handle.index + handle.count];
}

pub const WriteOptions = struct {
    pad_to_alignment: bool = true,
};

inline fn roundUp(value: anytype, multiple: @TypeOf(value)) @TypeOf(value) {
    const remainder = value % multiple;
    return if (remainder == 0) value else (value + multiple) - remainder;
}

pub inline fn writeSlice(comptime Type: type, slice: []const Type, comptime options: WriteOptions) SliceIndex(Type) {
    _ = options;
    comptime assert(@alignOf(Type) <= heap_alignment);
    const result_index = heap_index;
    @memcpy(@ptrCast([*]Type, @alignCast(@alignOf(Type), &heap_memory[heap_index]))[0..slice.len], slice);
    heap_index += @intCast(u16, @sizeOf(Type) * slice.len);
    heap_index = roundUp(heap_index, heap_alignment);
    return .{ .index = result_index, .count = @intCast(u16, slice.len) };
}

pub inline fn writeN(comptime Type: type, value: *const Type, count: u16) SliceIndex(Type) {
    comptime assert(@alignOf(Type) <= heap_alignment);
    const result_index = heap_index;
    @memset(@ptrCast([*]Type, @alignCast(@alignOf(Type), &heap_memory[heap_index]))[0..count], value.*);
    heap_index += @intCast(u16, @sizeOf(Type) * count);
    heap_index = roundUp(heap_index, heap_alignment);
    return .{ .index = result_index, .count = @intCast(u16, count) };
}

fn ClusterBuffer(comptime Type: type, comptime buffer_count: usize, comptime buffer_capacity: usize) type {
    return struct {
        buffers: [buffer_count]Cluster(Type),
        len: u32,

        pub inline fn init(self: *@This()) void {
            self.buffers[0] = allocateCluster(Type, buffer_capacity);
            self.len = 1;
        }

        pub inline fn write(self: *@This(), value: Type) Index(Type) {
            const current_index = self.len - 1;
            if (self.buffers[current_index].isSpace()) {
                return self.buffers[current_index].write(&value);
            }
            const next_index = self.len;
            self.len += 1;
            // TODO:
            std.debug.assert(self.len <= buffer_count);
            self.buffers[next_index] = allocateCluster(Type, buffer_capacity);
            return self.buffers[next_index].write(&value);
        }

        pub inline fn reserve(self: *@This()) Index(Type) {
            const current_index = self.len - 1;
            if (self.buffers[current_index].isSpace()) {
                return self.buffers[current_index].reserve();
            }
            const next_index = self.len;
            self.len += 1;
            // TODO:
            std.debug.assert(self.len <= buffer_count);
            self.buffers[next_index] = allocateCluster(Type, buffer_capacity);
            return self.buffers[next_index].reserve();
        }

        pub inline fn setZeroBuffers(self: *@This()) void {
            for (0..self.len) |i| {
                self.buffers[i].setZero();
            }
        }
    };
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

    const write_options = WriteOptions{ .pad_to_alignment = true };

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
