// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const geometry = @import("geometry.zig");
const app_core = @import("app_core.zig");
const RequestBuffer = app_core.RequestBuffer;

const build_options = @import("build_options");

const impl_headless = @import("frontends/headless.zig");
const impl_cli = @import("frontends/cli.zig");
const impl_wayland = if (build_options.have_wayland) @import("frontends/wayland.zig") else void;

pub const InterfaceImplTag = GenerateInterfaceImplTagEnum();
 
pub const InitError = impl_wayland.InitError || impl_cli.InitError || impl_headless.InitError;
pub const UpdateError = impl_wayland.UpdateError || impl_cli.UpdateError || impl_headless.UpdateError;

pub const InitFn = *const fn (allocator: std.mem.Allocator) InitError!void;
pub const DeinitFn = *const fn () void;
pub const UpdateFn = *const fn () UpdateError!RequestBuffer;

pub const Interface = struct {
    init: InitFn,
    update: UpdateFn,
    deinit: DeinitFn,
};

pub fn interface(interface_tag: InterfaceImplTag) Interface {
    return switch (interface_tag) {
        inline else => |i| interfaceInternal(i),
    };
}

inline fn interfaceInternal(comptime interface_tag: InterfaceImplTag) Interface {
    if (comptime interface_tag == .headless) {
        return .{
            .init = &impl_headless.init,
            .update = &impl_headless.update,
            .deinit = &impl_headless.deinit,
        };
    }

    if (comptime interface_tag == .cli) {
        return .{
            .init = &impl_cli.init,
            .update = &impl_cli.update,
            .deinit = &impl_cli.deinit,
        };
    }

    if (comptime build_options.have_wayland and interface_tag == .wayland) {
        return .{
            .init = &impl_wayland.init,
            .update = &impl_wayland.update,
            .deinit = &impl_wayland.deinit,
        };
    }

    unreachable;
}

fn GenerateInterfaceImplTagEnum() type {
    const EnumField = std.builtin.Type.EnumField;
    var fields: []const EnumField = &[_]EnumField{
        .{ .name = "headless", .value = 0 },
        .{ .name = "cli", .value = 1 },
    };
    if (build_options.have_wayland) {
        fields = fields ++ &[_]EnumField{.{ .name = "wayland", .value = 2 }};
    }
    return @Type(std.builtin.Type{
        .Enum = .{
            .tag_type = u16,
            .is_exhaustive = true,
            .fields = fields,
            .decls = &.{},
        },
    });
}

pub const side_left = ScreenPoint{ .native = -1.0 };
pub const side_right = ScreenPoint{ .native = 1.0 };
pub const side_top = ScreenPoint{ .native = -1.0 };
pub const side_bottom = ScreenPoint{ .native = 1.0 };

pub const width_full = ScreenLength{ .native = 2.0 };
pub const height_full = ScreenLength{ .native = 2.0 };

pub const ScreenPoint = union(enum) {
    native: f32,
    pixel: f32,
    norm: f32,

    pub inline fn toNative(self: @This(), screen_scale: f32) f32 {
        return switch (self) {
            .native => |native| native,
            .pixel => |pixel| -1.0 + (pixel * screen_scale),
            .norm => |norm| -1.0 + (norm * 2.0),
        };
    }
};

pub const ScreenLength = union(enum) {
    native: f32,
    pixel: f32,
    norm: f32,

    pub inline fn toNative(self: @This(), screen_scale: f32) f32 {
        return switch (self) {
            .native => |native| native,
            .pixel => |pixel| pixel * screen_scale,
            .norm => |norm| norm * 2.0,
        };
    }
};

pub const ScreenExtent = struct {
    x: ScreenPoint,
    y: ScreenPoint,
    width: ScreenLength,
    height: ScreenLength,

    pub inline fn toNative(self: @This(), screen_scale: geometry.ScaleFactor2D(f32)) geometry.Extent2D(f32) {
        return .{
            .x = self.x.toNative(screen_scale.horizontal),
            .y = self.y.toNative(screen_scale.vertical),
            .width = self.width.toNative(screen_scale.horizontal),
            .height = self.height.toNative(screen_scale.vertical),
        };
    }
};

test "ScreenExtent: pixel to native" {
    const expect = std.testing.expect;
    const screen_width: f32 = 1920;
    const screen_height: f32 = 1080;
    const scale_factor = geometry.ScaleFactor2D(f32){
        .horizontal = 2.0 / screen_width,
        .vertical = 2.0 / screen_height,
    };
    {
        const extent_pixels = ScreenExtent{
            .x = .{ .pixel = @divExact(screen_width, 2) },
            .y = .{ .pixel = @divExact(screen_height, 2) },
            .width = .{ .pixel = @divExact(screen_width, 2) },
            .height = .{ .pixel = @divExact(screen_height, 2) },
        };
        const extent_native = extent_pixels.toNative(scale_factor);
        try expect(extent_native.x == 0.0);
        try expect(extent_native.y == 0.0);
        try expect(extent_native.width == 1.0);
        try expect(extent_native.height == 1.0);
    }
    {
        const screen_extent = ScreenExtent{
            .x = .{ .pixel = 0 },
            .y = .{ .pixel = 0 },
            .width = .{ .pixel = 0 },
            .height = .{ .pixel = 0 },
        };
        const extent_native = screen_extent.toNative(scale_factor);
        try expect(extent_native.x == -1.0);
        try expect(extent_native.y == -1.0);
        try expect(extent_native.width == 0.0);
        try expect(extent_native.height == 0.0);
    }
    {
        const screen_extent = ScreenExtent{
            .x = .{ .pixel = screen_width },
            .y = .{ .pixel = screen_height },
            .width = .{ .pixel = 0 },
            .height = .{ .pixel = 0 },
        };
        const extent_native = screen_extent.toNative(scale_factor);
        // std.debug.print("x {d} y {d} width {d} height {d}\n\n", .{
        //     extent_native.x,
        //     extent_native.y,
        //     extent_native.width,
        //     extent_native.height,
        // });
        try expect(extent_native.x == 1.0);
        try expect(extent_native.y == 1.0);
        try expect(extent_native.width == 0.0);
        try expect(extent_native.height == 0.0);
    }
}

test "ScreenExtent: norm to native" {
    const expect = std.testing.expect;
    const screen_width: f32 = 1920;
    const screen_height: f32 = 1080;
    const scale_factor = geometry.ScaleFactor2D(f32){
        .horizontal = 2.0 / screen_width,
        .vertical = 2.0 / screen_height,
    };
    {
        const extent_pixels = ScreenExtent{
            .x = .{ .norm = 0.5 },
            .y = .{ .norm = 0.5 },
            .width = .{ .norm = 0.5 },
            .height = .{ .norm = 0.5 },
        };
        const extent_native = extent_pixels.toNative(scale_factor);
        try expect(extent_native.x == 0.0);
        try expect(extent_native.y == 0.0);
        try expect(extent_native.width == 1.0);
        try expect(extent_native.height == 1.0);
    }
    {
        const extent_pixels = ScreenExtent{
            .x = .{ .norm = 1.0 },
            .y = .{ .norm = 1.0 },
            .width = .{ .norm = 1.0 },
            .height = .{ .norm = 1.0 },
        };
        const extent_native = extent_pixels.toNative(scale_factor);
        try expect(extent_native.x == 1.0);
        try expect(extent_native.y == 1.0);
        try expect(extent_native.width == 2.0);
        try expect(extent_native.height == 2.0);
    }
}
