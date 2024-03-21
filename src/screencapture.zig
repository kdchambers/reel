// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const build_options = @import("build_options");
const graphics = @import("graphics.zig");
const geometry = @import("geometry.zig");
const Dimensions2D = geometry.Dimensions2D;

const backend_pipewire = @import("screencapture/pipewire/screencapture_pipewire.zig");
const backend_wlroots = if (build_options.have_wayland and build_options.have_wlr_screencopy)
    @import("screencapture/wlroots/screencapture_wlroots.zig")
else
    void;

pub const State = enum(u8) {
    uninitialized,
    init_pending,
    init_failed,
    active,
    fatal_error,
    closed,
};

pub const SupportedPixelFormat = enum(u32) {
    rgba,
    rgbx,
    rgb,
    bgra,
    bgrx,
    bgr,
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

pub const StreamInfo = struct {
    name: []const u8,
    dimensions: Dimensions2D(u32),
    pixel_format: ?SupportedPixelFormat,
};

pub const BackendInfo = struct {
    name: []const u8,
    query_streams: bool,
};

pub const ScreenshotResponse = union(enum) {
    file_path: []const u8,
    file_path_c: [*:0]const u8,
    pixel_buffer: struct {
        width: u32,
        height: u32,
        pixels: [*]const PixelType,
    },
};

//
// TODO: This is to merge the error sets of all backends
//

pub const InitErrorSet = error{Init};

pub const ScreenshotError = error{
    unknown,
};

pub const InitFn = fn (onSuccess: *const InitOnSuccessFn, onError: *const InitOnErrorFn) void;
pub const OpenStreamFn = fn (
    stream_index: ?u16,
    onFrameReady: *const OnFrameReadyFn,
    on_success: *const OpenStreamOnSuccessFn,
    on_error: *const OpenStreamOnErrorFn,
    user_data: ?*const anyopaque,
) void;
pub const DeinitFn = fn () void;
pub const ScreenshotFn = fn (onSuccess: *const OnScreenshotReadyFn, onFail: *const OnScreenshotFailFn) void;
pub const QueryBackendInfoFn = fn () BackendInfo;
pub const QueryStreamInfoFn = fn (allocator: std.mem.Allocator) []const StreamInfo;

pub const OnScreenshotReadyFn = fn (response: ScreenshotResponse) void;
pub const OnScreenshotFailFn = fn (reason: []const u8) void;

pub const OnFrameReadyFn = fn (stream_handle: StreamHandle, width: u32, height: u32, pixels: [*]const PixelType) void;

pub const InitOnSuccessFn = fn () void;
pub const InitOnErrorFn = fn (errcode: InitErrorSet) void;

pub const OpenStreamOnSuccessFn = fn (stream: StreamHandle, user_data: ?*const anyopaque) void;
pub const OpenStreamOnErrorFn = fn (user_data: ?*const anyopaque) void;

pub const StreamPauseFn = fn (handle: StreamHandle, is_paused: bool) void;
pub const StreamStateFn = fn (handle: StreamHandle) StreamState;
pub const StreamCloseFn = fn (handle: StreamHandle) void;
pub const StreamInfoFn = fn (handle: StreamHandle) StreamInfo;

pub const StreamHandle = u16;

pub const StreamState = enum {
    uninitialized,
    fatal_error,
    running,
    paused,
};

pub const Interface = struct {
    //
    // Vtable connecting to specific backend
    //
    init: *const InitFn,
    openStream: *const OpenStreamFn,
    deinit: *const DeinitFn,
    screenshot: *const ScreenshotFn,
    queryStreams: *const QueryStreamInfoFn,

    streamPause: *const StreamPauseFn,
    streamClose: *const StreamCloseFn,
    streamState: *const StreamStateFn,
    streamInfo: *const StreamInfoFn,

    info: BackendInfo,
};

var backend_buffer: [2]Backend = undefined;

const InterfaceBackends = union(Backend) {
    pipewire: Interface,
    wlroots: Interface,
};

fn createInterfaceInternal(comptime backend: Backend) !Interface {
    if (comptime build_options.have_wlr_screencopy and backend == .wlroots)
        return backend_wlroots.createInterface();
    if (comptime backend == .pipewire)
        return backend_pipewire.createInterface();
    unreachable;
}

pub fn createInterface(backend: Backend) !Interface {
    return switch (backend) {
        inline else => |b| createInterfaceInternal(b),
    };
}

pub fn createBestInterface(onFrameReady: *const OnFrameReadyFn) ?Interface {
    const backends = detectBackends();
    var best_match_index: u16 = std.math.maxInt(u16);
    for (backends) |backend| {
        best_match_index = @min(best_match_index, @intFromEnum(backend));
    }
    const selected_backend: Backend = @enumFromInt(best_match_index);
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
    if (comptime build_options.have_wlr_screencopy) {
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
