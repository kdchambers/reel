// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const renderer = @import("../../../renderer.zig");

const geometry = @import("../../../geometry.zig");
const Extent2D = geometry.Extent2D;
const Extent3D = geometry.Extent3D;
const ScaleFactor2D = geometry.ScaleFactor2D;
const Coordinates2D = geometry.Coordinates2D;
const Coordinates3D = geometry.Coordinates3D;
const Dimensions2D = geometry.Dimensions2D;
const Radius2D = geometry.Radius2D;

const event_system = @import("../event_system.zig");
const HoverZoneState = event_system.HoverZoneState;

const mini_heap = @import("../../../utils/mini_heap.zig");
const Index = mini_heap.Index;

const frontend = @import("../../wayland.zig");

const graphics = @import("../../../graphics.zig");
const Vertex = graphics.GenericVertex;
const FaceWriter = graphics.FaceWriter;
const QuadFace = graphics.QuadFace;
const TriangleFace = graphics.TriangleFace;
const RGBA = graphics.RGBA;
const TextWriterInterface = graphics.TextWriterInterface;

pub const MouseEventEntry = event_system.MouseEventEntry;

pub const Slider = struct {
    const knob_inner_radius_pixels: f32 = 7.0;
    const knob_radius_pixels: f32 = 10.0;

    label_buffer: []const []const u8,
    title: []const u8,

    active_index: u16,
    drag_active: bool,
    background_color: RGBA(u8),
    knob_outer_color: RGBA(u8),
    knob_inner_color: RGBA(u8),
    mouse_event_slot: mini_heap.Index(MouseEventEntry),
    knob_vertex_range: renderer.VertexRange,
    value_vertex_range: renderer.VertexRange,
    value_extent: Extent3D(f32),
    progress_bar_full_extent: Extent3D(f32),
    progress_bar_quad: u16,

    drag_start_mouse_x: f32,
    drag_start_x: f32,
    drag_interval: f32,
    drag_count: f32,
    drag_start_active_index: u16,

    pub fn init(self: *@This()) void {
        self.active_index = 0;
        self.drag_active = false;
    }

    pub const Response = struct {
        visual_change: bool = false,
        active_index: ?u16 = null,
    };

    pub fn update(self: *@This(), mouse_x: f32, left_mouse_active: bool, screen_scale: ScaleFactor2D(f32)) Response {
        var response = Response{};
        var event_ptr = self.mouse_event_slot.getPtr();
        if (self.drag_active) {
            const x_diff: f32 = mouse_x - self.drag_start_mouse_x;
            const relative_x = x_diff - self.drag_start_x;
            const index = self.drag_start_active_index + @as(i32, @intFromFloat(@floor((relative_x + (self.drag_interval / 2.0)) / self.drag_interval)));
            if (index >= 0 and index < self.label_buffer.len and index != self.active_index) {
                const index_diff: i32 = index - self.active_index;
                const x_shift = @as(f32, @floatFromInt(index_diff)) * self.drag_interval;
                self.active_index = @intCast(index);
                response.active_index = self.active_index;
                renderer.updateVertexRangeHPosition(
                    self.knob_vertex_range,
                    x_shift,
                );
                event_ptr.extent.x += x_shift;
                renderer.overwriteText(
                    self.value_vertex_range,
                    self.label_buffer[self.active_index],
                    self.value_extent,
                    screen_scale,
                    .small,
                    .regular,
                    RGBA(u8).white,
                    .top_right,
                );
                const progress_percentage: f32 = @as(f32, @floatFromInt(self.active_index)) / @as(f32, @floatFromInt(self.label_buffer.len - 1));
                assert(progress_percentage >= 0.0);
                assert(progress_percentage <= 1.0);
                const knob_inner_radius_width: f32 = knob_inner_radius_pixels * screen_scale.horizontal;
                const progress_bar_extent = Extent3D(f32){
                    .x = self.progress_bar_full_extent.x,
                    .y = self.progress_bar_full_extent.y,
                    .z = self.progress_bar_full_extent.z,
                    .width = @max(0.0, (self.progress_bar_full_extent.width * progress_percentage) - knob_inner_radius_width),
                    .height = self.progress_bar_full_extent.height,
                };
                renderer.overwriteQuad(self.progress_bar_quad, progress_bar_extent, RGBA(u8).white, .bottom_left);
            }
            if (!left_mouse_active) {
                self.drag_active = false;
            }
        } else {
            if (event_ptr.state.pending_left_click_release) {
                event_ptr.state.pending_left_click_release = false;
                self.drag_active = true;
                self.drag_start_active_index = self.active_index;
                self.drag_start_mouse_x = mouse_x;
            }
        }
        event_ptr.state.clear();
        return response;
    }

    pub fn draw(
        self: *@This(),
        extent: Extent3D(f32),
        screen_scale: ScaleFactor2D(f32),
        value_label_buffer_size: u16,
    ) void {
        const step_count = self.label_buffer.len;
        assert(step_count > 2);

        const title_text_height = 40.0 * screen_scale.vertical;
        const title_extent = Extent3D(f32){
            .x = extent.x,
            .y = extent.y - extent.height + title_text_height,
            .z = extent.z,
            .width = 60.0 * screen_scale.horizontal,
            .height = title_text_height,
        };
        _ = renderer.drawText(
            self.title,
            title_extent,
            screen_scale,
            .small,
            .regular,
            RGBA(u8).white,
            .top_left,
        );

        const value_label_height = 40.0 * screen_scale.vertical;
        const value_label_extent = Extent3D(f32){
            .x = extent.x,
            .y = extent.y - extent.height + value_label_height,
            .z = extent.z,
            .width = extent.width,
            .height = value_label_height,
        };
        self.value_extent = value_label_extent;
        self.value_vertex_range = renderer.reserveTextBuffer(value_label_buffer_size);
        renderer.overwriteText(
            self.value_vertex_range,
            self.label_buffer[self.active_index],
            self.value_extent,
            screen_scale,
            .small,
            .regular,
            RGBA(u8).white,
            .top_right,
        );

        const bar_height: f32 = 4.0 * screen_scale.vertical;
        const bar_extent = Extent3D(f32){
            .x = extent.x,
            .y = extent.y,
            .z = extent.z,
            .width = extent.width,
            .height = bar_height,
        };
        _ = renderer.drawQuad(bar_extent, self.background_color, .bottom_left);
        const value_interval: f32 = extent.width / @as(f32, @floatFromInt(step_count - 1));
        const point_size_pixels: f32 = 2.0;
        const point_width: f32 = point_size_pixels * screen_scale.horizontal;
        const point_height: f32 = point_size_pixels * screen_scale.vertical;
        const point_y_placement: f32 = extent.y - ((bar_height / 2.0) - (point_height / 2.0));
        for (0..step_count - 2) |i| {
            const point_extent = Extent3D(f32){
                .x = extent.x + @as(f32, @floatFromInt(i + 1)) * value_interval,
                .y = point_y_placement,
                .z = extent.z,
                .width = point_width,
                .height = point_height,
            };
            _ = renderer.drawQuad(point_extent, RGBA(u8).fromInt(40, 40, 40, 255), .bottom_left);
        }

        self.drag_interval = value_interval;
        self.drag_count = @floatFromInt(step_count - 2);

        const knob_placement_center = Coordinates3D(f32){
            .x = extent.x + @as(f32, @floatFromInt(self.active_index)) * value_interval,
            .y = point_y_placement,
            .z = extent.z,
        };
        const knob_radius = Radius2D(f32){
            .h = knob_radius_pixels * screen_scale.horizontal,
            .v = knob_radius_pixels * screen_scale.vertical,
        };
        const outer_vertex_range = renderer.drawCircle(knob_placement_center, knob_radius, self.knob_outer_color, 48);

        const knob_inner_radius = Radius2D(f32){
            .h = knob_inner_radius_pixels * screen_scale.horizontal,
            .v = knob_inner_radius_pixels * screen_scale.vertical,
        };
        const inner_vertex_range = renderer.drawCircle(knob_placement_center, knob_inner_radius, self.knob_inner_color, 32);
        self.knob_vertex_range = .{
            .start = outer_vertex_range.start,
            .count = outer_vertex_range.count + inner_vertex_range.count,
        };
        const knob_hover_extent = Extent3D(f32){
            .x = knob_placement_center.x - knob_radius.h,
            .y = knob_placement_center.y + knob_radius.v,
            .z = extent.z,
            .width = knob_radius.h * 2.0,
            .height = knob_radius.v * 2.0,
        };
        self.mouse_event_slot = event_system.writeMouseEventSlot(knob_hover_extent, .{});

        const progress_percentage: f32 = @as(f32, @floatFromInt(self.active_index)) / @as(f32, @floatFromInt(self.label_buffer.len - 1));
        assert(progress_percentage >= 0.0);
        assert(progress_percentage <= 1.0);
        self.progress_bar_full_extent = Extent3D(f32){
            .x = extent.x,
            .y = extent.y,
            .z = extent.z,
            .width = extent.width,
            .height = bar_height,
        };
        const progress_bar_extent = Extent3D(f32){
            .x = extent.x,
            .y = extent.y,
            .z = extent.z - 0.001,
            .width = @max(0.0, (extent.width * progress_percentage) - knob_inner_radius.h),
            .height = bar_height,
        };
        self.progress_bar_quad = renderer.drawQuad(progress_bar_extent, self.knob_outer_color, .bottom_left);
    }
};

