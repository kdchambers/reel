// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const geometry = @import("geometry.zig");
const app_core = @import("app_core.zig");
const RequestBuffer = app_core.RequestBuffer;

const Model = @import("Model.zig");

const build_options = @import("build_options");

const impl_headless = @import("frontends/headless.zig");
const impl_cli = @import("frontends/cli.zig");
const impl_wayland = if (build_options.have_wayland) @import("frontends/wayland.zig") else void;

pub const InterfaceImplTag = GenerateInterfaceImplTagEnum();
 
pub const InitError = impl_wayland.InitError || impl_cli.InitError || impl_headless.InitError;
pub const UpdateError = impl_wayland.UpdateError || impl_cli.UpdateError || impl_headless.UpdateError;

pub const InitFn = *const fn (allocator: std.mem.Allocator) InitError!void;
pub const DeinitFn = *const fn () void;
pub const UpdateFn = *const fn (model: *const Model) UpdateError!RequestBuffer;

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