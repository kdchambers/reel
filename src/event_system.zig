// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const mini_heap = @import("mini_heap.zig");

pub fn MouseEventSystem(comptime event_handler: anytype) type {
    return struct {
        const EventTypeTag = enum(u2) {
            on_hover,
            on_click,
        };

        const EventBinding = packed struct(u64) {
            tag: EventTypeTag,
            data: EventUnion,
        };

        const EventUnion = union(EventTypeTag) {
            on_click: OnClickBinding,
            on_hover: OnHoverBinding,
        };

        const OnHoverBindingFlags = packed struct(u6) {
            is_active: bool,
            reserved_bit_1: u1 = 0,
            reserved_bit_2: u1 = 0,
            reserved_bit_3: u1 = 0,
            reserved_bit_4: u1 = 0,
            reserved_bit_5: u1 = 0,
        };

        const OnHoverBinding = packed struct(u62) {
            enter_subsystem_index: u4,
            exit_subsystem_index: u4,
            enter_action_index: u8,
            exit_action_index: u8,
            flags: OnHoverBindingFlags,
            extent: Index(geometry.Extent(f32)),
        };

        const OnClickBinding = packed struct(u62) {
            press_subsystem_index: u4,
            release_subsystem_index: u4,
            press_action_index: u8,
            release_action_index: u8,
            button_id: u4,
            reserved: u2,
            extent: Index(geometry.Extent(f32)),
        };

        //
        // 16 Clusters of capacity 64 elements = Max of 1024
        //

        var binding_cluster_buffer: [16]mini_heap.Cluster(EventBinding, 64) = undefined;
        var binding_cluster_buffer_count: u32 = 0;

        pub fn addBinding(event: EventBinding) Index(EventBinding) {
            const cluster_index = binding_cluster_buffer_count;
            if (binding_cluster_buffer[cluster_index].isSpace()) {
                return binding_cluster_buffer[cluster_index].write(event);
            }
            binding_cluster_buffer_count += 1;
            binding_cluster_buffer[binding_cluster_buffer_count] = mini_heap.allocateCluster();
            binding_cluster_buffer[binding_cluster_buffer_count].write(&event);
        }

        //
        // TODO: Calculate closest point that would trigger an action & cache so you don't have to
        //       repeat this loop on each mouse movement
        //
        pub fn handleOnHover(position: *const geometry.Coordinates2D(f32)) void {
            const cluster_i: usize = 0;
            while (cluster_i < binding_cluster_buffer_count) : (cluster_i) {
                const cluster = &binding_cluster_buffer[cluster_i];
                var index_i: usize = 0;
                while (index_i < cluster.size) : (index_i += 1) {
                    const binding: *EventBinding = cluster.atPtr(index_i);
                    switch (binding.tag) {
                        .on_hover => {
                            const extent: *geometry.Extent2D(f32) = binding.extent.getPtr();
                            const is_within_extent = (position.x >= extent.x and position.x <= (extent.x + extent.width) and
                                position.y <= extent.y and position.y >= (extent.y - extent.height));
                            if (is_within_extent and !binding.data.on_hover.flags.is_active) {
                                //
                                // We're entering a new hover zone
                                //
                                binding.data.on_hover.flags.is_active = true;
                                event_handler.handleEvent(
                                    binding.data.on_hover.enter_subsystem_index,
                                    binding.data.on_hover.enter_action_index,
                                );
                            } else if (!is_within_extent and binding.data.on_hover.flags.is_active) {
                                //
                                // We're leaving an active hover zone
                                //
                                binding.data.on_hover.flags.is_active = false;
                                event_handler.handleEvent(
                                    binding.data.on_hover.exit_subsystem_index,
                                    binding.data.on_hover.exit_action_index,
                                );
                            }
                        },
                        else => {},
                    }
                }
            }
        }
    };
}
