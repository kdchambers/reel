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
            return @as(*Type, @ptrCast(@alignCast(&heap_memory[self.index]))).*;
        }

        pub inline fn getPtr(self: @This()) *Type {
            assert(self.index != std.math.maxInt(u16));
            assert(self.index % alignment == 0);
            return @as(*Type, @ptrCast(@alignCast(&heap_memory[self.index])));
        }

        pub inline fn toIndexAligned(self: @This()) IndexAligned(Type) {
            assert(self.index != std.math.maxInt(u16));
            assert(self.index % alignment == 0);
            return .{ .index = @intCast(@divExact(self.index, 8)) };
        }
    };
}

// Same as Index, but we can divide by 8 to save space (Must be on a 8 byte boundry)
pub fn IndexAligned(comptime Type: type) type {
    return packed struct(u14) {
        const alignment = @alignOf(Type);

        index: u14,

        pub inline fn get(self: @This()) Type {
            return @as(*Type, @ptrCast(@alignCast(&heap_memory[self.index * 8]))).*;
        }

        pub inline fn getPtr(self: @This()) *Type {
            return @as(*Type, @ptrCast(@alignCast(&heap_memory[self.index * 8])));
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
            return @as([*]Type, @ptrCast(@alignCast(&heap_memory[index])))[0..self.count];
        }

        pub inline fn makeSlice(self: @This(), index: u16, count: u16) SliceIndex(Type) {
            assert(index < self.count);
            assert(index + count < self.count);
            return .{ .index = self.index + (index * @sizeOf(Type)), .count = count };
        }
    };
}

pub fn BlockStable(comptime Type: type) type {
    return packed struct(u64) {
        const alignment = @alignOf(Type);

        pub const invalid = @This(){ .base_index = Index(Type).invalid, .capacity = 0, .used_bits = 0, .len = 0 };

        base_index: Index(Type),
        capacity: u8,
        len: u8,
        used_bits: u32,

        pub fn init(self: *@This(), capacity: usize) !void {
            const is_aligned = ((@alignOf(Type) * @as(usize, @intCast(capacity))) % heap_alignment) == 0;
            // TODO: Do proper tests for non-aligned types, for now be safe and disable
            if (!is_aligned) {
                std.log.err("cluster allocation of {s} x {d} is not aligned", .{
                    @typeName(Type),
                    capacity,
                });
                assert(is_aligned);
            }
            const slice = reserve(Type, capacity, .{ .pad_to_alignment = false });
            self.base_index = .{ .index = slice.index };
            self.capacity = @intCast(capacity);
            self.used_bits = 0;
            self.len = 0;
        }

        pub inline fn isNull(self: *@This()) bool {
            return self.base_index.index == Index(Type).invalid.index;
        }

        pub inline fn spaceCount(self: *@This()) usize {
            var unset_count: usize = 0;
            var i: usize = 0;
            while (i < 32) : (i += 1) {
                const bitshift: u5 = @intCast(i);
                if ((self.used_bits >> bitshift) & 0x1 == 0) {
                    unset_count += 1;
                }
            }
            return unset_count;
        }

        pub inline fn isSpace(self: *@This()) bool {
            for (0..32) |i| {
                if ((self.used_bits >> i) & 0x1 == 0) {
                    return true;
                }
            }
            return false;
        }

        pub inline fn reserveNextFreeIndex(self: *@This()) ?usize {
            for (0..32) |i| {
                const bitshift: u5 = @intCast(i);
                if ((self.used_bits >> bitshift) & 0x1 == 0) {
                    self.used_bits |= (@as(u32, 0x1) << bitshift);
                    assert((self.used_bits >> bitshift) & @as(u32, 0x1) == 1);
                    return i;
                }
            }
            return null;
        }

        pub inline fn add(self: *@This(), value: *const Type) !usize {
            assert(self.spaceCount() > 0);
            const next_index: usize = self.reserveNextFreeIndex() orelse return error.NoSpace;
            @as(*Type, @ptrCast(@alignCast(&heap_memory[self.base_index.index + (@sizeOf(Type) * next_index)]))).* = value.*;
            self.len += 1;
            return next_index;
        }

        pub inline fn remove(self: *@This(), index: usize) void {
            var set_bits_count: usize = 0;
            assert(self.capacity > 0);
            for (0..self.capacity) |i| {
                const bitshift: u5 = @intCast(i);
                if ((self.used_bits >> bitshift) & @as(u32, 0x1) == 1) {
                    if (set_bits_count == index) {
                        self.used_bits &= ~(@as(u32, 0x1) << bitshift);
                        assert((self.used_bits >> bitshift) & @as(u32, 0x1) == 0);
                        self.len -= 1;
                        return;
                    }
                    set_bits_count += 1;
                }
            }
            unreachable;
        }

        pub inline fn valueFromIndex(self: @This(), index: usize) Type {
            return @as([*]Type, @ptrCast(@alignCast(&heap_memory[self.base_index.index])))[index];
        }

        pub inline fn ptrMutFromIndex(self: @This(), index: usize) *Type {
            var set_bits_count: usize = 0;
            assert(self.capacity > 0);
            for (0..self.capacity) |i| {
                const bitshift: u5 = @intCast(i);
                if ((self.used_bits >> bitshift) & @as(u32, 0x1) == 1) {
                    if (set_bits_count == index) {
                        return @ptrCast(@alignCast(&heap_memory[self.base_index.index + (i * @sizeOf(Type))]));
                    }
                    set_bits_count += 1;
                }
            }
            unreachable;
        }

        pub inline fn ptrFromIndex(self: @This(), index: usize) *const Type {
            return @ptrCast(self.ptrMutFromIndex(index));
        }

        pub inline fn ptrIndexFromIndex(self: @This(), index: u16) Index(Type) {
            return Index(Type){ .index = self.base_index.index + index };
        }
    };
}

