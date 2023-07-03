// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const vulkan_config = @import("renderer/vulkan_config.zig");
const vk = @import("vulkan");
const vulkan_core = @import("renderer/vulkan_core.zig");

used: u64 = 0,
capacity: u64 = 0,
memory_index: u32 = 0,
memory: vk.DeviceMemory,
mapped_memory: [*]u8,

pub fn init(self: *@This(), memory_index: u32, size_bytes: u32) !void {
    self.* = .{
        .used = 0,
        .capacity = size_bytes,
        .memory_index = memory_index,
        .memory = undefined,
        .mapped_memory = undefined,
    };
    self.memory = try vulkan_core.device_dispatch.allocateMemory(vulkan_core.logical_device, &vk.MemoryAllocateInfo{
        .allocation_size = size_bytes,
        .memory_type_index = memory_index,
    }, null);
    self.mapped_memory = @ptrCast((try vulkan_core.device_dispatch.mapMemory(vulkan_core.logical_device, self.memory, 0, size_bytes, .{})).?);
}

pub inline fn allocate(self: *@This(), size_bytes: u64, alignment: u64) !u64 {
    const misalignment = self.used % alignment;
    const offset = if (misalignment > 0) alignment - misalignment else 0;
    const bytes_required = size_bytes + offset;
    const remaining_bytes = self.capacity - self.used;
    if (bytes_required > remaining_bytes)
        return error.OutOfMemory;
    const result = self.used + offset;
    self.used += bytes_required;
    return result;
}

pub inline fn toSlice(self: @This(), comptime Type: type, offset: u64, count: u64) []Type {
    return @as([*]Type, @ptrCast(@alignCast(&self.mapped_memory[offset])))[0..count];
}

pub inline fn mappedBytes(self: @This(), offset: u64, size: u64) []u8 {
    return self.mapped_memory[offset .. offset + size];
}
