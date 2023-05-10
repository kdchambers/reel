// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;
const geometry = @import("geometry.zig");
const Extent2D = geometry.Extent2D;
const ScaleFactor2D = geometry.ScaleFactor2D;
const Coordinates2D = geometry.Coordinates2D;

pub fn Image(comptime PixelType: type) type {
    return struct {
        width: u16,
        height: u16,
        pixels: [*]PixelType,
    };
}

pub fn TypeOfField(comptime t: anytype, comptime field_name: []const u8) type {
    for (@typeInfo(t).Struct.fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            return field.type;
        }
    }
    unreachable;
}

pub const AnchorPoint = enum {
    center,
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

pub inline fn writeQuad(
    comptime VertexType: type,
    extent: geometry.Extent3D(f32),
    comptime anchor_point: AnchorPoint,
    vertices: *[4]VertexType,
) void {
    vertices[0].z = extent.z;
    vertices[1].z = extent.z;
    vertices[2].z = extent.z;
    vertices[3].z = extent.z;
    switch (anchor_point) {
        .top_left => {
            vertices[0].x = extent.x;
            vertices[0].y = extent.y;
            vertices[1].x = extent.x + extent.width;
            vertices[1].y = extent.y;
            vertices[2].x = extent.x + extent.width;
            vertices[2].y = extent.y + extent.height;
            vertices[3].x = extent.x;
            vertices[3].y = extent.y + extent.height;
        },
        .bottom_left => {
            vertices[0].x = extent.x;
            vertices[0].y = extent.y - extent.height;
            vertices[1].x = extent.x + extent.width;
            vertices[1].y = extent.y - extent.height;
            vertices[2].x = extent.x + extent.width;
            vertices[2].y = extent.y;
            vertices[3].x = extent.x;
            vertices[3].y = extent.y;
        },
        .bottom_right => {
            vertices[0].x = extent.x - extent.width;
            vertices[0].y = extent.y - extent.height;
            vertices[1].x = extent.x;
            vertices[1].y = extent.y - extent.height;
            vertices[2].x = extent.x;
            vertices[2].y = extent.y;
            vertices[3].x = extent.x - extent.width;
            vertices[3].y = extent.y;
        },
        .center => {
            const half_width: f32 = extent.width / 2.0;
            const half_height: f32 = extent.height / 2.0;
            vertices[0].x = extent.x - half_width;
            vertices[0].y = extent.y - half_height;
            vertices[1].x = extent.x + half_width;
            vertices[1].y = extent.y - half_height;
            vertices[2].x = extent.x + half_width;
            vertices[2].y = extent.y + half_height;
            vertices[3].x = extent.x - half_width;
            vertices[3].y = extent.y + half_height;
        },
        else => @compileError("Invalid AnchorPoint"),
    }
}

pub inline fn writeQuadTextured(
    comptime VertexType: type,
    extent: geometry.Extent3D(f32),
    texture_extent: geometry.Extent2D(f32),
    comptime anchor_point: AnchorPoint,
    vertices: *[4]VertexType,
) void {
    // TODO: Implement other anchor points for texture mapping
    assert(anchor_point == .bottom_left);
    writeQuad(VertexType, extent, anchor_point, vertices);
    vertices[0].u = texture_extent.x;
    vertices[0].v = texture_extent.y;
    vertices[1].u = texture_extent.x + texture_extent.width;
    vertices[1].v = texture_extent.y;
    vertices[2].u = texture_extent.x + texture_extent.width;
    vertices[2].v = texture_extent.y + texture_extent.height;
    vertices[3].u = texture_extent.x;
    vertices[3].v = texture_extent.y + texture_extent.height;
}

pub fn RGB(comptime BaseType: type) type {
    return extern struct {
        const trait = std.meta.trait;
        const math = std.math;
        comptime {
            if (!(trait.isFloat(BaseType) or trait.isUnsignedInt(BaseType))) {
                std.debug.panic("RGB only accepts float and integer base types. Found {}", .{BaseType});
            }
        }

        const upper_bound: BaseType = if (trait.isFloat(BaseType)) 1.0 else math.maxInt(BaseType);
        const lower_bound: BaseType = 0;

        pub fn fromInt(r: u8, g: u8, b: u8) @This() {
            if (comptime trait.isFloat(BaseType)) {
                return .{
                    .r = @intToFloat(BaseType, r) / 255.0,
                    .g = @intToFloat(BaseType, g) / 255.0,
                    .b = @intToFloat(BaseType, b) / 255.0,
                };
            } else {
                return .{
                    .r = r,
                    .g = g,
                    .b = b,
                };
            }
        }

        pub inline fn toRGBA(self: @This()) RGBA(BaseType) {
            return .{
                .r = self.r,
                .g = self.g,
                .b = self.b,
                .a = upper_bound,
            };
        }

        r: BaseType,
        g: BaseType,
        b: BaseType,
    };
}

pub fn RGBA(comptime BaseType: type) type {
    return extern struct {
        const trait = std.meta.trait;
        const math = std.math;
        comptime {
            if (!(trait.isFloat(BaseType) or trait.isUnsignedInt(BaseType))) {
                std.debug.panic("RGBA only accepts float and integer base types. Found {}", .{BaseType});
            }
        }

        const upper_bound: BaseType = if (trait.isFloat(BaseType)) 1.0 else math.maxInt(BaseType);
        const lower_bound: BaseType = 0;

        pub const white: @This() = .{ .r = upper_bound, .g = upper_bound, .b = upper_bound, .a = upper_bound };
        pub const black: @This() = .{ .r = lower_bound, .g = lower_bound, .b = lower_bound, .a = upper_bound };
        pub const red: @This() = .{ .r = upper_bound, .g = lower_bound, .b = lower_bound, .a = upper_bound };
        pub const green: @This() = .{ .r = lower_bound, .g = upper_bound, .b = lower_bound, .a = upper_bound };
        pub const blue: @This() = .{ .r = lower_bound, .g = lower_bound, .b = upper_bound, .a = upper_bound };
        pub const transparent: @This() = .{ .r = lower_bound, .g = lower_bound, .b = upper_bound, .a = lower_bound };

        pub fn fromInt(r: u8, g: u8, b: u8, a: u8) @This() {
            if (comptime trait.isFloat(BaseType)) {
                return .{
                    .r = @intToFloat(BaseType, r) / 255.0,
                    .g = @intToFloat(BaseType, g) / 255.0,
                    .b = @intToFloat(BaseType, b) / 255.0,
                    .a = @intToFloat(BaseType, a) / 255.0,
                };
            } else {
                return .{
                    .r = r,
                    .g = g,
                    .b = b,
                    .a = a,
                };
            }
        }

        pub inline fn isEqual(self: @This(), color: @This()) bool {
            return (self.r == color.r and self.g == color.g and self.b == color.b and self.a == color.a);
        }

        r: BaseType,
        g: BaseType,
        b: BaseType,
        a: BaseType = upper_bound,
    };
}

//
// Default interface for Fontana font
//
pub const TextWriterInterface = struct {
    z: f32 = 0.8,
    color: RGBA(u8),

    pub fn write(
        self: *@This(),
        screen_extent: geometry.Extent2D(f32),
        texture_extent: geometry.Extent2D(f32),
    ) !void {
        //
        // This seems to *mostly* fix mapped glyph textures being distorted.
        // One "bad" glyph will cause the rest of the chars that follow it to
        // also be disorted, so it seems like the coordinates are causing this
        // issue.
        //
        // The fix is to reduce the precision of x,y coordinates to 1/8th of a
        // pixel at 1920 pixels per line. I'm still seeing some minor issues
        // in how glyphs are rendered such as bottom parts being faded. That
        // might require a separate fix in fontana though.
        //
        const max_precision = 1.0 / (1920.0 * 8.0);
        const truncated_extent = geometry.Extent3D(f32){
            .x = roundDown(screen_extent.x, max_precision),
            .y = roundDown(screen_extent.y, max_precision),
            .z = self.z,
            .width = screen_extent.width,
            .height = screen_extent.height,
        };

        const renderer = @import("renderer.zig");
        _ = renderer.drawIcon(
            truncated_extent,
            texture_extent,
            self.color,
            .bottom_left,
        );
    }
};

pub const BufferTextWriterInterface = struct {
    z: f32 = 0.8,
    color: RGBA(u8),
    vertex_start: u16,
    capacity: u16,
    used: u16 = 0,

    pub fn write(
        self: *@This(),
        screen_extent: geometry.Extent2D(f32),
        texture_extent: geometry.Extent2D(f32),
    ) !void {
        assert(self.used < self.capacity);

        //
        // This seems to *mostly* fix mapped glyph textures being distorted.
        // One "bad" glyph will cause the rest of the chars that follow it to
        // also be disorted, so it seems like the coordinates are causing this
        // issue.
        //
        // The fix is to reduce the precision of x,y coordinates to 1/8th of a
        // pixel at 1920 pixels per line. I'm still seeing some minor issues
        // in how glyphs are rendered such as bottom parts being faded. That
        // might require a separate fix in fontana though.
        //
        const max_precision = 1.0 / (1920.0 * 8.0);
        const truncated_extent = geometry.Extent3D(f32){
            .x = roundDown(screen_extent.x, max_precision),
            .y = roundDown(screen_extent.y, max_precision),
            .z = self.z,
            .width = screen_extent.width,
            .height = screen_extent.height,
        };

        const renderer = @import("renderer.zig");
        _ = renderer.overwriteIcon(
            self.vertex_start + (self.used * 4),
            truncated_extent,
            texture_extent,
            self.color,
            .bottom_left,
        );
        self.used += 1;
    }
};

inline fn roundDown(value: f32, comptime round_interval: f32) f32 {
    const rem = @rem(value, round_interval);
    return if (rem != 0) value - rem else value;
}

inline fn roundUp(value: f32, comptime round_interval: f32) f32 {
    const rem = @rem(value, round_interval);
    return if (rem != 0) value + (round_interval - rem) else value;
}

pub const TextureGreyscale = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};
