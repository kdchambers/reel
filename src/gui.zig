// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");

const QuadFaceWriter = graphics.QuadFaceWriter;
const QuadFace = graphics.QuadFace;

pub const button = struct {
    pub const DrawOptions = struct {
        color: graphics.RGB(f32),
        on_hover_color: ?graphics.RGB(f32) = null,
    };

    pub fn draw(
        comptime VertexType: type,
        face_writer: *QuadFaceWriter(VertexType),
        position: *const geometry.Coordinates2D(f32),
        dimensions: *const geometry.Dimensions2D(f32),
        comptime options: DrawOptions,
    ) !void {
        const button_extent = geometry.Extent2D(f32){
            .x = position.x,
            .y = position.y,
            .width = dimensions.width,
            .height = dimensions.height,
        };
        var background_face: *QuadFace(VertexType) = try face_writer.create();
        background_face.* = graphics.quadColored(VertexType, button_extent, options.color.toRGBA(), .bottom_left);
    }
};
