// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const geometry = @import("geometry.zig");
const Extent2D = geometry.Extent2D;
const ScaleFactor2D = geometry.ScaleFactor2D;

const event_system = @import("event_system.zig");
const HoverZoneState = event_system.HoverZoneState;

const mini_heap = @import("mini_heap.zig");
const Index = mini_heap.Index;

const graphics = @import("graphics.zig");
const Vertex = graphics.GenericVertex;
const FaceWriter = graphics.FaceWriter;
const QuadFace = graphics.QuadFace;
const RGBA = graphics.RGBA;

const fontana = @import("fontana");
const Pen = fontana.Font(.freetype_harfbuzz).Pen;

const TextWriterInterface = struct {
    quad_writer: *FaceWriter,
    pub fn write(
        self: *@This(),
        fontana_screen_extent: fontana.geometry.Extent2D(f32),
        fontana_texture_extent: fontana.geometry.Extent2D(f32),
    ) !void {
        const screen_extent = Extent2D(f32){
            .x = fontana_screen_extent.x,
            .y = fontana_screen_extent.y,
            .width = fontana_screen_extent.width,
            .height = fontana_screen_extent.height,
        };
        const texture_extent = Extent2D(f32){
            .x = fontana_texture_extent.x,
            .y = fontana_texture_extent.y,
            .width = fontana_texture_extent.width,
            .height = fontana_texture_extent.height,
        };
        (try self.quad_writer.create(QuadFace)).* = graphics.quadTextured(
            screen_extent,
            texture_extent,
            .bottom_left,
        );
    }
};

var vertices_buffer_ref: []Vertex = undefined;
var face_writer_ref: *FaceWriter = undefined;
var mouse_position_ref: *geometry.Coordinates2D(f64) = undefined;
var screen_dimensions_ref: *geometry.Dimensions2D(u16) = undefined;
var is_mouse_in_screen_ref: *bool = undefined;

pub fn init(
    face_writer: *FaceWriter,
    vertices_buffer: []Vertex,
    mouse_position: *geometry.Coordinates2D(f64),
    screen_dimensions: *geometry.Dimensions2D(u16),
    is_mouse_in_screen: *bool,
) void {
    face_writer_ref = face_writer;
    vertices_buffer_ref = vertices_buffer;
    mouse_position_ref = mouse_position;
    screen_dimensions_ref = screen_dimensions;
    is_mouse_in_screen_ref = is_mouse_in_screen;
}

pub const ImageButton = packed struct(u32) {
    background_vertex_index: u16,
    state_index: Index(HoverZoneState),

    pub fn create() !ImageButton {
        const state_index = event_system.reserveState();
        return ImageButton{
            .background_vertex_index = std.math.maxInt(u16),
            .state_index = state_index,
        };
    }

    pub fn draw(
        self: *@This(),
        extent: Extent2D(f32),
        background_color: graphics.RGBA(f32),
        texture_extent: Extent2D(f32),
    ) !void {
        self.background_vertex_index = @intCast(u16, face_writer_ref.vertices_used);
        (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(extent, background_color, .bottom_left);
        (try face_writer_ref.create(QuadFace)).* = graphics.quadTextured(extent, texture_extent, .bottom_left);
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
        vertices_buffer_ref[self.background_vertex_index + 0].color = color;
        vertices_buffer_ref[self.background_vertex_index + 1].color = color;
        vertices_buffer_ref[self.background_vertex_index + 2].color = color;
        vertices_buffer_ref[self.background_vertex_index + 3].color = color;
    }
};

pub const Button = packed struct(u32) {
    vertex_index: u16,
    state_index: Index(HoverZoneState),

    pub fn create() !Button {
        const state_index = event_system.reserveState();
        return Button{
            .vertex_index = std.math.maxInt(u16),
            .state_index = state_index,
        };
    }

    pub fn draw(
        self: *@This(),
        extent: Extent2D(f32),
        color: graphics.RGBA(f32),
        label: []const u8,
        pen: *Pen,
        screen_scale: ScaleFactor2D(f64),
    ) !void {
        self.vertex_index = @intCast(u16, face_writer_ref.vertices_used);
        (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(extent, color, .bottom_left);
        var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer_ref };
        try pen.write(
            label,
            .{ .x = extent.x, .y = extent.y },
            .{ .horizontal = screen_scale.horizontal, .vertical = screen_scale.vertical },
            &text_writer_interface,
        );
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
        vertices_buffer_ref[self.vertex_index + 0].color = color;
        vertices_buffer_ref[self.vertex_index + 1].color = color;
        vertices_buffer_ref[self.vertex_index + 2].color = color;
        vertices_buffer_ref[self.vertex_index + 3].color = color;
    }
};

pub fn drawRoundRect(
    extent: Extent2D(f32),
    color: RGBA(f32),
    screen_scale: ScaleFactor2D(f64),
    radius: f32,
) !void {
    const radius_v = @floatCast(f32, radius * screen_scale.vertical);
    const radius_h = @floatCast(f32, radius * screen_scale.horizontal);

    const middle_extent = Extent2D(f32){
        .x = extent.x,
        .y = extent.y - radius_v,
        .width = extent.width,
        .height = extent.height - (radius_v * 2.0),
    };
    const top_extent = Extent2D(f32){
        .x = extent.x + radius_h,
        .y = extent.y - extent.height + radius_v,
        .width = extent.width - (radius_h * 2.0),
        .height = radius_v,
    };
    const bottom_extent = Extent2D(f32){
        .x = extent.x + radius_h,
        .y = extent.y,
        .width = extent.width - (radius_h * 2.0),
        .height = radius_v,
    };

    (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(middle_extent, color, .bottom_left);
    (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(top_extent, color, .bottom_left);
    (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(bottom_extent, color, .bottom_left);

    // x = cx + r * cos(a)
    // y = cy + r * sin(a)
}
