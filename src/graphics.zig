// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const geometry = @import("geometry.zig");

pub fn Image(comptime PixelType: type) type {
    return struct {
        width: u16,
        height: u16,
        pixels: [*]PixelType,
    };
}

pub const FaceWriter = struct {
    vertices: []GenericVertex,
    indices: []u16,
    vertices_used: u16,
    indices_used: u16,

    pub fn init(vertex_buffer: []GenericVertex, index_buffer: []u16) FaceWriter {
        return .{
            .vertices = vertex_buffer,
            .indices = index_buffer,
            .vertices_used = 0,
            .indices_used = 0,
        };
    }

    pub fn create(self: *@This(), comptime Type: type) !*Type {
        if (Type == QuadFace)
            return self.createQuadFace();

        if (Type == TriangleFace)
            return self.createTriangleFace();

        @compileError("No other types supported");
    }

    pub fn allocate(self: *@This(), comptime Type: type, amount: u32) ![]Type {
        if (Type == QuadFace)
            return self.allocateQuadFaces(amount);

        if (Type == TriangleFace)
            return self.allocateTriangleFace(amount);

        @compileError("No other types supported");
    }

    pub inline fn reset(self: *@This()) void {
        self.vertices_used = 0;
        self.indices_used = 0;
    }

    inline fn createQuadFace(self: *@This()) !*QuadFace {
        const vertices_used = self.vertices_used;
        const indices_used = self.indices_used;

        if (vertices_used + 4 > self.vertices.len)
            return error.OutOfMemory;

        if (indices_used + 6 > self.indices.len)
            return error.OutOfMemory;

        self.indices[indices_used + 0] = vertices_used + 0; // Top left
        self.indices[indices_used + 1] = vertices_used + 1; // Top right
        self.indices[indices_used + 2] = vertices_used + 2; // Bottom right
        self.indices[indices_used + 3] = vertices_used + 0; // Top left
        self.indices[indices_used + 4] = vertices_used + 2; // Bottom right
        self.indices[indices_used + 5] = vertices_used + 3; // Bottom left

        self.vertices_used += 4;
        self.indices_used += 6;

        return @ptrCast(*QuadFace, &self.vertices[vertices_used]);
    }

    inline fn allocateQuadFaces(self: *@This(), amount: u32) ![]QuadFace {
        const vertices_used = self.vertices_used;
        const indices_used = self.indices_used;

        const vertices_required = 4 * amount;
        const indices_required = 6 * amount;

        if (vertices_used + vertices_required > self.vertices.len)
            return error.OutOfMemory;

        if (indices_used + indices_required > self.indices.len)
            return error.OutOfMemory;

        var j: usize = 0;
        while (j < amount) : (j += 1) {
            const i = indices_used + (j * 6);
            const v = @intCast(u16, vertices_used + (j * 4));
            self.indices[i + 0] = v + 0; // Top left
            self.indices[i + 1] = v + 1; // Top right
            self.indices[i + 2] = v + 2; // Bottom right
            self.indices[i + 3] = v + 0; // Top left
            self.indices[i + 4] = v + 2; // Bottom right
            self.indices[i + 5] = v + 3; // Bottom left
        }

        self.vertices_used += @intCast(u16, 4 * amount);
        self.indices_used += @intCast(u16, 6 * amount);

        return @ptrCast([*]QuadFace, &self.vertices[vertices_used])[0..amount];
    }

    inline fn allocateTriangleFace(self: *@This(), amount: u32) !*TriangleFace {
        const vertices_used = self.vertices_used;
        const indices_used = self.indices_used;

        const vertices_required = 3 * amount;
        const indices_required = 3 * amount;

        if (vertices_used + vertices_required > self.vertices.len)
            return error.OutOfMemory;

        if (indices_used + indices_required > self.indices.len)
            return error.OutOfMemory;

        var j: usize = 0;
        while (j < amount) : (j += 1) {
            const i = indices_used + (j * 3);
            const v = vertices_used + (j * 3);
            self.indices[i + 0] = v + 0;
            self.indices[i + 1] = v + 1;
            self.indices[i + 2] = v + 2;
        }

        self.vertex_used += 3 * amount;
        self.indices_used += 3 * amount;

        return @ptrCast([*]TriangleFace, &self.vertices[vertices_used])[0..amount];
    }

    inline fn createTriangleFace(self: *@This()) !*TriangleFace {
        const vertices_used = self.vertices_used;
        const indices_used = self.indices_used;

        if (vertices_used + 3 > self.vertices.len)
            return error.OutOfMemory;

        if (indices_used + 3 > self.indices.len)
            return error.OutOfMemory;

        self.indices[indices_used + 0] = vertices_used + 0;
        self.indices[indices_used + 1] = vertices_used + 1;
        self.indices[indices_used + 2] = vertices_used + 2;

        self.vertex_used += 3;
        self.indices_used += 3;

        return @ptrCast(*TriangleFace, &self.vertices[vertices_used]);
    }
};

