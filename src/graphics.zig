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

pub const FaceWriter = struct {
    vertices: []GenericVertex,
    indices: []u16,
    vertices_used: u16,
    indices_used: u16,

    // This allows the creation of arenas where vertices_used doesn't
    // correspond the to next vertex index
    vertex_offset: u16,

    pub fn init(vertex_buffer: []GenericVertex, index_buffer: []u16) FaceWriter {
        return .{
            .vertices = vertex_buffer,
            .indices = index_buffer,
            .vertices_used = 0,
            .indices_used = 0,
            .vertex_offset = 0,
        };
    }

    pub fn create(self: *@This(), comptime Type: type) !*Type {
        if (Type == QuadFace)
            return self.createQuadFace();

        if (Type == TriangleFace)
            return self.createTriangleFace();

        @compileError("No other types supported");
    }

    pub fn createArena(self: *@This(), vertex_count: usize) @This() {
        const vertex_start = self.vertices_used;
        const vertex_end = vertex_start + vertex_count;

        const index_count = vertex_count + @divExact(vertex_count, 2);
        const index_start = self.indices_used;
        const index_end = index_start + index_count;

        self.vertices_used += @intCast(u16, vertex_count);
        self.indices_used += @intCast(u16, index_count);
        return .{
            .vertices = self.vertices[vertex_start..vertex_end],
            .indices = self.indices[index_start..index_end],
            .vertices_used = 0,
            .indices_used = 0,
            .vertex_offset = vertex_start,
        };
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
            return error.OutOfSpace;

        if (indices_used + 6 > self.indices.len)
            return error.OutOfSpace;

        const vertex_index_base = vertices_used + self.vertex_offset;

        self.indices[indices_used + 0] = vertex_index_base + 0; // Top left
        self.indices[indices_used + 1] = vertex_index_base + 1; // Top right
        self.indices[indices_used + 2] = vertex_index_base + 2; // Bottom right
        self.indices[indices_used + 3] = vertex_index_base + 0; // Top left
        self.indices[indices_used + 4] = vertex_index_base + 2; // Bottom right
        self.indices[indices_used + 5] = vertex_index_base + 3; // Bottom left

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
            return error.OutOfSpace;

        if (indices_used + indices_required > self.indices.len)
            return error.OutOfSpace;

        var j: usize = 0;
        var vertex_index = vertices_used + self.vertex_offset;
        while (j < amount) : (j += 1) {
            const i = indices_used + (j * 6);
            self.indices[i + 0] = vertex_index + 0; // Top left
            self.indices[i + 1] = vertex_index + 1; // Top right
            self.indices[i + 2] = vertex_index + 2; // Bottom right
            self.indices[i + 3] = vertex_index + 0; // Top left
            self.indices[i + 4] = vertex_index + 2; // Bottom right
            self.indices[i + 5] = vertex_index + 3; // Bottom left
            vertex_index += 4;
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
            return error.OutOfSpace;

        if (indices_used + indices_required > self.indices.len)
            return error.OutOfSpace;

        var j: usize = 0;
        var vertex_index = vertices_used + self.vertex_offset;
        while (j < amount) : (j += 1) {
            const i = indices_used + (j * 3);
            self.indices[i + 0] = vertex_index + 0;
            self.indices[i + 1] = vertex_index + 1;
            self.indices[i + 2] = vertex_index + 2;
            vertex_index += 3;
        }

        self.vertex_used += 3 * amount;
        self.indices_used += 3 * amount;

        return @ptrCast([*]TriangleFace, &self.vertices[vertices_used])[0..amount];
    }

    inline fn createTriangleFace(self: *@This()) !*TriangleFace {
        const vertices_used = self.vertices_used;
        const indices_used = self.indices_used;

        if (vertices_used + 3 > self.vertices.len)
            return error.OutOfSpace;

        if (indices_used + 3 > self.indices.len)
            return error.OutOfSpace;

        const vertex_index: u16 = vertices_used + self.vertex_offset;
        self.indices[indices_used + 0] = vertex_index + 0;
        self.indices[indices_used + 1] = vertex_index + 1;
        self.indices[indices_used + 2] = vertex_index + 2;

        self.vertices_used += 3;
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
    assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));
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
        .bottom_right => [_]VertexType{
            .{ .x = extent.x - extent.width, .y = extent.y - extent.height }, // Top Left
            .{ .x = extent.x,                .y = extent.y - extent.height }, // Top Right
            .{ .x = extent.x,                .y = extent.y },                 // Bottom Right
            .{ .x = extent.x - extent.width, .y = extent.y },                 // Bottom Left
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

pub fn writeQuad(
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

fn quadTexturedConfig(
    comptime VertexType: type,
    extent: geometry.Extent2D(TypeOfField(VertexType, "x")),
    texture_extent: geometry.Extent2D(TypeOfField(VertexType, "tx")),
    comptime anchor_point: AnchorPoint,
) QuadFaceConfig(VertexType) {
    assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));
    assert(TypeOfField(VertexType, "tx") == TypeOfField(VertexType, "ty"));
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
    assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));
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
        const trait = std.meta.trait;
        const math = std.math;
        comptime {
            if(!(trait.isFloat(BaseType) or trait.isUnsignedInt(BaseType))) {
                std.debug.panic("RGB only accepts float and integer base types. Found {}", .{BaseType});
            }
        }

        const upper_bound: BaseType = if(trait.isFloat(BaseType)) 1.0 else math.maxInt(BaseType);
        const lower_bound: BaseType = 0;

        pub fn fromInt(r: u8, g: u8, b: u8) @This() {
            if(comptime trait.isFloat(BaseType)) {
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
            if(!(trait.isFloat(BaseType) or trait.isUnsignedInt(BaseType))) {
                std.debug.panic("RGBA only accepts float and integer base types. Found {}", .{BaseType});
            }
        }

        const upper_bound: BaseType = if(trait.isFloat(BaseType)) 1.0 else math.maxInt(BaseType);
        const lower_bound: BaseType = 0;

        pub const white: @This() = .{ .r = upper_bound, .g = upper_bound, .b = upper_bound, .a = upper_bound };
        pub const black: @This() = .{ .r = lower_bound, .g = lower_bound, .b = lower_bound, .a = upper_bound };
        pub const red: @This() = .{ .r = upper_bound, .g = lower_bound, .b = lower_bound, .a = upper_bound };
        pub const green: @This() = .{ .r = lower_bound, .g = upper_bound, .b = lower_bound, .a = upper_bound };
        pub const blue: @This() = .{ .r = lower_bound, .g = lower_bound, .b = upper_bound, .a = upper_bound };
        pub const transparent: @This() = .{ .r = lower_bound, .g = lower_bound, .b = upper_bound, .a = lower_bound };

        pub fn fromInt(r: u8, g: u8, b: u8, a: u8) @This() {
            if(comptime trait.isFloat(BaseType)) {
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

pub fn drawCircle(
    center: geometry.Coordinates2D(f32),
    radius_pixels: f32,
    color: RGBA(f32),
    screen_scale: geometry.ScaleFactor2D(f32),
    face_writer: *FaceWriter,
) !void {
    const point_count = @max(20, @floatToInt(u16, @divFloor(radius_pixels, 2)));

    const radius_h: f64 = radius_pixels * screen_scale.horizontal;
    const radius_v: f64 = radius_pixels * screen_scale.vertical;

    const degreesToRadians = std.math.degreesToRadians;

    const rotation_per_point = degreesToRadians(f64, 360 / @intToFloat(f64, point_count));

    const vertices_index: u16 = face_writer.vertices_used;
    var indices_index: u16 = face_writer.indices_used;

    face_writer.vertices[vertices_index] = GenericVertex{
        .x = @floatCast(f32, center.x),
        .y = @floatCast(f32, center.y),
        .color = color,
    };

    //
    // Draw first on-curve point
    //
    face_writer.vertices[vertices_index + 1] = GenericVertex{
        .x = @floatCast(f32, center.x + (radius_h * @cos(0.0))),
        .y = @floatCast(f32, center.y + (radius_v * @sin(0.0))),
        .color = color,
    };

    var i: u16 = 1;
    while (i <= point_count) : (i += 1) {
        const angle_radians: f64 = rotation_per_point * @intToFloat(f64, i);
        face_writer.vertices[vertices_index + i + 1] = GenericVertex{
            .x = @floatCast(f32, center.x + (radius_h * @cos(angle_radians))),
            .y = @floatCast(f32, center.y + (radius_v * @sin(angle_radians))),
            .color = color,
        };
        face_writer.indices[indices_index + 0] = vertices_index; // Center
        face_writer.indices[indices_index + 1] = vertices_index + i + 0; // Previous
        face_writer.indices[indices_index + 2] = vertices_index + i + 1; // Current
        indices_index += 3;
    }

    face_writer.vertices_used += point_count + 2;
    face_writer.indices_used += point_count * 3;
}

pub const Corner = enum {
    top_right,
    top_left,
    bottom_right,
    bottom_left,
};

pub fn drawRoundedCorner(
    comptime corner: Corner,
    placement: Coordinates2D(f32),
    color: RGBA(f32),
    radius: f32,
    screen_scale: ScaleFactor2D(f32),
    face_writer: *FaceWriter,
) !void {
    const radius_h: f32 = radius * screen_scale.horizontal;
    const radius_v: f32 = radius * screen_scale.vertical;
    const points_per_curve = @floatToInt(u16, @floor(radius));
    const rotation_per_point = std.math.degreesToRadians(f64, 90 / @intToFloat(f64, points_per_curve - 1));
    switch(comptime corner) {
        .top_right => {
            const vertices_index: u16 = face_writer.vertices_used;
            const start_indices_index: u16 = face_writer.indices_used;
            const corner_x = placement.x;
            const corner_y = placement.y;
            //
            // Draw corner point
            //
            face_writer.vertices[vertices_index] = GenericVertex{
                .x = corner_x,
                .y = corner_y,
                .color = color,
            };
            //
            // Draw first on-curve point
            //
            var start_angle_radians = std.math.degreesToRadians(f64, 180);

            face_writer.vertices[vertices_index + 1] = GenericVertex{
                .x = @floatCast(f32, corner_x - (radius_h * @cos(start_angle_radians))),
                .y = @floatCast(f32, corner_y - (radius_v * @sin(start_angle_radians))),
                .color = color,
            };
            var i: u16 = 1;
            while (i < points_per_curve) : (i += 1) {
                const angle_radians: f64 = start_angle_radians - (rotation_per_point * @intToFloat(f64, i));
                face_writer.vertices[vertices_index + i + 1] = GenericVertex{
                    .x = @floatCast(f32, corner_x - (radius_h * @cos(angle_radians))),
                    .y = @floatCast(f32, corner_y - (radius_v * @sin(angle_radians))),
                    .color = color,
                };
                const indices_index = start_indices_index + ((i - 1) * 3);
                face_writer.indices[indices_index + 0] = vertices_index + i + 1; // Current
                face_writer.indices[indices_index + 1] = vertices_index + i + 0; // Previous
                face_writer.indices[indices_index + 2] = vertices_index; // Corner
            }
            face_writer.vertices_used += points_per_curve + 2;
            face_writer.indices_used += (points_per_curve - 1) * 3;
        },
        .top_left => {
            const vertices_index: u16 = face_writer.vertices_used;
            const start_indices_index: u16 = face_writer.indices_used;
            const corner_x = placement.x;
            const corner_y = placement.y;
            //
            // Draw corner point
            //
            face_writer.vertices[vertices_index] = GenericVertex{
                .x = corner_x,
                .y = corner_y,
                .color = color,
            };
            //
            // Draw first on-curve point
            //
            var angle_radians = std.math.degreesToRadians(f64, 0);
            face_writer.vertices[vertices_index + 1] = GenericVertex{
                .x = @floatCast(f32, corner_x - (radius_h * @cos(angle_radians))),
                .y = @floatCast(f32, corner_y - (radius_v * @sin(angle_radians))),
                .color = color,
            };
            var i: u16 = 1;
            while (i < points_per_curve) : (i += 1) {
                angle_radians += rotation_per_point;
                face_writer.vertices[vertices_index + i + 1] = GenericVertex{
                    .x = @floatCast(f32, corner_x - (radius_h * @cos(angle_radians))),
                    .y = @floatCast(f32, corner_y - (radius_v * @sin(angle_radians))),
                    .color = color,
                };
                const indices_index = start_indices_index + ((i - 1) * 3);
                face_writer.indices[indices_index + 0] = vertices_index; // Corner
                face_writer.indices[indices_index + 1] = vertices_index + i + 0; // Previous
                face_writer.indices[indices_index + 2] = vertices_index + i + 1; // Current
            }
            face_writer.vertices_used += points_per_curve + 2;
            face_writer.indices_used += (points_per_curve - 1) * 3;
        },
        .bottom_right => {
            const vertices_index: u16 = face_writer.vertices_used;
            const start_indices_index: u16 = face_writer.indices_used;
            const corner_x = placement.x;
            const corner_y = placement.y;
            //
            // Draw corner point
            //
            face_writer.vertices[vertices_index] = GenericVertex{
                .x = corner_x,
                .y = corner_y,
                .color = color,
            };
            //
            // Draw first on-curve point
            //
            var start_angle_radians = std.math.degreesToRadians(f64, 180);

            face_writer.vertices[vertices_index + 1] = GenericVertex{
                .x = @floatCast(f32, corner_x - (radius_h * @cos(start_angle_radians))),
                .y = @floatCast(f32, corner_y - (radius_v * @sin(start_angle_radians))),
                .color = color,
            };
            var i: u16 = 1;
            while (i < points_per_curve) : (i += 1) {
                const angle_radians: f64 = start_angle_radians + (rotation_per_point * @intToFloat(f64, i));
                face_writer.vertices[vertices_index + i + 1] = GenericVertex{
                    .x = @floatCast(f32, corner_x - (radius_h * @cos(angle_radians))),
                    .y = @floatCast(f32, corner_y - (radius_v * @sin(angle_radians))),
                    .color = color,
                };
                const indices_index = start_indices_index + ((i - 1) * 3);
                face_writer.indices[indices_index + 0] = vertices_index + i + 1; // Current
                face_writer.indices[indices_index + 1] = vertices_index + i + 0; // Previous
                face_writer.indices[indices_index + 2] = vertices_index; // Corner
            }
            face_writer.vertices_used += points_per_curve + 2;
            face_writer.indices_used += (points_per_curve - 1) * 3;
        },
        .bottom_left => {
            const vertices_index: u16 = face_writer.vertices_used;
            const start_indices_index: u16 = face_writer.indices_used;
            const corner_x = placement.x;
            const corner_y = placement.y;
            //
            // Draw corner point
            //
            face_writer.vertices[vertices_index] = GenericVertex{
                .x = corner_x,
                .y = corner_y,
                .color = color,
            };
            //
            // Draw first on-curve point
            //
            var start_angle_radians = std.math.degreesToRadians(f64, 270);

            face_writer.vertices[vertices_index + 1] = GenericVertex{
                .x = @floatCast(f32, corner_x - (radius_h * @cos(start_angle_radians))),
                .y = @floatCast(f32, corner_y - (radius_v * @sin(start_angle_radians))),
                .color = color,
            };
            var i: u16 = 1;
            while (i < points_per_curve) : (i += 1) {
                const angle_radians: f64 = start_angle_radians + (rotation_per_point * @intToFloat(f64, i));
                face_writer.vertices[vertices_index + i + 1] = GenericVertex{
                    .x = @floatCast(f32, corner_x - (radius_h * @cos(angle_radians))),
                    .y = @floatCast(f32, corner_y - (radius_v * @sin(angle_radians))),
                    .color = color,
                };
                const indices_index = start_indices_index + ((i - 1) * 3);
                face_writer.indices[indices_index + 0] = vertices_index + i + 1; // Current
                face_writer.indices[indices_index + 1] = vertices_index + i + 0; // Previous
                face_writer.indices[indices_index + 2] = vertices_index; // Corner
            }
            face_writer.vertices_used += points_per_curve + 2;
            face_writer.indices_used += (points_per_curve - 1) * 3;
        }
    }
}

pub fn drawRoundRect(
    extent: Extent2D(f32),
    color: RGBA(f32),
    radius: f32,
    screen_scale: ScaleFactor2D(f32),
    face_writer: *FaceWriter,
) !void {
    const radius_v = @floatCast(f32, radius * screen_scale.vertical);
    const radius_h = @floatCast(f32, radius * screen_scale.horizontal);

    const middle_extent = Extent2D(f32){
        .x = extent.x,
        .y = extent.y - radius_v,
        .width = extent.width,
        .height = extent.height - (radius_v * 2.0),
    };
    const top_extent = Extent2D(f32){
        .x = extent.x + radius_h,
        .y = extent.y - extent.height + radius_v,
        .width = extent.width - (radius_h * 2.0),
        .height = radius_v,
    };
    const bottom_extent = Extent2D(f32){
        .x = extent.x + radius_h,
        .y = extent.y,
        .width = extent.width - (radius_h * 2.0),
        .height = radius_v,
    };

    (try face_writer.create(QuadFace)).* = quadColored(middle_extent, color, .bottom_left);
    (try face_writer.create(QuadFace)).* = quadColored(top_extent, color, .bottom_left);
    (try face_writer.create(QuadFace)).* = quadColored(bottom_extent, color, .bottom_left);

    const top_left_arc_placement = Coordinates2D(f32){
        .x = extent.x + radius_h,
        .y = extent.y - (extent.height - radius_v),
    };

    try drawRoundedCorner(
        .top_left,
        top_left_arc_placement,
        color,
        radius,
        screen_scale,
        face_writer,
    );

    const bottom_left_arc_placement = Coordinates2D(f32){
        .x = extent.x + radius_h,
        .y = extent.y - radius_v,
    };

    try drawRoundedCorner(
        .bottom_left,
        bottom_left_arc_placement,
        color,
        radius,
        screen_scale,
        face_writer,
    );

    const top_right_arc_placement = Coordinates2D(f32){
        .x = extent.x + extent.width - radius_h,
        .y = extent.y - (extent.height - radius_v),
    };

    try drawRoundedCorner(
        .top_right,
        top_right_arc_placement,
        color,
        radius,
        screen_scale,
        face_writer,
    );

    const bottom_right_arc_placement = Coordinates2D(f32){
        .x = extent.x + extent.width - radius_h,
        .y = extent.y - radius_v,
    };

    try drawRoundedCorner(
        .bottom_right,
        bottom_right_arc_placement,
        color,
        radius,
        screen_scale,
        face_writer,
    );
}

pub fn drawCross(
    extent: Extent2D(f32),
    width_horizontal: f32,
    width_vertical: f32,
    color: RGBA(f32),
    face_writer: *FaceWriter,
) !void {
    const point_topleft = geometry.Coordinates2D(f32){
        .x = extent.x,
        .y = extent.y - extent.height,
    };
    const point_topright = geometry.Coordinates2D(f32){
        .x = extent.x + extent.width,
        .y = extent.y - extent.height,
    };
    const point_bottomleft = geometry.Coordinates2D(f32){
        .x = extent.x,
        .y = extent.y,
    };
    const point_bottomright = geometry.Coordinates2D(f32){
        .x = extent.x + extent.width,
        .y = extent.y,
    };
    const vertices_index: u16 = face_writer.vertices_used;
    const indices_index: u16 = face_writer.indices_used;

    const half_width_v: f32 = width_vertical / 2.0;
    const half_width_h: f32 = width_horizontal / 2.0;

    // Top right upper
    face_writer.vertices[vertices_index + 0] = GenericVertex{
        .x = point_topright.x - half_width_h,
        .y = point_topright.y,
        .color = color,
    };
    // Top right lower
    face_writer.vertices[vertices_index + 1] = GenericVertex{
        .x = point_topright.x,
        .y = point_topright.y + half_width_v,
        .color = color,
    };

    // bottom left lower
    face_writer.vertices[vertices_index + 2] = GenericVertex{
        .x = point_bottomleft.x + half_width_h,
        .y = point_bottomleft.y,
        .color = color,
    };

    // bottom left upper
    face_writer.vertices[vertices_index + 3] = GenericVertex{
        .x = point_bottomleft.x,
        .y = point_bottomleft.y - half_width_v,
        .color = color,
    };

    face_writer.indices[indices_index + 0] = vertices_index + 0; // TRU
    face_writer.indices[indices_index + 1] = vertices_index + 1; // TRL
    face_writer.indices[indices_index + 2] = vertices_index + 2; // BLL

    face_writer.indices[indices_index + 3] = vertices_index + 2; // BBL
    face_writer.indices[indices_index + 4] = vertices_index + 3; // BLU
    face_writer.indices[indices_index + 5] = vertices_index + 0; // TRU

    // Top left lower
    face_writer.vertices[vertices_index + 4] = GenericVertex{
        .x = point_topleft.x,
        .y = point_topleft.y + half_width_v,
        .color = color,
    };
    // Top left upper
    face_writer.vertices[vertices_index + 5] = GenericVertex{
        .x = point_topleft.x + half_width_h,
        .y = point_topleft.y,
        .color = color,
    };
    // Bottom right upper
    face_writer.vertices[vertices_index + 6] = GenericVertex{
        .x = point_bottomright.x,
        .y = point_bottomright.y - half_width_v,
        .color = color,
    };
    // Bottom right lower
    face_writer.vertices[vertices_index + 7] = GenericVertex{
        .x = point_bottomright.x - half_width_h,
        .y = point_bottomright.y,
        .color = color,
    };

    face_writer.indices[indices_index + 6] = vertices_index + 4; // TLL
    face_writer.indices[indices_index + 7] = vertices_index + 5; // TLU
    face_writer.indices[indices_index + 8] = vertices_index + 6; // BRU

    face_writer.indices[indices_index + 9] = vertices_index + 6; // BRU
    face_writer.indices[indices_index + 10] = vertices_index + 7; // BRL
    face_writer.indices[indices_index + 11] = vertices_index + 4; // TLL

    face_writer.vertices_used += 8;
    face_writer.indices_used += 12;
}

pub fn drawBox(
    extent: Extent2D(f32),
    border_color: RGBA(f32),
    border_width: f32,
    face_writer: *FaceWriter,
) !void {
    const extent_left = geometry.Extent2D(f32){
        .x = extent.x,
        .y = extent.y,
        .width = border_width,
        .height = extent.height,
    };
    const extent_right = geometry.Extent2D(f32){
        .x = extent.x + extent.width - border_width,
        .y = extent.y,
        .width = border_width,
        .height = extent.height,
    };
    const extent_top = geometry.Extent2D(f32){
        .x = extent.x + border_width,
        .y = (extent.y - extent.height) + border_width,
        .width = extent.width - border_width,
        .height = border_width,
    };
    const extent_bottom = geometry.Extent2D(f32){
        .x = extent.x + border_width,
        .y = extent.y,
        .width = extent.width - (border_width * 2.0),
        .height = border_width,
    };
    const border_quads = try face_writer.allocate(QuadFace, 4);
    border_quads[0] = quadColored(extent_left, border_color, .bottom_left);
    border_quads[1] = quadColored(extent_right, border_color, .bottom_left);
    border_quads[2] = quadColored(extent_top, border_color, .bottom_left);
    border_quads[3] = quadColored(extent_bottom, border_color, .bottom_left);
}

pub const TextureGreyscale = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

pub const VertexAllocatorOptions = struct {
    supported_geometry: struct {
        triangle: bool,
        quad: bool,
        triangle_fan: bool,
    },
    index_buffer: bool,
    arena_creation: bool,
};

pub fn VertexAllocator(comptime VertexType: type, comptime options: VertexAllocatorOptions) type {
    return struct {
        const vertices_per_quad = if (options.index_buffer) 4 else 6;

        pub const TriangleFace = [3]VertexType;
        pub const QuadFace = [vertices_per_quad]VertexType;

        vertices: []VertexType,
        indices: if (options.index_buffer) []u16 else void,
        vertices_used: u16,
        indices_used: if (options.index_buffer) u16 else void,

        // This allows the creation of arenas where vertices_used doesn't
        // correspond the to next vertex index
        vertex_offset: if (options.arena_creation) u16 else void,

        pub const init = if (options.index_buffer) initWithIndices else initWithoutIndices;

        fn initWithIndices(vertex_buffer: []GenericVertex, index_buffer: []u16) @This() {
            return .{
                .vertices = vertex_buffer,
                .indices = index_buffer,
                .vertices_used = 0,
                .indices_used = 0,
                .vertex_offset = 0,
            };
        }

        fn initWithoutIndices(vertex_buffer: []GenericVertex) @This() {
            return .{
                .vertices = vertex_buffer,
                .vertices_used = 0,
                .vertex_offset = 0,
            };
        }

        pub fn create(self: *@This(), comptime Type: type) !*Type {
            if (comptime Type == QuadFace) {
                assert(options.supported_geometry.quad);
                return self.createQuadFace();
            }

            if (comptime Type == TriangleFace) {
                assert(options.supported_geometry.triangle);
                return self.createTriangleFace();
            }
            @compileError("No other types supported");
        }

        pub fn createArena(self: *@This(), vertex_count: usize) @This() {
            if (comptime options.arena_creation) {
                const vertex_start = self.vertices_used;
                const vertex_end = vertex_start + vertex_count;

                const index_count = vertex_count + @divExact(vertex_count, 2);
                const index_start = self.indices_used;
                const index_end = index_start + index_count;

                self.vertices_used += @intCast(u16, vertex_count);
                self.indices_used += @intCast(u16, index_count);
                return .{
                    .vertices = self.vertices[vertex_start..vertex_end],
                    .indices = self.indices[index_start..index_end],
                    .vertices_used = 0,
                    .indices_used = 0,
                    .vertex_offset = vertex_start,
                };
            } else @compileError("VertexAllocator not created with `arena_creation feature enabled`");
            unreachable;
        }

        pub fn allocate(self: *@This(), comptime Type: type, amount: u32) ![]Type {
            if (comptime Type == QuadFace) {
                assert(options.supported_geometry.quad);
                return self.allocateQuadFaces(amount);
            }

            if (comptime Type == TriangleFace) {
                assert(options.supported_geometry.triangle);
                return self.allocateTriangleFace(amount);
            }

            @compileError("No other types supported");
        }

        pub inline fn reset(self: *@This()) void {
            self.vertices_used = 0;
            if (comptime options.index_buffer)
                self.indices_used = 0;
        }

        inline fn createQuadFace(self: *@This()) !*QuadFace {
            const vertices_used = self.vertices_used;
            if ((vertices_used + vertices_per_quad) > self.vertices.len)
                return error.OutOfSpace;

            if (comptime options.index_buffer) {
                const indices_used = self.indices_used;
                if (indices_used + 6 > self.indices.len)
                    return error.OutOfSpace;

                const vertex_index_base = vertices_used + self.vertex_offset;

                self.indices[indices_used + 0] = vertex_index_base + 0; // Top left
                self.indices[indices_used + 1] = vertex_index_base + 1; // Top right
                self.indices[indices_used + 2] = vertex_index_base + 2; // Bottom right
                self.indices[indices_used + 3] = vertex_index_base + 0; // Top left
                self.indices[indices_used + 4] = vertex_index_base + 2; // Bottom right
                self.indices[indices_used + 5] = vertex_index_base + 3; // Bottom left

                self.vertices_used += vertices_per_quad;
                self.indices_used += 6;

                return @ptrCast(*QuadFace, &self.vertices[vertices_used]);
            } else {
                self.vertices_used += vertices_per_quad;
                return @ptrCast(*QuadFace, &self.vertices[vertices_used]);
            }
            unreachable;
        }

        inline fn allocateQuadFaces(self: *@This(), amount: u32) ![]QuadFace {
            const vertices_used = self.vertices_used;
            const vertices_required = vertices_per_quad * amount;
            if ((vertices_used + vertices_required) > self.vertices.len)
                return error.OutOfSpace;

            if (comptime options.index_buffer) {
                assert(vertices_per_quad == 4);

                const indices_used = self.indices_used;
                const indices_required = 6 * amount;
                if (indices_used + indices_required > self.indices.len)
                    return error.OutOfSpace;

                var j: usize = 0;
                var vertex_index = vertices_used + self.vertex_offset;
                while (j < amount) : (j += 1) {
                    const i = indices_used + (j * 6);
                    self.indices[i + 0] = vertex_index + 0; // Top left
                    self.indices[i + 1] = vertex_index + 1; // Top right
                    self.indices[i + 2] = vertex_index + 2; // Bottom right
                    self.indices[i + 3] = vertex_index + 0; // Top left
                    self.indices[i + 4] = vertex_index + 2; // Bottom right
                    self.indices[i + 5] = vertex_index + 3; // Bottom left
                    vertex_index += 4;
                }

                self.vertices_used += @intCast(u16, vertices_per_quad * amount);
                self.indices_used += @intCast(u16, 6 * amount);

                return @ptrCast([*]QuadFace, &self.vertices[vertices_used])[0..amount];
            } else {
                assert(vertices_per_quad == 6);
                self.vertices_used += vertices_per_quad * amount;
                return @ptrCast([*]QuadFace, &self.vertices[vertices_used][0..amount]);
            }
            unreachable;
        }

        inline fn allocateTriangleFace(self: *@This(), amount: u32) !*TriangleFace {
            const vertices_used = self.vertices_used;
            const vertices_required = 3 * amount;

            if (vertices_used + vertices_required > self.vertices.len)
                return error.OutOfSpace;

            if (comptime options.index_buffer) {
                const indices_used = self.indices_used;
                const indices_required = 3 * amount;

                if (indices_used + indices_required > self.indices.len)
                    return error.OutOfSpace;

                var j: usize = 0;
                var vertex_index = vertices_used + self.vertex_offset;
                while (j < amount) : (j += 1) {
                    const i = indices_used + (j * 3);
                    self.indices[i + 0] = vertex_index + 0;
                    self.indices[i + 1] = vertex_index + 1;
                    self.indices[i + 2] = vertex_index + 2;
                    vertex_index += 3;
                }

                self.vertex_used += 3 * amount;
                self.indices_used += 3 * amount;

                return @ptrCast([*]TriangleFace, &self.vertices[vertices_used])[0..amount];
            } else {
                self.vertex_used += 3 * amount;
                return @ptrCast([*]TriangleFace, &self.vertices[vertices_used])[0..amount];
            }
            unreachable;
        }

        inline fn createTriangleFace(self: *@This()) !*TriangleFace {
            const vertices_used = self.vertices_used;
            if (vertices_used + 3 > self.vertices.len)
                return error.OutOfSpace;

            if (comptime options.index_buffer) {
                const indices_used = self.indices_used;

                if (indices_used + 3 > self.indices.len)
                    return error.OutOfSpace;

                const vertex_index: u16 = vertices_used + self.vertex_offset;
                self.indices[indices_used + 0] = vertex_index + 0;
                self.indices[indices_used + 1] = vertex_index + 1;
                self.indices[indices_used + 2] = vertex_index + 2;

                self.vertices_used += 3;
                self.indices_used += 3;

                return @ptrCast(*TriangleFace, &self.vertices[vertices_used]);
            } else {
                self.vertices_used += 3;
                return @ptrCast(*TriangleFace, &self.vertices[vertices_used]);
            }
        }
    };
}