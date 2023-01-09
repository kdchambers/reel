// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;

const mini_heap = @import("mini_heap.zig");
const geometry = @import("geometry.zig");

const Index = mini_heap.Index;
const IndexAligned = mini_heap.IndexAligned;

const MouseEventEntry = packed struct(u32) {
    hover_enabled: bool,
    hover_active: bool,
    extent: mini_heap.IndexAligned(geometry.Extent2D(f32)),
    state: mini_heap.Index(HoverZoneState),
};

pub const HoverZoneState = packed struct(u8) {
    hover_enter: bool,
    hover_exit: bool,
    left_click_press: bool,
    left_click_release: bool,
    right_click_press: bool,
    right_click_release: bool,
    pending_right_click_release: bool,
    pending_left_click_release: bool,

    pub const init = HoverZoneState{
        .hover_enter = false,
        .hover_exit = false,
        .left_click_press = false,
        .left_click_release = false,
        .right_click_press = false,
        .right_click_release = false,
        .pending_right_click_release = false,
        .pending_left_click_release = false,
    };

    pub fn reset(self: *@This()) void {
        self.hover_enter = false;
        self.hover_exit = false;
        self.left_click_press = false;
        self.left_click_release = false;
        self.right_click_press = false;
        self.right_click_release = false;
        self.pending_left_click_release = false;
        self.pending_right_click_release = false;
    }

    pub fn clear(self: *@This()) void {
        self.hover_enter = false;
        self.hover_exit = false;
        self.left_click_press = false;
        self.left_click_release = false;
        self.right_click_press = false;
        self.right_click_release = false;
        //
        // Don't clear pending_*_click_release as that's internal state
        // required to determine when a full release event occurs
        //
    }
};

/// Wayland uses linux' input-event-codes for keys and buttons. When a mouse button is
/// clicked one of these will be sent with the event.
/// https://wayland-book.com/seat/pointer.html
/// https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h
pub const MouseButton = enum(c_int) {
    left = 0x110,
    right = 0x111,
    middle = 0x112,
    _,
};

fn ClusterBuffer(comptime Type: type, comptime buffer_count: usize, comptime buffer_capacity: usize) type {
    return struct {
        buffers: [buffer_count]mini_heap.Cluster(Type),
        len: u32,

        pub inline fn init(self: *@This()) void {
            self.buffers[0] = mini_heap.allocateCluster(Type, buffer_capacity);
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
            self.buffers[next_index] = mini_heap.allocateCluster(Type, buffer_capacity);
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
            self.buffers[next_index] = mini_heap.allocateCluster(Type, buffer_capacity);
            return self.buffers[next_index].reserve();
        }
    };
}

pub fn init() !void {
    try mini_heap.init();
    event_cluster_buffer.init();
    state_cluster_buffer.init();
}

pub fn reset() void {
    mini_heap.reset();
    event_cluster_buffer.init();
    state_cluster_buffer.init();
}

/// Clears all globally stored State entries so that no values are set
pub fn clearState() void {
    var buffer_i: usize = 0;
    while (buffer_i < event_cluster_buffer.len) : (buffer_i += 1) {
        state_cluster_buffer.buffers[buffer_i].setZero();
    }
}

//
// 16 Clusters of capacity 64 elements = Max of 1024
//
var event_cluster_buffer: ClusterBuffer(MouseEventEntry, 16, 64) = undefined;
var state_cluster_buffer: ClusterBuffer(HoverZoneState, 16, 64) = undefined;

pub inline fn reserveState() Index(HoverZoneState) {
    return state_cluster_buffer.reserve();
}

pub const MouseEventOptions = packed struct(u32) {
    enable_hover: bool,
    start_active: bool,
    reserved: u30 = 0,
};

pub fn bindStateToMouseEvent(
    state_index: Index(HoverZoneState),
    extent: geometry.Extent2D(f32),
    options: MouseEventOptions,
) void {
    const extent_index = mini_heap.write(geometry.Extent2D(f32), &extent);
    const event = MouseEventEntry{
        .extent = extent_index.toIndexAligned(),
        .state = state_index,
        .hover_active = options.start_active,
        .hover_enabled = options.enable_hover,
    };
    _ = event_cluster_buffer.write(event);
}

pub fn addMouseEvent(
    extent: geometry.Extent2D(f32),
    enable_hover: bool,
    start_active: bool,
) Index(HoverZoneState) {
    const extent_index = mini_heap.write(geometry.Extent2D(f32), &extent);
    const state_index = state_cluster_buffer.reserve();
    const event = MouseEventEntry{
        .extent = extent_index.toIndexAligned(),
        .state = state_index,
        .hover_active = start_active,
        .hover_enabled = enable_hover,
    };
    _ = event_cluster_buffer.write(event);
    return state_index;
}

pub fn handleMouseMovement(position: *const geometry.Coordinates2D(f64)) void {
    var buffer_i: usize = 0;
    while (buffer_i < event_cluster_buffer.len) : (buffer_i += 1) {
        const cluster = &event_cluster_buffer.buffers[buffer_i];
        var cluster_i: u8 = 0;
        while (cluster_i < cluster.len) : (cluster_i += 1) {
            const entry = cluster.atPtr(cluster_i);
            if (entry.hover_enabled) {
                const extent: geometry.Extent2D(f32) = entry.extent.get();
                const is_within_extent = (position.x >= extent.x and position.x <= (extent.x + extent.width) and
                    position.y <= extent.y and position.y >= (extent.y - extent.height));
                if (is_within_extent and !entry.hover_active) {
                    //
                    // We're entering a new hover zone
                    //
                    entry.hover_active = true;
                    entry.state.getPtr().hover_enter = true;
                } else if (!is_within_extent and entry.hover_active) {
                    //
                    // We're leaving an active hover zone
                    //
                    entry.hover_active = false;
                    entry.state.getPtr().hover_exit = true;
                }
            }
        }
    }
}

pub fn handleMouseClick(position: *const geometry.Coordinates2D(f64), button: MouseButton, button_action: wl.Pointer.ButtonState) void {
    var buffer_i: usize = 0;

    while (buffer_i < event_cluster_buffer.len) : (buffer_i += 1) {
        const cluster = &event_cluster_buffer.buffers[buffer_i];
        var cluster_i: u8 = 0;
        while (cluster_i < cluster.len) : (cluster_i += 1) {
            const entry = cluster.atPtr(cluster_i);
            if (entry.hover_enabled) {
                const extent: geometry.Extent2D(f32) = entry.extent.get();
                const is_within_extent = (position.x >= extent.x and position.x <= (extent.x + extent.width) and
                    position.y <= extent.y and position.y >= (extent.y - extent.height));
                if (is_within_extent) {
                    var state = entry.state.getPtr();

                    if (button_action == .pressed and button == .left) {
                        state.left_click_press = true;
                        state.pending_left_click_release = true;
                    }

                    if (button_action == .pressed and button == .right) {
                        state.right_click_press = true;
                        state.pending_right_click_release = true;
                    }

                    if (button_action == .released) {
                        if (button == .left and state.pending_left_click_release) {
                            state.left_click_release = true;
                            state.pending_left_click_release = false;
                        }
                        if (button == .right and state.pending_right_click_release) {
                            state.right_click_release = true;
                            state.pending_right_click_release = false;
                        }
                    }
                }
            }
        }
    }
}