pub const Selector = struct {
    const max_label_count = 8;

    active_index: u16,
    labels: []const []const u8,

    mouse_event_slots: mini_heap.SliceIndex(MouseEventEntry),
    vertex_range_buffer: [max_label_count]renderer.VertexRange,

    background_color: graphics.RGBA(u8),
    border_color: graphics.RGBA(u8),
    active_background_color: graphics.RGBA(u8),
    hovered_background_color: graphics.RGBA(u8),

    pub fn init(self: *@This()) void {
        _ = self;
    }

    const Reponse = struct {
        visual_change: bool = false,
        active_index: ?u16 = null,
    };

    pub fn update(self: *@This()) Reponse {
        var response: Reponse = .{};
        for (self.mouse_event_slots.get(), 0..) |*event, i| {
            const state_copy = event.state;
            event.state.clear();
            if (state_copy.hover_enter) {
                renderer.updateVertexRangeColor(self.vertex_range_buffer[i], self.hovered_background_color);
                response.visual_change = true;
            }
            if (state_copy.hover_exit) {
                const color = if (i == self.active_index) self.active_background_color else self.background_color;
                renderer.updateVertexRangeColor(self.vertex_range_buffer[i], color);
                response.visual_change = true;
            }

            if (state_copy.left_click_press) {
                if (i != self.active_index) {
                    self.active_index = @intCast(i);
                    response.active_index = self.active_index;
                    renderer.updateVertexRangeColor(self.vertex_range_buffer[i], self.active_background_color);
                    response.visual_change = true;
                }
            }
        }
        return response;
    }

    pub fn draw(
        self: *@This(),
        placement: Coordinates3D(f32),
        screen_scale: ScaleFactor2D(f32),
    ) void {
        const radius_pixels: f32 = 5.0;
        const radius = Radius2D(f32){
            .h = radius_pixels * screen_scale.horizontal,
            .v = radius_pixels * screen_scale.vertical,
        };

        var width_max: f32 = 0.0;
        var widths_buffer: [8]f32 = undefined;

        for (self.labels, 0..) |label, i| {
            widths_buffer[i] = renderer.calculateRenderedDimensions(label, .small).width * screen_scale.horizontal;
            width_max = @max(widths_buffer[i], width_max);
        }

        const box_width: f32 = width_max + (20.0 * screen_scale.horizontal);

        const extent = Extent3D(f32){
            .x = placement.x,
            .y = placement.y,
            .z = placement.z,
            .width = 100 * screen_scale.horizontal,
            .height = 26.0 * screen_scale.vertical,
        };

        const seperator_width_pixels: f32 = 1.0;
        const seperator_width: f32 = seperator_width_pixels * screen_scale.horizontal;

        {
            const background_color = if (self.active_index == 0) self.active_background_color else self.background_color;
            const left_side_extent = Extent3D(f32){
                .x = placement.x,
                .y = placement.y - radius.v,
                .z = placement.z,
                .width = radius.h,
                .height = extent.height - (radius.v * 2.0),
            };
            self.vertex_range_buffer[0].start = renderer.drawQuad(left_side_extent, background_color, .bottom_left);

            const middle_section_extent = Extent3D(f32){
                .x = placement.x + radius.h,
                .y = placement.y,
                .z = placement.z,
                .width = box_width,
                .height = extent.height,
            };
            _ = renderer.drawQuad(middle_section_extent, background_color, .bottom_left);

            var arc_vertex_count: u16 = 0;
            //
            // Register hover zone with event system
            //
            const hover_extent = Extent3D(f32){
                .x = placement.x,
                .y = placement.y,
                .z = placement.z,
                .width = box_width + radius.h,
                .height = extent.height,
            };
            const label_count: u16 = @intCast(self.labels.len);
            self.mouse_event_slots = event_system.reserveMouseEventSlots(label_count);
            event_system.overwriteMouseEventSlot(&self.mouse_event_slots.get()[0], hover_extent, .{});

            const top_left_arc_placement = Coordinates3D(f32){
                .x = extent.x + radius.h,
                .y = extent.y - (extent.height - radius.v),
                .z = placement.z,
            };
            arc_vertex_count += renderer.drawArc(top_left_arc_placement, radius, background_color, 180, 90, 10).count;

            const bottom_left_arc_placement = Coordinates3D(f32){
                .x = extent.x + radius.h,
                .y = extent.y - radius.v,
                .z = placement.z,
            };
            arc_vertex_count += renderer.drawArc(bottom_left_arc_placement, radius, background_color, 90, 90, 10).count;
            self.vertex_range_buffer[0].count = arc_vertex_count + 8;

            const seperator_extent = Extent3D(f32){
                .x = placement.x + radius.h + box_width,
                .y = placement.y,
                .z = placement.z,
                .width = 1.0 * screen_scale.horizontal,
                .height = extent.height,
            };
            _ = renderer.drawQuad(seperator_extent, self.border_color, .bottom_left);
            _ = renderer.drawText(self.labels[0], middle_section_extent, screen_scale, .small, .bold, RGBA(u8).white, .center);
        }

        const last_index = self.labels.len - 1;

        //
        // Draw middle sections
        //
        {
            const index_start: usize = 1;
            const index_end: usize = last_index;
            for (index_start..index_end) |i| {
                const background_color = if (self.active_index == i) self.active_background_color else self.background_color;
                const middle_section_extent = Extent3D(f32){
                    .x = placement.x + radius.h + ((box_width + seperator_width) * @as(f32, @floatFromInt(i))),
                    .y = placement.y,
                    .z = placement.z,
                    .width = box_width,
                    .height = extent.height,
                };
                self.vertex_range_buffer[i].start = renderer.drawQuad(middle_section_extent, background_color, .bottom_left);
                self.vertex_range_buffer[i].count = 4;

                const seperator_extent = Extent3D(f32){
                    .x = middle_section_extent.x + box_width,
                    .y = placement.y,
                    .z = placement.z,
                    .width = 1.0 * screen_scale.horizontal,
                    .height = extent.height,
                };
                _ = renderer.drawQuad(seperator_extent, self.border_color, .bottom_left);

                _ = renderer.drawText(self.labels[i], middle_section_extent, screen_scale, .small, .bold, RGBA(u8).white, .center);
                event_system.overwriteMouseEventSlot(&self.mouse_event_slots.get()[i], middle_section_extent, .{});
            }
        }

        //
        // Draw final section
        //
        {
            const background_color = if (self.active_index == last_index) self.active_background_color else self.background_color;
            const middle_section_extent = Extent3D(f32){
                .x = placement.x + radius.h + ((box_width + seperator_width) * @as(f32, @floatFromInt(last_index))),
                .y = placement.y,
                .z = placement.z,
                .width = box_width,
                .height = extent.height,
            };
            self.vertex_range_buffer[last_index].start = renderer.drawQuad(middle_section_extent, background_color, .bottom_left);

            const right_middle_extent = Extent3D(f32){
                .x = middle_section_extent.x + middle_section_extent.width,
                .y = placement.y - radius.v,
                .z = placement.z,
                .width = radius.h,
                .height = extent.height - (radius.v * 2.0),
            };
            _ = renderer.drawQuad(right_middle_extent, background_color, .bottom_left);

            //
            // Register hover zone with event system
            //
            const hover_extent = Extent3D(f32){
                .x = middle_section_extent.x,
                .y = placement.y,
                .z = placement.z,
                .width = box_width + radius.h,
                .height = extent.height,
            };
            event_system.overwriteMouseEventSlot(&self.mouse_event_slots.get()[last_index], hover_extent, .{});

            var vertex_count: u16 = 0;
            const top_right_arc_placement = Coordinates3D(f32){
                .x = middle_section_extent.x + middle_section_extent.width,
                .y = extent.y - (extent.height - radius.v),
                .z = placement.z,
            };
            vertex_count += renderer.drawArc(top_right_arc_placement, radius, background_color, 270, 90, 10).count;

            const bottom_right_arc_placement = Coordinates3D(f32){
                .x = middle_section_extent.x + middle_section_extent.width,
                .y = extent.y - radius.v,
                .z = placement.z,
            };
            vertex_count += renderer.drawArc(bottom_right_arc_placement, radius, background_color, 0, 90, 10).count;
            self.vertex_range_buffer[last_index].count = vertex_count + 8;

            _ = renderer.drawText(self.labels[last_index], middle_section_extent, screen_scale, .small, .bold, RGBA(u8).white, .center);
        }
    }
};

