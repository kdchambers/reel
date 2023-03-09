// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

pub const pulse = @import("audio/pulse.zig");

const Backend = enum {
    alsa,
    pulseaudio,
    jack,
    pipewire,
};

pub const OpenError = pulse.OpenErrors || error{Unknown};
pub const InitError = pulse.InitErrors || error{Unknown};

pub const InitFn = fn (
    successCallback: *const InitSuccessCallbackFn,
    failureCallback: *const InitFailCallbackFn,
) InitError!void;

pub const OpenFn = fn (
    device_name: ?[*:0]const u8,
    successCallback: *const OpenSuccessCallbackFn,
    failureCallback: *const OpenFailCallbackFn,
) OpenError!void;

pub const InitSuccessCallbackFn = fn () void;
pub const InitFailCallbackFn = fn (err: InitError) void;

pub const OpenSuccessCallbackFn = fn () void;
pub const OpenFailCallbackFn = fn (err: OpenError) void;

pub const CloseFn = fn () void;
pub const GetStateFn = fn () State;
pub const InputListFn = fn (allocator: std.mem.Allocator, callback: *const InputListCallbackFn) void;
pub const InputListCallbackFn = fn (input_devices: [][]const u8) void;

pub const OnReadSamplesFn = fn (samples: []i16) void;

pub const State = enum {
    initialized,
    closed,
    open,
};

pub const Interface = struct {
    init: *const InitFn,
    open: *const OpenFn,
    close: *const CloseFn,
    inputList: *const InputListFn,
    state: *const GetStateFn,
};

// TODO: Support more backends
pub fn createBestInterface(on_read_sample_callback: *const OnReadSamplesFn) Interface {
    return pulse.createInterface(on_read_sample_callback);
}

pub fn availableBackends(backend_buffer: *[4]Backend) []Backend {
    backend_buffer[0] = .pulseaudio;
    return backend_buffer[0..1];
}
