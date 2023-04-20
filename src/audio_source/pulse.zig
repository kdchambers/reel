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

pub const StreamDirection = enum(i32) {
    no_direction = 0,
    playback = 1,
    record = 2,
    upload = 3,
};

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

var pulse_thread_loop: *pa_threaded_mainloop = undefined;
var pulse_loop_api: *pa_mainloop_api = undefined;
var pulse_context: *pa_context = undefined;

const Stream = struct {
    samplesReadyCallback: *const SamplesReadyCallbackFn = undefined,
    pulse_stream: *pa_stream = undefined,
    state: StreamState = .closed,
};

var handles: DynamicHandles = undefined;
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

var sourceListReadyCallback: ?*const ListReadyCallbackFn = null;

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

    handles.threaded_mainloop_new = library_handle.lookup(@TypeOf(handles.threaded_mainloop_new), "pa_threaded_mainloop_new") orelse
        return error.LookupFailed;
    handles.threaded_mainloop_get_api = library_handle.lookup(@TypeOf(handles.threaded_mainloop_get_api), "pa_threaded_mainloop_get_api") orelse
        return error.LookupFailed;
    handles.threaded_mainloop_start = library_handle.lookup(@TypeOf(handles.threaded_mainloop_start), "pa_threaded_mainloop_start") orelse
        return error.LookupFailed;
    handles.threaded_mainloop_free = library_handle.lookup(@TypeOf(handles.threaded_mainloop_free), "pa_threaded_mainloop_free") orelse
        return error.LookupFailed;
    handles.threaded_mainloop_stop = library_handle.lookup(@TypeOf(handles.threaded_mainloop_stop), "pa_threaded_mainloop_stop") orelse
        return error.LookupFailed;
    handles.threaded_mainloop_unlock = library_handle.lookup(@TypeOf(handles.threaded_mainloop_unlock), "pa_threaded_mainloop_unlock") orelse
        return error.LookupFailed;
    handles.threaded_mainloop_lock = library_handle.lookup(@TypeOf(handles.threaded_mainloop_lock), "pa_threaded_mainloop_lock") orelse
        return error.LookupFailed;
    handles.threaded_mainloop_wait = library_handle.lookup(@TypeOf(handles.threaded_mainloop_wait), "pa_threaded_mainloop_wait") orelse
        return error.LookupFailed;

    handles.context_new = library_handle.lookup(@TypeOf(handles.context_new), "pa_context_new") orelse
        return error.LookupFailed;
    handles.context_new_with_proplist = library_handle.lookup(@TypeOf(handles.context_new_with_proplist), "pa_context_new_with_proplist") orelse
        return error.LookupFailed;
    handles.context_connect = library_handle.lookup(@TypeOf(handles.context_connect), "pa_context_connect") orelse
        return error.LookupFailed;
    handles.context_disconnect = library_handle.lookup(@TypeOf(handles.context_disconnect), "pa_context_disconnect") orelse
        return error.LookupFailed;
    handles.context_unref = library_handle.lookup(@TypeOf(handles.context_unref), "pa_context_unref") orelse
        return error.LookupFailed;
    handles.context_set_state_callback = library_handle.lookup(@TypeOf(handles.context_set_state_callback), "pa_context_set_state_callback") orelse
        return error.LookupFailed;
    handles.context_get_state = library_handle.lookup(@TypeOf(handles.context_get_state), "pa_context_get_state") orelse
        return error.LookupFailed;
    handles.context_get_sink_info_list = library_handle.lookup(@TypeOf(handles.context_get_sink_info_list), "pa_context_get_sink_info_list") orelse
        return error.LookupFailed;
    handles.context_get_source_info_list = library_handle.lookup(@TypeOf(handles.context_get_source_info_list), "pa_context_get_source_info_list") orelse
        return error.LookupFailed;
    handles.context_get_card_info_list = library_handle.lookup(@TypeOf(handles.context_get_card_info_list), "pa_context_get_card_info_list") orelse
        return error.LookupFailed;
    handles.context_get_source_info_by_index = library_handle.lookup(@TypeOf(handles.context_get_source_info_by_index), "pa_context_get_source_info_by_index") orelse
        return error.LookupFailed;

    handles.stream_new = library_handle.lookup(@TypeOf(handles.stream_new), "pa_stream_new") orelse
        return error.LookupFailed;
    handles.stream_set_read_callback = library_handle.lookup(@TypeOf(handles.stream_set_read_callback), "pa_stream_set_read_callback") orelse
        return error.LookupFailed;
    handles.stream_peek = library_handle.lookup(@TypeOf(handles.stream_peek), "pa_stream_peek") orelse
        return error.LookupFailed;
    handles.stream_drop = library_handle.lookup(@TypeOf(handles.stream_drop), "pa_stream_drop") orelse
        return error.LookupFailed;
    handles.stream_get_state = library_handle.lookup(@TypeOf(handles.stream_get_state), "pa_stream_get_state") orelse
        return error.LookupFailed;
    handles.stream_set_state_callback = library_handle.lookup(@TypeOf(handles.stream_set_state_callback), "pa_stream_set_state_callback") orelse
        return error.LookupFailed;
    handles.stream_connect_record = library_handle.lookup(@TypeOf(handles.stream_connect_record), "pa_stream_connect_record") orelse
        return error.LookupFailed;
    handles.stream_unref = library_handle.lookup(@TypeOf(handles.stream_unref), "pa_stream_unref") orelse
        return error.LookupFailed;
    handles.stream_get_sample_spec = library_handle.lookup(@TypeOf(handles.stream_get_sample_spec), "pa_stream_get_sample_spec") orelse
        return error.LookupFailed;
    handles.stream_get_channel_map = library_handle.lookup(@TypeOf(handles.stream_get_channel_map), "pa_stream_get_channel_map") orelse
        return error.LookupFailed;
    handles.stream_get_device_name = library_handle.lookup(@TypeOf(handles.stream_get_device_name), "pa_stream_get_device_name") orelse
        return error.LookupFailed;
    handles.stream_get_device_index = library_handle.lookup(@TypeOf(handles.stream_get_device_index), "pa_stream_get_device_index") orelse
        return error.LookupFailed;

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

    active_callbacks = .{ .create_stream = .{
        .onSuccess = onSuccess,
        .onFail = onFail,
    } };

    var stream_ptr: *Stream = blk: {
        for (&stream_buffer) |*stream| {
            if (stream.state == .closed) {
                stream.samplesReadyCallback = samplesReadyCallback;
                stream.state = .initializating;
                break :blk stream;
            }
        }
        return error.MaxStreamCountReached;
    };

    handles.threaded_mainloop_lock(pulse_thread_loop);

    const pulse_stream = handles.stream_new(pulse_context, "Audio Input", &_sample_spec, null) orelse
        return error.PulseStreamCreateFail;

    stream_ptr.*.pulse_stream = pulse_stream;

    handles.stream_set_state_callback(pulse_stream, onStreamStateCallback, stream_ptr);
    handles.stream_set_read_callback(pulse_stream, streamReadCallback, stream_ptr);

    const target_fps = 30;
    const bytes_per_sample = 2 * @sizeOf(i16);
    const bytes_per_second = 44100 * bytes_per_sample;
    const buffer_size: u32 = @divExact(bytes_per_second, target_fps);

    const flags: StreamFlags = .{};
    const buffer_attributes = BufferAttr{
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

    handles.threaded_mainloop_unlock(pulse_thread_loop);
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

fn onStreamStateCallback(pulse_stream: *pa_stream, userdata: ?*anyopaque) callconv(.C) void {
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

fn onContextStateChangedCallback(context: *pa_context, success: i32, userdata: ?*anyopaque) callconv(.C) void {
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

fn streamReadCallback(pulse_stream: *pa_stream, bytes_available_count: u64, userdata: ?*anyopaque) callconv(.C) void {
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

fn handleCardInfo(context: *pa_context, info: *const pa_card_info, eol: i32, userdata: ?*anyopaque) callconv(.C) void {
    _ = context;
    _ = userdata;
    if (eol > 0) return;
    std.log.info("Card: {s}", .{info.name});
}

fn handleSourceInfo(context: *pa_context, info: *const pa_source_info, eol: i32, userdata: ?*anyopaque) callconv(.C) void {
    _ = context;
    _ = userdata;

    assert(backend_state == .initialized);

    if (eol > 0) {
        sourceListReadyCallback.?(source_buffer[0..source_count]);
        return;
    }

    std.log.info("Name: {s}", .{info.description});
    std.log.info("State: {s}", .{@tagName(info.state)});
    std.log.info("Monitor: {s}", .{info.monitor_of_sink_name orelse "null"});

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

    if (info.active_port) |active_port| {
        if (active_port.*.type == .analog) {
            source_buffer[source_count].source_type = .microphone;
            std.log.info("Adding mic", .{});
        }
    } else if (info.n_ports == 1) {
        if (info.ports[0].*.type == .mic) {
            source_buffer[source_count].source_type = .microphone;
            std.log.info("Adding mic", .{});
        }
    } else if (info.monitor_of_sink_name != null) {
        source_buffer[source_count].source_type = .desktop;
        std.log.info("Adding desktop output", .{});
    }

    source_count += 1;
}

fn handleSinkInfo(context: *pa_context, info: *const pa_sink_info, eol: i32, userdata: ?*anyopaque) callconv(.C) void {
    _ = context;
    _ = userdata;
    if (eol > 0) return;
    std.log.info("Sink: {s} {s}", .{ info.name, info.description });
}

//
// Pulse Audio bindings / definitions
// TODO: Move to separate file
//

const pa_mainloop_api = opaque {};
const pa_threaded_mainloop = opaque {};
const pa_context = opaque {};
const pa_stream = opaque {};
const pa_proplist = opaque {};

const ContextState = enum(i32) {
    unconnected,
    connecting,
    authorizing,
    setting_name,
    ready,
    failed,
    terminated,
};

const ContextFlags = packed struct(i32) {
    noautospawn: bool = false,
    nofail: bool = false,
    reserved_bit_2: bool = false,
    reserved_bit_3: bool = false,
    reserved_bit_4: bool = false,
    reserved_bit_5: bool = false,
    reserved_bit_6: bool = false,
    reserved_bit_7: bool = false,
    reserved_bit_8: bool = false,
    reserved_bit_9: bool = false,
    reserved_bit_10: bool = false,
    reserved_bit_11: bool = false,
    reserved_bit_12: bool = false,
    reserved_bit_13: bool = false,
    reserved_bit_14: bool = false,
    reserved_bit_15: bool = false,
    reserved_bit_16: bool = false,
    reserved_bit_17: bool = false,
    reserved_bit_18: bool = false,
    reserved_bit_19: bool = false,
    reserved_bit_20: bool = false,
    reserved_bit_21: bool = false,
    reserved_bit_22: bool = false,
    reserved_bit_23: bool = false,
    reserved_bit_24: bool = false,
    reserved_bit_25: bool = false,
    reserved_bit_26: bool = false,
    reserved_bit_27: bool = false,
    reserved_bit_28: bool = false,
    reserved_bit_29: bool = false,
    reserved_bit_30: bool = false,
    reserved_bit_31: bool = false,
};

//
// Threaded Loop
//
extern fn pa_threaded_mainloop_new() callconv(.C) ?*pa_threaded_mainloop;
extern fn pa_threaded_mainloop_get_api(loop: *pa_threaded_mainloop) callconv(.C) ?*pa_mainloop_api;
extern fn pa_threaded_mainloop_start(loop: *pa_threaded_mainloop) callconv(.C) i32;
extern fn pa_threaded_mainloop_free(loop: *pa_threaded_mainloop) callconv(.C) void;
extern fn pa_threaded_mainloop_stop(loop: *pa_threaded_mainloop) callconv(.C) void;
extern fn pa_threaded_mainloop_unlock(loop: *pa_threaded_mainloop) callconv(.C) void;
extern fn pa_threaded_mainloop_lock(loop: *pa_threaded_mainloop) callconv(.C) void;
extern fn pa_threaded_mainloop_wait(loop: *pa_threaded_mainloop) callconv(.C) void;

//
// Context
//

const ContextSuccessFn = fn (context: *pa_context, success: i32, userdata: ?*anyopaque) callconv(.C) void;

const pa_spawn_api = extern struct {
    prefork: *const fn () callconv(.C) void,
    postfork: *const fn () callconv(.C) void,
    atfork: *const fn () callconv(.C) void,
};
const pa_operation = opaque {};

const pa_sink_info_cb_t = fn (context: *pa_context, info: *const pa_sink_info, eol: i32, userdata: ?*anyopaque) callconv(.C) void;
const pa_source_info_cb_t = fn (context: *pa_context, info: *const pa_source_info, eol: i32, userdata: ?*anyopaque) callconv(.C) void;
const pa_card_info_cb_t = fn (context: *pa_context, info: *const pa_card_info, eol: i32, userdata: ?*anyopaque) callconv(.C) void;

const pa_card_profile_info = extern struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
    n_sinks: u32,
    n_sources: u32,
    priority: u32,
};

const pa_card_profile_info2 = extern struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
    n_sinks: u32,
    n_sources: u32,
    priority: u32,
    available: i32,
};

const pa_card_port_info = extern struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
    priority: u32,
    available: i32,
    direction: i32,
    n_profiles: u32,
    profiles: **pa_card_profile_info,
    proplist: *pa_proplist,
    latency_offest: u64,
    profiles2: **pa_card_profile_info2,
    availability_group: [*:0]const u8,
    type: PortType,
};

const pa_card_info = extern struct {
    index: u32,
    name: [*:0]const u8,
    owner_module: u32,
    driver: [*:0]const u8,
    n_profiles: u32,
    profiles: [*]pa_card_profile_info,
    active_profile: *pa_card_profile_info,
    proplist: *pa_proplist,
    n_ports: u32,
    ports: [*]*pa_card_port_info,
    profiles2: **pa_card_profile_info2,
    active_profile2: *pa_card_profile_info2,
};

const PortType = enum(u32) {
    unknown = 0,
    aux,
    speaker,
    headphones,
    line,
    mic,
    headset,
    handset,
    earpiece,
    spdif,
    hdmi,
    tv,
    radio,
    video,
    usb,
    bluetooth,
    portable,
    handsfree,
    car,
    hifi,
    phone,
    network,
    analog,
};

const PA_CHANNELS_MAX = 32;

const pa_volume_t = u32;
const pa_usec_t = u64;

const pa_cvolume = extern struct {
    channels: u8,
    values: [PA_CHANNELS_MAX]pa_volume_t,
};

const pa_sink_flags_t = packed struct(u32) {
    hw_volume_ctrl: bool = false,
    latency: bool = false,
    hardward: bool = false,
    network: bool = false,
    hw_mute_ctrl: bool = false,
    decibel_volume: bool = false,
    flat_volume: bool = false,
    dynamic_latency: bool = false,
    set_formats: bool = false,
    reserved_bit_9: bool = false,
    reserved_bit_10: bool = false,
    reserved_bit_11: bool = false,
    reserved_bit_12: bool = false,
    reserved_bit_13: bool = false,
    reserved_bit_14: bool = false,
    reserved_bit_15: bool = false,
    reserved_bit_16: bool = false,
    reserved_bit_17: bool = false,
    reserved_bit_18: bool = false,
    reserved_bit_19: bool = false,
    reserved_bit_20: bool = false,
    reserved_bit_21: bool = false,
    reserved_bit_22: bool = false,
    reserved_bit_23: bool = false,
    reserved_bit_24: bool = false,
    reserved_bit_25: bool = false,
    reserved_bit_26: bool = false,
    reserved_bit_27: bool = false,
    reserved_bit_28: bool = false,
    reserved_bit_29: bool = false,
    reserved_bit_30: bool = false,
    reserved_bit_31: bool = false,
};

const pa_sink_state_t = enum(i32) {
    invalid_state = -1,
    running = 0,
    idle = 1,
    suspended = 2,
};

const pa_sink_port_info = extern struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
    priority: u32,
    available: i32,
    availability_group: ?[*:0]const u8,
    type: u32,
};