pub const CategoryList = struct {
    const max_category_count = 4;
    const max_label_count = 8;

    title: []const u8,
    categories: []const []const u8,
    entry_labels: []const []const u8,
    entry_categories: [max_label_count]u8,
    background_color: RGBA(u8),
    label_background: RGBA(u8),
    label_background_hovered: RGBA(u8),

    vertex_index_buffer: [max_label_count]u16,
    mouse_event_slots: mini_heap.SliceIndex(MouseEventEntry),
    background_extent_slot: mini_heap.Index(MouseEventEntry),

    pub fn init(self: *@This()) void {
        _ = self;
    }

    const Response = struct {
        item_clicked: ?u16 = null,
        closed: bool = false,
    };

    pub fn update(self: *@This()) Response {
        var response = Response{};
        for (self.mouse_event_slots.get(), 0..) |*event, i| {
            const state_copy = event.state;
            event.state.clear();
            if (state_copy.hover_enter) {
                var quad_ptr = renderer.quad(self.vertex_index_buffer[i]);
                quad_ptr[0].color = self.label_background_hovered;
                quad_ptr[1].color = self.label_background_hovered;
                quad_ptr[2].color = self.label_background_hovered;
                quad_ptr[3].color = self.label_background_hovered;
                frontend.requestRender();
            }
            if (state_copy.hover_exit) {
                var quad_ptr = renderer.quad(self.vertex_index_buffer[i]);
                quad_ptr[0].color = self.label_background;
                quad_ptr[1].color = self.label_background;
                quad_ptr[2].color = self.label_background;
                quad_ptr[3].color = self.label_background;
                frontend.requestRender();
            }

            if (state_copy.left_click_press) {
                response.item_clicked = @intCast(i);
            }
        }

        var event = self.background_extent_slot.get();
        const state_copy = event.state;
        event.state.clear();
        if (state_copy.left_click_press) {
            response.closed = true;
        }
        return response;
    }

    pub fn draw(
        self: *@This(),
        //
        // NOTE: `placement` is top_right instead of the normal `bottom_left`
        //
        placement: Coordinates3D(f32),
        width: f32,
        item_height: f32,
        screen_scale: ScaleFactor2D(f32),
    ) void {

        //
        // We're reserving the quads here as we don't really know the height of the
        // list at this point. Trying to render at the end with a lower z is causing
        // problems with alpha blending.
        //
        const background_quads: renderer.VertexRange = renderer.reserveQuads(2);

        const title_margin_top: f32 = 5.0 * screen_scale.vertical;
        const title_height = 40.0 * screen_scale.vertical;
        const title_extent = Extent3D(f32){
            .x = placement.x,
            .y = placement.y + title_height + title_margin_top,
            .z = placement.z,
            .width = width,
            .height = item_height,
        };
        const title_label_color = RGBA(u8).white;
        _ = renderer.drawText(self.title, title_extent, screen_scale, .medium, .regular, title_label_color, .center);

        const entry_left_margin: f32 = 15.0 * screen_scale.horizontal;
        const category_y_offset: f32 = 25.0 * screen_scale.vertical;
        const entry_y_offset: f32 = 30.0 * screen_scale.vertical;
        const category_label_color = RGBA(u8).fromInt(200, 200, 200, 255);
        const entry_label_color = RGBA(u8).fromInt(220, 220, 220, 255);
        const category_line_color = RGBA(u8).fromInt(200, 200, 200, 255);

        self.mouse_event_slots = event_system.reserveMouseEventSlots(@as(u16, @intCast(self.entry_labels.len)));

        const title_margin_bottom: f32 = 10.0 * screen_scale.vertical;
        var current_y: f32 = placement.y + title_height + category_y_offset + title_margin_bottom;

        for (self.categories, 0..) |category_label, category_index| {
            const category_label_extent = Extent3D(f32){
                .x = placement.x,
                .y = current_y,
                .z = placement.z,
                .width = width,
                .height = item_height,
            };
            const result = renderer.drawText(category_label, category_label_extent, screen_scale, .small, .regular, category_label_color, .center);
            current_y += category_y_offset;

            const rendered_extent = result.written_extent;

            const line_margin_text: f32 = 10.0 * screen_scale.horizontal;
            const line_margin_border: f32 = 10.0 * screen_scale.horizontal;
            const line_height: f32 = 1.0 * screen_scale.vertical;
            {
                const line_end_x: f32 = rendered_extent.x - line_margin_text;
                const line_start_x: f32 = placement.x + line_margin_border;
                const left_line_extent = Extent3D(f32){
                    .x = line_start_x,
                    .y = rendered_extent.y - (rendered_extent.height / 3.0),
                    .z = placement.z,
                    .width = line_end_x - line_start_x,
                    .height = line_height,
                };
                _ = renderer.drawQuad(left_line_extent, category_line_color, .bottom_left);
            }
            {
                const line_end_x: f32 = rendered_extent.x + rendered_extent.width + line_margin_text;
                const line_start_x: f32 = placement.x + width - line_margin_border;
                const right_line_extent = Extent3D(f32){
                    .x = line_start_x,
                    .y = rendered_extent.y - (rendered_extent.height / 3.0),
                    .z = placement.z,
                    .width = line_end_x - line_start_x,
                    .height = line_height,
                };
                _ = renderer.drawQuad(right_line_extent, category_line_color, .bottom_left);
            }

            for (self.entry_categories[0..self.entry_labels.len], 0..) |entry_category, entry_index| {
                if (entry_category == category_index) {
                    current_y += 5.0 * screen_scale.vertical;
                    const entry_label_extent = Extent3D(f32){
                        .x = placement.x + entry_left_margin,
                        .y = current_y,
                        .z = placement.z,
                        .width = width,
                        .height = item_height,
                    };
                    const entry_label = self.entry_labels[entry_index];
                    _ = renderer.drawText(entry_label, entry_label_extent, screen_scale, .small, .regular, entry_label_color, .middle_left);
                    current_y += entry_y_offset;

                    const label_background_extent = Extent3D(f32){
                        .x = placement.x,
                        .y = entry_label_extent.y,
                        .z = entry_label_extent.z,
                        .width = width,
                        .height = item_height,
                    };
                    self.vertex_index_buffer[entry_index] = renderer.drawQuad(label_background_extent, self.label_background, .bottom_left);
                    event_system.overwriteMouseEventSlot(&self.mouse_event_slots.get()[entry_index], label_background_extent, .{});
                }
            }
        }

        const border_extent = Extent3D(f32){
            .x = placement.x,
            .y = placement.y,
            .z = placement.z,
            .width = width,
            .height = current_y - placement.y - entry_y_offset,
        };
        const border_width: f32 = 1.0 * screen_scale.horizontal;
        const border_height: f32 = 1.0 * screen_scale.vertical;
        const background_extent = Extent3D(f32){
            .x = border_extent.x + border_width,
            .y = border_extent.y + border_height,
            .z = border_extent.z,
            .width = border_extent.width - (border_width * 2.0),
            .height = border_extent.height - (border_height * 2.0),
        };
        const border_color = RGBA(u8).black;
        renderer.overwriteQuad(background_quads.start, border_extent, border_color, .top_left);
        renderer.overwriteQuad(background_quads.start + 4, background_extent, self.background_color, .top_left);

        //
        // We have to convert top_left to bottom_left :|
        //
        const mouse_extent = Extent3D(f32){
            .x = border_extent.x,
            .y = border_extent.y + border_extent.height,
            .z = border_extent.z,
            .width = border_extent.width,
            .height = border_extent.height,
        };
        self.background_extent_slot = event_system.writeMouseEventSlot(mouse_extent, .{ .invert = true, .enable_hover = false });
    }
};

