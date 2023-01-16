// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

pub const pulse = @import("audio/pulse.zig");

const Backend = enum {
    alsa,
    pulseaudio,
    jack,
    pipewire,
};

pub fn availableBackends(backend_buffer: *[4]Backend) []Backend {
    backend_buffer[0] = .pulseaudio;
    return backend_buffer[0..1];
}
