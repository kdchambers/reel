// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const graphics = @import("graphics.zig");

const backend_pipewire = @import("screencast_backends/pipewire/screencast_pipewire.zig");

pub const State = enum(u8) {
    uninitialized,
    init_pending,
    init_failed,
    open,
    closed,
    paused,
};

pub const OpenOnSuccessFn = fn (width: u32, height: u32) void;
pub const OpenOnErrorFn = fn () void;

pub const PixelType = graphics.RGBA(u8);
pub const FrameImage = graphics.Image(PixelType);

/// List of backends for screencasting, ordered in terms of preference
/// Top of the list being the most preferable
pub const Backend = enum(u16) {
    wlr,
    pipewire,
    invalid = std.math.maxInt(u16),
};

//
// TODO: This is to merge the error sets of all backends
//
pub const RequestOpenErrorSet = backend_pipewire.InitErrorSet;

pub const RequestOpenFn = fn (onSuccess: *const OpenOnSuccessFn, onError: *const OpenOnErrorFn) RequestOpenErrorSet!void;
pub const StateFn = fn () State;
pub const NextFrameImageFn = fn () ?FrameImage;
pub const PauseFn = fn () void;
pub const UnpauseFn = fn () void;
pub const CloseFn = fn () void;

pub const Interface = struct {
    //
    // Vtable connecting to specific backend
    //
    requestOpen: *const RequestOpenFn,
    state: *const StateFn,
    nextFrameImage: *const NextFrameImageFn,
    pause: *const PauseFn,
    unpause: *const UnpauseFn,
    close: *const CloseFn,
};

var backend_buffer: [2]Backend = undefined;

pub fn createInterface(backend: Backend) !Interface {
    return switch (backend) {
        .pipewire => backend_pipewire.createInterface(),
        //
        // TODO: Implement other backends
        //
        else => unreachable,
    };
}

pub fn createBestInterface() ?Interface {
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
        .pipewire => backend_pipewire.createInterface(),
        .wlr => null,
        else => null,
    };
}

// TODO: Implement properly
pub fn detectBackends() []Backend {
    backend_buffer[0] = .pipewire;
    return backend_buffer[0..1];
}
