// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const graphics = @import("graphics.zig");
const geometry = @import("geometry.zig");
const styling = @import("app_styling.zig");
const fontana = @import("fontana");
const Pen = fontana.Font(.freetype_harfbuzz).Pen;

const QuadFaceWriter = graphics.QuadFaceWriter;
const QuadFace = graphics.QuadFace;
const ScaleFactor2D = geometry.ScaleFactor2D;
const Extent2D = geometry.Extent2D;

const TextWriterInterface = struct {
    quad_writer: *QuadFaceWriter,
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
        (try self.quad_writer.create()).* = graphics.quadTextured(
            screen_extent,
            texture_extent,
            .bottom_left,
        );
    }
};

pub inline fn drawBottomBar(
    face_writer: *QuadFaceWriter,
    screen_scale: ScaleFactor2D(f64),
    pen: *Pen,
) !void {
    const height_pixels: f32 = 30;
    const extent = Extent2D(f32){
        .x = -1.0,
        .y = 1.0,
        .width = 2.0,
        .height = @floatCast(f32, height_pixels * screen_scale.vertical),
    };
    (try face_writer.create()).* = graphics.quadColored(extent, styling.bottom_bar_color.toRGBA(), .bottom_left);

    var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer };
    const bottom_margin = 10 * screen_scale.vertical;
    pen.write(
        "cpu 25",
        .{ .x = -0.95, .y = 1.0 - bottom_margin },
        .{ .horizontal = screen_scale.horizontal, .vertical = screen_scale.vertical },
        &text_writer_interface,
    ) catch |err| {
        std.log.err("Failed to draw text. Error: {}", .{err});
    };
}
