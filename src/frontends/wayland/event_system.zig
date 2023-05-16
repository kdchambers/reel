// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

// TODO: Remove wayland ref
const wayland = @import("wayland");
const wl = wayland.client.wl;

const mini_heap = @import("mini_heap.zig");
const geometry = @import("../../geometry.zig");
const Extent2D = geometry.Extent2D;

const Index = mini_heap.Index;
const SliceIndex = mini_heap.SliceIndex;
const IndexAligned = mini_heap.IndexAligned;

pub const HoverZoneState = packed struct(u8) {
    hover_enter: bool = false,
    hover_exit: bool = false,
    left_click_press: bool = false,
    left_click_release: bool = false,
    right_click_press: bool = false,
    right_click_release: bool = false,
    pending_right_click_release: bool = false,
    pending_left_click_release: bool = false,

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

pub var mouse_click_coordinates: ?geometry.Coordinates2D(f64) = null;

const max_mouse_event_slot_count = 128;
var event_slot_buffer: SliceIndex(MouseEventEntry) = .{ .index = std.math.maxInt(u16), .count = 0 };
var event_count: u16 = 0;

pub fn init() !void {
    try mini_heap.init();
    event_slot_buffer = mini_heap.reserve(MouseEventEntry, max_mouse_event_slot_count, .{});
}

pub const MouseEventOptions = packed struct(u32) {
    enable_hover: bool = true,
    start_active: bool = false,
    reserved: u30 = 0,
};

pub const MouseEventEntry = extern struct {
    const Flags = packed struct(u8) {
        hover_enabled: bool = false,
        click_left_enabled: bool = false,
        click_right_enabled: bool = false,
        hover_active: bool = false,
        reserved: u4 = 0,
    };

    extent: Extent2D(f32),
    z_layer: u8,
    draw_index: u8,
    state: HoverZoneState,
    flags: Flags,
};

comptime {
    assert(@sizeOf(Extent2D(f32)) == 16);
    assert(@alignOf(Extent2D(f32)) == 4);
    assert(@sizeOf(MouseEventEntry) == 20);
    assert(@alignOf(MouseEventEntry) == 4);
}

pub fn reserveMouseEventSlot() Index(MouseEventEntry) {
    assert(event_count < max_mouse_event_slot_count);
    const current_index: u16 = event_count;
    event_count += 1;
    return event_slot_buffer.toIndex(current_index);
}

pub fn reserveMouseEventSlots(count: u16) SliceIndex(MouseEventEntry) {
    const current_index: u16 = event_count;
    event_count += count;
    assert(event_count < max_mouse_event_slot_count);
    return event_slot_buffer.makeSlice(current_index, count);
}

var current_draw_index: u8 = 0;

pub inline fn invalidateEvents() void {
    current_draw_index += 1;
    if (current_draw_index == 254) {
        // TODO: Implement
        assert(false);
        current_draw_index = 1;
        //
        //  Set draw_index of all entries to 0
        //
    }
}

pub fn writeMouseEventSlot(
    mouse_event_slot_index: Index(MouseEventEntry),
    extent: geometry.Extent3D(f32),
    options: MouseEventOptions,
) void {
    mouse_event_slot_index.getPtr().* = .{
        .extent = extent.to2D(),
        .z_layer = @floatToInt(u8, @floor(extent.z * 100.0)),
        .draw_index = current_draw_index,
        .state = .{},
        .flags = .{
            .hover_enabled = options.enable_hover,
            .hover_active = options.start_active,
        },
    };
}

pub fn handleMouseClick(position: *const geometry.Coordinates2D(f64), button: MouseButton, button_action: wl.Pointer.ButtonState) void {
    var min_z_layer: u8 = 255;
    var matched_entry: *MouseEventEntry = undefined;
    for (event_slot_buffer.get()[0..event_count]) |*entry| {
        if (entry.draw_index == current_draw_index and entry.z_layer <= min_z_layer) {
            const is_within_extent = (position.x >= entry.extent.x and position.x <= (entry.extent.x + entry.extent.width) and
                position.y <= entry.extent.y and position.y >= (entry.extent.y - entry.extent.height));
            if (!is_within_extent)
                continue;
            min_z_layer = entry.z_layer;
            matched_entry = entry;
        }
    }

    if (min_z_layer == 255)
        return;

    if (button_action == .pressed and button == .left) {
        matched_entry.state.left_click_press = true;
        matched_entry.state.pending_left_click_release = true;
    }

    if (button_action == .pressed and button == .right) {
        matched_entry.state.right_click_press = true;
        matched_entry.state.pending_right_click_release = true;
    }

    if (button_action == .released) {
        if (button == .left and matched_entry.state.pending_left_click_release) {
            matched_entry.state.left_click_release = true;
            matched_entry.state.pending_left_click_release = false;
        }
        if (button == .right and matched_entry.state.pending_right_click_release) {
            matched_entry.state.right_click_release = true;
            matched_entry.state.pending_right_click_release = false;
        }
    }
}

const MouseMovementUpdate = packed struct(u16) {
    hover_enter: bool = false,
    hover_exit: bool = false,
    reserved: u14 = 0,
};

pub fn handleMouseMovement(position: *const geometry.Coordinates2D(f64)) MouseMovementUpdate {
    var min_enter_z_layer: u8 = 255;
    var min_exit_z_layer: u8 = 255;

    var matched_hover_enter: ?*MouseEventEntry = null;
    var matched_hover_exit: ?*MouseEventEntry = null;

    var response: MouseMovementUpdate = .{};
    for (event_slot_buffer.get()[0..event_count]) |*entry| {
        if (entry.draw_index == current_draw_index and entry.flags.hover_enabled) {
            const extent = entry.extent;
            const is_within_extent = (position.x >= extent.x and position.x <= (extent.x + extent.width) and
                position.y <= extent.y and position.y >= (extent.y - extent.height));
            if (is_within_extent and !entry.flags.hover_active and entry.z_layer <= min_exit_z_layer) {
                assert(entry.z_layer != min_enter_z_layer);
                //
                // We're entering a new hover zone
                //
                entry.flags.hover_active = true;
                min_enter_z_layer = entry.z_layer;
                matched_hover_enter = entry;
            } else if (!is_within_extent and entry.flags.hover_active) {
                assert(entry.z_layer != min_exit_z_layer);
                //
                // We're leaving an active hover zone
                //
                entry.flags.hover_active = false;
                min_exit_z_layer = entry.z_layer;
                matched_hover_exit = entry;
            }
        }
    }

    if (matched_hover_exit) |match| {
        match.state.hover_exit = true;
        response.hover_exit = true;
    }

    if (matched_hover_enter) |match| {
        match.state.hover_enter = true;
        response.hover_exit = false;
        response.hover_enter = true;
    }

    return response;
}
