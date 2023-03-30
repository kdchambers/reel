// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const geometry = @import("../../../geometry.zig");
const Extent2D = geometry.Extent2D;
const ScaleFactor2D = geometry.ScaleFactor2D;
const Coordinates2D = geometry.Coordinates2D;

const event_system = @import("../event_system.zig");
const HoverZoneState = event_system.HoverZoneState;

const mini_heap = @import("../mini_heap.zig");
const Index = mini_heap.Index;

const graphics = @import("../../../graphics.zig");
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

pub var vertices_buffer_ref: []Vertex = undefined;
pub var face_writer_ref: *FaceWriter = undefined;
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
        screen_scale: ScaleFactor2D(f32),
        pen: anytype,
        border_color: graphics.RGBA(f32),
        border_width: f32,
    ) !void {
        const rendered_text_dimensions = pen.calculateRenderDimensions(title);
        const border_quads = try face_writer_ref.allocate(QuadFace, 5);
        const text_margin_horizontal: f32 = 20;
        const text_width: f32 = @floatCast(f32, (text_margin_horizontal + rendered_text_dimensions.width) * screen_scale.horizontal);
        const margin_left: f32 = @floatCast(f32, 15.0 * screen_scale.horizontal);

        //
        // This doesn't need to match the text height, as it will be centered. It just needs to be higher
        //
        const title_extent_height = @floatCast(f32, (rendered_text_dimensions.height + 20) * screen_scale.vertical);

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

pub const Dropdown = struct {
    is_open: bool,
    item_count: u8,
    state_index: Index(HoverZoneState),
    extent_index: Index(geometry.Extent2D(f32)),

    item_states: [8]Index(HoverZoneState),
    item_extents: [8]Index(geometry.Extent2D(f32)),

    pub fn create(item_count: u8) !@This() {
        std.debug.assert(item_count <= 8);
        const state_index = event_system.reserveState();
        state_index.getPtr().reset();
        var result = @This(){
            .is_open = false,
            .item_count = item_count,
            .state_index = state_index,
            .extent_index = .{ .index = std.math.maxInt(u16) },
            .item_states = undefined,
            .item_extents = undefined,
        };
        var i: usize = 0;
        while (i < item_count) : (i += 1) {
            result.item_states[i] = event_system.reserveState();
            result.item_states[i].getPtr().reset();
            result.item_extents[i] = .{ .index = std.math.maxInt(u16) };
        }
        return result;
    }

    pub fn draw(
        self: *@This(),
        extent: Extent2D(f32),
        labels: []const []const u8,
        selected_index: u32,
        pen: anytype,
        screen_scale: ScaleFactor2D(f32),
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
        screen_scale: ScaleFactor2D(f32),
        color: graphics.RGBA(f32),
        is_checked: bool,
    ) !void {
        const grey = graphics.RGB(f32).fromInt(120, 120, 120);

        try graphics.drawCircle(
            center,
            radius_pixels,
            grey.toRGBA(),
            screen_scale,
            face_writer_ref,
        );

        if (is_checked) {
            try graphics.drawCircle(
                center,
                radius_pixels / 2,
                color,
                screen_scale,
                face_writer_ref,
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

pub const Button = packed struct(u64) {
    vertex_index: u16,
    vertex_count: u16,
    state_index: Index(HoverZoneState),
    extent_index: Index(geometry.Extent2D(f32)),

    pub const DrawOptions = struct {
        rounding_radius: ?f64,
    };

    pub fn create() Button {
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
        screen_scale: ScaleFactor2D(f32),
        comptime options: DrawOptions,
    ) !void {
        self.vertex_index = @intCast(u16, face_writer_ref.vertices_used);
        if (comptime options.rounding_radius) |rounding_radius| {
            try graphics.drawRoundRect(extent, color, rounding_radius, screen_scale, face_writer_ref);
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
