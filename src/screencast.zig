// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const build_options = @import("build_options");
const graphics = @import("graphics.zig");

const backend_pipewire = @import("screencast_backends/pipewire/screencast_pipewire.zig");
const backend_wlroots = if (build_options.have_wayland)
    @import("screencast_backends/wlroots/screencast_wlroots.zig")
else
    void;

pub const State = enum(u8) {
    uninitialized,
    init_pending,
    init_failed,
    open,
    fatal_error,
    closed,
    paused,
};

pub const OpenOnSuccessFn = fn (width: u32, height: u32) void;
pub const OpenOnErrorFn = fn () void;

pub const PixelType = graphics.RGBA(u8);
pub const FrameImage = graphics.Image(PixelType);

pub const Backend = GenerateBackendEnum();

fn GenerateBackendEnum() type {
    const EnumField = std.builtin.Type.EnumField;
    var fields: []const EnumField = &[_]EnumField{};
    var index = 0;
    fields = fields ++ &[_]EnumField{.{ .name = "pipewire", .value = index }};
    index += 1;
    if (build_options.have_wayland) {
        fields = fields ++ &[_]EnumField{ .{ .name = "wlroots", .value = index } };
        index += 1;
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

//
// TODO: This is to merge the error sets of all backends
//
pub const RequestOpenErrorSet = backend_pipewire.InitErrorSet;

pub const RequestOpenFn = fn (onSuccess: *const OpenOnSuccessFn, onError: *const OpenOnErrorFn) RequestOpenErrorSet!void;
pub const StateFn = fn () State;
pub const OnFrameReadyFn = fn (width: u32, height: u32, pixels: [*]const PixelType) void;
pub const PauseFn = fn () void;
pub const UnpauseFn = fn () void;
pub const CloseFn = fn () void;

pub const Interface = struct {
    //
    // Vtable connecting to specific backend
    //
    requestOpen: *const RequestOpenFn,
    state: *const StateFn,
    pause: *const PauseFn,
    unpause: *const UnpauseFn,
    close: *const CloseFn,
};

var backend_buffer: [2]Backend = undefined;

const InterfaceBackends = union(Backend) {
    pipewire: Interface,
    wlroots: Interface,
};

fn createInterfaceInternal(comptime backend: Backend, onFrameReady: *const OnFrameReadyFn) !Interface {
    if(comptime build_options.have_wayland and backend == .wlroots)
        return backend_wlroots.createInterface(onFrameReady);
    if(comptime backend == .pipewire)
        return backend_pipewire.createInterface(onFrameReady);
    unreachable;
}

pub fn createInterface(backend: Backend, onFrameReady: *const OnFrameReadyFn) !Interface {
    return switch(backend) {
        inline else => |b| createInterfaceInternal(b, onFrameReady),
    };
}

pub fn createBestInterface(onFrameReady: *const OnFrameReadyFn) ?Interface {
    const backends = detectBackends();
    var best_match_index: u16 = std.math.maxInt(u16);
    for (backends) |backend| {
        best_match_index = @min(best_match_index, @enumToInt(backend));
    }
    const selected_backend = @intToEnum(Backend, best_match_index);
    std.log.info("Screencast backend selected: {s}", .{
        @tagName(selected_backend),
    });
    return switch (selected_backend) {
        .pipewire => backend_pipewire.createInterface(onFrameReady),
        .wlroots => backend_wlroots.createInterface(onFrameReady),
        else => null,
    };
}

pub fn detectBackends() []Backend {
    var index: usize = 0;
    if (comptime build_options.have_wayland) {
        const have_wlroots = backend_wlroots.detectSupport();
        if (have_wlroots) {
            backend_buffer[index] = .wlroots;
            index += 1;
        }
    }

    const have_pipewire = backend_pipewire.detectSupport();
    if (have_pipewire) {
        backend_buffer[index] = .pipewire;
        index += 1;
    }
    return backend_buffer[0..index];
}