const pa_source_port_info = extern struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
    priority: u32,
    available: i32,
    availability_group: ?[*:0]const u8,
    type: PortType,
};

const pa_format_info = extern struct {
    encoding: pa_encoding_t,
    plist: *pa_proplist,
};

const pa_encoding_t = enum(i32) {
    any = 0,
    pcm = 1,
    ac3_iec61937 = 2,
    eac3_iec61937 = 3,
    mpeg_iec61937 = 4,
    dts_iec61937 = 5,
    mpeg2_aac_iec61937 = 6,
    truehd_ie61937 = 7,
    dtshd_ie61937 = 8,
    max = 9,
    invalid = -1,
};

const pa_sink_info = extern struct {
    name: [*:0]const u8,
    index: u32,
    description: [*:0]const u8,
    sample_spec: pa_sample_spec,
    channel_map: pa_channel_map,
    owner_module: u32,
    volume: pa_cvolume,
    mute: i32,
    monitor_source: u32,
    monitor_source_name: [*:0]const u8,
    latency: pa_usec_t,
    driver: [*:0]const u8,
    flags: pa_sink_flags_t,
    proplist: *pa_proplist,
    configured_latency: pa_usec_t,
    base_volume: pa_volume_t,
    state: pa_sink_state_t,
    n_volume_steps: u32,
    card: u32,
    n_ports: u32,
    ports: **pa_sink_port_info,
    active_port: *pa_sink_port_info,
    n_formats: u8,
    formats: **pa_format_info,
};

