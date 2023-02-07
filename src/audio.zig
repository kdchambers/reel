// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

pub const pulse = @import("audio/pulse.zig");

const Backend = enum {
    alsa,
    pulseaudio,
    jack,
    pipewire,
};

pub const OpenError = pulse.OpenErrors || error{Unknown};

pub const OpenFn = fn () OpenError!void;
pub const CloseFn = fn () void;
pub const OnReadSamplesFn = fn (samples: []i16) void;

pub const Interface = struct {
    open: *const OpenFn,
    close: *const CloseFn,
};

// TODO: Support more backends
pub fn createBestInterface(on_read_sample_callback: *const OnReadSamplesFn) Interface {
    return pulse.createInterface(on_read_sample_callback);
}

pub fn availableBackends(backend_buffer: *[4]Backend) []Backend {
    backend_buffer[0] = .pulseaudio;
    return backend_buffer[0..1];
}
