// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const geometry = @import("geometry.zig");
const Extent2D = geometry.Extent2D;
const ScaleFactor2D = geometry.ScaleFactor2D;

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
        pub fn fromInt(r: u8, g: u8, b: u8, a: u8) @This() {
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

pub fn drawCircle(
    center: geometry.Coordinates2D(f64),
    radius_pixels: f64,
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

// TODO: Move to graphics
pub fn drawRoundRect(
    extent: Extent2D(f32),
    color: RGBA(f32),
    radius: f64,
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

    const points_per_curve = @floatToInt(u16, @floor(radius));
    const rotation_per_point = std.math.degreesToRadians(f64, 90 / @intToFloat(f64, points_per_curve - 1));

    {
        //
        // Top Left
        //
        const vertices_index: u16 = face_writer.vertices_used;
        const start_indices_index: u16 = face_writer.indices_used;
        const corner_x = extent.x + radius_h;
        const corner_y = extent.y - (extent.height - radius_v);
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
    }

    {
        //
        // Top Right
        //
        const vertices_index: u16 = face_writer.vertices_used;
        const start_indices_index: u16 = face_writer.indices_used;
        const corner_x = extent.x + extent.width - radius_h;
        const corner_y = extent.y - (extent.height - radius_v);
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
    }

    {
        //
        // Bottom Left
        //
        const vertices_index: u16 = face_writer.vertices_used;
        const start_indices_index: u16 = face_writer.indices_used;
        const corner_x = extent.x + radius_h;
        const corner_y = extent.y - radius_v;
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

    {
        //
        // Bottom Right
        //
        const vertices_index: u16 = face_writer.vertices_used;
        const start_indices_index: u16 = face_writer.indices_used;
        const corner_x = extent.x + extent.width - radius_h;
        const corner_y = extent.y - radius_v;
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
    }
}

// TODO: Move to graphics
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