// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;
const DynLib = std.DynLib;

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
});

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

const pw = @import("../bindings/pipewire/pipewire.zig");
const spa = @import("../bindings/spa/spa.zig");

const required_pipewire_symbols = pw.SymbolList{
    .init = true,
    .deinit = true,
    .propertiesNew = true,
    .threadLoopNew = true,
    .threadLoopDestroy = true,
    .threadLoopStart = true,
    .threadLoopStop = true,
    .threadLoopLock = true,
    .threadLoopUnlock = true,
    .threadLoopGetLoop = true,
    .streamDequeueBuffer = true,
    .streamQueueBuffer = true,
    .streamNewSimple = true,
    .streamStateAsString = true,
    .streamDestroy = true,
    .streamConnect = true,
};

var symbols: pw.Symbols(required_pipewire_symbols) = undefined;
var stream: *pw.Stream = undefined;
var thread_loop: *pw.ThreadLoop = undefined;

var libpipewire_handle_opt: ?DynLib = null;

pub const InitErrors = error{
    PipewireConnectServerFail,
    CreateThreadFail,
    CreateStreamFail,
    ConnectStreamFail,
};

pub const CreateStreamError = error{
    PipewireStreamCreateFail,
    PipewireStreamStartFail,
};

var is_stream_ready: bool = false;

var sourceListReadyCallback: *const ListReadyCallbackFn = undefined;
var backend_state: State = .closed;

pub fn isSupported() bool {
    if (libpipewire_handle_opt == null) {
        libpipewire_handle_opt = DynLib.open("libpipewire-0.3.so.0") catch {
            std.log.err("Failed to load libpipewire-0.3.so.0", .{});
            return false;
        };
        symbols.load(&(libpipewire_handle_opt.?)) catch {
            std.log.err("Failed to load symbol", .{});
            return false;
        };
    }

    if (is_stream_ready)
        return true;

    //
    // It seems we need to actually create a stream to determine if
    // we can actually use pipewire.
    //
    setupStream() catch {
        std.log.info("Failed to setup pipewire audio source", .{});
        return false;
    };

    is_stream_ready = true;

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

        .info = .{ .name = "pipewire" },
    };
}

pub fn init(
    onSuccess: *const InitSuccessCallbackFn,
    onFail: *const InitFailCallbackFn,
) InitErrors!void {
    _ = onSuccess;
    _ = onFail;

    assert(false);
}

pub fn deinit() void {
    symbols.threadLoopStop(thread_loop);
    symbols.streamDestroy(stream);
    symbols.threadLoopDestroy(thread_loop);
    symbols.deinit();
}

fn listSources(allocator: std.mem.Allocator, listReadyCallback: *const ListReadyCallbackFn) void {
    _ = allocator;
    _ = listReadyCallback;
    assert(false);
}

pub fn state() State {
    return backend_state;
}

pub fn createStream(
    source_index_opt: ?u32,
    samplesReadyCallback: *const SamplesReadyCallbackFn,
    onSuccess: *const CreateStreamSuccessCallbackFn,
    onFail: *const CreateStreamFailCallbackFn,
) CreateStreamError!void {
    assert(backend_state == .initialized);

    _ = source_index_opt;
    _ = samplesReadyCallback;
    _ = onSuccess;
    _ = onFail;

    assert(false);
}

fn streamStart(s: StreamHandle) void {
    _ = s;
    // assert(stream.index < max_concurrent_streams);
    // assert(stream_buffer[stream.index].state == .paused);
    // stream_buffer[stream.index].state = .running;
}

fn streamPause(s: StreamHandle) void {
    _ = s;
    // assert(stream.index < max_concurrent_streams);
    // assert(stream_buffer[stream.index].state == .running);
    // stream_buffer[stream.index].state = .paused;
}

fn streamClose(s: StreamHandle) void {
    _ = s;
    // assert(stream.index < max_concurrent_streams);
    // handles.stream_unref(stream_buffer[stream.index].pulse_stream);
    // stream_buffer[stream.index].state = .closed;
    // assert(stream_buffer[stream.index].state == .closed);
}

fn streamState(s: StreamHandle) StreamState {
    _ = s;
    return .running;
    // assert(stream.index < max_concurrent_streams);
    // return stream_buffer[stream.index].state;
}

// pub fn init(
//     onSuccess: *const audio.InitSuccessCallbackFn,
//     onFail: *const audio.InitFailCallbackFn,
// ) InitErrors!void {
//     std.debug.assert(backend_state == .closed);

//     onInitFailCallback = onFail;
//     onInitSuccessCallback = onSuccess;

//     if (!is_stream_ready) {
//         try setupStream();
//         is_stream_ready = true;
//     }

//     backend_state = .initialized;
//     onInitSuccessCallback();
// }

const stream_events = pw.StreamEvents{
    .state_changed = onStateChangedCallback,
    .param_changed = onParamChangedCallback,
    .process = onProcessCallback,
    .io_changed = null,
    .add_buffer = null,
    .remove_buffer = null,
    .drained = null,
    .command = null,
    .trigger_done = null,
    .destroy = null,
    .control_info = null,
};

fn onStateChangedCallback(_: ?*anyopaque, old: pw.StreamState, new: pw.StreamState, error_message: [*c]const u8) callconv(.C) void {
    _ = old;
    const error_string: [*c]const u8 = error_message orelse "none";
    std.log.warn("pipewire state changed. \"{s}\". Error: {s}", .{ symbols.streamStateAsString(new), error_string });
}

