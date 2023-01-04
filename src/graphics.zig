// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const geometry = @import("geometry.zig");

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
) QuadFace(VertexType) {
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

pub fn generateTexturedQuad(
    comptime VertexType: type,
    extent: geometry.Extent2D(TypeOfField(VertexType, "x")),
    texture_extent: geometry.Extent2D(TypeOfField(VertexType, "tx")),
    comptime anchor_point: AnchorPoint,
) QuadFace(VertexType) {
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

pub fn generateQuadColored(
    comptime VertexType: type,
    extent: geometry.Extent2D(TypeOfField(VertexType, "x")),
    quad_color: RGBA(f32),
    comptime anchor_point: AnchorPoint,
) QuadFace(VertexType) {
    std.debug.assert(TypeOfField(VertexType, "x") == TypeOfField(VertexType, "y"));
    var base_quad = generateQuad(VertexType, extent, anchor_point);
    base_quad[0].color = quad_color;
    base_quad[1].color = quad_color;
    base_quad[2].color = quad_color;
    base_quad[3].color = quad_color;
    return base_quad;
}

pub const GenericVertex = packed struct {
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

    pub fn nullFace() QuadFace(GenericVertex) {
        return .{ .{}, .{}, .{}, .{} };
    }
};

pub fn QuadFace(comptime VertexType: type) type {
    return [4]VertexType;
}

pub fn RGB(comptime BaseType: type) type {
    return packed struct {
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
    return packed struct {
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

/// Used to allocate QuadFaceWriters that share backing memory
pub fn QuadFaceWriterPool(comptime VertexType: type) type {
    return struct {
        memory_ptr: [*]QuadFace(VertexType),
        memory_quad_range: u32,

        pub fn initialize(start: [*]align(@alignOf(VertexType)) u8, memory_quad_range: u32) @This() {
            return .{
                .memory_ptr = @ptrCast([*]QuadFace(VertexType), start),
                .memory_quad_range = memory_quad_range,
            };
        }

        pub fn create(self: *@This(), quad_index: u16, quad_size: u16) QuadFaceWriter(VertexType) {
            std.debug.assert((quad_index + quad_size) <= self.memory_quad_range);
            return QuadFaceWriter(VertexType).initialize(self.memory_ptr, quad_index, quad_size);
        }
    };
}

pub fn QuadFaceWriter(comptime VertexType: type) type {
    return struct {
        memory_ptr: [*]QuadFace(VertexType),

        quad_index: u32,
        capacity: u32,
        used: u32 = 0,

        pub fn initialize(base: [*]QuadFace(VertexType), quad_index: u32, quad_size: u32) @This() {
            return .{
                .memory_ptr = @ptrCast([*]QuadFace(VertexType), &base[quad_index]),
                .quad_index = quad_index,
                .capacity = quad_size,
                .used = 0,
            };
        }

        pub fn indexFromBase(self: @This()) u32 {
            return self.quad_index + self.used;
        }

        pub fn remaining(self: *@This()) u32 {
            std.debug.assert(self.capacity >= self.used);
            return @intCast(u32, self.capacity - self.used);
        }

        pub fn reset(self: *@This()) void {
            self.used = 0;
        }

        pub fn create(self: *@This()) !*QuadFace(VertexType) {
            if (self.used == self.capacity) return error.OutOfMemory;
            defer self.used += 1;
            return &self.memory_ptr[self.used];
        }

        pub fn allocate(self: *@This(), amount: u32) ![]QuadFace(VertexType) {
            if ((self.used + amount) > self.capacity) return error.OutOfMemory;
            defer self.used += amount;
            return self.memory_ptr[self.used .. self.used + amount];
        }
    };
}