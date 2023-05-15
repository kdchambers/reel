// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;
const DynLib = std.DynLib;

const root = @import("../audio_source.zig");
const InitSuccessCallbackFn = root.InitSuccessCallbackFn;
const InitFailCallbackFn = root.InitFailCallbackFn;
const OpenFailCallbackFn = root.OpenFailCallbackFn;
const OpenSuccessCallbackFn = root.OpenSuccessCallbackFn;
const State = root.State;
const ListReadyCallbackFn = root.ListReadyCallbackFn;
const SourceInfo = root.SourceInfo;
const SamplesReadyCallbackFn = root.SamplesReadyCallbackFn;
const StreamState = root.StreamState;
const StreamHandle = root.StreamHandle;
const CreateStreamSuccessCallbackFn = root.CreateStreamSuccessCallbackFn;
const CreateStreamFailCallbackFn = root.CreateStreamFailCallbackFn;

const pa = @import("../bindings/pulse/pulse.zig");

pub const InitErrors = error{
    LibraryNotAvailable,
    LookupFailed,
    PulseThreadedLoopStartFail,
    PulseThreadedLoopCreateFail,
    PulseThreadedLoopGetApiFail,
    PulseContextCreateFail,
    PulseContextStartFail,
    PulseConnectServerFail,
};

pub const CreateStreamError = error{
    MaxStreamCountReached,
    InvalidSourceIndex,
    //
    // Pulse Specific
    //
    PulseStreamCreateFail,
    PulseStreamConnectFail,
    PulseStreamStartFail,
};

const max_concurrent_streams = 4;
const max_source_count = 16;

const default_sample_spec = pa.SampleSpec{
    .format = .s16le,
    .rate = 44100,
    .channels = 2,
};

var pulse_thread_loop: *pa.ThreadedMainloop = undefined;
var pulse_loop_api: *pa.MainloopApi = undefined;
var pulse_context: *pa.Context = undefined;

const Stream = struct {
    samplesReadyCallback: *const SamplesReadyCallbackFn = undefined,
    pulse_stream: *pa.Stream = undefined,
    state: StreamState = .closed,
};

const required_symbols = pa.SymbolList{
    .threaded_mainloop_new = true,
    .threaded_mainloop_get_api = true,
    .threaded_mainloop_start = true,
    .threaded_mainloop_free = true,
    .threaded_mainloop_stop = true,
    .threaded_mainloop_unlock = true,
    .threaded_mainloop_lock = true,
    .threaded_mainloop_wait = true,

    .context_new = true,
    .context_new_with_proplist = true,
    .context_connect = true,
    .context_disconnect = true,
    .context_unref = true,
    .context_set_state_callback = true,
    .context_get_state = true,
    .context_get_source_info_list = true,
    .context_get_card_info_list = true,
    .context_get_source_info_by_index = true,

    .stream_new = true,
    .stream_set_read_callback = true,
    .stream_peek = true,
    .stream_drop = true,
    .stream_get_state = true,
    .stream_set_state_callback = true,
    .stream_connect_record = true,
    .stream_unref = true,
    .stream_get_sample_spec = true,
    .stream_get_channel_map = true,
    .stream_get_device_name = true,
    .stream_get_device_index = true,
};

var handles: pa.DynamicLoader(required_symbols) = undefined;

var backend_state: State = .closed;
var library_handle_opt: ?DynLib = null;

var stream_buffer = [1]Stream{.{}} ** max_concurrent_streams;

var active_callbacks: union {
    init: struct {
        onSuccess: *const InitSuccessCallbackFn,
        onFail: *const InitFailCallbackFn,
    },
    create_stream: struct {
        onSuccess: *const CreateStreamSuccessCallbackFn,
        onFail: *const CreateStreamFailCallbackFn,
    },
} = undefined;

var sourceListReadyCallback: *const ListReadyCallbackFn = undefined;

var list_sources_allocator: std.mem.Allocator = undefined;

var source_buffer: [max_source_count]SourceInfo = undefined;
var source_count: u32 = 0;

pub fn isSupported() bool {
    if (library_handle_opt == null) {
        library_handle_opt = DynLib.open("libpulse.so.0") catch return false;
    }
    return true;
}

pub fn interface() root.Interface {
    return .{
        .init = &init,
        .deinit = &deinit,
        .listSources = &listSources,
        .createStream = &createStream,
        .streamStart = &streamStart,
        .streamPause = &streamPause,
        .streamClose = &streamClose,
        .streamState = &streamState,

        .info = .{ .name = "pulseaudio" },
    };
}