pub const TriangleFace = TriangleConfig(GenericVertex);

fn TriangleConfig(comptime VertexType: type) type {
    return [3]VertexType;
}

pub inline fn quadTextured(
    extent: geometry.Extent2D(f32),
    texture_extent: geometry.Extent2D(f32),
    comptime anchor_point: AnchorPoint,
) QuadFaceConfig(GenericVertex) {
    return quadTexturedConfig(GenericVertex, extent, texture_extent, anchor_point);
}

pub inline fn quadColored(
    extent: geometry.Extent2D(f32),
    quad_color: RGBA(f32),
    comptime anchor_point: AnchorPoint,
) QuadFaceConfig(GenericVertex) {
    return quadColoredConfig(GenericVertex, extent, quad_color, anchor_point);
}

pub const QuadFace = [4]GenericVertex;

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

pub fn generateQuad(
    comptime VertexType: type,
    extent: geometry.Extent2D(TypeOfField(VertexType, "x")),
    comptime anchor_point: AnchorPoint,
) QuadFaceConfig(VertexType) {
    std.debug.assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));
    return switch (anchor_point) {
        .top_left => [_]VertexType{
            // zig fmt: off
            .{ .x = extent.x,                .y = extent.y },                 // Top Left
            .{ .x = extent.x + extent.width, .y = extent.y },                 // Top Right
            .{ .x = extent.x + extent.width, .y = extent.y + extent.height }, // Bottom Right
            .{ .x = extent.x,                .y = extent.y + extent.height }, // Bottom Left
        },
        .bottom_left => [_]VertexType{
            .{ .x = extent.x,                .y = extent.y - extent.height }, // Top Left
            .{ .x = extent.x + extent.width, .y = extent.y - extent.height }, // Top Right
            .{ .x = extent.x + extent.width, .y = extent.y },                 // Bottom Right
            .{ .x = extent.x,                .y = extent.y },                 // Bottom Left
        },
        .center => [_]VertexType{
            .{ .x = extent.x - (extent.width / 2.0), .y = extent.y - (extent.height / 2.0) }, // Top Left
            .{ .x = extent.x + (extent.width / 2.0), .y = extent.y - (extent.height / 2.0) }, // Top Right
            .{ .x = extent.x + (extent.width / 2.0), .y = extent.y + (extent.height / 2.0) }, // Bottom Right
            .{ .x = extent.x - (extent.width / 2.0), .y = extent.y + (extent.height / 2.0) }, // Bottom Left
            // zig fmt: on
        },
        else => @compileError("Invalid AnchorPoint"),
    };
}

fn quadTexturedConfig(
    comptime VertexType: type,
    extent: geometry.Extent2D(TypeOfField(VertexType, "x")),
    texture_extent: geometry.Extent2D(TypeOfField(VertexType, "tx")),
    comptime anchor_point: AnchorPoint,
) QuadFaceConfig(VertexType) {
    std.debug.assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));
    std.debug.assert(TypeOfField(VertexType, "tx") == TypeOfField(VertexType, "ty"));
    var base_quad = generateQuad(VertexType, extent, anchor_point);
    base_quad[0].tx = texture_extent.x;
    base_quad[0].ty = texture_extent.y;
    base_quad[1].tx = texture_extent.x + texture_extent.width;
    base_quad[1].ty = texture_extent.y;
    base_quad[2].tx = texture_extent.x + texture_extent.width;
    base_quad[2].ty = texture_extent.y + texture_extent.height;
    base_quad[3].tx = texture_extent.x;
    base_quad[3].ty = texture_extent.y + texture_extent.height;
    return base_quad;
}

fn quadColoredConfig(
    comptime VertexType: type,
    extent: geometry.Extent2D(TypeOfField(VertexType, "x")),
    quad_color: RGBA(f32),
    comptime anchor_point: AnchorPoint,
) QuadFaceConfig(VertexType) {
    std.debug.assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));
    var base_quad = generateQuad(VertexType, extent, anchor_point);
    base_quad[0].color = quad_color;
    base_quad[1].color = quad_color;
    base_quad[2].color = quad_color;
    base_quad[3].color = quad_color;
    return base_quad;
}

