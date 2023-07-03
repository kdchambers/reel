// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wlr = wayland.client.zwlr;

const WaylandAllocator = @This();

pub const Buffer = struct {
    buffer: *wl.Buffer,
    size: u32,
    offset: u32,
};

mapped_memory: []align(4096) u8,
memory_pool: *wl.ShmPool,
used: u32,

pub fn init(initial_size: u64, shared_memory: *wl.Shm) !WaylandAllocator {
    const shm_name = "/reel_wl_shm";
    const fd = std.c.shm_open(
        shm_name,
        linux.O.RDWR | linux.O.CREAT,
        linux.O.EXCL,
    );

    if (fd < 0) {
        return error.OpenSharedMemoryFailed;
    }
    _ = std.c.shm_unlink(shm_name);

    const alignment_padding_bytes: usize = initial_size % std.mem.page_size;
    const allocation_size_bytes: usize = initial_size + (std.mem.page_size - alignment_padding_bytes);
    std.debug.assert(allocation_size_bytes % std.mem.page_size == 0);
    std.debug.assert(allocation_size_bytes <= std.math.maxInt(i32));

    std.log.info("Allocating {} for frames", .{std.fmt.fmtIntSizeDec(allocation_size_bytes)});

    try std.os.ftruncate(fd, allocation_size_bytes);

    const shared_memory_map = try std.os.mmap(null, allocation_size_bytes, linux.PROT.READ | linux.PROT.WRITE, linux.MAP.SHARED, fd, 0);
    const shared_memory_pool = try wl.Shm.createPool(shared_memory, fd, @intCast(allocation_size_bytes));

    return WaylandAllocator{
        .mapped_memory = shared_memory_map[0..allocation_size_bytes],
        .memory_pool = shared_memory_pool,
        .used = 0,
    };
}

pub fn deinit(self: *@This()) void {
    self.used = 0;
    self.memory_pool.destroy();
    std.os.munmap(self.mapped_memory);
}

pub fn create(self: *@This(), width: u32, height: u32, stride: u32, format: wl.Shm.Format) !Buffer {
    std.debug.assert(width <= std.math.maxInt(i32));
    std.debug.assert(height <= std.math.maxInt(i32));
    std.debug.assert(stride <= std.math.maxInt(i32));
    const buffer = try self.memory_pool.createBuffer(
        @intCast(self.used),
        @intCast(width),
        @intCast(height),
        @intCast(stride),
        format,
    );
    const allocation_size: u32 = height * stride;
    const offset: u32 = self.used;
    self.used += allocation_size;
    return Buffer{
        .buffer = buffer,
        .size = allocation_size,
        .offset = offset,
    };
}

pub fn mappedMemoryForBuffer(self: @This(), buffer: *const Buffer) []u8 {
    const index_start = buffer.offset;
    const index_end = index_start + buffer.size;
    return self.mapped_memory[index_start..index_end];
}
