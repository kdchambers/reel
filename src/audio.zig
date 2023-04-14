// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

pub const backend_pulse = @import("audio/pulse.zig");
pub const backend_pipewire = @import("audio/pipewire.zig");

const Backend = enum {
    alsa,
    pulseaudio,
    jack,
    pipewire,
};

pub const OpenError = backend_pulse.OpenErrors || backend_pipewire.OpenErrors || error{Unknown};
pub const InitError = backend_pulse.InitErrors || backend_pipewire.InitErrors || error{Unknown};

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
pub const InputListCallbackFn = fn (input_devices: []InputDeviceInfo) void;

pub const OnReadSamplesFn = fn (samples: []i16) void;

pub const InputDeviceInfo = struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
};

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
    if (backend_pipewire.isSupported())
        return backend_pipewire.createInterface(on_read_sample_callback);
    if (backend_pulse.isSupported())
        return backend_pulse.createInterface(on_read_sample_callback);
    //
    // TODO: Return an error
    //
    unreachable;
}

pub fn availableBackends(backend_buffer: *[4]Backend) []Backend {
    var backend_count: u32 = 0;
    if (backend_pipewire.isSupported()) {
        backend_buffer[backend_count] = .pipewire;
        backend_count += 1;
    }
    if (backend_pulse.isSupported()) {
        backend_buffer[backend_count] = .pulseaudio;
        backend_count += 1;
    }
    return backend_buffer[0..backend_count];
}