fn onProcessCallback(_: ?*anyopaque) callconv(.C) void {
    const buffer = symbols.streamDequeueBuffer(stream);
    const buffer_bytes = buffer.*.buffer.*.datas[0].data orelse return;
    const buffer_size_bytes = buffer.*.buffer.*.datas[0].chunk.*.size;
    const sample_count = @divExact(buffer_size_bytes, @sizeOf(i16));
    _ = buffer_bytes;
    _ = sample_count;
    // onReadSamplesCallback(@ptrCast([*]i16, @alignCast(2, buffer_bytes))[0..sample_count]);
    _ = symbols.streamQueueBuffer(stream, buffer);
}

fn onParamChangedCallback(_: ?*anyopaque, id: u32, params: [*c]const spa.Pod) callconv(.C) void {
    _ = params;
    std.log.info("Param changed format (unknown) {d}", .{id});
    if (id == @enumToInt(spa.ParamType.format)) {
        std.log.info("Param changed format", .{});
        // if (pw.spa_format_parse(params, &audio_format.media_type, &audio_format.media_subtype) < 0) {
        //     return;
        // }
        // if (audio_format.media_type != pw.SPA_MEDIA_TYPE_audio or audio_format.media_subtype != pw.SPA_MEDIA_SUBTYPE_raw) {
        //     std.log.info("Rejecting non-raw audio format", .{});
        //     return;
        // }
        // _ = pw.spa_format_audio_raw_parse(params, &audio_format.info.raw);
        // std.log.info("Audiof format: Rate {d} Channels {d}", .{
        //     audio_format.info.raw.rate,
        //     audio_format.info.raw.channels,
        // });
        // format_confirmed = true;
    }
}

fn setupStream() error{ PipewireConnectServerFail, CreateStreamFail, ConnectStreamFail }!void {
    var argc: i32 = 1;
    var argv = [_][*:0]const u8{"reel"};

    symbols.init(@ptrCast(*i32, &argc), @ptrCast(*[*][*:0]const u8, &argv));

    thread_loop = symbols.threadLoopNew("Pipewire thread loop", null);

    if (symbols.threadLoopStart(thread_loop) < 0) {
        return error.PipewireConnectServerFail;
    }
    symbols.threadLoopLock(thread_loop);

    const stream_properties = symbols.propertiesNew(
        pw.keys.media_type,
        "Audio",
        pw.keys.media_category,
        "Capture",
        pw.keys.media_role,
        "Music",
        @as(usize, 0), // NULL
    );

    stream = symbols.streamNewSimple(
        symbols.threadLoopGetLoop(thread_loop),
        "audio-capture",
        stream_properties,
        &stream_events,
        null,
    ) orelse return error.CreateStreamFail;

    const AudioFormatParam = extern struct {
        const KeyPair = extern struct {
            key: spa.Format,
            flags: u32 = 0,
            size: u32 = 4,
            kind: spa.PodType,
            value: u32,
            padding: u32 = 0,
        };

        size: u32,
        kind: spa.PodType,
        object_kind: spa.PodType,
        object_id: spa.ParamType,
        key_pairs: [6]KeyPair,
    };

    const audio_format_param = AudioFormatParam{
        .size = @sizeOf(AudioFormatParam),
        .kind = .object,
        .object_kind = .object_format,
        .object_id = .enum_format,
        .key_pairs = .{
            .{
                .key = .media_type,
                .kind = .id,
                .value = @enumToInt(spa.MediaType.audio),
            },
            .{
                .key = .media_subtype,
                .kind = .id,
                .value = @enumToInt(spa.MediaSubtype.raw),
            },
            .{
                .key = .audio_format,
                .kind = .id,
                .value = @enumToInt(spa.AudioFormat.s16_le),
            },
            .{
                .key = .audio_rate,
                .kind = .int,
                .value = 44100,
            },
            .{
                .key = .audio_channels,
                .kind = .int,
                .value = 2,
            },
            .{
                .key = .audio_position,
                .size = 16,
                .kind = .array,
                .value = @enumToInt(spa.AudioChannel.fr),
                .padding = @enumToInt(spa.AudioChannel.fl),
            },
        },
    };

    var param_ptr = &audio_format_param;
    var ret_code = symbols.streamConnect(
        stream,
        .input,
        pw.id_any,
        .{
            .autoconnect = true,
            .map_buffers = true,
            .rt_process = true,
        },
        @ptrCast(*[*]spa.Pod, &param_ptr),
        1,
    );
    if (ret_code != 0) {
        std.log.info("Failed to connect to stream. Error: {s}", .{c.strerror(-ret_code)});
        return error.ConnectStreamFail;
    }
}

// pub fn open(
//     device_name_opt: ?[*:0]const u8,
//     onSuccess: *const audio.OpenSuccessCallbackFn,
//     onFail: *const audio.OpenFailCallbackFn,
// ) OpenErrors!void {
//     _ = device_name_opt;

//     onOpenFailCallback = onFail;
//     onOpenSuccessCallback = onSuccess;

//     std.debug.assert(backend_state == .initialized);

//     //
//     // Activate the read thread
//     //
//     symbols.pw_thread_loop_unlock(thread_loop);

//     onOpenSuccessCallback();
// }
