// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const app_core = @import("app_core.zig");
const RequestBuffer = app_core.RequestBuffer;

const build_options = @import("build_options");

const backend_headless = @import("user_interface_backends/headless.zig");
const backend_cli = @import("user_interface_backends/cli.zig");
const backend_wayland = if (build_options.have_wayland) @import("user_interface_backends/wayland.zig") else void;

pub const Backend = GenerateBackendEnum();
 
pub const InitError = backend_wayland.InitError || backend_cli.InitError || backend_headless.InitError;
pub const UpdateError = backend_wayland.UpdateError || backend_cli.UpdateError || backend_headless.UpdateError;

pub const InitFn = *const fn (allocator: std.mem.Allocator) InitError!void;
pub const DeinitFn = *const fn () void;
pub const UpdateFn = *const fn () UpdateError!RequestBuffer;

pub const Interface = struct {
    init: InitFn,
    update: UpdateFn,
    deinit: DeinitFn,
};

pub fn interface(ui_backend: Backend) Interface {
    return switch (ui_backend) {
        inline else => |backend_enum| interfaceInternal(backend_enum),
    };
}

inline fn interfaceInternal(comptime backend: Backend) Interface {
    if (comptime backend == .headless) {
        return .{
            .init = &backend_headless.init,
            .update = &backend_headless.update,
            .deinit = &backend_headless.deinit,
        };
    }

    if (comptime backend == .cli) {
        return .{
            .init = &backend_cli.init,
            .update = &backend_cli.update,
            .deinit = &backend_cli.deinit,
        };
    }

    if (comptime build_options.have_wayland and backend == .wayland) {
        return .{
            .init = &backend_wayland.init,
            .update = &backend_wayland.update,
            .deinit = &backend_wayland.deinit,
        };
    }

    unreachable;
}

fn GenerateBackendEnum() type {
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
