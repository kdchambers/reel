// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const geometry = @import("geometry.zig");
const Extent2D = geometry.Extent2D;
const ScaleFactor2D = geometry.ScaleFactor2D;
const Coordinates2D = geometry.Coordinates2D;

const event_system = @import("event_system.zig");
const HoverZoneState = event_system.HoverZoneState;

const mini_heap = @import("mini_heap.zig");
const Index = mini_heap.Index;

const graphics = @import("graphics.zig");
const Vertex = graphics.GenericVertex;
const FaceWriter = graphics.FaceWriter;
const QuadFace = graphics.QuadFace;
const RGBA = graphics.RGBA;

const TextWriterInterface = struct {
    quad_writer: *FaceWriter,
    pub fn write(
        self: *@This(),
        screen_extent: geometry.Extent2D(f32),
        texture_extent: geometry.Extent2D(f32),
    ) !void {
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
        state_index.getPtr().reset();
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

    pub inline fn state(self: @This()) HoverZoneState {
        const state_copy = self.state_index.get();
        self.state_index.getPtr().clear();
        return state_copy;
    }

    pub inline fn statePtr(self: @This()) *HoverZoneState {
        return self.state_index.getPtr();
    }

    pub fn setBackgroundColor(self: @This(), color: graphics.RGBA(f32)) void {
        vertices_buffer_ref[self.background_vertex_index + 0].color = color;
        vertices_buffer_ref[self.background_vertex_index + 1].color = color;
        vertices_buffer_ref[self.background_vertex_index + 2].color = color;
        vertices_buffer_ref[self.background_vertex_index + 3].color = color;
    }
};

pub const Button = packed struct(u64) {
    vertex_index: u16,
    vertex_count: u16,
    state_index: Index(HoverZoneState),
    reserved: u16 = 0,

    pub const DrawOptions = struct {
        rounding_radius: ?f64,
    };

    pub fn create() !Button {
        const state_index = event_system.reserveState();
        state_index.getPtr().reset();
        return Button{
            .vertex_index = std.math.maxInt(u16),
            .state_index = state_index,
            .vertex_count = undefined,
        };
    }

    pub fn draw(
        self: *@This(),
        extent: Extent2D(f32),
        color: graphics.RGBA(f32),
        label: []const u8,
        pen: anytype,
        screen_scale: ScaleFactor2D(f64),
        comptime options: DrawOptions,
    ) !void {
        self.vertex_index = @intCast(u16, face_writer_ref.vertices_used);
        if (options.rounding_radius) |rounding_radius| {
            try drawRoundRect(extent, color, screen_scale, rounding_radius);
            self.vertex_count = @intCast(u16, face_writer_ref.vertices_used - self.vertex_index);
        } else {
            self.vertex_count = 4;
            (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(extent, color, .bottom_left);
        }

        var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer_ref };
        try pen.writeCentered(label, extent, screen_scale, &text_writer_interface);

        const bind_options = event_system.MouseEventOptions{ .enable_hover = true, .start_active = false };
        event_system.bindStateToMouseEvent(self.state_index, extent, bind_options);
    }

    pub inline fn state(self: @This()) HoverZoneState {
        const state_copy = self.state_index.get();
        self.state_index.getPtr().clear();
        return state_copy;
    }

    pub inline fn statePtr(self: @This()) *HoverZoneState {
        return self.state_index.getPtr();
    }

    pub fn setColor(self: @This(), color: graphics.RGBA(f32)) void {
        var i = self.vertex_index;
        const end_index = self.vertex_index + self.vertex_count;
        while (i < end_index) : (i += 1) {
            vertices_buffer_ref[i].color = color;
        }
    }
};

pub fn drawRoundRect(
    extent: Extent2D(f32),
    color: RGBA(f32),
    screen_scale: ScaleFactor2D(f64),
    radius: f64,
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

    const points_per_curve = @floatToInt(u16, @floor(radius));
    const rotation_per_point = std.math.degreesToRadians(f64, 90 / @intToFloat(f64, points_per_curve - 1));

    {
        //
        // Top Left
        //
        const vertices_index: u16 = face_writer_ref.vertices_used;
        const start_indices_index: u16 = face_writer_ref.indices_used;
        const corner_x = extent.x + radius_h;
        const corner_y = extent.y - (extent.height - radius_v);
        //
        // Draw corner point
        //
        face_writer_ref.vertices[vertices_index] = Vertex{
            .x = corner_x,
            .y = corner_y,
            .color = color,
        };
        //
        // Draw first on-curve point
        //
        var angle_radians = std.math.degreesToRadians(f64, 0);
        face_writer_ref.vertices[vertices_index + 1] = Vertex{
            .x = @floatCast(f32, corner_x - (radius_h * @cos(angle_radians))),
            .y = @floatCast(f32, corner_y - (radius_v * @sin(angle_radians))),
            .color = color,
        };
        var i: u16 = 1;
        while (i < points_per_curve) : (i += 1) {
            angle_radians += rotation_per_point;
            face_writer_ref.vertices[vertices_index + i + 1] = Vertex{
                .x = @floatCast(f32, corner_x - (radius_h * @cos(angle_radians))),
                .y = @floatCast(f32, corner_y - (radius_v * @sin(angle_radians))),
                .color = color,
            };
            const indices_index = start_indices_index + ((i - 1) * 3);
            face_writer_ref.indices[indices_index + 0] = vertices_index; // Corner
            face_writer_ref.indices[indices_index + 1] = vertices_index + i + 0; // Previous
            face_writer_ref.indices[indices_index + 2] = vertices_index + i + 1; // Current
        }
        face_writer_ref.vertices_used += points_per_curve + 2;
        face_writer_ref.indices_used += (points_per_curve - 1) * 3;
    }

    {
        //
        // Top Right
        //
        const vertices_index: u16 = face_writer_ref.vertices_used;
        const start_indices_index: u16 = face_writer_ref.indices_used;
        const corner_x = extent.x + extent.width - radius_h;
        const corner_y = extent.y - (extent.height - radius_v);
        //
        // Draw corner point
        //
        face_writer_ref.vertices[vertices_index] = Vertex{
            .x = corner_x,
            .y = corner_y,
            .color = color,
        };
        //
        // Draw first on-curve point
        //
        var start_angle_radians = std.math.degreesToRadians(f64, 180);

        face_writer_ref.vertices[vertices_index + 1] = Vertex{
            .x = @floatCast(f32, corner_x - (radius_h * @cos(start_angle_radians))),
            .y = @floatCast(f32, corner_y - (radius_v * @sin(start_angle_radians))),
            .color = color,
        };
        var i: u16 = 1;
        while (i < points_per_curve) : (i += 1) {
            const angle_radians: f64 = start_angle_radians - (rotation_per_point * @intToFloat(f64, i));
            face_writer_ref.vertices[vertices_index + i + 1] = Vertex{
                .x = @floatCast(f32, corner_x - (radius_h * @cos(angle_radians))),
                .y = @floatCast(f32, corner_y - (radius_v * @sin(angle_radians))),
                .color = color,
            };
            const indices_index = start_indices_index + ((i - 1) * 3);
            face_writer_ref.indices[indices_index + 0] = vertices_index + i + 1; // Current
            face_writer_ref.indices[indices_index + 1] = vertices_index + i + 0; // Previous
            face_writer_ref.indices[indices_index + 2] = vertices_index; // Corner
        }
        face_writer_ref.vertices_used += points_per_curve + 2;
        face_writer_ref.indices_used += (points_per_curve - 1) * 3;
    }

    {
        //
        // Bottom Left
        //
        const vertices_index: u16 = face_writer_ref.vertices_used;
        const start_indices_index: u16 = face_writer_ref.indices_used;
        const corner_x = extent.x + radius_h;
        const corner_y = extent.y - radius_v;
        //
        // Draw corner point
        //
        face_writer_ref.vertices[vertices_index] = Vertex{
            .x = corner_x,
            .y = corner_y,
            .color = color,
        };
        //
        // Draw first on-curve point
        //
        var start_angle_radians = std.math.degreesToRadians(f64, 270);

        face_writer_ref.vertices[vertices_index + 1] = Vertex{
            .x = @floatCast(f32, corner_x - (radius_h * @cos(start_angle_radians))),
            .y = @floatCast(f32, corner_y - (radius_v * @sin(start_angle_radians))),
            .color = color,
        };
        var i: u16 = 1;
        while (i < points_per_curve) : (i += 1) {
            const angle_radians: f64 = start_angle_radians + (rotation_per_point * @intToFloat(f64, i));
            face_writer_ref.vertices[vertices_index + i + 1] = Vertex{
                .x = @floatCast(f32, corner_x - (radius_h * @cos(angle_radians))),
                .y = @floatCast(f32, corner_y - (radius_v * @sin(angle_radians))),
                .color = color,
            };
            const indices_index = start_indices_index + ((i - 1) * 3);
            face_writer_ref.indices[indices_index + 0] = vertices_index + i + 1; // Current
            face_writer_ref.indices[indices_index + 1] = vertices_index + i + 0; // Previous
            face_writer_ref.indices[indices_index + 2] = vertices_index; // Corner
        }
        face_writer_ref.vertices_used += points_per_curve + 2;
        face_writer_ref.indices_used += (points_per_curve - 1) * 3;
    }

    {
        //
        // Bottom Right
        //
        const vertices_index: u16 = face_writer_ref.vertices_used;
        const start_indices_index: u16 = face_writer_ref.indices_used;
        const corner_x = extent.x + extent.width - radius_h;
        const corner_y = extent.y - radius_v;
        //
        // Draw corner point
        //
        face_writer_ref.vertices[vertices_index] = Vertex{
            .x = corner_x,
            .y = corner_y,
            .color = color,
        };
        //
        // Draw first on-curve point
        //
        var start_angle_radians = std.math.degreesToRadians(f64, 180);

        face_writer_ref.vertices[vertices_index + 1] = Vertex{
            .x = @floatCast(f32, corner_x - (radius_h * @cos(start_angle_radians))),
            .y = @floatCast(f32, corner_y - (radius_v * @sin(start_angle_radians))),
            .color = color,
        };
        var i: u16 = 1;
        while (i < points_per_curve) : (i += 1) {
            const angle_radians: f64 = start_angle_radians + (rotation_per_point * @intToFloat(f64, i));
            face_writer_ref.vertices[vertices_index + i + 1] = Vertex{
                .x = @floatCast(f32, corner_x - (radius_h * @cos(angle_radians))),
                .y = @floatCast(f32, corner_y - (radius_v * @sin(angle_radians))),
                .color = color,
            };
            const indices_index = start_indices_index + ((i - 1) * 3);
            face_writer_ref.indices[indices_index + 0] = vertices_index + i + 1; // Current
            face_writer_ref.indices[indices_index + 1] = vertices_index + i + 0; // Previous
            face_writer_ref.indices[indices_index + 2] = vertices_index; // Corner
        }
        face_writer_ref.vertices_used += points_per_curve + 2;
        face_writer_ref.indices_used += (points_per_curve - 1) * 3;
    }
}