const pa_source_flags_t = packed struct(u32) {
    hw_volume_control: bool = false,
    latency: bool = false,
    hardware: bool = false,
    network: bool = false,
    hw_mute_ctrl: bool = false,
    decibel_volume: bool = false,
    dynamic_volume: bool = false,
    dynamic_latency: bool = false,
    reserved_bit_8: bool = false,
    reserved_bit_9: bool = false,
    reserved_bit_10: bool = false,
    reserved_bit_11: bool = false,
    reserved_bit_12: bool = false,
    reserved_bit_13: bool = false,
    reserved_bit_14: bool = false,
    reserved_bit_15: bool = false,
    reserved_bit_16: bool = false,
    reserved_bit_17: bool = false,
    reserved_bit_18: bool = false,
    reserved_bit_19: bool = false,
    reserved_bit_20: bool = false,
    reserved_bit_21: bool = false,
    reserved_bit_22: bool = false,
    reserved_bit_23: bool = false,
    reserved_bit_24: bool = false,
    reserved_bit_25: bool = false,
    reserved_bit_26: bool = false,
    reserved_bit_27: bool = false,
    reserved_bit_28: bool = false,
    reserved_bit_29: bool = false,
    reserved_bit_30: bool = false,
    reserved_bit_31: bool = false,
};

