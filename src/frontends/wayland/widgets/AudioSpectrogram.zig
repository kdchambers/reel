// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

// TODO: This is just a bar graph..

const std = @import("std");
const geometry = @import("../../../geometry.zig");
const Extent2D = geometry.Extent2D;
const ScaleFactor2D = geometry.ScaleFactor2D;
const Coordinates2D = geometry.Coordinates2D;

const graphics = @import("../../../graphics.zig");
const Vertex = graphics.GenericVertex;
const FaceWriter = graphics.FaceWriter;
const QuadFace = graphics.QuadFace;
const RGBA = graphics.RGBA;

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
    placement: geometry.Coordinates2D(f32),
    screen_scale: ScaleFactor2D(f32),
) !void {
    self.bin_count = @intCast(u16, freq_bins.len);
    const height = self.height_pixels * screen_scale.vertical;
    const bar_width: f32 = 4 * screen_scale.horizontal;
    const bar_spacing: f32 = 2 * screen_scale.horizontal;
    const bar_increment: f32 = bar_width + bar_spacing;
    const bar_color = graphics.RGBA(f32).fromInt(50, 100, 65, 255);

    self.vertex_index = root.face_writer_ref.vertices_used;
    var quads = try root.face_writer_ref.allocate(QuadFace, self.bin_count);
    for (freq_bins, quads, 0..) |freq_value, *quad, i| {
        const db_clamped = @min(self.max_cutoff_db, @max(self.min_cutoff_db, freq_value));
        const bar_height = height - ((db_clamped / self.min_cutoff_db) * height);
        const extent = Extent2D(f32){
            .x = placement.x + (@intToFloat(f32, i) * bar_increment),
            .y = placement.y,
            .width = bar_width,
            .height = bar_height,
        };
        quad.* = graphics.quadColored(extent, bar_color, .bottom_left);
        quad.*[0].color = graphics.RGBA(f32).fromInt(150, 50, 70, 255);
        quad.*[1].color = graphics.RGBA(f32).fromInt(150, 50, 70, 255);
    }
}

pub fn update(self: *@This(), freq_bins: []f32, screen_scale: ScaleFactor2D(f32)) !void {
    std.debug.assert(freq_bins.len == self.bin_count);
    var quads = @ptrCast([*]QuadFace, &root.vertices_buffer_ref[self.vertex_index]);
    const height = self.height_pixels * screen_scale.vertical;
    var i: usize = 0;
    const y_lower = quads[i][2].y;
    std.debug.assert(y_lower == quads[i][3].y);
    while (i < self.bin_count) : (i += 1) {
        const freq_value = freq_bins[i];
        const db_clamped = @min(self.max_cutoff_db, @max(self.min_cutoff_db, freq_value));
        const bar_height = height - ((db_clamped / self.min_cutoff_db) * height);
        std.debug.assert(quads[i][0].y == quads[i][1].y);
        quads[i][0].y = y_lower - bar_height;
        quads[i][1].y = y_lower - bar_height;
    }
}
