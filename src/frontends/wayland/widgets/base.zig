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
const TextWriterInterface = graphics.TextWriterInterface;

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

pub const Selector = struct {
    active_index: u16,
    labels: []const []const u8,
    state_indices: mini_heap.SliceIndex(Index(HoverZoneState)),
    vertex_indices: mini_heap.SliceIndex(u16),
    extent_indices: mini_heap.SliceIndex(Index(geometry.Extent2D(f32))),

    background_color: graphics.RGBA(f32),
    border_color: graphics.RGBA(f32),
    active_background_color: graphics.RGBA(f32),
    hovered_background_color: graphics.RGBA(f32),

    pub fn create(labels: []const []const u8) @This() {
        var state_buffer: [16]Index(HoverZoneState) = undefined;
        for (0..labels.len) |heading_i| {
            state_buffer[heading_i] = event_system.reserveState();
            state_buffer[heading_i].getPtr().clear();
        }

        const state_indices = mini_heap.writeSlice(
            Index(HoverZoneState),
            state_buffer[0..labels.len],
            .{ .check_alignment = true },
        );

        const vertex_indices = mini_heap.reserve(
            u16,
            @intCast(u16, labels.len),
            .{ .check_alignment = true },
        );
        const extent_indices = mini_heap.reserve(
            Index(geometry.Extent2D(f32)),
            @intCast(u16, labels.len),
            .{ .check_alignment = true },
        );

        for (extent_indices.get()) |*extent_index| {
            extent_index.index = std.math.maxInt(u16);
        }

        return .{
            .active_index = 0,
            .labels = labels,
            .state_indices = state_indices,
            .vertex_indices = vertex_indices,
            .extent_indices = extent_indices,
            .border_color = .{
                .r = 0.6,
                .g = 0.6,
                .b = 0.6,
                .a = 1.0,
            },
            .background_color = .{
                .r = 0.3,
                .g = 0.25,
                .b = 0.3,
                .a = 1.0,
            },
            .active_background_color = .{
                .r = 0.22,
                .g = 0.18,
                .b = 0.22,
                .a = 1.0,
            },
            .hovered_background_color = .{
                .r = 0.25,
                .g = 0.21,
                .b = 0.23,
                .a = 1.0,
            },
        };
    }

    const Update = struct {
        color_changed: bool = false,
        index_changed: bool = false,
    };

    pub fn update(self: *@This()) Update {
        var result: Update = .{};
        const last_index = self.labels.len - 1;
        for (self.state_indices.get(), 0..) |*state, i| {
            if (i == self.active_index)
                continue;
            const ptr = state.getPtr();
            if (ptr.hover_enter) {
                const vertex_count: u16 = if (i == 0 or i == last_index) 22 else 4;
                var vertex_index = self.vertex_indices.get()[i];
                const end_index = vertex_index + vertex_count;
                while (vertex_index < end_index) : (vertex_index += 1) {
                    vertices_buffer_ref[vertex_index].color = self.hovered_background_color;
                }
            }
            if (ptr.hover_exit) {
                const vertex_count: u16 = if (i == 0 or i == last_index) 22 else 4;
                var vertex_index = self.vertex_indices.get()[i];
                const end_index = vertex_index + vertex_count;
                while (vertex_index < end_index) : (vertex_index += 1) {
                    vertices_buffer_ref[vertex_index].color = self.background_color;
                }
            }
            if (ptr.left_click_press) {
                {
                    //
                    // Reset color of currently active tab
                    //
                    const vertex_count: u16 = if (self.active_index == 0 or self.active_index == last_index) 22 else 4;
                    var vertex_index = self.vertex_indices.get()[self.active_index];
                    const end_index = vertex_index + vertex_count;
                    while (vertex_index < end_index) : (vertex_index += 1) {
                        vertices_buffer_ref[vertex_index].color = self.background_color;
                    }
                }
                const vertex_count: u16 = if (i == 0 or i == last_index) 22 else 4;
                var vertex_index = self.vertex_indices.get()[i];
                const end_index = vertex_index + vertex_count;
                while (vertex_index < end_index) : (vertex_index += 1) {
                    vertices_buffer_ref[vertex_index].color = self.active_background_color;
                }
                self.active_index = @intCast(u16, i);
                result.index_changed = true;
            }
            ptr.reset();
        }
        return result;
    }

    pub fn draw(
        self: *@This(),
        placement: Coordinates2D(f32),
        screen_scale: ScaleFactor2D(f32),
        pen: anytype,
    ) !void {
        const radius: f32 = 5.0;
        const radius_h: f32 = radius * screen_scale.horizontal;
        const radius_v: f32 = radius * screen_scale.vertical;

        var width_max: f32 = 0.0;
        var widths_buffer: [8]f32 = undefined;
        for (self.labels, 0..) |label, i| {
            widths_buffer[i] = pen.calculateRenderDimensions(label).width * screen_scale.horizontal;
            width_max = @max(widths_buffer[i], width_max);
        }

        var vertices_ref = self.vertex_indices.get();
        var states_ref = self.state_indices.get();
        var extents_ref = self.extent_indices.get();

        const box_width: f32 = width_max + (20.0 * screen_scale.horizontal);

        const extent = Extent2D(f32){
            .x = placement.x,
            .y = placement.y,
            .width = 100 * screen_scale.horizontal,
            .height = 40.0 * screen_scale.vertical,
        };

        const seperator_width_pixels: f32 = 1.0;
        const seperator_width: f32 = seperator_width_pixels * screen_scale.horizontal;

        {
            vertices_ref[0] = face_writer_ref.vertices_used;

            const background_color = if (self.active_index == 0) self.active_background_color else self.background_color;
            const left_side_extent = Extent2D(f32){
                .x = placement.x,
                .y = placement.y - radius_v,
                .width = radius_h,
                .height = extent.height - (radius_v * 2.0),
            };

            (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(left_side_extent, background_color, .bottom_left);

            const middle_section_extent = Extent2D(f32){
                .x = placement.x + radius_h,
                .y = placement.y,
                .width = box_width,
                .height = extent.height,
            };
            (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(middle_section_extent, background_color, .bottom_left);

            //
            // Register hover zone with event system
            //
            const hover_extent = Extent2D(f32){
                .x = placement.x,
                .y = placement.y,
                .width = box_width + radius_h,
                .height = extent.height,
            };
            const bind_options = event_system.MouseEventOptions{ .enable_hover = true, .start_active = false };
            event_system.bindStateToMouseEvent(states_ref[0], hover_extent, &extents_ref[0], bind_options);

            const top_left_arc_placement = Coordinates2D(f32){
                .x = extent.x + radius_h,
                .y = extent.y - (extent.height - radius_v),
            };

            try graphics.drawRoundedCorner(
                .top_left,
                top_left_arc_placement,
                background_color,
                radius,
                screen_scale,
                face_writer_ref,
            );

            const bottom_left_arc_placement = Coordinates2D(f32){
                .x = extent.x + radius_h,
                .y = extent.y - radius_v,
            };

            try graphics.drawRoundedCorner(
                .bottom_left,
                bottom_left_arc_placement,
                background_color,
                radius,
                screen_scale,
                face_writer_ref,
            );

            const seperator_extent = Extent2D(f32){
                .x = placement.x + radius_h + box_width,
                .y = placement.y,
                .width = 1.0 * screen_scale.horizontal,
                .height = extent.height,
            };
            (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(seperator_extent, self.border_color, .bottom_left);

            var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer_ref };
            pen.writeCentered(self.labels[0], middle_section_extent, screen_scale, &text_writer_interface) catch |err| {
                std.log.err("Failed to draw {}. Lack of space", .{err});
            };
        }

        const last_index = self.labels.len - 1;

        //
        // Draw middle sections
        //
        {
            const index_start: usize = 1;
            const index_end: usize = last_index;
            for (index_start..index_end) |i| {
                vertices_ref[i] = face_writer_ref.vertices_used;
                const background_color = if (self.active_index == i) self.active_background_color else self.background_color;
                const middle_section_extent = Extent2D(f32){
                    .x = placement.x + radius_h + ((box_width + seperator_width) * @intToFloat(f32, i)),
                    .y = placement.y,
                    .width = box_width,
                    .height = extent.height,
                };

                (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(middle_section_extent, background_color, .bottom_left);

                const seperator_extent = Extent2D(f32){
                    .x = middle_section_extent.x + box_width,
                    .y = placement.y,
                    .width = 1.0 * screen_scale.horizontal,
                    .height = extent.height,
                };
                (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(seperator_extent, self.border_color, .bottom_left);

                var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer_ref };
                pen.writeCentered(self.labels[i], middle_section_extent, screen_scale, &text_writer_interface) catch |err| {
                    std.log.err("Failed to draw {}. Lack of space", .{err});
                };

                const bind_options = event_system.MouseEventOptions{ .enable_hover = true, .start_active = false };
                event_system.bindStateToMouseEvent(states_ref[i], middle_section_extent, &extents_ref[i], bind_options);
            }
        }

        //
        // Draw final section
        //
        {
            vertices_ref[last_index] = face_writer_ref.vertices_used;

            const background_color = if (self.active_index == last_index) self.active_background_color else self.background_color;
            const middle_section_extent = Extent2D(f32){
                .x = placement.x + radius_h + ((box_width + seperator_width) * @intToFloat(f32, last_index)),
                .y = placement.y,
                .width = box_width,
                .height = extent.height,
            };
            (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(middle_section_extent, background_color, .bottom_left);

            const right_middle_extent = Extent2D(f32){
                .x = middle_section_extent.x + middle_section_extent.width,
                .y = placement.y - radius_v,
                .width = radius_h,
                .height = extent.height - (radius_v * 2.0),
            };
            (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(right_middle_extent, background_color, .bottom_left);

            //
            // Register hover zone with event system
            //
            const hover_extent = Extent2D(f32){
                .x = middle_section_extent.x,
                .y = placement.y,
                .width = box_width + radius_h,
                .height = extent.height,
            };
            const bind_options = event_system.MouseEventOptions{ .enable_hover = true, .start_active = false };
            event_system.bindStateToMouseEvent(states_ref[last_index], hover_extent, &extents_ref[last_index], bind_options);

            const top_right_arc_placement = Coordinates2D(f32){
                .x = middle_section_extent.x + middle_section_extent.width,
                .y = extent.y - (extent.height - radius_v),
            };

            try graphics.drawRoundedCorner(
                .top_right,
                top_right_arc_placement,
                background_color,
                radius,
                screen_scale,
                face_writer_ref,
            );

            const bottom_right_arc_placement = Coordinates2D(f32){
                .x = middle_section_extent.x + middle_section_extent.width,
                .y = extent.y - radius_v,
            };

            try graphics.drawRoundedCorner(
                .bottom_right,
                bottom_right_arc_placement,
                background_color,
                radius,
                screen_scale,
                face_writer_ref,
            );

            var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer_ref };
            pen.writeCentered(self.labels[last_index], middle_section_extent, screen_scale, &text_writer_interface) catch |err| {
                std.log.err("Failed to draw {}. Lack of space", .{err});
            };
        }
    }
};

pub const TabbedSection = struct {
    headings: []const []const u8,
    active_index: u16,
    underline_color: graphics.RGB(f32),
    state_indices: mini_heap.SliceIndex(Index(HoverZoneState)),
    vertex_indices: mini_heap.SliceIndex(u16),
    extent_indices: mini_heap.SliceIndex(Index(geometry.Extent2D(f32))),

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
        const extent_indices = mini_heap.reserve(
            Index(geometry.Extent2D(f32)),
            @intCast(u16, headings.len),
            .{ .check_alignment = true },
        );
        for (extent_indices.get()) |*extent_index| {
            extent_index.index = std.math.maxInt(u16);
        }
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
            .extent_indices = extent_indices,
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

            std.debug.assert(state_index.get().hover_enter == false);
            std.debug.assert(state_index.get().hover_exit == false);
            std.debug.assert(state_index.get().left_click_press == false);

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
                if (self.active_index != i) {
                    self.active_index = @intCast(u16, i);
                    result.tab_changed = true;
                }
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
        var extent_indices = self.extent_indices.get();

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

            const bind_options = event_system.MouseEventOptions{ .enable_hover = true, .start_active = false };
            event_system.bindStateToMouseEvent(state_indices[i], text_extent, &extent_indices[i], bind_options);

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

        const initial_extent = geometry.Extent2D(f32){
            .x = -1.0,
            .y = -1.0,
            .width = 0.0,
            .height = 0.0,
        };
        var i: usize = 0;
        while (i < item_count) : (i += 1) {
            result.item_states[i] = event_system.reserveState();
            result.item_states[i].getPtr().reset();
            result.item_extents[i] = mini_heap.write(geometry.Extent2D(f32), &initial_extent);
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
            var extent_buffer: [8]Extent2D(f32) = undefined;
            for (0..self.labels.len) |i| {
                extent_buffer[i] = .{
                    .x = extent.x,
                    .y = extent.y + (extent.height * @intToFloat(f32, i + 1)),
                    .width = extent.width,
                    .height = extent.height,
                };
                self.item_extents[i].getPtr().* = extent_buffer[i];
            }
            event_system.addBlockingMouseEvents(
                self.item_extents[0..self.labels.len],
                true,
                true,
                self.item_states[0..self.labels.len],
            );
            for (self.labels, 0..) |label, i| {
                (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(extent_buffer[i], color, .bottom_left);
                try pen.writeCentered(label, extent_buffer[i], screen_scale, &text_writer_interface);
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
        center: geometry.Coordinates2D(f32),
        radius_pixels: f32,
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
                radius_pixels / 2.0,
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

    pub inline fn clicked(self: @This()) bool {
        return self.state().left_click_press;
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

pub const CloseButton = struct {
    const clear_color = graphics.RGBA(f32){ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 };

    vertex_index: u16,
    state_index: Index(HoverZoneState),
    extent_index: Index(geometry.Extent2D(f32)),
    on_hover_color: graphics.RGBA(f32),

    pub fn create() CloseButton {
        const state_index = event_system.reserveState();
        state_index.getPtr().reset();
        return .{
            .vertex_index = std.math.maxInt(u16),
            .state_index = state_index,
            .extent_index = .{ .index = std.math.maxInt(u16) },
            .on_hover_color = undefined,
        };
    }

    const Update = struct {
        left_clicked: bool = false,
        color_changed: bool = false,
    };

    pub fn update(self: *@This()) Update {
        const state_copy = self.state_index.get();
        self.state_index.getPtr().clear();

        var result: Update = .{};

        if (state_copy.left_click_press) {
            result.left_clicked = true;
        }

        if (state_copy.hover_enter) {
            result.color_changed = true;
            self.setColor(self.on_hover_color);
        }

        if (state_copy.hover_exit) {
            result.color_changed = true;
            self.setColor(clear_color);
        }

        return result;
    }

    pub fn draw(
        self: *@This(),
        extent: Extent2D(f32),
        screen_scale: ScaleFactor2D(f32),
    ) !void {
        self.vertex_index = @intCast(u16, face_writer_ref.vertices_used);
        (try face_writer_ref.create(QuadFace)).* = graphics.quadColored(extent, clear_color, .bottom_left);
        const line_color = graphics.RGBA(f32).fromInt(20, 20, 20, 255);

        const horizontal_margin: f32 = extent.width * 0.2;
        const vertical_margin: f32 = extent.height * 0.2;
        const cross_extent = geometry.Extent2D(f32){
            .x = extent.x + horizontal_margin,
            .y = extent.y - vertical_margin,
            .width = extent.width - (horizontal_margin * 2.0),
            .height = extent.height - (vertical_margin * 2.0),
        };
        try graphics.drawCross(
            cross_extent,
            2.5 * screen_scale.horizontal,
            2.5 * screen_scale.vertical,
            line_color,
            face_writer_ref,
        );
        const bind_options = event_system.MouseEventOptions{ .enable_hover = true, .start_active = false };
        event_system.bindStateToMouseEvent(self.state_index, extent, &self.extent_index, bind_options);
    }

    fn setColor(self: @This(), color: graphics.RGBA(f32)) void {
        var i = self.vertex_index;
        const end_index = self.vertex_index + 4;
        while (i < end_index) : (i += 1) {
            vertices_buffer_ref[i].color = color;
        }
    }
};
