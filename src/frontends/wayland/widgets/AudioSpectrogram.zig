// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

// TODO: This is just a bar graph..

const std = @import("std");
const assert = std.debug.assert;
const geometry = @import("../../../geometry.zig");
const Extent2D = geometry.Extent2D;
const ScaleFactor2D = geometry.ScaleFactor2D;
const Coordinates2D = geometry.Coordinates2D;

const graphics = @import("../../../graphics.zig");
const Vertex = graphics.GenericVertex;
const FaceWriter = graphics.FaceWriter;
const QuadFace = graphics.QuadFace;
const RGBA = graphics.RGBA;

const bar_color_from = graphics.RGBA(f32).fromInt(50, 100, 65, 255);
const bar_color_to = graphics.RGBA(f32).fromInt(250, 0, 0, 255);

// TODO: Remove
const root = @import("base.zig");

vertex_index: u16,
bin_count: u16,
height_pixels: f32,
min_cutoff_db: f32,
max_cutoff_db: f32,

pub fn draw(
    self: *@This(),
    freq_bins: []const f32,
    extent: geometry.Extent2D(f32),
    screen_scale: ScaleFactor2D(f32),
) !void {
    self.bin_count = @intCast(u16, freq_bins.len);
    self.height_pixels = extent.height / screen_scale.vertical;

    const bar_width: f32 = extent.width / (@intToFloat(f32, self.bin_count) * 2.0);
    const bar_spacing = (extent.width - (bar_width * @intToFloat(f32, self.bin_count))) / @intToFloat(f32, self.bin_count + 1);
    const bar_increment: f32 = bar_width + bar_spacing;

    const volume_range_db: f32 = self.max_cutoff_db - self.min_cutoff_db;
    assert(volume_range_db >= 0);

    self.vertex_index = root.face_writer_ref.vertices_used;
    var quads = try root.face_writer_ref.allocate(QuadFace, self.bin_count);
    for (freq_bins, quads, 0..) |freq_value, *quad, i| {
        const db_clamped = @min(self.max_cutoff_db, @max(self.min_cutoff_db, freq_value));
        const percentage = (db_clamped + (-self.min_cutoff_db)) / volume_range_db;
        assert(percentage >= 0.0);
        assert(percentage <= 1.0);

        const bar_height = percentage * extent.height;
        const bar_extent = Extent2D(f32){
            .x = extent.x + (@intToFloat(f32, i) * bar_increment),
            .y = extent.y,
            .width = bar_width,
            .height = bar_height,
        };
        quad.* = graphics.quadColored(bar_extent, bar_color_from, .bottom_left);
        const bar_color_top = graphics.RGBA(f32){
            .r = lerp(bar_color_from.r, bar_color_to.r, percentage),
            .g = lerp(bar_color_from.g, bar_color_to.g, percentage),
            .b = lerp(bar_color_from.b, bar_color_to.b, percentage),
            .a = 1.0,
        };
        quad.*[0].color = bar_color_top;
        quad.*[1].color = bar_color_top;
    }
}

pub fn update(self: *@This(), freq_bins: []f32, screen_scale: ScaleFactor2D(f32)) !void {
    assert(freq_bins.len == self.bin_count);
    var quads = @ptrCast([*]QuadFace, &root.vertices_buffer_ref[self.vertex_index]);
    const height = self.height_pixels * screen_scale.vertical;
    var i: usize = 0;
    const y_lower = quads[i][2].y;
    assert(y_lower == quads[i][3].y);

    const volume_range_db: f32 = self.max_cutoff_db - self.min_cutoff_db;
    assert(volume_range_db >= 0);

    while (i < self.bin_count) : (i += 1) {
        const freq_value = freq_bins[i];
        const db_clamped = @min(self.max_cutoff_db, @max(self.min_cutoff_db, freq_value));
        const percentage = (db_clamped + (-self.min_cutoff_db)) / volume_range_db;
        assert(percentage >= 0.0);
        assert(percentage <= 1.0);
        const bar_color_top = graphics.RGBA(f32){
            .r = lerp(bar_color_from.r, bar_color_to.r, percentage),
            .g = lerp(bar_color_from.g, bar_color_to.g, percentage),
            .b = lerp(bar_color_from.b, bar_color_to.b, percentage),
            .a = 1.0,
        };
        const bar_height = percentage * height;
        std.debug.assert(quads[i][0].y == quads[i][1].y);
        quads[i][0].y = y_lower - bar_height;
        quads[i][1].y = y_lower - bar_height;
        quads[i][0].color = bar_color_top;
        quads[i][1].color = bar_color_top;
    }
}

fn lerp(from: f32, to: f32, value: f32) f32 {
    return from + (value * (to - from));
}