pub const ListSelectPopup = struct {
    const max_label_count = 3;

    title: []const u8,
    label_buffer: [max_label_count][]const u8,
    label_count: u16,
    border_color: RGBA(u8),
    background_color: RGBA(u8),
    entry_background_color: RGBA(u8),
    entry_background_hovered_color: RGBA(u8),

    vertex_index_buffer: [max_label_count]u16,
    mouse_event_slots: mini_heap.SliceIndex(MouseEventEntry),

    pub fn init(self: *@This()) void {
        self.label_count = 0;
        self.vertex_index_buffer = [1]u16{std.math.maxInt(u16)} ** max_label_count;
    }

    pub fn draw(
        self: *@This(),
        placement: Coordinates3D(f32),
        width: f32,
        item_height: f32,
        screen_scale: ScaleFactor2D(f32),
    ) void {
        const title_height = 40.0 * screen_scale.vertical;
        const height = title_height + @as(f32, @floatFromInt(self.label_count)) * item_height;
        const border_extent = Extent3D(f32){
            .x = placement.x,
            .y = placement.y,
            .z = placement.z,
            .width = width,
            .height = height,
        };
        _ = renderer.drawQuad(border_extent, self.border_color, .top_left);

        const border_thickness_pixels: f32 = 1.0;
        const border_h: f32 = border_thickness_pixels * screen_scale.horizontal;
        const border_v: f32 = border_thickness_pixels * screen_scale.vertical;
        const background_extent = Extent3D(f32){
            .x = placement.x + border_h,
            .y = placement.y + border_v,
            .z = placement.z,
            .width = width - (border_h * 2.0),
            .height = height - (border_v * 2.0),
        };
        _ = renderer.drawQuad(background_extent, self.background_color, .top_left);

        const title_extent = Extent3D(f32){
            .x = placement.x,
            .y = placement.y + title_height,
            .z = placement.z,
            .width = width,
            .height = item_height,
        };
        const title_label_color = RGBA(u8).white;
        _ = renderer.drawText(self.title, title_extent, screen_scale, .medium, .regular, title_label_color, .center);

        const entry_left_margin: f32 = 15.0 * screen_scale.horizontal;
        const entry_label_color = RGBA(u8).fromInt(220, 220, 220, 255);

        self.mouse_event_slots = event_system.reserveMouseEventSlots(@as(u16, @intCast(self.label_count)));

        var current_y: f32 = placement.y + title_height + item_height;
        for (self.label_buffer[0..self.label_count], 0..) |label, i| {
            const entry_label_extent = Extent3D(f32){
                .x = placement.x + entry_left_margin,
                .y = current_y,
                .z = placement.z,
                .width = width,
                .height = item_height,
            };
            _ = renderer.drawText(label, entry_label_extent, screen_scale, .small, .regular, entry_label_color, .middle_left);
            current_y += item_height;

            const label_background_extent = Extent3D(f32){
                .x = placement.x,
                .y = entry_label_extent.y,
                .z = entry_label_extent.z,
                .width = width,
                .height = item_height,
            };
            self.vertex_index_buffer[i] = renderer.drawQuad(label_background_extent, self.entry_background_color, .bottom_left);
            event_system.overwriteMouseEventSlot(&self.mouse_event_slots.get()[i], label_background_extent, .{});
        }
    }

    const Response = struct {
        item_clicked: ?u8 = null,
        visual_change: bool = false,
    };

    pub fn update(self: *@This()) Response {
        var response = Response{};
        if (self.vertex_index_buffer[0] == std.math.maxInt(u16))
            return response;

        for (self.mouse_event_slots.get()[0..self.label_count], 0..) |*event, i| {
            const state_copy = event.state;
            event.state.clear();
            if (state_copy.hover_enter) {
                var quad_ptr = renderer.quad(self.vertex_index_buffer[i]);
                quad_ptr[0].color = self.entry_background_hovered_color;
                quad_ptr[1].color = self.entry_background_hovered_color;
                quad_ptr[2].color = self.entry_background_hovered_color;
                quad_ptr[3].color = self.entry_background_hovered_color;
                response.visual_change = true;
            }
            if (state_copy.hover_exit) {
                var quad_ptr = renderer.quad(self.vertex_index_buffer[i]);
                quad_ptr[0].color = self.entry_background_color;
                quad_ptr[1].color = self.entry_background_color;
                quad_ptr[2].color = self.entry_background_color;
                quad_ptr[3].color = self.entry_background_color;
                response.visual_change = true;
            }

            if (state_copy.left_click_press) {
                response.item_clicked = @intCast(i);
            }
        }

        return response;
    }
};

