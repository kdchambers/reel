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
const TriangleFace = graphics.TriangleFace;
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

pub const TabbedSection = struct {
    headings: []const []const u8,
    active_index: u16,
    underline_color: graphics.RGB(f32),
    state_indices: mini_heap.SliceIndex(Index(HoverZoneState)),
    vertex_indices: mini_heap.SliceIndex(u16),

    pub fn create(
        headings: []const []const u8,
        underline_color: graphics.RGB(f32),
    ) @This() {
        std.debug.assert(headings.len <= 32);
        var state_buffer: [32]Index(HoverZoneState) = undefined;
        for (0..headings.len) |heading_i| {
            state_buffer[heading_i] = event_system.reserveState();
            state_buffer[heading_i].getPtr().clear();
        }
        const vertex_indices = mini_heap.reserve(
            u16,
            @intCast(u16, headings.len),
            .{ .check_alignment = true },
        );
        const state_indices = mini_heap.writeSlice(
            Index(HoverZoneState),
            state_buffer[0..headings.len],
            .{ .check_alignment = true },
        );
        return .{
            .headings = headings,
            .active_index = 0,
            .underline_color = underline_color,
            .state_indices = state_indices,
            .vertex_indices = vertex_indices,
        };
    }

    pub const UpdateResult = struct {
        tab_changed: bool = false,
    };

    pub fn update(self: *@This()) UpdateResult {
        const color_hovered = graphics.RGBA(f32).fromInt(50, 50, 50, 50);
        const color_normal = graphics.RGBA(f32).fromInt(0, 0, 0, 0);
        var vertex_indices = self.vertex_indices.get();

        var result: UpdateResult = .{};

        var state_indices = self.state_indices.get();
        for (state_indices, 0..) |state_index, i| {
            const state_copy = state_index.get();
            state_index.getPtr().clear();
            if (state_copy.hover_enter) {
                const index_start = vertex_indices[i];
                const index_end: usize = index_start + 4;
                for (vertices_buffer_ref[index_start..index_end]) |*vertex| {
                    vertex.color = color_hovered;
                }
            }
            if (state_copy.hover_exit) {
                const index_start = vertex_indices[i];
                const index_end: usize = index_start + 4;
                for (vertices_buffer_ref[index_start..index_end]) |*vertex| {
                    vertex.color = color_normal;
                }
            }

            if (state_copy.left_click_press) {
                self.active_index = @intCast(u16, i);
                result.tab_changed = true;
            }
        }

        return result;
    }

    pub fn draw(
        self: *@This(),
        extent: Extent2D(f32),
        screen_scale: ScaleFactor2D(f32),
        pen: anytype,
        border_width: f32,
    ) !void {
        _ = border_width;
        if (screen_scale.horizontal == 0 or screen_scale.vertical == 0)
            return;

        const box_height: f32 = 40.0 * screen_scale.vertical;
        const box_spacing: f32 = 60.0 * screen_scale.horizontal;
        const text_padding: f32 = 5 * screen_scale.horizontal;

        var vertex_indices = self.vertex_indices.get();
        const background_color = graphics.RGBA(f32).fromInt(0, 0, 0, 0);

        var state_indices = self.state_indices.get();

        var current_x_offset: f32 = box_spacing / 2.0;
        for (self.headings, 0..) |title, i| {
            const title_width: f32 = pen.calculateRenderDimensions(title).width * screen_scale.horizontal;
            const text_extent = geometry.Extent2D(f32){
                .x = extent.x + current_x_offset,
                .y = (extent.y - extent.height) + box_height,
                .width = title_width + text_padding,
                .height = box_height,
            };
            const box_extent = geometry.Extent2D(f32){
                .x = extent.x + current_x_offset - (box_spacing / 2.0),
                .y = (extent.y - extent.height) + box_height,
                .width = title_width + box_spacing,
                .height = box_height,
            };

            vertex_indices[i] = face_writer_ref.vertices_used;
            (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(box_extent, background_color, .bottom_left);

            var dummy_extent_index = Index(geometry.Extent2D(f32)){ .index = std.math.maxInt(u16) };

            const bind_options = event_system.MouseEventOptions{ .enable_hover = true, .start_active = false };
            event_system.bindStateToMouseEvent(state_indices[i], text_extent, &dummy_extent_index, bind_options);

            var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer_ref };
            pen.writeCentered(title, text_extent, screen_scale, &text_writer_interface) catch |err| {
                std.log.err("Failed to draw {}. Lack of space", .{err});
            };

            if (i == self.active_index) {
                const underline_color = graphics.RGBA(f32).fromInt(150, 35, 57, 255);
                const underline_width = box_spacing + title_width;
                const underline_extent = geometry.Extent2D(f32){
                    .x = extent.x + current_x_offset - (box_spacing / 2.0),
                    .y = (extent.y - extent.height) + box_height,
                    .width = underline_width,
                    .height = 2 * screen_scale.vertical,
                };
                (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(underline_extent, underline_color, .bottom_left);
            }

            current_x_offset += (box_spacing + title_width);
        }
    }
};

pub const Section = struct {
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
    //
    // TODO: Implement
    //
    const Model = struct {
        is_open: bool,
        selected_index: u16,
        labels: [][]const u8,
    };

    is_open: bool,
    item_count: u8,
    state_index: Index(HoverZoneState),
    extent_index: Index(geometry.Extent2D(f32)),
    vertex_index: u16,
    labels: []const []const u8,
    selected_index: u16,

    item_states: [8]Index(HoverZoneState),
    item_extents: [8]Index(geometry.Extent2D(f32)),

    pub fn create(item_count: u8) !@This() {
        std.debug.assert(item_count <= 8);
        const state_index = event_system.reserveState();
        state_index.getPtr().reset();
        var result = @This(){
            .is_open = false,
            .labels = undefined,
            .selected_index = 0,
            .vertex_index = std.math.maxInt(u16),
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

    pub inline fn state(self: @This()) HoverZoneState {
        const state_copy = self.state_index.get();
        self.state_index.getPtr().clear();
        return state_copy;
    }

    pub fn setColor(self: @This(), color: graphics.RGBA(f32)) void {
        var i = self.vertex_index;
        const end_index = self.vertex_index + 4;
        while (i < end_index) : (i += 1) {
            vertices_buffer_ref[i].color = color;
        }
    }

    pub fn setItemColor(self: @This(), index: usize, color: graphics.RGBA(f32)) void {
        const vertex_index = blk: {
            var vertices_count: usize = 7 + (self.labels[self.selected_index].len * 4);
            var i: usize = 0;
            while (i < index) : (i += 1) {
                vertices_count += 4 + (self.labels[i].len * 4);
            }
            break :blk vertices_count;
        };
        var i = vertex_index + self.vertex_index;
        const end_index = i + 4;
        while (i < end_index) : (i += 1) {
            vertices_buffer_ref[i].color = color;
        }
    }

    pub fn draw(
        self: *@This(),
        extent: Extent2D(f32),
        pen: anytype,
        screen_scale: ScaleFactor2D(f32),
        color: graphics.RGBA(f32),
    ) !void {
        self.vertex_index = @intCast(u16, face_writer_ref.vertices_used);

        (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(extent, color, .bottom_left);

        const label_extent = Extent2D(f32){
            .x = extent.x,
            .y = extent.y,
            .width = extent.width * 0.7,
            .height = extent.height,
        };
        var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer_ref };
        try pen.writeCentered(self.labels[self.selected_index], label_extent, screen_scale, &text_writer_interface);

        var triangle_vertices: *TriangleFace = try face_writer_ref.create(TriangleFace);
        const triangle_color = graphics.RGBA(f32).fromInt(200, 200, 200, 255);

        triangle_vertices[0] = .{};
        triangle_vertices[1] = .{};
        triangle_vertices[2] = .{};

        triangle_vertices[0].color = triangle_color;
        triangle_vertices[1].color = triangle_color;
        triangle_vertices[2].color = triangle_color;

        const triangle_height: f32 = extent.height / 4.0;
        const triangle_height_pixels = triangle_height / screen_scale.vertical;
        const triangle_width: f32 = (triangle_height_pixels * 1.5) * screen_scale.horizontal;
        const triangle_left: f32 = extent.x + (extent.width * 0.75);
        const triangle_bottom: f32 = extent.y - (extent.height * 0.33);

        triangle_vertices[0].x = triangle_left;
        triangle_vertices[0].y = triangle_bottom - triangle_height;
        triangle_vertices[1].x = triangle_left + triangle_width;
        triangle_vertices[1].y = triangle_bottom - triangle_height;
        triangle_vertices[2].x = triangle_left + (triangle_width / 2.0);
        triangle_vertices[2].y = triangle_bottom;

        const bind_options = event_system.MouseEventOptions{ .enable_hover = true, .start_active = false };
        event_system.bindStateToMouseEvent(self.state_index, extent, &self.extent_index, bind_options);

        if (self.is_open) {
            for (self.labels, 0..) |label, i| {
                const item_extent = Extent2D(f32){
                    .x = extent.x,
                    .y = extent.y + (extent.height * @intToFloat(f32, i + 1)),
                    .width = extent.width,
                    .height = extent.height,
                };
                (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(item_extent, color, .bottom_left);
                try pen.writeCentered(label, item_extent, screen_scale, &text_writer_interface);
                event_system.bindStateToMouseEvent(self.item_states[i], item_extent, &self.item_extents[i], bind_options);
            }
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