pub fn init(
    onSuccess: *const InitSuccessCallbackFn,
    onFail: *const InitFailCallbackFn,
) InitErrors!void {
    assert(backend_state == .closed);

    active_callbacks = .{ .init = .{
        .onSuccess = onSuccess,
        .onFail = onFail,
    } };

    var library_handle = library_handle_opt orelse DynLib.open("libpulse.so") catch return error.LibraryNotAvailable;
    handles.load(&library_handle) catch return error.LibraryNotAvailable;

    pulse_thread_loop = handles.threaded_mainloop_new() orelse
        return error.PulseThreadedLoopCreateFail;
    pulse_loop_api = handles.threaded_mainloop_get_api(pulse_thread_loop) orelse
        return error.PulseThreadedLoopGetApiFail;
    pulse_context = handles.context_new(pulse_loop_api, "Reel") orelse
        return error.PulseContextCreateFail;
    if (handles.context_connect(pulse_context, null, .{}, null) < 0) {
        return error.PulseConnectServerFail;
    }

    backend_state = .initializating;

    handles.context_set_state_callback(pulse_context, onContextStateChangedCallback, null);

    if (handles.threaded_mainloop_start(pulse_thread_loop) != 0) {
        return error.PulseThreadedLoopStartFail;
    }
}

pub fn deinit() void {
    for (stream_buffer) |stream| {
        if (stream.state == .paused or stream.state == .running) {
            //
            // TODO: Don't just unref, disconnect, etc
            //
            handles.stream_unref(stream.pulse_stream);
        }
    }

    handles.context_disconnect(pulse_context);
    handles.context_unref(pulse_context);
    handles.threaded_mainloop_stop(pulse_thread_loop);
    handles.threaded_mainloop_free(pulse_thread_loop);

    for (source_buffer[0..source_count]) |source_info| {
        list_sources_allocator.free(std.mem.span(source_info.name));
        list_sources_allocator.free(std.mem.span(source_info.description));
    }
}

fn state() State {
    return backend_state;
}

fn listSources(allocator: std.mem.Allocator, listReadyCallback: *const ListReadyCallbackFn) void {
    assert(backend_state == .initialized);
    if (source_count > 0) {
        //
        // We've already stored the list, just return it
        //
        listReadyCallback(source_buffer[0..source_count]);
    } else {
        list_sources_allocator = allocator;
        sourceListReadyCallback = listReadyCallback;
        _ = handles.context_get_source_info_list(pulse_context, handleSourceInfo, null);
    }
}

pub fn createStream(
    source_index_opt: ?u32,
    samplesReadyCallback: *const SamplesReadyCallbackFn,
    onSuccess: *const CreateStreamSuccessCallbackFn,
    onFail: *const CreateStreamFailCallbackFn,
) CreateStreamError!void {
    assert(backend_state == .initialized);

    //
    // TODO: Add back support for opening default stream
    //       Because the design is a little broken atm we're gonna
    //       assume / assert that source_index corresponds to the index
    //       of the source returned by pulse
    //
    assert(source_index_opt != null);

    active_callbacks = .{ .create_stream = .{
        .onSuccess = onSuccess,
        .onFail = onFail,
    } };

    var stream_ptr = &stream_buffer[source_index_opt.?];
    assert(stream_ptr.state == .closed);
    stream_ptr.samplesReadyCallback = samplesReadyCallback;
    stream_ptr.state = .initializating;

    // var stream_ptr: *Stream = blk: {
    //     for (&stream_buffer) |*stream| {
    //         if (stream.state == .closed) {
    //             stream.samplesReadyCallback = samplesReadyCallback;
    //             stream.state = .initializating;
    //             break :blk stream;
    //         }
    //     }
    //     return error.MaxStreamCountReached;
    // };

    const pulse_stream = handles.stream_new(pulse_context, "Audio Input", &default_sample_spec, null) orelse
        return error.PulseStreamCreateFail;

    stream_ptr.*.pulse_stream = pulse_stream;

    handles.stream_set_state_callback(pulse_stream, onStreamStateCallback, stream_ptr);
    handles.stream_set_read_callback(pulse_stream, streamReadCallback, stream_ptr);

    const target_fps = 30;
    const bytes_per_sample = 2 * @sizeOf(i16);
    const bytes_per_second = 44100 * bytes_per_sample;
    const buffer_size: u32 = @divExact(bytes_per_second, target_fps);

    const flags: pa.StreamFlags = .{};
    const buffer_attributes = pa.BufferAttr{
        .max_length = std.math.maxInt(u32),
        .tlength = std.math.maxInt(u32),
        .minreq = std.math.maxInt(u32),
        .prebuf = buffer_size,
        .fragsize = buffer_size,
    };

    //
    // If using `source_index_opt`, it's required that listSources has already
    // been called. Otherwise it's not possible to know what it would refer to.
    //
    if (source_index_opt) |source_index|
        assert(source_index < source_count);

    const source_name = if (source_index_opt) |source_index| source_buffer[source_index].name else null;

    std.log.info("audio_input_pulse: Connecting to device \"{s}\"", .{source_name orelse "default"});
    if (handles.stream_connect_record(pulse_stream, source_name, &buffer_attributes, flags) != 0) {
        return error.PulseStreamConnectFail;
    }
}

