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

pub const Section = packed struct(u64) {
    pub fn draw(
        extent: Extent2D(f32),
        title: []const u8,
        screen_scale: ScaleFactor2D(f64),
        pen: anytype,
        border_color: graphics.RGBA(f32),
        border_width: f32,
    ) !void {

        //
        // TODO: Don't hardcode text_width or margin_left
        //
        const border_quads = try face_writer_ref.allocate(QuadFace, 5);
        const text_width: f32 = @floatCast(f32, 120.0 * screen_scale.horizontal);
        const margin_left: f32 = @floatCast(f32, 15.0 * screen_scale.horizontal);

        //
        // This doesn't need to match the text height, as it will be centered. It just needs to be higher
        //
        const title_extent_height = @floatCast(f32, 40.0 * screen_scale.vertical);

        const title_extent = geometry.Extent2D(f32){
            .x = extent.x + margin_left,
            .y = (extent.y - extent.height) + (title_extent_height / 2.0),
            .width = text_width,
            .height = title_extent_height,
        };
        var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer_ref };
        try pen.writeCentered(title, title_extent, screen_scale, &text_writer_interface);

        const extent_left = geometry.Extent2D(f32){
            .x = extent.x,
            .y = extent.y,
            .width = border_width,
            .height = extent.height,
        };
        const extent_right = geometry.Extent2D(f32){
            .x = extent.x + extent.width - border_width,
            .y = extent.y,
            .width = border_width,
            .height = extent.height,
        };
        const extent_top_left = geometry.Extent2D(f32){
            .x = extent.x + border_width,
            .y = (extent.y - extent.height) + border_width,
            .width = margin_left,
            .height = border_width,
        };
        const extent_top_right = geometry.Extent2D(f32){
            .x = extent.x + border_width + text_width + margin_left,
            .y = (extent.y - extent.height) + border_width,
            .width = extent.width - (border_width * 2 + text_width + margin_left),
            .height = border_width,
        };
        const extent_bottom = geometry.Extent2D(f32){
            .x = extent.x + border_width,
            .y = extent.y,
            .width = extent.width - (border_width * 2),
            .height = border_width,
        };
        border_quads[0] = graphics.quadColored(extent_left, border_color, .bottom_left);
        border_quads[1] = graphics.quadColored(extent_right, border_color, .bottom_left);
        border_quads[2] = graphics.quadColored(extent_top_left, border_color, .bottom_left);
        border_quads[3] = graphics.quadColored(extent_top_right, border_color, .bottom_left);
        border_quads[4] = graphics.quadColored(extent_bottom, border_color, .bottom_left);
    }
};

pub const Dropdown = packed struct(u64) {
    state_index: Index(HoverZoneState),
    extent_index: Index(geometry.Extent2D(f32)),
    opened_extent_index: Index(geometry.Extent2D(f32)),
    reserved: u16 = 0,

    pub fn create() !@This() {
        const state_index = event_system.reserveState();
        state_index.getPtr().reset();
        return @This(){
            .state_index = state_index,
            .extent_index = .{ .index = std.math.maxInt(u16) },
            .opened_extent_index = .{ .index = std.math.maxInt(u16) },
        };
    }

    pub fn draw(
        self: *@This(),
        extent: Extent2D(f32),
        labels: []const []const u8,
        selected_index: u32,
        pen: anytype,
        screen_scale: ScaleFactor2D(f64),
        color: graphics.RGBA(f32),
        is_open: bool,
    ) !void {
        if (!is_open) {
            (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(extent, color, .bottom_left);

            var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer_ref };
            try pen.writeCentered(labels[selected_index], extent, screen_scale, &text_writer_interface);

            const bind_options = event_system.MouseEventOptions{ .enable_hover = true, .start_active = false };
            event_system.bindStateToMouseEvent(self.state_index, extent, &self.extent_index, bind_options);
        }
    }
};

