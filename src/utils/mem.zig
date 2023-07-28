const std = @import("std");
const assert = std.debug.assert;

const mini_heap = @import("../frontends/wayland/mini_heap.zig");
const Cluster = mini_heap.Cluster;

const BlockStable = mini_heap.BlockStable;

pub const BlockIndex = packed struct(u32) {
    block_i: u16,
    item_i: u16,

    pub inline fn isNull(self: @This()) bool {
        return self.block_i == std.math.maxInt(u16) and self.item_i == std.math.maxInt(u16);
    }

    pub const invalid = @This(){
        .block_i = std.math.maxInt(u16),
        .item_i = std.math.maxInt(u16),
    };
};

pub fn BlockStableArray(comptime Type: type, comptime capacity: usize, comptime block_capacity: usize) type {
    return struct {
        blocks: [capacity]BlockStable(Type) = [1]BlockStable(Type){BlockStable(Type).invalid} ** capacity,

        pub fn len(self: *const @This()) usize {
            var count: usize = 0;
            inline for (self.blocks) |block| {
                count += block.len;
            }
            return count;
        }

        pub fn ptrMutableFromIndex(self: *@This(), index: usize) *Type {
            assert(index < self.len());
            var local_index: usize = index;
            inline for (self.blocks) |block| {
                if (local_index < block.len) {
                    return block.ptrMutableFromIndex(@intCast(local_index));
                }
                local_index -= block.len;
            }
            unreachable;
        }

        pub fn ptrFromIndex(self: *const @This(), index: usize) *const Type {
            assert(index < self.len());
            var local_index: usize = index;
            inline for (self.blocks) |block| {
                if (local_index < block.len) {
                    return block.ptrFromIndex(@intCast(local_index));
                }
                local_index -= block.len;
            }
            unreachable;
        }

        pub fn add(self: *@This(), value: *const Type) !BlockIndex {
            for (&self.blocks, 0..) |*block, block_i| {
                if (block.isNull()) {
                    @setCold(true);
                    block.init(block_capacity) catch return error.MiniHeapFull;
                }
                const item_i: usize = block.add(value) catch continue;
                return BlockIndex{
                    .block_i = @intCast(block_i),
                    .item_i = @intCast(item_i),
                };
            }
            return error.BlocksFull;
        }

        pub inline fn remove(self: *@This(), block_index: BlockIndex) void {
            self.blocks[block_index.block_i].remove(block_index.item_i);
        }
    };
}

pub const ClusterIndex = packed struct(u16) {
    cluster: u8,
    item: u8,

    const invalid = @This(){
        .cluster = std.math.maxInt(u8),
        .item = std.math.maxInt(u8),
    };
};

pub fn ClusterArray(comptime Type: type, comptime capacity: usize, comptime cluster_capacity: usize) type {
    return struct {
        clusters: [capacity]Cluster(Type) = [1]Cluster(Type){Cluster(Type).invalid} ** capacity,

        pub fn len(self: *const @This()) usize {
            var valid_count: usize = 0;
            for (self.clusters) |cluster| {
                if (cluster != Cluster(Type).invalid) {
                    valid_count += 1;
                }
            }
            return valid_count;
        }

        pub fn ptrAt(self: *@This()) *Type {
            _ = self;
        }

        pub fn add(self: *@This(), value: *const Type) !ClusterIndex {
            inline for (&self.clusters, 0..) |*cluster, cluster_i| {
                if (cluster.isNull()) {
                    cluster.init(cluster_capacity) catch return error.MiniHeapFull;
                }
                if (cluster.isSpace()) {
                    _ = cluster.write(value);
                    return ClusterIndex{
                        .cluster = @intCast(cluster_i),
                        .item = @intCast(cluster.len - 1),
                    };
                }
            }
            return error.ClustersFull;
        }

        pub fn remove(self: *@This(), index: usize) void {
            var remaining_indices: usize = index;
            for (self.clusters) |*cluster| {
                if (remaining_indices < cluster.len) {
                    cluster.remove(@intCast(remaining_indices));
                    return;
                }
                remaining_indices -= cluster.len;
            }
            unreachable;
        }
    };
}