const pa_source_state_t = enum(i32) {
    invalid_state = -1,
    running = 0,
    idle = 1,
    suspended = 2,
};

const pa_source_info = extern struct {
    name: [*:0]const u8,
    index: u32,
    description: [*:0]const u8,
    sample_spec: pa_sample_spec,
    channel_map: pa_channel_map,
    owner_module: u32,
    volume: pa_cvolume,
    mute: i32,
    monitor_of_sink: u32,
    monitor_of_sink_name: ?[*:0]const u8,
    latency: pa_usec_t,
    driver: [*:0]const u8,
    flags: pa_source_flags_t,
    proplist: *pa_proplist,

    configured_latency: pa_usec_t,
    base_volume: pa_volume_t,
    state: pa_source_state_t,
    n_volume_steps: u32,
    card: u32,
    n_ports: u32,
    ports: [*]*pa_source_port_info,
    active_port: ?*pa_source_port_info,
    n_formats: u8,
    formats: **pa_format_info,
};

extern fn pa_context_new(mainloop: *pa_mainloop_api, name: [*:0]const u8) callconv(.C) ?*pa_context;
extern fn pa_context_new_with_proplist(
    mainloop: *pa_mainloop_api,
    name: [*:0]const u8,
    proplist: *const pa_proplist,
) callconv(.C) ?*pa_context;
extern fn pa_context_connect(
    context: *pa_context,
    server: ?[*:0]const u8,
    flags: ContextFlags,
    api: ?*pa_spawn_api,
) i32;
extern fn pa_context_disconnect(context: *pa_context) callconv(.C) void;
extern fn pa_context_unref(context: *pa_context) callconv(.C) void;
extern fn pa_context_set_state_callback(
    context: *pa_context,
    state_callback: *const ContextSuccessFn,
    userdata: ?*anyopaque,
) callconv(.C) void;
extern fn pa_context_get_state(context: *const pa_context) callconv(.C) ContextState;
extern fn pa_context_get_sink_info_list(
    context: *const pa_context,
    callback: *const pa_sink_info_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;
extern fn pa_context_get_source_info_list(
    context: *const pa_context,
    callback: *const pa_source_info_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;
extern fn pa_context_get_card_info_list(
    context: *const pa_context,
    callback: *const pa_card_info_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;
extern fn pa_context_get_source_info_by_index(
    context: *const pa_context,
    index: u32,
    callback: *const pa_source_info_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

//
// Stream
//

const StreamRequestFn = fn (stream: *pa_stream, bytes_available_count: u64, userdata: ?*anyopaque) callconv(.C) void;
const StreamNotifyFn = fn (stream: *pa_stream, userdata: ?*anyopaque) callconv(.C) void;

extern fn pa_stream_new(context: *pa_context, name: [*:0]const u8, sample_spec: *const SampleSpec, map: ?*const ChannelMap) ?*pa_stream;
extern fn pa_stream_set_read_callback(stream: *pa_stream, callback: *const StreamRequestFn, userdata: ?*anyopaque) callconv(.C) void;
extern fn pa_stream_peek(stream: *pa_stream, data: *?*const void, data_size_bytes: *u64) callconv(.C) i32;
extern fn pa_stream_drop(stream: *pa_stream) callconv(.C) i32;
extern fn pa_stream_get_state(stream: *pa_stream) callconv(.C) PulseStreamState;
extern fn pa_stream_set_state_callback(stream: *pa_stream, callback: *const StreamNotifyFn, userdata: ?*anyopaque) callconv(.C) void;
extern fn pa_stream_connect_record(stream: *pa_stream, device: ?[*:0]const u8, buffer_attributes: ?*const BufferAttr, flags: StreamFlags) callconv(.C) i32;
extern fn pa_stream_unref(stream: *pa_stream) callconv(.C) void;
extern fn pa_stream_get_sample_spec(stream: *pa_stream) callconv(.C) *const pa_sample_spec;
extern fn pa_stream_get_channel_map(stream: *pa_stream) callconv(.C) *const pa_channel_map;
extern fn pa_stream_get_device_name(stream: *pa_stream) callconv(.C) [*:0]const u8;
extern fn pa_stream_get_device_index(stream: *pa_stream) callconv(.C) u32;

const StreamFlags = packed struct(i32) {
    start_corked: bool = false,
    interpolate_timing: bool = false,
    not_monotonic: bool = false,
    auto_timing_update: bool = false,
    no_remap_channels: bool = false,
    no_remix_channels: bool = false,
    fix_format: bool = false,
    fix_rate: bool = false,
    fix_channels: bool = false,
    dont_move: bool = false,
    variable_rate: bool = false,
    peak_detect: bool = false,
    start_muted: bool = false,
    adjust_latency: bool = false,
    early_requests: bool = false,
    inhibit_auto_suspend: bool = false,
    start_unmuted: bool = false,
    fail_on_suspend: bool = false,
    relative_volume: bool = false,
    passthrough: bool = false,
    reserved_bit_20: bool = false,
    reserved_bit_21: bool = false,
    reserved_bit_22: bool = false,
    reserved_bit_23: bool = false,
    reserved_bit_24: bool = false,
    reserved_bit_25: bool = false,
    reserved_bit_26: bool = false,
    reserved_bit_27: bool = false,
    reserved_bit_28: bool = false,
    reserved_bit_29: bool = false,
    reserved_bit_30: bool = false,
    reserved_bit_31: bool = false,
};

const _sample_spec = SampleSpec{
    .format = .s16le,
    .rate = 44100,
    .channels = 2,
};

// TODO: Rename when moved into it's own file (Was StreamState)
const PulseStreamState = enum(i32) {
    unconnected,
    creating,
    ready,
    failed,
    terminated,
};

const DynamicHandles = struct {
    threaded_mainloop_new: *const @TypeOf(pa_threaded_mainloop_new),
    threaded_mainloop_get_api: *const @TypeOf(pa_threaded_mainloop_get_api),
    threaded_mainloop_start: *const @TypeOf(pa_threaded_mainloop_start),
    threaded_mainloop_free: *const @TypeOf(pa_threaded_mainloop_free),
    threaded_mainloop_stop: *const @TypeOf(pa_threaded_mainloop_stop),
    threaded_mainloop_unlock: *const @TypeOf(pa_threaded_mainloop_unlock),
    threaded_mainloop_lock: *const @TypeOf(pa_threaded_mainloop_lock),
    threaded_mainloop_wait: *const @TypeOf(pa_threaded_mainloop_wait),

    context_new: *const @TypeOf(pa_context_new),
    context_new_with_proplist: *const @TypeOf(pa_context_new_with_proplist),
    context_connect: *const @TypeOf(pa_context_connect),
    context_disconnect: *const @TypeOf(pa_context_disconnect),
    context_unref: *const @TypeOf(pa_context_unref),
    context_set_state_callback: *const @TypeOf(pa_context_set_state_callback),
    context_get_state: *const @TypeOf(pa_context_get_state),
    context_get_sink_info_list: *const @TypeOf(pa_context_get_sink_info_list),
    context_get_source_info_list: *const @TypeOf(pa_context_get_source_info_list),
    context_get_card_info_list: *const @TypeOf(pa_context_get_card_info_list),
    context_get_source_info_by_index: *const @TypeOf(pa_context_get_source_info_by_index),

    stream_new: *const @TypeOf(pa_stream_new),
    stream_set_read_callback: *const @TypeOf(pa_stream_set_read_callback),
    stream_peek: *const @TypeOf(pa_stream_peek),
    stream_drop: *const @TypeOf(pa_stream_drop),
    stream_get_state: *const @TypeOf(pa_stream_get_state),
    stream_set_state_callback: *const @TypeOf(pa_stream_set_state_callback),
    stream_connect_record: *const @TypeOf(pa_stream_connect_record),
    stream_unref: *const @TypeOf(pa_stream_unref),
    stream_get_sample_spec: *const @TypeOf(pa_stream_get_sample_spec),
    stream_get_channel_map: *const @TypeOf(pa_stream_get_channel_map),
    stream_get_device_name: *const @TypeOf(pa_stream_get_device_name),
    stream_get_device_index: *const @TypeOf(pa_stream_get_device_index),
};

pub const SampleFormat = enum(i32) {
    u8,
    alaw,
    ulaw,
    s16le,
    s16be,
    float32le,
    float32be,
    s32le,
    s32be,
    s24le,
    s24be,
    s24_32le,
    s24_32be,
    max,
    invalid = -1,
};

pub const ChannelPosition = enum(i32) {
    invalid = -1,
    mono = 0,
    front_left,
    front_right,
    front_center,
    rear_center,
    rear_left,
    rear_right,
    lfe,
    front_left_of_center,
    front_right_of_center,
    side_left,
    side_right,
    aux0,
    aux1,
    aux2,
    aux3,
    aux4,
    aux5,
    aux6,
    aux7,
    aux8,
    aux9,
    aux10,
    aux11,
    aux12,
    aux13,
    aux14,
    aux15,
    aux16,
    aux17,
    aux18,
    aux19,
    aux20,
    aux21,
    aux22,
    aux23,
    aux24,
    aux25,
    aux26,
    aux27,
    aux28,
    aux29,
    aux30,
    aux31,
    top_center,
    top_front_left,
    top_front_right,
    top_front_center,
    top_rear_left,
    top_rear_right,
    top_rear_center,
    max,
};

const channels_max = 32;
pub const pa_channel_map = extern struct {
    channels: u8,
    map: [channels_max]ChannelPosition,
};
pub const ChannelMap = pa_channel_map;

pub const pa_sample_spec = extern struct {
    format: SampleFormat,
    rate: u32,
    channels: u8,
};
pub const SampleSpec = pa_sample_spec;

pub const BufferAttr = extern struct {
    max_length: u32,
    tlength: u32,
    prebuf: u32,
    minreq: u32,
    fragsize: u32,
};
