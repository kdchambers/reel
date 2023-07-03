// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const geometry = @import("../../../geometry.zig");
const Extent2D = geometry.Extent2D;
const Extent3D = geometry.Extent3D;
const ScaleFactor2D = geometry.ScaleFactor2D;
const Coordinates2D = geometry.Coordinates2D;

const graphics = @import("../../../graphics.zig");
const Vertex = graphics.GenericVertex;
const FaceWriter = graphics.FaceWriter;
const QuadFace = graphics.QuadFace;
const RGBA = graphics.RGBA;

const renderer = @import("../../../renderer.zig");
const frontend = @import("../../wayland.zig");

const overlay_color = RGBA(u8){ .r = 0, .b = 0, .g = 0, .a = 125 };

const bar_height_pixels = 2;

vertex_index: u16,
extent: geometry.Extent3D(f32),
bar_height: f32,
value_vertex_range: renderer.VertexRange,
value_extent: Extent3D(f32),

pub fn init(self: *@This()) void {
    _ = self;
}

inline fn decibelToPercent(decibels: f64) f64 {
    const decibel_range_min = 6.0;
    const decibel_range_max = 3.0;
    const decibel_range_total = decibel_range_max - decibel_range_min;
    return @max(@min((-decibels - decibel_range_min) / decibel_range_total, 1.0), 0.0);
}

pub fn update(self: *@This(), decibels: f64, screen_scale: ScaleFactor2D(f32)) void {
    const percentage = decibelToPercent(decibels);
    const overlay_extent = geometry.Extent3D(f32){
        .x = self.extent.x + @as(f32, @floatCast(self.extent.width * percentage)),
        .y = self.extent.y,
        .z = self.extent.z,
        .width = self.extent.width * @as(f32, @floatCast(1.0 - percentage)),
        .height = self.bar_height,
    };
    renderer.overwriteQuad(self.vertex_index, overlay_extent, overlay_color, .bottom_left);

    var value_string_buffer: [4]u8 = undefined;
    const value_string: []const u8 = std.fmt.bufPrint(&value_string_buffer, "{d:.0}db", .{decibels}) catch "";
    if (value_string.len > 0) {
        renderer.overwriteText(
            self.value_vertex_range,
            value_string,
            self.value_extent,
            screen_scale,
            .small,
            .regular,
            RGBA(u8).white,
            .top_right,
        );
    }

    frontend.requestRender();
}

pub fn draw(self: *@This(), extent: geometry.Extent3D(f32), screen_scale: ScaleFactor2D(f32)) void {
    const title_text_height = 40.0 * screen_scale.vertical;
    const title_extent = Extent3D(f32){
        .x = extent.x,
        .y = extent.y - extent.height + title_text_height,
        .z = extent.z,
        .width = 120.0 * screen_scale.horizontal,
        .height = title_text_height,
    };
    _ = renderer.drawText(
        "Scene Volume",
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
    self.value_vertex_range = renderer.reserveTextBuffer(4);

    const percentage = 1.0;
    self.extent = extent;
    self.bar_height = bar_height_pixels * screen_scale.vertical;
    const background_extent = geometry.Extent3D(f32){
        .x = self.extent.x,
        .y = self.extent.y,
        .z = extent.z,
        .width = self.extent.width,
        .height = self.bar_height,
    };
    const color_from = graphics.RGBA(u8).fromInt(25, 255, 35, 255);
    const color_to = graphics.RGBA(u8).fromInt(255, 35, 35, 255);
    const colors = [4]graphics.RGBA(u8){ color_from, color_to, color_to, color_from };
    _ = renderer.drawQuadMultiColor(background_extent, colors, .bottom_left);

    const overlay_extent = geometry.Extent3D(f32){
        .x = self.extent.x + @as(f32, @floatCast(self.extent.width * percentage)),
        .y = self.extent.y,
        .z = extent.z,
        .width = self.extent.width * @as(f32, @floatCast(1.0 - percentage)),
        .height = self.bar_height,
    };
    self.vertex_index = renderer.drawQuad(overlay_extent, overlay_color, .bottom_left);
}