fn streamStart(stream: StreamHandle) void {
    assert(stream.index < max_concurrent_streams);
    assert(stream_buffer[stream.index].state == .paused);
    stream_buffer[stream.index].state = .running;
}

fn streamPause(stream: StreamHandle) void {
    assert(stream.index < max_concurrent_streams);
    assert(stream_buffer[stream.index].state == .running);
    stream_buffer[stream.index].state = .paused;
}

fn streamClose(stream: StreamHandle) void {
    assert(stream.index < max_concurrent_streams);
    handles.stream_unref(stream_buffer[stream.index].pulse_stream);
    stream_buffer[stream.index].state = .closed;
    assert(stream_buffer[stream.index].state == .closed);
}

fn streamState(stream: StreamHandle) StreamState {
    assert(stream.index < max_concurrent_streams);
    return stream_buffer[stream.index].state;
}

fn onStreamStateCallback(pulse_stream: *pa.Stream, userdata: ?*anyopaque) callconv(.C) void {
    const stream = @ptrCast(*Stream, @alignCast(@alignOf(Stream), userdata));
    switch (handles.stream_get_state(pulse_stream)) {
        .creating => assert(stream.state == .initializating),
        .ready => {
            assert(stream.state == .initializating);
            const sample_spec = handles.stream_get_sample_spec(pulse_stream);
            const channel_map = handles.stream_get_channel_map(pulse_stream);
            assert(sample_spec.channels == channel_map.channels);
            std.log.info("Audio input stream channels: {d} {s} {s}", .{
                channel_map.channels,
                @tagName(channel_map.map[0]),
                @tagName(channel_map.map[1]),
            });

            stream.state = .paused;
            active_callbacks.create_stream.onSuccess(.{
                //
                // Calculate the index based on where the pointer is positioned in `stream_buffer`
                //
                .index = @intCast(u32, @divExact(@ptrToInt(stream) - @ptrToInt(&stream_buffer[0]), @sizeOf(Stream))),
            });
        },
        .failed => {
            stream.state = .fatal;
            active_callbacks.create_stream.onFail(error.PulseStreamStartFail);
        },
        .terminated => {
            assert(stream.state == .paused or stream.state == .running);
            stream.state = .closed;
        },
        .unconnected => std.log.info("pulse: Stream unconnected", .{}),
    }
}

fn onContextStateChangedCallback(context: *pa.Context, success: i32, userdata: ?*anyopaque) callconv(.C) void {
    //
    // TODO: Check the `success` parameter
    //
    _ = success;
    _ = userdata;

    switch (handles.context_get_state(context)) {
        .connecting, .authorizing, .setting_name => assert(backend_state == .initializating),
        .ready => {
            assert(backend_state == .initializating);
            std.log.info("pulse: Connected to context", .{});
            backend_state = .initialized;
            active_callbacks.init.onSuccess();
        },
        .terminated => {
            assert(backend_state == .initialized);
            backend_state = .closed;
            std.log.info("pulse: Terminated", .{});
        },
        .failed => {
            backend_state = .fatal;
            active_callbacks.init.onFail(error.PulseContextStartFail);
        },
        .unconnected => std.log.info("pulse: Unconnected", .{}),
    }
}

