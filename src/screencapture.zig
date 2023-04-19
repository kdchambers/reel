// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const build_options = @import("build_options");
const graphics = @import("graphics.zig");
const geometry = @import("geometry.zig");

const backend_pipewire = @import("screencapture_backends/pipewire/screencapture_pipewire.zig");
const backend_wlroots = if (build_options.have_wayland)
    @import("screencapture_backends/wlroots/screencapture_wlroots.zig")
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
        fields = fields ++ &[_]EnumField{.{ .name = "wlroots", .value = index }};
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

pub const InitErrorSet = backend_wlroots.InitErrorSet;

pub const InitFn = fn (onSuccess: *const InitOnSuccessFn, onError: *const InitOnErrorFn) void;
pub const OpenStreamFn = fn (on_success: *const OpenStreamOnSuccessFn, on_error: *const OpenStreamOnErrorFn) void;
pub const DeinitFn = fn () void;
pub const ScreenshotFn = fn (callback: *const OnScreenshotReadyFn) void;

pub const OnScreenshotReadyFn = fn (width: u32, height: u32, pixels: [*]const PixelType) void;
pub const OnFrameReadyFn = fn (width: u32, height: u32, pixels: [*]const PixelType) void;

pub const InitOnSuccessFn = fn () void;
pub const InitOnErrorFn = fn (errcode: InitErrorSet) void;

pub const OpenStreamOnSuccessFn = fn (stream_interface: StreamInterface) void;
pub const OpenStreamOnErrorFn = fn () void;

pub const StreamInterface = struct {
    pub const State = enum {
        running,
        paused,
    };

    pub const PauseFn = fn (self: @This(), is_paused: bool) void;
    pub const StateFn = fn (self: @This()) StreamInterface.State;
    pub const CloseFn = fn (self: @This()) void;

    //
    // Internal handle that represents the display
    //
    index: u32,

    pause: *const PauseFn,
    close: *const CloseFn,
    state: *const StateFn,

    dimensions: geometry.Dimensions2D(u32),
};

pub const Interface = struct {
    //
    // Vtable connecting to specific backend
    //
    init: *const InitFn,
    openStream: *const OpenStreamFn,
    deinit: *const DeinitFn,
    screenshot: *const ScreenshotFn,
};

var backend_buffer: [2]Backend = undefined;

const InterfaceBackends = union(Backend) {
    pipewire: Interface,
    wlroots: Interface,
};

fn createInterfaceInternal(comptime backend: Backend, onFrameReady: *const OnFrameReadyFn) !Interface {
    if (comptime build_options.have_wayland and backend == .wlroots)
        return backend_wlroots.createInterface(onFrameReady);
    if (comptime backend == .pipewire)
        return backend_pipewire.createInterface(onFrameReady);
    unreachable;
}

pub fn createInterface(backend: Backend, onFrameReady: *const OnFrameReadyFn) !Interface {
    return switch (backend) {
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
