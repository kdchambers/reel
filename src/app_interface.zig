// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const graphics = @import("graphics.zig");
const geometry = @import("geometry.zig");
const styling = @import("app_styling.zig");

const widget = @import("widgets");
const Button = widget.Button;
const ImageButton = widget.ImageButton;

const FaceWriter = graphics.FaceWriter;
const QuadFace = graphics.QuadFace;
const ScaleFactor2D = geometry.ScaleFactor2D;
const Extent2D = geometry.Extent2D;

const TextWriterInterface = struct {
    quad_writer: *FaceWriter,
    pub fn write(
        self: *@This(),
        screen_extent: Extent2D(f32),
        texture_extent: Extent2D(f32),
    ) !void {
        (try self.quad_writer.create(QuadFace)).* = graphics.quadTextured(
            screen_extent,
            texture_extent,
            .bottom_left,
        );
    }
};

pub fn drawBottomBar(
    face_writer: *FaceWriter,
    screen_scale: ScaleFactor2D(f64),
    pen: anytype,
) !void {
    const height_pixels: f32 = 30;
    const extent = Extent2D(f32){
        .x = -1.0,
        .y = 1.0,
        .width = 2.0,
        .height = @floatCast(f32, height_pixels * screen_scale.vertical),
    };
    (try face_writer.create(QuadFace)).* = graphics.quadColored(extent, styling.bottom_bar_color.toRGBA(), .bottom_left);

    var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer };
    const bottom_margin = 10 * @floatCast(f32, screen_scale.vertical);
    pen.write(
        "cpu 25",
        .{ .x = -0.95, .y = 1.0 - bottom_margin },
        screen_scale,
        &text_writer_interface,
    ) catch |err| {
        std.log.err("Failed to draw text. Error: {}", .{err});
    };
}