pub const TabbedSection = struct {
    const max_label_count = 8;

    headings: []const []const u8,
    active_index: u16,

    mouse_event_slots: mini_heap.SliceIndex(event_system.MouseEventEntry),
    vertex_index_buffer: [max_label_count]u16,

    pub fn init(
        self: *@This(),
        headings: []const []const u8,
    ) void {
        assert(headings.len <= max_label_count);
        self.vertex_index_buffer = [1]u16{std.math.maxInt(u16)} ** max_label_count;
        self.headings = headings;
        self.active_index = 0;
    }

    pub const Response = struct {
        tab_index: ?u16 = null,
        visual_change: bool = false,
    };

    pub fn update(self: *@This()) Response {
        var response: Response = .{};
        for (self.mouse_event_slots.get(), 0..) |*event, i| {
            const state_copy = event.state;
            event.state.clear();

            // if (state_copy.hover_enter) {
            //     var quad_ptr = renderer.quad(self.vertex_index_buffer[i]);
            //     quad_ptr[0].color = color_hovered;
            //     quad_ptr[1].color = color_hovered;
            //     quad_ptr[2].color = color_hovered;
            //     quad_ptr[3].color = color_hovered;
            //     response.visual_change = true;
            // }
            // if (state_copy.hover_exit) {
            //     var quad_ptr = renderer.quad(self.vertex_index_buffer[i]);
            //     quad_ptr[0].color = color_normal;
            //     quad_ptr[1].color = color_normal;
            //     quad_ptr[2].color = color_normal;
            //     quad_ptr[3].color = color_normal;
            //     response.visual_change = true;
            // }

            if (state_copy.left_click_press) {
                if (self.active_index != i) {
                    self.active_index = @intCast(i);
                    response.tab_index = self.active_index;
                }
            }
        }
        return response;
    }

    pub fn draw(
        self: *@This(),
        extent: Extent3D(f32),
        screen_scale: ScaleFactor2D(f32),
    ) void {
        if (screen_scale.horizontal == 0 or screen_scale.vertical == 0)
            return;

        const border_pixels: f32 = 1.0;
        const border_h: f32 = border_pixels * screen_scale.horizontal;
        const border_v: f32 = border_pixels * screen_scale.vertical;

        const bar_height: f32 = 30.0 * screen_scale.vertical;

        const box_height: f32 = bar_height - (border_v * 2.0);
        const box_width: f32 = 160.0 * screen_scale.horizontal;

        const anchor_top: f32 = extent.y - extent.height;
        const box_bottom: f32 = anchor_top + bar_height - border_v;

        const topbar_extent = Extent3D(f32){
            .x = extent.x,
            .y = anchor_top + bar_height,
            .z = extent.z,
            .width = extent.width,
            .height = bar_height,
        };
        _ = renderer.drawQuad(topbar_extent, RGBA(u8).fromInt(57, 59, 63, 255), .bottom_left);

        self.mouse_event_slots = event_system.reserveMouseEventSlots(@intCast(self.headings.len));

        var current_x_offset: f32 = extent.x;
        for (self.headings, self.mouse_event_slots.get(), 0..) |title, *mouse_slot, i| {
            const box_extent = Extent3D(f32){
                .x = current_x_offset + border_h,
                .y = box_bottom,
                .z = extent.z,
                .width = box_width,
                .height = box_height,
            };

            const background_color = if (i == self.active_index)
                RGBA(u8).fromInt(23, 23, 23, 200)
            else
                RGBA(u8).fromInt(23, 23, 23, 100);

            self.vertex_index_buffer[i] = renderer.drawQuad(box_extent, background_color, .bottom_left);

            const text_extent = Extent3D(f32){
                .x = current_x_offset + border_h,
                .y = box_bottom,
                .z = extent.z,
                .width = box_width,
                .height = box_height,
            };
            event_system.overwriteMouseEventSlot(mouse_slot, box_extent, .{ .enable_hover = true });

            _ = renderer.drawText(title, text_extent, screen_scale, .medium, .regular, RGBA(u8).white, .center);

            current_x_offset += (box_width + border_h);
        }
    }
};