fn streamReadCallback(pulse_stream: *pa.Stream, bytes_available_count: u64, userdata: ?*anyopaque) callconv(.C) void {
    const stream = @ptrCast(*Stream, @alignCast(@alignOf(Stream), userdata));
    assert(stream.state == .paused or stream.state == .running);

    assert(backend_state == .initialized);

    if (stream.state == .running)
        return;

    var pcm_buffer_opt: ?[*]i16 = undefined;
    var bytes_read_count: u64 = bytes_available_count;
    const ret_code = handles.stream_peek(pulse_stream, @ptrCast(*?*void, &pcm_buffer_opt), &bytes_read_count);
    if (ret_code < 0) {
        std.log.err("Failed to read stream", .{});
        // TODO:
        assert(false);
    }

    if (pcm_buffer_opt) |pcm_buffer| {
        stream.samplesReadyCallback(
            //
            // Calculate the index based on where the pointer is positioned in `stream_buffer`
            //
            StreamHandle{ .index = @intCast(u32, @divExact(@ptrToInt(stream) - @ptrToInt(&stream_buffer[0]), @sizeOf(Stream))) },
            pcm_buffer[0..@divExact(bytes_read_count, @sizeOf(i16))],
        );
    } else {
        //
        // There's no input data to read
        //
        if (bytes_read_count != 0)
            return;
        //
        // If `temp_buffer_opt` == null, but `bytes_read_count` != 0, it indicates there is a hole in the
        // audio stream. In this scenario we still want to call `pa_stream_drop`.
        // https://freedesktop.org/software/pulseaudio/doxygen/stream_8h.html#ac2838c449cde56e169224d7fe3d00824
        //
    }
    if (handles.stream_drop(pulse_stream) != 0) {
        std.log.err("pa_stream_drop fail", .{});
    }
}

fn handleCardInfo(context: *pa.Context, info: *const pa.CardInfo, eol: i32, userdata: ?*anyopaque) callconv(.C) void {
    _ = context;
    _ = userdata;
    if (eol > 0) return;
    std.log.info("Card: {s}", .{info.name});
}

fn handleSourceInfo(context: *pa.Context, info: *const pa.SourceInfo, eol: i32, userdata: ?*anyopaque) callconv(.C) void {
    _ = context;
    _ = userdata;

    assert(backend_state == .initialized);

    if (eol > 0) {
        sourceListReadyCallback(source_buffer[0..source_count]);
        return;
    }

    std.log.info("Name: {s}", .{info.description});
    std.log.info("State: {s}", .{@tagName(info.state)});
    std.log.info("Monitor: {s}", .{info.monitor_of_sink_name orelse "null"});
    std.log.info("Is monitor? {s}", .{if (info.monitor_of_sink == pa.invalid_index) "false" else "true"});

    for (0..info.n_ports) |i| {
        const current_port = info.ports[i];
        std.log.info("  {d} Port type: {s} name: {s} desc: {s}", .{
            i,
            @tagName(current_port.*.type),
            current_port.*.name,
            current_port.*.description,
        });
    }

    if (source_count >= max_source_count) {
        std.log.warn("pulse: Internal input device buffer full. Ignoring device", .{});
        return;
    }

    const name = list_sources_allocator.dupeZ(u8, std.mem.span(info.name)) catch "";
    const description = list_sources_allocator.dupeZ(u8, std.mem.span(info.description)) catch "";
    source_buffer[source_count] = .{
        .name = name,
        .description = description,
    };

    source_buffer[source_count].source_type = .unknown;

    choose_type: {
        if (info.monitor_of_sink != pa.invalid_index) {
            //
            // If the audio source is a monitor for a sink, we assume it's monitoring
            // desktop audio
            //
            source_buffer[source_count].source_type = .desktop;
            std.log.info("Adding desktop output", .{});
        } else if (info.active_port) |active_port| {
            if (active_port.available == .no) {
                std.log.info("Port not available", .{});
                break :choose_type;
            }
            //
            // Otherwise, check what type of audio source it is based on the port
            //
            if (active_port.*.type == .analog or active_port.*.type == .mic) {
                source_buffer[source_count].source_type = .microphone;
                std.log.info("Adding mic", .{});
            }
        }
    }

    source_count += 1;
}

fn handleSinkInfo(context: *pa.Context, info: *const pa.SinkInfo, eol: i32, userdata: ?*anyopaque) callconv(.C) void {
    _ = context;
    _ = userdata;
    if (eol > 0) return;
    std.log.info("Sink: {s} {s}", .{ info.name, info.description });
}
