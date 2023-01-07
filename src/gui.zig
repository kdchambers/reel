// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");
const event_system = @import("event_system.zig");
const mini_heap = @import("mini_heap.zig");

const QuadFaceWriter = graphics.QuadFaceWriter;
const QuadFace = graphics.QuadFace;
const HoverZoneState = event_system.HoverZoneState;
const Index = mini_heap.Index;

var face_buffer_ref: []graphics.QuadFace = undefined;
var face_writer_ref: *QuadFaceWriter = undefined;
var mouse_position_ref: *geometry.Coordinates2D(f64) = undefined;
var screen_dimensions_ref: *geometry.Dimensions2D(u16) = undefined;
var is_mouse_in_screen_ref: *bool = undefined;

pub fn init(
    face_writer: *QuadFaceWriter,
    face_buffer: []graphics.QuadFace,
    mouse_position: *geometry.Coordinates2D(f64),
    screen_dimensions: *geometry.Dimensions2D(u16),
    is_mouse_in_screen: *bool,
) void {
    face_writer_ref = face_writer;
    face_buffer_ref = face_buffer;
    mouse_position_ref = mouse_position;
    screen_dimensions_ref = screen_dimensions;
    is_mouse_in_screen_ref = is_mouse_in_screen;
}

pub const ImageButton = packed struct(u32) {
    background_face_index: u16,
    state_index: Index(HoverZoneState),

    pub fn create() !ImageButton {
        const state_index = event_system.reserveState();
        return ImageButton{
            .background_face_index = std.math.maxInt(u16),
            .state_index = state_index,
        };
    }

    pub fn draw(
        self: *@This(),
        extent: geometry.Extent2D(f32),
        background_color: graphics.RGBA(f32),
        texture_extent: geometry.Extent2D(f32),
    ) !void {
        self.background_face_index = @intCast(u16, face_writer_ref.used);
        (try face_writer_ref.create()).* = graphics.quadColored(extent, background_color, .bottom_left);
        (try face_writer_ref.create()).* = graphics.quadTextured(extent, texture_extent, .bottom_left);
        event_system.bindStateToMouseEvent(
            self.state_index,
            extent,
            .{
                .enable_hover = true,
                .start_active = false,
            },
        );
    }

    pub inline fn state(self: @This()) *HoverZoneState {
        return self.state_index.getPtr();
    }

    pub fn setBackgroundColor(self: @This(), color: graphics.RGBA(f32)) void {
        const index = face_writer_ref.quad_index + self.background_face_index;
        face_buffer_ref[index][0].color = color;
        face_buffer_ref[index][1].color = color;
        face_buffer_ref[index][2].color = color;
        face_buffer_ref[index][3].color = color;
    }
};

pub const Button = packed struct(u32) {
    face_index: u16,
    state_index: Index(HoverZoneState),

    pub fn create() !Button {
        const state_index = event_system.reserveState();
        return Button{
            .face_index = std.math.maxInt(u16),
            .state_index = state_index,
        };
    }

    pub fn draw(self: *@This(), extent: geometry.Extent2D(f32), color: graphics.RGBA(f32)) !void {
        self.face_index = @intCast(u16, face_writer_ref.used);
        (try face_writer_ref.create()).* = graphics.quadColored(extent, color, .bottom_left);
        event_system.bindStateToMouseEvent(
            self.state_index,
            extent,
            .{
                .enable_hover = true,
                .start_active = false,
            },
        );
    }

    pub inline fn state(self: @This()) *HoverZoneState {
        return self.state_index.getPtr();
    }

    pub fn setColor(self: @This(), color: graphics.RGBA(f32)) void {
        const index = face_writer_ref.quad_index + self.face_index;
        face_buffer_ref[index][0].color = color;
        face_buffer_ref[index][1].color = color;
        face_buffer_ref[index][2].color = color;
        face_buffer_ref[index][3].color = color;
    }
};
