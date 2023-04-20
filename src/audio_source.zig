// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

pub const backend_pulse = @import("audio_source/pulse.zig");
// pub const backend_pipewire = @import("audio_source/pipewire.zig");

const Backend = enum {
    alsa,
    pulseaudio,
    jack,
    pipewire,
};

pub const InitFn = fn (
    successCallback: *const InitSuccessCallbackFn,
    failureCallback: *const InitFailCallbackFn,
) InitError!void;

// pub const InitError = backend_pulse.InitErrors || backend_pipewire.InitErrors || error{Unknown};
pub const InitError = backend_pulse.InitErrors || error{Unknown};

pub const InitSuccessCallbackFn = fn () void;
pub const InitFailCallbackFn = fn (err: InitError) void;

pub const DeinitFn = fn () void;
pub const GetStateFn = fn () State;

pub const ListSourcesFn = fn (allocator: std.mem.Allocator, callback: *const ListReadyCallbackFn) void;
pub const ListReadyCallbackFn = fn (source_info: []SourceInfo) void;

pub const StreamHandle = packed struct(u32) {
    index: u32,
};

pub const CreateStreamFn = fn (
    source_index: ?u32,
    readSamplesCallback: *const SamplesReadyCallbackFn,
    successCallback: *const CreateStreamSuccessCallbackFn,
    failureCallback: *const CreateStreamFailCallbackFn,
) CreateStreamError!void;

// pub const CreateStreamError = backend_pulse.CreateStreamError || backend_pipewire.CreateStreamError || error{Unknown};
pub const CreateStreamError = backend_pulse.CreateStreamError || error{Unknown};

pub const SamplesReadyCallbackFn = fn (stream: StreamHandle, samples: []i16) void;
pub const CreateStreamSuccessCallbackFn = fn (stream: StreamHandle) void;
pub const CreateStreamFailCallbackFn = fn (err: CreateStreamError) void;

pub const StreamStartFn = fn (stream: StreamHandle) void;
pub const StreamPauseFn = fn (stream: StreamHandle) void;
pub const StreamCloseFn = fn (stream: StreamHandle) void;
pub const StreamStateFn = fn (stream: StreamHandle) StreamState;

pub const Interface = struct {
    init: *const InitFn,
    deinit: *const DeinitFn,
    listSources: *const ListSourcesFn,
    createStream: *const CreateStreamFn,
    streamStart: *const StreamStartFn,
    streamPause: *const StreamPauseFn,
    streamClose: *const StreamCloseFn,
    streamState: *const StreamStateFn,
};

pub const SourceType = enum {
    unknown,
    microphone,
    desktop,
};

pub const SourceInfo = struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
    source_type: SourceType = .unknown,
};

pub const State = enum {
    initializating,
    initialized,
    fatal,
    closed,
};

pub const StreamState = enum {
    initializating,
    paused,
    running,
    fatal,
    closed,
};

// TODO: Support more backends
pub fn bestInterface() Interface {
    // if (backend_pipewire.isSupported())
    //     return backend_pipewire.createInterface(on_read_sample_callback);
    if (backend_pulse.isSupported())
        return backend_pulse.interface();
    //
    // TODO: Return an error
    //
    unreachable;
}

pub fn availableBackends(backend_buffer: *[4]Backend) []Backend {
    var backend_count: u32 = 0;
    // if (backend_pipewire.isSupported()) {
    //     backend_buffer[backend_count] = .pipewire;
    //     backend_count += 1;
    // }
    if (backend_pulse.isSupported()) {
        backend_buffer[backend_count] = .pulseaudio;
        backend_count += 1;
    }
    return backend_buffer[0..backend_count];
}