pub fn Cluster(comptime Type: type) type {
    return packed struct(u32) {
        const alignment = @alignOf(Type);

        pub const invalid = @This(){ .base_index = Index(Type).invalid, .capacity = 0, .len = 0 };

        base_index: Index(Type),
        capacity: u8,
        len: u8,

        pub fn create(capacity: usize) !Cluster(Type) {
            return try allocateCluster(Type, capacity);
        }

        pub fn init(self: *@This(), capacity: usize) !void {
            self.* = try allocateCluster(Type, capacity);
        }

        pub inline fn setNull(self: *@This()) void {
            self.base_index = Index(Type).invalid;
        }

        pub inline fn isNull(self: @This()) bool {
            return self.base_index.index == Index(Type).invalid.index;
        }

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
            const end_index: usize = start_index + (@sizeOf(Type) * @as(usize, @intCast(self.capacity)));
            @memset(heap_memory[start_index..end_index], 0);
        }

        pub inline fn write(self: *@This(), value: *const Type) Index(Type) {
            const dst_local_index: usize = @intCast(self.len);
            const dst_local_offset: usize = @sizeOf(Type) * dst_local_index;
            const dst_offset: usize = self.base_index.index + dst_local_offset;
            const dst_ptr: *Type = @ptrCast(@alignCast(&heap_memory[dst_offset]));
            dst_ptr.* = value.*;
            const index: u16 = self.base_index.index + self.len;
            self.len += 1;
            return .{ .index = index };
        }

        pub inline fn at(self: @This(), index: usize) Type {
            return @as([*]Type, @ptrCast(@alignCast(&heap_memory[self.base_index.index])))[index];
        }

        pub inline fn atPtr(self: @This(), index: usize) *Type {
            const misalignment = (self.base_index.index + (index * @sizeOf(Type))) % alignment;
            if (misalignment != 0) {
                std.log.err("Base index: {d} Type: {s}, alignment: {d}, index: {d} is misaligned", .{
                    self.base_index.index,
                    @typeName(Type),
                    alignment,
                    index,
                });
            }
            return @ptrCast(@alignCast(&heap_memory[self.base_index.index + (index * @sizeOf(Type))]));
        }

        pub inline fn ptrFromIndex(self: @This(), index: usize) *const Type {
            const misalignment = (self.base_index.index + (index * @sizeOf(Type))) % alignment;
            if (misalignment != 0) {
                std.log.err("Base index: {d} Type: {s}, alignment: {d}, index: {d} is misaligned", .{
                    self.base_index.index,
                    @typeName(Type),
                    alignment,
                    index,
                });
            }
            return @ptrCast(@alignCast(&heap_memory[self.base_index.index + (index * @sizeOf(Type))]));
        }

        pub inline fn atIndex(self: @This(), index: usize) Index(Type) {
            return Index(Type){ .index = self.base_index.index + index };
        }

        pub inline fn isSpace(self: @This()) bool {
            return (self.len < self.capacity);
        }
    };
}

var heap_memory: []align(heap_alignment) u8 = undefined;
var heap_index: usize = undefined;

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

pub inline fn freeBytesCount() usize {
    return heap_memory.len - heap_index;
}

pub inline fn usedBytesCount() usize {
    return heap_index;
}

pub inline fn reserve(comptime Type: type, count: usize, comptime options: WriteOptions) SliceIndex(Type) {
    _ = options;
    assert(heap_index % heap_alignment == 0);
    assert(@alignOf(Type) <= heap_alignment);
    const result_index: u16 = @intCast(heap_index);
    const allocation_size: usize = @sizeOf(Type) * count;
    heap_index += allocation_size;
    heap_index = roundUp(heap_index, heap_alignment);
    assert(heap_index % heap_alignment == 0);
    assert(result_index % @alignOf(Type) == 0);
    return .{ .index = result_index, .count = @intCast(count) };
}

pub fn allocateCluster(comptime Type: type, capacity: usize) !Cluster(Type) {
    const is_aligned = ((@alignOf(Type) * capacity) % heap_alignment) == 0;
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
        .capacity = @intCast(capacity),
        .len = 0,
    };
}

pub inline fn write(comptime Type: type, value: *const Type) Index(Type) {
    assert(heap_index % heap_alignment == 0);
    assert(@alignOf(Type) <= heap_alignment);
    const alignment_padding = comptime heap_alignment - @alignOf(Type);
    const dst_ptr: *Type = @ptrCast(@alignCast(&heap_memory[heap_index]));
    dst_ptr.* = value.*;
    const result_index: usize = heap_index;
    heap_index += @sizeOf(Type) + alignment_padding;
    assert(heap_index % heap_alignment == 0);
    assert(result_index % @alignOf(Type) == 0);
    return .{ .index = @intCast(result_index) };
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
    const result_index: usize = heap_index;
    @memcpy(@as([*]Type, @ptrCast(@alignCast(&heap_memory[heap_index])))[0..slice.len], slice);
    heap_index += @intCast(@sizeOf(Type) * slice.len);
    heap_index = roundUp(heap_index, heap_alignment);
    return .{ .index = @intCast(result_index), .count = @intCast(slice.len) };
}

pub inline fn writeN(comptime Type: type, value: *const Type, count: u16) SliceIndex(Type) {
    comptime assert(@alignOf(Type) <= heap_alignment);
    const result_index: usize = heap_index;
    @memset(@as([*]Type, @ptrCast(@alignCast(&heap_memory[heap_index])))[0..count], value.*);
    heap_index += @intCast(@sizeOf(Type) * count);
    heap_index = roundUp(heap_index, heap_alignment);
    return .{ .index = @intCast(result_index), .count = @intCast(count) };
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