// pub const Section = struct {
//     pub fn draw(
//         extent: Extent3D(f32),
//         title: []const u8,
//         screen_scale: ScaleFactor2D(f32),
//         border_color: graphics.RGBA(u8),
//         border_width: f32,
//     ) !void {
//         const rendered_text_dimensions: Dimensions2D(f32) = .{
//             .width = 200,
//             .height = 40,
//         };
//         const text_margin_horizontal: f32 = 20;
//         const text_width: f32 = @floatCast(f32, (text_margin_horizontal + rendered_text_dimensions.width) * screen_scale.horizontal);
//         const margin_left: f32 = @floatCast(f32, 15.0 * screen_scale.horizontal);

//         //
//         // This doesn't need to match the text height, as it will be centered. It just needs to be higher
//         //
//         const title_extent_height = @floatCast(f32, (rendered_text_dimensions.height + 20) * screen_scale.vertical);

//         const title_extent = geometry.Extent3D(f32){
//             .x = extent.x + margin_left,
//             .y = (extent.y - extent.height) + (title_extent_height / 2.0),
//             .z = extent.z,
//             .width = text_width,
//             .height = title_extent_height,
//         };

//         _ = renderer.drawText(title, title_extent, screen_scale, .small, RGBA(u8).white, .middle, .middle);

//         const extent_left = Extent3D(f32){
//             .x = extent.x,
//             .y = extent.y,
//             .z = extent.z,
//             .width = border_width,
//             .height = extent.height,
//         };
//         const extent_right = Extent3D(f32){
//             .x = extent.x + extent.width - border_width,
//             .y = extent.y,
//             .z = extent.z,
//             .width = border_width,
//             .height = extent.height,
//         };
//         const extent_top_left = Extent3D(f32){
//             .x = extent.x + border_width,
//             .y = (extent.y - extent.height) + border_width,
//             .z = extent.z,
//             .width = margin_left,
//             .height = border_width,
//         };
//         const extent_top_right = Extent3D(f32){
//             .x = extent.x + border_width + text_width + margin_left,
//             .y = (extent.y - extent.height) + border_width,
//             .z = extent.z,
//             .width = extent.width - (border_width * 2 + text_width + margin_left),
//             .height = border_width,
//         };
//         const extent_bottom = Extent3D(f32){
//             .x = extent.x + border_width,
//             .y = extent.y,
//             .z = extent.z,
//             .width = extent.width - (border_width * 2),
//             .height = border_width,
//         };

//         _ = renderer.drawQuad(extent_left, border_color, .bottom_left);
//         _ = renderer.drawQuad(extent_right, border_color, .bottom_left);
//         _ = renderer.drawQuad(extent_top_left, border_color, .bottom_left);
//         _ = renderer.drawQuad(extent_top_right, border_color, .bottom_left);
//         _ = renderer.drawQuad(extent_bottom, border_color, .bottom_left);
//     }
// };

