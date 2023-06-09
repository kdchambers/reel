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
    .streamDisconnect = true,
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
    PipewireStreamConnectFail,
    PipewireConnectThreadFail,
};

var sourceListReadyCallback: *const ListReadyCallbackFn = undefined;
var onSamplesReady: *const SamplesReadyCallbackFn = undefined;
var backend_state: State = .closed;

var onInitSuccess: *const InitSuccessCallbackFn = undefined;
var onInitFail: *const InitFailCallbackFn = undefined;

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

pub fn deinit() void {
    symbols.threadLoopLock(thread_loop);
    _ = symbols.streamDisconnect(stream);
    symbols.streamDestroy(stream);
    symbols.threadLoopUnlock(thread_loop);

    symbols.threadLoopStop(thread_loop);
    symbols.threadLoopDestroy(thread_loop);
    symbols.deinit();
}

const source_buffer = [1]root.SourceInfo{.{
    .name = "default sink",
    .description = "default sink",
    .source_type = .microphone,
}};

fn listSources(allocator: std.mem.Allocator, listReadyCallback: *const ListReadyCallbackFn) void {
    _ = allocator;
    listReadyCallback(&source_buffer);
}

pub fn state() State {
    return backend_state;
}

var onStreamCreateSuccess: *const CreateStreamSuccessCallbackFn = undefined;

pub fn createStream(
    source_index_opt: ?u32,
    samplesReadyCallback: *const SamplesReadyCallbackFn,
    onSuccess: *const CreateStreamSuccessCallbackFn,
    onFail: *const CreateStreamFailCallbackFn,
) CreateStreamError!void {
    assert(backend_state == .initialized);

    onSamplesReady = samplesReadyCallback;
    onStreamCreateSuccess = onSuccess;

    _ = source_index_opt;
    _ = onFail;

    thread_loop = symbols.threadLoopNew("Pipewire audio capture thread loop", null);

    if (symbols.threadLoopStart(thread_loop) < 0) {
        return error.PipewireConnectThreadFail;
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
    ) orelse return error.PipewireStreamCreateFail;

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
        return error.PipewireStreamConnectFail;
    }

    symbols.threadLoopUnlock(thread_loop);
}

fn streamStart(stream_handle: StreamHandle) void {
    _ = stream_handle;
    @panic("Implement streamStart in audio_source pipewire backend");
}

fn streamPause(stream_handle: StreamHandle) void {
    _ = stream_handle;
    @panic("Implement streamPause in audio_source pipewire backend");
}

fn streamClose(stream_handle: StreamHandle) void {
    _ = stream_handle;
    @panic("Implement streamClose in audio_source pipewire backend");
}

fn streamState(stream_handle: StreamHandle) StreamState {
    _ = stream_handle;
    @panic("Implement streamState in audio_source pipewire backend");
}

pub fn init(
    onSuccess: *const InitSuccessCallbackFn,
    onFail: *const InitFailCallbackFn,
) InitErrors!void {
    std.debug.assert(backend_state == .closed);

    onInitFail = onFail;
    onInitSuccess = onSuccess;

    var argc: i32 = 1;
    var argv = [_][*:0]const u8{"reel"};
    symbols.init(@ptrCast(*i32, &argc), @ptrCast(*[*][*:0]const u8, &argv));

    backend_state = .initialized;
    onInitSuccess();
}

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
    const stream_handle = StreamHandle{ .index = 0 };
    onSamplesReady(stream_handle, @ptrCast([*]i16, @alignCast(2, buffer_bytes))[0..sample_count]);
    _ = symbols.streamQueueBuffer(stream, buffer);
}

fn onParamChangedCallback(_: ?*anyopaque, id: u32, params_opt: ?*const spa.Pod) callconv(.C) void {
    const params = params_opt orelse return;
    if (id == @enumToInt(spa.ParamType.format)) {
        var media_type: u32 = 0;
        var media_subtype: u32 = 0;

        if (spa.formatParse(params, &media_type, &media_subtype) < 0) {
            return;
        }
        if (@intToEnum(spa.MediaType, media_type) != .audio or @intToEnum(spa.MediaSubtype, media_subtype) != .raw) {
            std.log.info("Rejecting non-raw audio format", .{});
            return;
        }

        var audio_info: spa.AudioInfoRaw = undefined;
        _ = spa.formatAudioRawParse(params, &audio_info);
        std.log.info("Audio format: Rate {d} Channels {d}", .{
            audio_info.rate,
            audio_info.channels,
        });
        onStreamCreateSuccess(.{ .index = 0 });
    }
}