pub const TextureVertex = extern struct {
    x: u16,
    y: u16,
    u: u16,
    v: u16,
};

pub const ColorVertex = extern struct {
    x: u16,
    y: u16,
    color: RGBA(u8),
};

// 8 * 4 = 32 bytes
pub const GenericVertex = extern struct {
    x: f32 = 1.0,
    y: f32 = 1.0,
    // This default value references the last pixel in our texture which
    // we set all values to 1.0 so that we can use it to multiply a color
    // without changing it. See fragment shader
    tx: f32 = 1.0,
    ty: f32 = 1.0,
    color: RGBA(f32) = .{
        .r = 1.0,
        .g = 1.0,
        .b = 1.0,
        .a = 1.0,
    },

    pub fn nullFace() QuadFaceConfig(GenericVertex) {
        return .{ .{}, .{}, .{}, .{} };
    }
};

fn QuadFaceConfig(comptime VertexType: type) type {
    return [4]VertexType;
}

pub fn RGB(comptime BaseType: type) type {
    return extern struct {
        pub fn fromInt(r: u8, g: u8, b: u8) @This() {
            return .{
                .r = @intToFloat(BaseType, r) / 255.0,
                .g = @intToFloat(BaseType, g) / 255.0,
                .b = @intToFloat(BaseType, b) / 255.0,
            };
        }

        pub inline fn toRGBA(self: @This()) RGBA(BaseType) {
            return .{
                .r = self.r,
                .g = self.g,
                .b = self.b,
                .a = 1.0,
            };
        }

        r: BaseType,
        g: BaseType,
        b: BaseType,
    };
}

pub fn RGBA(comptime BaseType: type) type {
    return extern struct {
        pub fn fromInt(comptime IntType: type, r: IntType, g: IntType, b: IntType, a: IntType) @This() {
            return .{
                .r = @intToFloat(BaseType, r) / 255.0,
                .g = @intToFloat(BaseType, g) / 255.0,
                .b = @intToFloat(BaseType, b) / 255.0,
                .a = @intToFloat(BaseType, a) / 255.0,
            };
        }

        pub inline fn isEqual(self: @This(), color: @This()) bool {
            return (self.r == color.r and self.g == color.g and self.b == color.b and self.a == color.a);
        }

        r: BaseType,
        g: BaseType,
        b: BaseType,
        a: BaseType,
    };
}


// fn imageCrop(
//     comptime Pixel: type,
//     src_width: u32,
//     crop_extent: geometry.Extent2D(u32),
//     input_pixels: [*]const Pixel,
//     output_pixels: [*]Pixel,
// ) !void {
//     var y: usize = crop_extent.y;
//     const y_end: usize = y + crop_extent.height;
//     const row_size: usize = crop_extent.width * @sizeOf(Pixel);
//     while (y < y_end) : (y += 1) {
//         std.debug.assert(y < crop_extent.y + crop_extent.height);
//         const src_index: usize = crop_extent.x + (y * src_width);
//         const dst_index: usize = crop_extent.width * y;
//         @memcpy(
//             @ptrCast([*]u8, &output_pixels[dst_index]),
//             @ptrCast([*]const u8, &input_pixels[src_index]),
//             row_size,
//         );
//     }
// }

// fn imageCopyExact(
//     comptime Pixel: type,
//     src_position: geometry.Coordinates2D(u32),
//     dst_position: geometry.Coordinates2D(u32),
//     dimensions: geometry.Dimensions2D(u32),
//     src_stride: u32,
//     dst_stride: u32,
//     input_pixels: [*]const Pixel,
//     output_pixels: [*]Pixel,
// ) void {
//     var y: usize = 0;
//     const row_size: usize = dimensions.width * @sizeOf(Pixel);
//     while (y < dimensions.height) : (y += 1) {
//         const src_y = src_position.y + y;
//         const dst_y = dst_position.y + y;
//         const src_index = src_position.x + (src_y * src_stride);
//         const dst_index = dst_position.x + (dst_y * dst_stride);
//         @memcpy(
//             @ptrCast([*]u8, &output_pixels[dst_index]),
//             @ptrCast([*]const u8, &input_pixels[src_index]),
//             row_size,
//         );
//     }
// }