pub const Dropdown = struct {
    const max_label_count = 8;

    const Model = struct {
        is_open: bool,
        selected_index: u16,
        labels: []const []const u8,
    };
    model: Model,

    mouse_event_slot: mini_heap.Index(event_system.MouseEventEntry),
    mouse_event_slots: mini_heap.SliceIndex(event_system.MouseEventEntry),
    vertex_index_buffer: [max_label_count]u16,

    outer_vertex_range: renderer.VertexRange,
    inner_vertex_range: renderer.VertexRange,

    background_color: RGBA(u8),
    background_color_hovered: RGBA(u8),
    accent_color: RGBA(u8),

    pub fn init(self: *@This()) void {
        self.model = .{
            .is_open = false,
            .selected_index = 0,
            .labels = undefined,
        };
        self.vertex_index_buffer = [1]u16{std.math.maxInt(u16)} ** max_label_count;
    }

    pub const Response = struct {
        visual_change: bool = false,
        active_index: ?u16 = null,
        redraw: bool = false,
    };

    pub inline fn update(self: *@This()) Response {
        var response = Response{};
        if (self.outer_vertex_range.start == std.math.maxInt(u16))
            return response;

        const state_copy = self.mouse_event_slot.get().state;
        self.mouse_event_slot.getPtr().state.clear();

        if (state_copy.hover_enter) {
            renderer.updateQuadRangeColor(self.inner_vertex_range.start, @divExact(self.inner_vertex_range.count, 4), self.background_color_hovered);
            response.visual_change = true;
        } else if (state_copy.hover_exit) {
            renderer.updateQuadRangeColor(self.inner_vertex_range.start, @divExact(self.inner_vertex_range.count, 4), self.background_color);
            response.visual_change = true;
        }

        if (self.model.is_open) {
            for (self.mouse_event_slots.get(), 0..self.model.labels.len) |*event, i| {
                const item_state_copy = event.state;
                event.state.clear();
                if (item_state_copy.hover_enter) {
                    var quad_ptr = renderer.quad(self.vertex_index_buffer[i]);
                    quad_ptr[0].color = self.background_color_hovered;
                    quad_ptr[1].color = self.background_color_hovered;
                    quad_ptr[2].color = self.background_color_hovered;
                    quad_ptr[3].color = self.background_color_hovered;
                    response.visual_change = true;
                }
                if (item_state_copy.hover_exit) {
                    var quad_ptr = renderer.quad(self.vertex_index_buffer[i]);
                    quad_ptr[0].color = self.background_color;
                    quad_ptr[1].color = self.background_color;
                    quad_ptr[2].color = self.background_color;
                    quad_ptr[3].color = self.background_color;
                    response.visual_change = true;
                }

                if (item_state_copy.left_click_press) {
                    self.model.selected_index = @intCast(i);
                    response.active_index = self.model.selected_index;
                    self.model.is_open = false;
                    std.log.info("Item selected: {d}", .{i});
                }
            }
        }

        if (state_copy.left_click_press) {
            self.model.is_open = !self.model.is_open;
            response.redraw = true;
        }

        return response;
    }

    pub fn draw(
        self: *@This(),
        extent: Extent3D(f32),
        screen_scale: ScaleFactor2D(f32),
    ) void {
        const rounding_radius_pixels = 5.0;
        const rounding_radius = Radius2D(f32){
            .h = rounding_radius_pixels * screen_scale.horizontal,
            .v = rounding_radius_pixels * screen_scale.vertical,
        };
        self.outer_vertex_range = renderer.drawRoundedRect(extent, self.accent_color, .bottom_left, rounding_radius, 8);

        const border_width_pixels = 1.0;
        const border_width_h: f32 = border_width_pixels * screen_scale.horizontal;
        const border_width_v: f32 = border_width_pixels * screen_scale.vertical;
        const inner_extent = Extent3D(f32){
            .x = extent.x + border_width_h,
            .y = extent.y - border_width_v,
            .z = extent.z,
            .width = extent.width - (border_width_h * 2.0),
            .height = extent.height - (border_width_v * 2.0),
        };
        const inner_rounding_radius_pixels = rounding_radius_pixels - border_width_pixels;
        const inner_rounding_radius = Radius2D(f32){
            .h = inner_rounding_radius_pixels * screen_scale.horizontal,
            .v = inner_rounding_radius_pixels * screen_scale.vertical,
        };
        self.inner_vertex_range = renderer.drawRoundedRect(inner_extent, self.background_color, .bottom_left, inner_rounding_radius, 8);

        const label_extent = Extent3D(f32){
            .x = extent.x,
            .y = extent.y,
            .z = extent.z,
            .width = extent.width * 0.7,
            .height = extent.height,
        };
        self.mouse_event_slot = event_system.writeMouseEventSlot(extent, .{});

        const active_label = self.model.labels[self.model.selected_index];
        _ = renderer.drawText(active_label, label_extent, screen_scale, .small, .regular, RGBA(u8).white, .center);

        const triangle_height: f32 = extent.height / 4.0;
        const triangle_height_pixels = triangle_height / screen_scale.vertical;
        const triangle_width: f32 = (triangle_height_pixels * 1.5) * screen_scale.horizontal;
        const triangle_left: f32 = extent.x + (extent.width * 0.75);
        const triangle_bottom: f32 = extent.y - (extent.height * 0.33);

        {
            const triangle_color = graphics.RGBA(u8).fromInt(200, 200, 200, 255);
            var p0: Coordinates2D(f32) = undefined;
            var p1: Coordinates2D(f32) = undefined;
            var p2: Coordinates2D(f32) = undefined;
            p0.x = triangle_left;
            p0.y = triangle_bottom - triangle_height;
            p1.x = triangle_left + triangle_width;
            p1.y = triangle_bottom - triangle_height;
            p2.x = triangle_left + (triangle_width / 2.0);
            p2.y = triangle_bottom;
            _ = renderer.drawTriangle(p0, p1, p2, 0.0, triangle_color);
        }

        if (self.model.is_open) {
            const vertical_gap_pixels = 1.0;
            const vertical_gap = vertical_gap_pixels * screen_scale.vertical;
            const item_height = extent.height - vertical_gap;
            const vertical_stride = item_height + vertical_gap;
            self.mouse_event_slots = event_system.reserveMouseEventSlots(@intCast(self.model.labels.len));
            for (self.model.labels, self.mouse_event_slots.get(), 0..) |label, *slot, i| {
                const item_extent = Extent3D(f32){
                    .x = extent.x,
                    .y = extent.y + (vertical_stride * @as(f32, @floatFromInt(i + 1))),
                    .z = extent.z,
                    .width = extent.width,
                    .height = item_height,
                };
                event_system.overwriteMouseEventSlot(slot, item_extent, .{});
                self.vertex_index_buffer[i] = renderer.drawQuad(item_extent, self.background_color, .bottom_left);
                _ = renderer.drawText(label, item_extent, screen_scale, .small, .regular, RGBA(u8).white, .center);
            }
        }
    }
};

// pub const Checkbox = packed struct(u32) {
//     state_index: Index(HoverZoneState),
//     extent_index: Index(geometry.Extent3D(f32)),

//     pub fn create() !@This() {
//         const state_index = event_system.reserveState();
//         state_index.getPtr().reset();
//         return @This(){
//             .state_index = state_index,
//             .extent_index = .{ .index = std.math.maxInt(u16) },
//         };
//     }

//     pub fn draw(
//         self: *@This(),
//         center: geometry.Coordinates2D(f32),
//         radius_pixels: f32,
//         screen_scale: ScaleFactor2D(f32),
//         color: graphics.RGBA(u8),
//         is_checked: bool,
//     ) !void {
//         const grey = graphics.RGB(f32).fromInt(120, 120, 120);

//         try graphics.drawCircle(
//             center,
//             radius_pixels,
//             grey.toRGBA(),
//             screen_scale,
//             face_writer_ref,
//         );

//         if (is_checked) {
//             try graphics.drawCircle(
//                 center,
//                 radius_pixels / 2.0,
//                 color,
//                 screen_scale,
//                 face_writer_ref,
//             );
//         }

//         //
//         // Style #2
//         //

//         // if(!is_checked) {
//         //     try drawCircle(
//         //         center,
//         //         radius_pixels,
//         //         screen_scale,
//         //         grey.toRGBA(),
//         //     );
//         // } else {
//         //     try drawCircle(
//         //         center,
//         //         radius_pixels,
//         //         screen_scale,
//         //         color,
//         //     );
//         //     try drawCircle(
//         //         center,
//         //         radius_pixels / 3,
//         //         screen_scale,
//         //         grey.toRGBA(),
//         //     );
//         // }

//         const radius_h: f64 = radius_pixels * screen_scale.horizontal;
//         const radius_v: f64 = radius_pixels * screen_scale.vertical;

//         const extent = geometry.Extent3D(f32){
//             .x = @floatCast(f32, center.x - radius_h),
//             .y = @floatCast(f32, center.y + radius_v),
//             .width = @floatCast(f32, radius_h * 2),
//             .height = @floatCast(f32, radius_v * 2),
//         };

//         event_system.bindStateToMouseEvent(
//             self.state_index,
//             extent,
//             &self.extent_index,
//             .{
//                 .enable_hover = true,
//                 .start_active = false,
//             },
//         );
//     }

