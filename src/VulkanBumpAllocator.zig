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

pub inline fn init(memory_index: u32, size_bytes: u32) !@This() {
    var this = @This(){
        .used = 0,
        .capacity = size_bytes,
        .memory_index = memory_index,
        .memory = undefined,
        .mapped_memory = undefined,
    };
    this.memory = try vulkan_core.device_dispatch.allocateMemory(vulkan_core.logical_device, &vk.MemoryAllocateInfo{
        .allocation_size = size_bytes,
        .memory_type_index = memory_index,
    }, null);
    this.mapped_memory = @ptrCast([*]u8, (try vulkan_core.device_dispatch.mapMemory(vulkan_core.logical_device, this.memory, 0, size_bytes, .{})).?);
    return this;
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
