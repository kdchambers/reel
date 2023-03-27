// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

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

vertex_index: u32,
extent: geometry.Extent2D(f32),

pub fn setDecibelLevel(self: *@This(), decibels: f64) void {
    var overlay_quad = @ptrCast(*graphics.QuadFace, &root.face_writer_ref.vertices[self.vertex_index]);
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
    const decibel_range_min = 6.0;
    const decibel_range_max = 3.0;
    const decibel_range_total = decibel_range_max - decibel_range_min;
    return @max(@min((-decibels - decibel_range_min) / decibel_range_total, 1.0), 0.0);
}

pub fn init(self: *@This(), extent: geometry.Extent2D(f32)) !void {
    const percentage = 1.0;
    self.extent = extent;
    // const color_green = graphics.RGBA(f32){ .r = 0, .g = 1.0, .b = 0.0, .a = 1.0 };
    // const color_red = graphics.RGBA(f32){ .r = 1, .g = 0.0, .b = 0.0, .a = 1.0 };
    const color_black = graphics.RGBA(f32){ .r = 0, .g = 0, .b = 0.0, .a = 1.0 };

    // const color_from = graphics.RGBA(f32).fromInt(u8, 50, 230, 50, 255);
    const color_from = graphics.RGBA(f32).fromInt(50, 100, 65, 255);
    // const color_to = graphics.RGBA(f32).fromInt(u8, 230, 50, 50, 255);
    const color_to = graphics.RGBA(f32).fromInt(150, 50, 70, 255);

    var overlay_quad = try root.face_writer_ref.create(QuadFace);
    overlay_quad.* = graphics.generateQuad(graphics.GenericVertex, self.extent, .bottom_left);
    overlay_quad[0].color = color_from; // Top left
    overlay_quad[1].color = color_to; // Top right
    overlay_quad[2].color = color_to; // Bottom right
    overlay_quad[3].color = color_from; // Bottom left

    self.vertex_index = root.face_writer_ref.vertices_used;

    var background_quad = try root.face_writer_ref.create(QuadFace);
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