//     pub inline fn clicked(self: @This()) bool {
//         return self.state().left_click_press;
//     }

//     pub inline fn state(self: @This()) HoverZoneState {
//         const state_copy = self.state_index.get();
//         self.state_index.getPtr().clear();
//         return state_copy;
//     }
// };

pub const Button = struct {
    vertex_index: u16,
    vertex_count: u16,
    color: graphics.RGBA(u8),
    color_hovered: graphics.RGBA(u8),
    text_color: graphics.RGBA(u8),
    label: []const u8,
    mouse_event_slot: mini_heap.Index(event_system.MouseEventEntry),

    pub const DrawOptions = struct {
        rounding_radius: ?f32 = null,
    };

    pub fn init(self: *@This()) void {
        self.vertex_index = std.math.maxInt(u16);
    }

    pub fn draw(
        self: *@This(),
        extent: Extent3D(f32),
        screen_scale: ScaleFactor2D(f32),
        comptime options: DrawOptions,
    ) void {
        if (comptime options.rounding_radius) |rounding_radius| {
            const radius = Radius2D(f32){ .h = rounding_radius * screen_scale.horizontal, .v = rounding_radius * screen_scale.vertical };
            const vertex_range = renderer.drawRoundedRect(
                extent,
                self.color,
                .bottom_left,
                radius,
                @max(8, @as(u16, @intFromFloat(@floor(rounding_radius)))),
            );
            self.vertex_index = vertex_range.start;
            self.vertex_count = vertex_range.count;
        } else {
            self.vertex_count = 4;
            self.vertex_index = renderer.drawQuad(extent, self.color, .bottom_left);
        }
        _ = renderer.drawText(self.label, extent, screen_scale, .medium, .regular, self.text_color, .center);
        self.mouse_event_slot = event_system.writeMouseEventSlot(extent, .{});
    }

    pub const Response = struct {
        clicked: bool = false,
        modified: bool = false,
    };

    pub inline fn update(self: @This()) Response {
        if (self.vertex_index == std.math.maxInt(u16))
            return .{ .clicked = false, .modified = false };

        const state_copy = self.mouse_event_slot.get().state;
        assert(self.mouse_event_slot.index % @alignOf(MouseEventEntry) == 0);
        self.mouse_event_slot.getPtr().state.clear();
        var modified: bool = false;

        if (state_copy.hover_enter) {
            renderer.updateQuadRangeColor(self.vertex_index, @divExact(self.vertex_count, 4), self.color_hovered);
            modified = true;
        } else if (state_copy.hover_exit) {
            renderer.updateQuadRangeColor(self.vertex_index, @divExact(self.vertex_count, 4), self.color);
            modified = true;
        }
        return .{ .clicked = state_copy.left_click_press, .modified = modified };
    }

    // pub inline fn state(self: @This()) HoverZoneState {
    //     const state_copy = self.state_index.get();
    //     self.state_index.getPtr().clear();
    //     return state_copy;
    // }

    // pub inline fn statePtr(self: @This()) *HoverZoneState {
    //     return self.state_index.getPtr();
    // }

    // pub fn setColor(self: @This(), color: graphics.RGBA(u8)) void {
    //     for (renderer.vertexSlice(self.vertex_index, self.vertex_count)) |*vertex| {
    //         vertex.color = color;
    //     }
    // }
};

pub const IconButton = struct {
    mouse_event_slot: Index(MouseEventEntry),

    icon_vertex_index: u16,
    background_vertex_index: u16,
    on_hover_background_color: RGBA(u8),
    on_hover_icon_color: RGBA(u8),
    background_color: RGBA(u8),
    icon_color: RGBA(u8),
    icon: renderer.Icon,

    pub fn init(self: *@This()) void {
        self.icon_vertex_index = std.math.maxInt(u16);
    }

    pub fn draw(
        self: *@This(),
        placement: Coordinates3D(f32),
        margin_pixels: f32,
        screen_scale: ScaleFactor2D(f32),
    ) void {
        const margin_h: f32 = margin_pixels * screen_scale.horizontal;
        const margin_v: f32 = margin_pixels * screen_scale.vertical;
        const icon_size_pixels: f32 = switch (self.icon) {
            .add_circle_24px => 24.0,
            .delete_16px => 16.0,
            else => 32.0,
        };
        const icon_width: f32 = icon_size_pixels * screen_scale.horizontal;
        const icon_height: f32 = icon_size_pixels * screen_scale.vertical;
        const background_extent = Extent3D(f32){
            .x = placement.x,
            .y = placement.y,
            .z = placement.z,
            .width = icon_width + (margin_h * 2.0),
            .height = icon_height + (margin_v * 2.0),
        };
        const icon_placement = Coordinates3D(f32){
            .x = placement.x + margin_h,
            .y = placement.y - margin_v,
            .z = placement.z,
        };

        self.background_vertex_index = renderer.drawQuad(background_extent, self.background_color, .bottom_left);
        self.icon_vertex_index = renderer.drawIcon(icon_placement, self.icon, screen_scale, self.icon_color, .bottom_left);

        const hover_extent = Extent3D(f32){
            .x = icon_placement.x,
            .y = icon_placement.y,
            .z = icon_placement.z,
            .width = icon_width,
            .height = icon_height,
        };

        self.mouse_event_slot = event_system.writeMouseEventSlot(hover_extent, .{});
        assert(self.mouse_event_slot.index % @alignOf(MouseEventEntry) == 0);
    }

    pub const IconButtonUpdate = struct {
        clicked: bool = false,
        modified: bool = false,
    };

    pub inline fn update(self: *@This()) IconButtonUpdate {
        if (self.icon_vertex_index == std.math.maxInt(u16))
            return .{ .clicked = false, .modified = false };

        const state_copy = self.mouse_event_slot.get().state;
        assert(self.mouse_event_slot.index % @alignOf(MouseEventEntry) == 0);
        self.mouse_event_slot.getPtr().state.clear();
        var modified: bool = false;

        if (state_copy.hover_enter) {
            renderer.updateIconColor(self.icon_vertex_index, self.on_hover_icon_color);
            renderer.updateQuadColor(self.background_vertex_index, self.on_hover_background_color);
            modified = true;
        } else if (state_copy.hover_exit) {
            renderer.updateIconColor(self.icon_vertex_index, self.icon_color);
            renderer.updateQuadColor(self.background_vertex_index, self.background_color);
            modified = true;
        }
        return .{ .clicked = state_copy.left_click_press, .modified = modified };
    }

    inline fn setIconColor(self: @This(), color: graphics.RGBA(u8)) void {
        for (renderer.vertexSlice(self.vertex_index, 4)) |*vertex| {
            vertex.color = color;
        }
    }
};
