// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

// TODO: Remove wayland ref
const wayland = @import("wayland");
const wl = wayland.client.wl;

const mini_heap = @import("../../utils/mini_heap.zig");
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

pub const MouseEventOptions = packed struct(u32) {
    enable_hover: bool = true,
    start_active: bool = false,
    invert: bool = false,
    reserved: u29 = 0,
};

pub const MouseEventEntry = extern struct {
    const Flags = packed struct(u8) {
        hover_enabled: bool = false,
        click_left_enabled: bool = false,
        click_right_enabled: bool = false,
        hover_active: bool = false,
        invert: bool = false,
        reserved: u3 = 0,
    };

    extent: Extent2D(f32),
    z_layer: u8,
    reserved: u8 = 0,
    state: HoverZoneState,
    flags: Flags,
};

comptime {
    assert(@sizeOf(Extent2D(f32)) == 16);
    assert(@alignOf(Extent2D(f32)) == 4);
    assert(@sizeOf(MouseEventEntry) == 20);
    assert(@alignOf(MouseEventEntry) == 4);
}

const MouseMovementUpdate = packed struct(u16) {
    hover_enter: bool = false,
    hover_exit: bool = false,
    reserved: u14 = 0,
};

const max_mouse_event_slot_count = 128;

pub var mouse_click_coordinates: ?geometry.Coordinates2D(f64) = null;

var event_slot_buffer: SliceIndex(MouseEventEntry) = .{ .index = std.math.maxInt(u16), .count = 0 };
var mouse_event_slot_count: u16 = 0;

pub fn init() !void {
    try mini_heap.init();
    const init_mouse_entry = MouseEventEntry{
        .extent = .{ .x = -2.0, .y = -2.0, .width = 0.0, .height = 0.0 },
        .z_layer = 255,
        .state = .{},
        .flags = .{},
    };
    event_slot_buffer = mini_heap.writeN(MouseEventEntry, &init_mouse_entry, max_mouse_event_slot_count);
}

pub fn reserveMouseEventSlot() Index(MouseEventEntry) {
    assert(mouse_event_slot_count < max_mouse_event_slot_count);
    const current_index: u16 = mouse_event_slot_count;
    mouse_event_slot_count += 1;
    return event_slot_buffer.toIndex(current_index);
}

pub fn reserveMouseEventSlots(count: u16) SliceIndex(MouseEventEntry) {
    const current_index: u16 = mouse_event_slot_count;
    mouse_event_slot_count += count;
    assert(mouse_event_slot_count < max_mouse_event_slot_count);
    return event_slot_buffer.makeSlice(current_index, count);
}

pub inline fn invalidateEvents() void {
    mouse_event_slot_count = 0;
}

pub fn writeMouseEventSlot(
    extent: geometry.Extent3D(f32),
    options: MouseEventOptions,
) Index(MouseEventEntry) {
    //
    // Doesn't make sense to do hover testing on an inverted region as it will cover most
    // of the screen and cause z collision issues
    //
    assert(!(options.invert and options.enable_hover));
    event_slot_buffer.get()[mouse_event_slot_count] = .{
        .extent = extent.to2D(),
        .z_layer = @intFromFloat(@floor(extent.z * 100.0)),
        .state = .{},
        .flags = .{
            .hover_enabled = options.enable_hover,
            .hover_active = options.start_active,
            .invert = options.invert,
        },
    };
    const written_index = mouse_event_slot_count;
    mouse_event_slot_count += 1;
    return event_slot_buffer.toIndex(written_index);
}

pub inline fn overwriteMouseEventSlot(
    slot: *MouseEventEntry,
    extent: geometry.Extent3D(f32),
    options: MouseEventOptions,
) void {
    //
    // Doesn't make sense to do hover testing on an inverted region as it will cover most
    // of the screen and cause z collision issues
    //
    assert(!(options.invert and options.enable_hover));
    slot.* = .{
        .extent = extent.to2D(),
        .z_layer = @intFromFloat(@floor(extent.z * 100.0)),
        .state = .{},
        .flags = .{
            .hover_enabled = options.enable_hover,
            .hover_active = options.start_active,
            .invert = options.invert,
        },
    };
}

pub fn handleMouseClick(position: *const geometry.Coordinates2D(f64), button: MouseButton, button_action: wl.Pointer.ButtonState) void {
    var min_z_layer: u8 = 255;
    var matched_entry: *MouseEventEntry = undefined;
    for (event_slot_buffer.get()[0..mouse_event_slot_count]) |*entry| {
        if (entry.z_layer <= min_z_layer) {
            const is_within_extent = (position.x >= entry.extent.x and position.x <= (entry.extent.x + entry.extent.width) and
                position.y <= entry.extent.y and position.y >= (entry.extent.y - entry.extent.height));
            //
            // The `invert` flags means we're using this to check if a mouse click DIDN'T happen inside a region.
            // It also ignores the depth value so we continue instead of potentially causing a match. If we were to
            // match we could run into collisions where more than one region with the same depth value are matched
            //
            if (entry.flags.invert) {
                assert(!entry.flags.hover_enabled);
                if (!is_within_extent and button_action == .pressed and button == .left)
                    entry.state.left_click_press = true;
                continue;
            }
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

pub fn handleMouseMovement(position: *const geometry.Coordinates2D(f64)) MouseMovementUpdate {
    var min_enter_z_layer: u8 = 255;
    var min_exit_z_layer: u8 = 255;

    var matched_hover_enter: ?*MouseEventEntry = null;
    var matched_hover_exit: ?*MouseEventEntry = null;

    var response: MouseMovementUpdate = .{};
    for (event_slot_buffer.get()[0..mouse_event_slot_count]) |*entry| {
        if (entry.flags.hover_enabled) {
            const extent = entry.extent;
            const is_within_extent = (position.x >= extent.x and position.x <= (extent.x + extent.width) and
                position.y <= extent.y and position.y >= (extent.y - extent.height));
            if (is_within_extent and !entry.flags.hover_active and entry.z_layer <= min_exit_z_layer) {
                assert(entry.z_layer < 255);
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