pub const Checkbox = packed struct(u32) {
    state_index: Index(HoverZoneState),
    extent_index: Index(geometry.Extent2D(f32)),

    pub fn create() !@This() {
        const state_index = event_system.reserveState();
        state_index.getPtr().reset();
        return @This(){
            .state_index = state_index,
            .extent_index = .{ .index = std.math.maxInt(u16) },
        };
    }

    pub fn draw(
        self: *@This(),
        center: geometry.Coordinates2D(f64),
        radius_pixels: f64,
        screen_scale: ScaleFactor2D(f64),
        color: graphics.RGBA(f32),
        is_checked: bool,
    ) !void {
        const grey = graphics.RGB(f32).fromInt(120, 120, 120);

        try drawCircle(
            center,
            radius_pixels,
            screen_scale,
            grey.toRGBA(),
        );

        if (is_checked) {
            try drawCircle(
                center,
                radius_pixels / 2,
                screen_scale,
                color,
            );
        }

        //
        // Style #2
        //

        // if(!is_checked) {
        //     try drawCircle(
        //         center,
        //         radius_pixels,
        //         screen_scale,
        //         grey.toRGBA(),
        //     );
        // } else {
        //     try drawCircle(
        //         center,
        //         radius_pixels,
        //         screen_scale,
        //         color,
        //     );
        //     try drawCircle(
        //         center,
        //         radius_pixels / 3,
        //         screen_scale,
        //         grey.toRGBA(),
        //     );
        // }

        const radius_h: f64 = radius_pixels * screen_scale.horizontal;
        const radius_v: f64 = radius_pixels * screen_scale.vertical;

        const extent = geometry.Extent2D(f32){
            .x = @floatCast(f32, center.x - radius_h),
            .y = @floatCast(f32, center.y + radius_v),
            .width = @floatCast(f32, radius_h * 2),
            .height = @floatCast(f32, radius_v * 2),
        };

        event_system.bindStateToMouseEvent(
            self.state_index,
            extent,
            &self.extent_index,
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
};

pub const AudioVolumeLevelHorizontal = struct {
    vertex_index: u32,
    extent: geometry.Extent2D(f32),

    pub fn setDecibelLevel(self: *@This(), decibels: f64) void {
        var overlay_quad = @ptrCast(*graphics.QuadFace, &face_writer_ref.vertices[self.vertex_index]);
        const percentage = decibelToPercent(decibels);
        const overlay_extent = geometry.Extent2D(f32){
            .x = self.extent.x + @floatCast(f32, self.extent.width * percentage),
            .y = self.extent.y,
            .width = self.extent.width * @floatCast(f32, 1.0 - percentage),
            .height = self.extent.height,
        };
        overlay_quad.* = graphics.generateQuad(graphics.GenericVertex, overlay_extent, .bottom_left);
        const color_black = graphics.RGBA(f32){ .r = 0, .g = 0, .b = 0.0, .a = 1.0 };
        overlay_quad[0].color = color_black; // Top left
        overlay_quad[1].color = color_black; // Top right
        overlay_quad[2].color = color_black; // Bottom right
        overlay_quad[3].color = color_black; // Bottom left
        overlay_quad[0].color.a = 0.5;
        overlay_quad[1].color.a = 0.5;
        overlay_quad[2].color.a = 0.5;
        overlay_quad[3].color.a = 0.5;
    }

    inline fn decibelToPercent(decibels: f64) f64 {
        const decibel_range_min = 6.5;
        const decibel_range_max = 3.5;
        const decibel_range_total = decibel_range_max - decibel_range_min;
        return @max(@min((-decibels - decibel_range_min) / decibel_range_total, 1.0), 0.0);
    }

    pub fn init(self: *@This(), extent: geometry.Extent2D(f32)) !void {
        const percentage = 1.0;
        self.extent = extent;
        const color_green = graphics.RGBA(f32){ .r = 0, .g = 1.0, .b = 0.0, .a = 1.0 };
        const color_red = graphics.RGBA(f32){ .r = 1, .g = 0.0, .b = 0.0, .a = 1.0 };
        const color_black = graphics.RGBA(f32){ .r = 0, .g = 0, .b = 0.0, .a = 1.0 };

        var overlay_quad = try face_writer_ref.create(QuadFace);
        overlay_quad.* = graphics.generateQuad(graphics.GenericVertex, self.extent, .bottom_left);
        overlay_quad[0].color = color_red; // Top left
        overlay_quad[1].color = color_green; // Top right
        overlay_quad[2].color = color_green; // Bottom right
        overlay_quad[3].color = color_red; // Bottom left

        self.vertex_index = face_writer_ref.vertices_used;

        var background_quad = try face_writer_ref.create(QuadFace);
        const background_extent = geometry.Extent2D(f32){
            .x = self.extent.x + @floatCast(f32, self.extent.width * percentage),
            .y = self.extent.y,
            .width = self.extent.width * @floatCast(f32, 1.0 - percentage),
            .height = self.extent.height,
        };
        background_quad.* = graphics.generateQuad(graphics.GenericVertex, background_extent, .bottom_left);

        background_quad[0].color = color_black; // Top left
        background_quad[1].color = color_black; // Top right
        background_quad[2].color = color_black; // Bottom right
        background_quad[3].color = color_black; // Bottom left
        background_quad[0].color.a = 0.5;
        background_quad[1].color.a = 0.5;
        background_quad[2].color.a = 0.5;
        background_quad[3].color.a = 0.5;
    }
};

pub const AudioVolumeLevel = struct {
    vertex_index: u32,
    extent: geometry.Extent2D(f32),

    pub fn setDecibelLevel(self: *@This(), decibels: f64) void {
        var overlay_quad = @ptrCast(*graphics.QuadFace, &face_writer_ref.vertices[self.vertex_index]);
        const percentage = decibelToPercent(decibels);
        const overlay_extent = geometry.Extent2D(f32){
            .x = self.extent.x,
            .y = self.extent.y - @floatCast(f32, self.extent.height * percentage),
            .width = self.extent.width,
            .height = self.extent.height * @floatCast(f32, 1.0 - percentage),
        };
        overlay_quad.* = graphics.generateQuad(graphics.GenericVertex, overlay_extent, .bottom_left);
        const color_black = graphics.RGBA(f32){ .r = 0, .g = 0, .b = 0.0, .a = 1.0 };
        overlay_quad[0].color = color_black; // Top left
        overlay_quad[1].color = color_black; // Top right
        overlay_quad[2].color = color_black; // Bottom right
        overlay_quad[3].color = color_black; // Bottom left
        overlay_quad[0].color.a = 0.5;
        overlay_quad[1].color.a = 0.5;
        overlay_quad[2].color.a = 0.5;
        overlay_quad[3].color.a = 0.5;
    }

    inline fn decibelToPercent(decibels: f64) f64 {
        const decibel_range_min = 6.5;
        const decibel_range_max = 3.5;
        const decibel_range_total = decibel_range_max - decibel_range_min;
        return @max(@min((-decibels - decibel_range_min) / decibel_range_total, 1.0), 0.0);
    }

    pub fn init(self: *@This()) !void {
        const percentage = 1.0;
        self.extent = geometry.Extent2D(f32){
            .x = 0.5,
            .y = 0.8,
            .width = 0.010,
            .height = 0.1,
        };
        const color_green = graphics.RGBA(f32){ .r = 0, .g = 1.0, .b = 0.0, .a = 1.0 };
        const color_red = graphics.RGBA(f32){ .r = 1, .g = 0.0, .b = 0.0, .a = 1.0 };
        const color_black = graphics.RGBA(f32){ .r = 0, .g = 0, .b = 0.0, .a = 1.0 };

        var overlay_quad = try face_writer_ref.create(QuadFace);
        overlay_quad.* = graphics.generateQuad(graphics.GenericVertex, self.extent, .bottom_left);
        overlay_quad[0].color = color_green; // Top left
        overlay_quad[1].color = color_green; // Top right
        overlay_quad[2].color = color_red; // Bottom right
        overlay_quad[3].color = color_red; // Bottom left

        self.vertex_index = face_writer_ref.vertices_used;

        var background_quad = try face_writer_ref.create(QuadFace);
        const background_extent = geometry.Extent2D(f32){
            .x = self.extent.x,
            .y = self.extent.y - @floatCast(f32, self.extent.height * percentage),
            .width = self.extent.width,
            .height = self.extent.height * @floatCast(f32, 1.0 - percentage),
        };
        background_quad.* = graphics.generateQuad(graphics.GenericVertex, background_extent, .bottom_left);

        background_quad[0].color = color_black; // Top left
        background_quad[1].color = color_black; // Top right
        background_quad[2].color = color_black; // Bottom right
        background_quad[3].color = color_black; // Bottom left
        background_quad[0].color.a = 0.5;
        background_quad[1].color.a = 0.5;
        background_quad[2].color.a = 0.5;
        background_quad[3].color.a = 0.5;
    }
};

pub const ImageButton = packed struct(u64) {
    background_vertex_index: u16,
    state_index: Index(HoverZoneState),
    extent_index: Index(geometry.Extent2D(f32)),
    reserved: u16 = 0,

    pub fn create() !ImageButton {
        const state_index = event_system.reserveState();
        state_index.getPtr().reset();
        return ImageButton{
            .background_vertex_index = std.math.maxInt(u16),
            .state_index = state_index,
            .extent_index = .{ .index = std.math.maxInt(u16) },
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
            &self.extent_index,
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
    extent_index: Index(geometry.Extent2D(f32)),

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
            .extent_index = .{ .index = std.math.maxInt(u16) },
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
        event_system.bindStateToMouseEvent(self.state_index, extent, &self.extent_index, bind_options);
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

pub fn drawCross(
    extent: Extent2D(f32),
    width_horizontal: f32,
    width_vertical: f32,
    color: RGBA(f32),
) !void {
    const point_topleft = geometry.Coordinates2D(f32){
        .x = extent.x,
        .y = extent.y - extent.height,
    };
    const point_topright = geometry.Coordinates2D(f32){
        .x = extent.x + extent.width,
        .y = extent.y - extent.height,
    };
    const point_bottomleft = geometry.Coordinates2D(f32){
        .x = extent.x,
        .y = extent.y,
    };
    const point_bottomright = geometry.Coordinates2D(f32){
        .x = extent.x + extent.width,
        .y = extent.y,
    };
    const vertices_index: u16 = face_writer_ref.vertices_used;
    const indices_index: u16 = face_writer_ref.indices_used;

    const half_width_v: f32 = width_vertical / 2.0;
    const half_width_h: f32 = width_horizontal / 2.0;

    // Top right upper
    face_writer_ref.vertices[vertices_index + 0] = Vertex{
        .x = point_topright.x - half_width_h,
        .y = point_topright.y,
        .color = color,
    };
    // Top right lower
    face_writer_ref.vertices[vertices_index + 1] = Vertex{
        .x = point_topright.x,
        .y = point_topright.y + half_width_v,
        .color = color,
    };

    // bottom left lower
    face_writer_ref.vertices[vertices_index + 2] = Vertex{
        .x = point_bottomleft.x + half_width_h,
        .y = point_bottomleft.y,
        .color = color,
    };

    // bottom left upper
    face_writer_ref.vertices[vertices_index + 3] = Vertex{
        .x = point_bottomleft.x,
        .y = point_bottomleft.y - half_width_v,
        .color = color,
    };

    face_writer_ref.indices[indices_index + 0] = vertices_index + 0; // TRU
    face_writer_ref.indices[indices_index + 1] = vertices_index + 1; // TRL
    face_writer_ref.indices[indices_index + 2] = vertices_index + 2; // BLL

    face_writer_ref.indices[indices_index + 3] = vertices_index + 2; // BBL
    face_writer_ref.indices[indices_index + 4] = vertices_index + 3; // BLU
    face_writer_ref.indices[indices_index + 5] = vertices_index + 0; // TRU

    // Top left lower
    face_writer_ref.vertices[vertices_index + 4] = Vertex{
        .x = point_topleft.x,
        .y = point_topleft.y + half_width_v,
        .color = color,
    };
    // Top left upper
    face_writer_ref.vertices[vertices_index + 5] = Vertex{
        .x = point_topleft.x + half_width_h,
        .y = point_topleft.y,
        .color = color,
    };
    // Bottom right upper
    face_writer_ref.vertices[vertices_index + 6] = Vertex{
        .x = point_bottomright.x,
        .y = point_bottomright.y - half_width_v,
        .color = color,
    };
    // Bottom right lower
    face_writer_ref.vertices[vertices_index + 7] = Vertex{
        .x = point_bottomright.x - half_width_h,
        .y = point_bottomright.y,
        .color = color,
    };

    face_writer_ref.indices[indices_index + 6] = vertices_index + 4; // TLL
    face_writer_ref.indices[indices_index + 7] = vertices_index + 5; // TLU
    face_writer_ref.indices[indices_index + 8] = vertices_index + 6; // BRU

    face_writer_ref.indices[indices_index + 9] = vertices_index + 6; // BRU
    face_writer_ref.indices[indices_index + 10] = vertices_index + 7; // BRL
    face_writer_ref.indices[indices_index + 11] = vertices_index + 4; // TLL

    face_writer_ref.vertices_used += 8;
    face_writer_ref.indices_used += 12;
}

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

pub fn drawCircle(
    center: geometry.Coordinates2D(f64),
    radius_pixels: f64,
    screen_scale: ScaleFactor2D(f64),
    color: graphics.RGBA(f32),
) !void {
    const point_count = @max(20, @floatToInt(u16, @divFloor(radius_pixels, 2)));

    const radius_h: f64 = radius_pixels * screen_scale.horizontal;
    const radius_v: f64 = radius_pixels * screen_scale.vertical;

    const degreesToRadians = std.math.degreesToRadians;

    const rotation_per_point = degreesToRadians(f64, 360 / @intToFloat(f64, point_count));

    const vertices_index: u16 = face_writer_ref.vertices_used;
    var indices_index: u16 = face_writer_ref.indices_used;

    face_writer_ref.vertices[vertices_index] = Vertex{
        .x = @floatCast(f32, center.x),
        .y = @floatCast(f32, center.y),
        .color = color,
    };

    //
    // Draw first on-curve point
    //
    face_writer_ref.vertices[vertices_index + 1] = Vertex{
        .x = @floatCast(f32, center.x + (radius_h * @cos(0.0))),
        .y = @floatCast(f32, center.y + (radius_v * @sin(0.0))),
        .color = color,
    };

    var i: u16 = 1;
    while (i <= point_count) : (i += 1) {
        const angle_radians: f64 = rotation_per_point * @intToFloat(f64, i);
        face_writer_ref.vertices[vertices_index + i + 1] = Vertex{
            .x = @floatCast(f32, center.x + (radius_h * @cos(angle_radians))),
            .y = @floatCast(f32, center.y + (radius_v * @sin(angle_radians))),
            .color = color,
        };
        face_writer_ref.indices[indices_index + 0] = vertices_index; // Center
        face_writer_ref.indices[indices_index + 1] = vertices_index + i + 0; // Previous
        face_writer_ref.indices[indices_index + 2] = vertices_index + i + 1; // Current
        indices_index += 3;
    }

    face_writer_ref.vertices_used += point_count + 2;
    face_writer_ref.indices_used += point_count * 3;
}
