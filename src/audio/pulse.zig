// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const audio = @import("../audio.zig");
const DynLib = std.DynLib;

pub const Simple = opaque {};
pub const StreamDirection = enum(i32) {
    no_direction = 0,
    playback = 1,
    record = 2,
    upload = 3,
};

pub const OpenErrors = error{
    PulseConnectServerFail,
    PulseThreadedLoopStartFail,
    PulseThreadedLoopCreateFail,
    PulseThreadedLoopGetApiFail,
    PulseContextCreateFail,
};

var stream_state: audio.State = .closed;

var onReadSamplesCallback: *const audio.OnReadSamplesFn = undefined;

pub fn createInterface(read_samples_callback: *const audio.OnReadSamplesFn) audio.Interface {
    onReadSamplesCallback = read_samples_callback;
    return .{
        .open = &open,
        .close = &close,
        .state = &state,
    };
}

pub fn state() audio.State {
    return stream_state;
}

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

const ContextSuccessFn = fn (context: *pa_context, success: i32, userdata: ?*void) callconv(.C) void;

const pa_spawn_api = extern struct {
    prefork: *const fn () callconv(.C) void,
    postfork: *const fn () callconv(.C) void,
    atfork: *const fn () callconv(.C) void,
};

extern fn pa_context_new(mainloop: *pa_mainloop_api, name: [*:0]const u8) callconv(.C) ?*pa_context;
extern fn pa_context_new_with_proplist(mainloop: *pa_mainloop_api, name: [*:0]const u8, proplist: *const pa_proplist) callconv(.C) ?*pa_context;
extern fn pa_context_connect(context: *pa_context, server: ?[*:0]const u8, flags: ContextFlags, api: ?*pa_spawn_api) i32;
extern fn pa_context_unref(context: *pa_context) callconv(.C) void;
extern fn pa_context_set_state_callback(context: *pa_context, state_callback: *const ContextSuccessFn, userdata: ?*void) callconv(.C) void;
extern fn pa_context_get_state(context: *const pa_context) callconv(.C) ContextState;

//
// Stream
//

const StreamRequestFn = fn (stream: *pa_stream, bytes_available_count: u64, userdata: ?*void) callconv(.C) void;
const StreamNotifyFn = fn (stream: *pa_stream, userdata: ?*void) callconv(.C) void;

extern fn pa_stream_new(context: *pa_context, name: [*:0]const u8, sample_spec: *const SampleSpec, map: ?*const ChannelMap) ?*pa_stream;
extern fn pa_stream_set_read_callback(stream: *pa_stream, callback: *const StreamRequestFn, userdata: ?*void) callconv(.C) void;
extern fn pa_stream_peek(stream: *pa_stream, data: *?*const void, data_size_bytes: *u64) callconv(.C) i32;
extern fn pa_stream_drop(stream: *pa_stream) callconv(.C) i32;
extern fn pa_stream_get_state(stream: *pa_stream) callconv(.C) StreamState;
extern fn pa_stream_set_state_callback(stream: *pa_stream, callback: *const StreamNotifyFn, userdata: ?*void) callconv(.C) void;
extern fn pa_stream_connect_record(stream: *pa_stream, device: ?[*:0]const u8, buffer_attributes: ?*const BufferAttr, flags: StreamFlags) callconv(.C) i32;
extern fn pa_stream_unref(stream: *pa_stream) callconv(.C) void;

var _thread_loop: *pa_threaded_mainloop = undefined;
var _loop_api: *pa_mainloop_api = undefined;
var _context: *pa_context = undefined;
var _stream: *pa_stream = undefined;

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

const StreamState = enum(i32) {
    unconnected,
    creating,
    ready,
    failed,
    terminated,
};

var initialized: bool = false;

// fn aWeight(sample: f64) f64 {
//     const sample2: f64 = sample * sample;
//     return (1.2588966 * 148840000 * sample2 * sample2) / ((sample2 * 424.36) * std.math.sqrt(sample2 + 11599.29) * (sample2 + 544496.41) * (sample2 + 148840000));

//     //    	var f2 = f*f;
//     // return 1.2588966 * 148840000 * f2*f2 /
//     // ((f2 + 424.36) * Math.sqrt((f2 + 11599.29) * (f2 + 544496.41)) * (f2 + 148840000));
// }

fn streamReadCallback(stream: *pa_stream, bytes_available_count: u64, userdata: ?*void) callconv(.C) void {
    _ = userdata;
    var pcm_buffer_opt: ?[*]i16 = undefined;
    var bytes_read_count: u64 = bytes_available_count;
    const ret_code = pa_stream_peek(stream, @ptrCast(*?*void, &pcm_buffer_opt), &bytes_read_count);
    if (ret_code < 0) {
        std.log.err("Failed to read stream", .{});
        // TODO:
        std.debug.assert(false);
    }

    if (pcm_buffer_opt) |pcm_buffer| {
        onReadSamplesCallback(pcm_buffer[0..@divExact(bytes_read_count, @sizeOf(i16))]);
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
    if (pa_stream_drop(stream) != 0) {
        std.log.err("pa_stream_drop fail", .{});
    }
}

fn onStreamStateCallback(stream: *pa_stream, userdata: ?*void) callconv(.C) void {
    _ = userdata;
    switch (pa_stream_get_state(stream)) {
        .creating, .terminated => {},
        .ready => {
            std.log.info("Stream ready", .{});
        },
        .failed => std.log.err("Stream failed", .{}),
        .unconnected => std.log.info("Stream unconnected", .{}),
    }
}

fn onContextStateChangedCallback(context: *pa_context, success: i32, userdata: ?*void) callconv(.C) void {
    _ = success;
    _ = userdata;
    switch (pa_context_get_state(context)) {
        .connecting, .authorizing, .setting_name => {},
        .ready => {
            std.log.info("Stream ready (context)", .{});
            _stream = pa_stream_new(context, "Audio Input", &_sample_spec, null) orelse {
                std.log.err("Failed to create input audio stream", .{});
                // TODO:
                std.debug.assert(false);
                return;
            };

            pa_stream_set_state_callback(_stream, onStreamStateCallback, null);
            pa_stream_set_read_callback(_stream, streamReadCallback, null);

            const target_fps = 30;
            const bytes_per_sample = 2 * @sizeOf(i16);
            const bytes_per_second = 44100 * bytes_per_sample;
            const buffer_size: u32 = @divFloor(bytes_per_second, target_fps);

            const device: ?[*:0]const u8 = null;
            const flags: StreamFlags = .{};
            const buffer_attributes = BufferAttr{
                .max_length = std.math.maxInt(u32),
                .tlength = std.math.maxInt(u32),
                .minreq = std.math.maxInt(u32),
                .prebuf = buffer_size,
                .fragsize = buffer_size,
            };
            if (pa_stream_connect_record(_stream, device, &buffer_attributes, flags) < 0) {
                std.log.err("Failed to connect to recording stream", .{});
            }
            stream_state = .open;
            initialized = true;
        },
        .terminated => {
            std.log.info("Terminated", .{});
        },
        .failed => {
            std.log.err("Context state change reporting failure", .{});
        },
        .unconnected => {
            std.log.info("Unconnected", .{});
        },
    }
}

pub fn open() OpenErrors!void {
    comptime {
        const c = @cImport(@cInclude("pulse/pulseaudio.h"));
        const assert = std.debug.assert;
        assert(c.PA_CONTEXT_UNCONNECTED == @enumToInt(ContextState.unconnected));
        assert(c.PA_CONTEXT_CONNECTING == @enumToInt(ContextState.connecting));
        assert(c.PA_CONTEXT_AUTHORIZING == @enumToInt(ContextState.authorizing));
        assert(c.PA_CONTEXT_SETTING_NAME == @enumToInt(ContextState.setting_name));
        assert(c.PA_CONTEXT_READY == @enumToInt(ContextState.ready));
        assert(c.PA_CONTEXT_FAILED == @enumToInt(ContextState.failed));
        assert(c.PA_CONTEXT_TERMINATED == @enumToInt(ContextState.terminated));
    }
    _thread_loop = pa_threaded_mainloop_new() orelse return error.PulseThreadedLoopCreateFail;
    _loop_api = pa_threaded_mainloop_get_api(_thread_loop) orelse return error.PulseThreadedLoopGetApiFail;
    _context = pa_context_new(_loop_api, "Reel") orelse return error.PulseContextCreateFail;

    if (pa_context_connect(_context, null, .{}, null) < 0) {
        std.log.err("Failed to connect to pulse server", .{});
        return error.PulseConnectServerFail;
    }

    pa_context_set_state_callback(_context, onContextStateChangedCallback, null);

    if (pa_threaded_mainloop_start(_thread_loop) != 0) {
        std.log.err("Failed to start pulse client loop", .{});
        return error.PulseThreadedLoopStartFail;
    }

    std.log.info("Pulse opened", .{});
}

pub fn close() void {
    pa_stream_unref(_stream);
    pa_context_unref(_context);
    pa_threaded_mainloop_stop(_thread_loop);
    pa_threaded_mainloop_free(_thread_loop);
}

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
pub const ChannelMap = extern struct {
    channels: u8,
    map: [channels_max]ChannelPosition,
};

pub const SampleSpec = extern struct {
    format: SampleFormat,
    rate: u32,
    channels: u8,
};

pub const BufferAttr = extern struct {
    max_length: u32,
    tlength: u32,
    prebuf: u32,
    minreq: u32,
    fragsize: u32,
};

//
// Extern function definitions
//

extern fn pa_simple_read(
    simple: *Simple,
    data: [*]u8,
    bytes: usize,
    err: *i32,
) callconv(.C) i32;

extern fn pa_simple_new(
    server: ?[*:0]const u8,
    name: [*:0]const u8,
    dir: StreamDirection,
    dev: ?[*:0]const u8,
    stream_name: [*:0]const u8,
    sample_spec: *const SampleSpec,
    map: ?*const ChannelMap,
    attr: ?*const BufferAttr,
    err: ?*i32,
) callconv(.C) ?*Simple;

extern fn pa_simple_free(simple: *Simple) callconv(.C) void;
extern fn pa_strerror(err: i32) [*:0]const u8;

//
// Function alias'
//

pub const simpleNew = pa_simple_new;
pub const simpleRead = pa_simple_read;
pub const simpleFree = pa_simple_free;
pub const strError = pa_strerror;

//
// Functions as Types for loading
//

const SimpleNewFn = *const @TypeOf(simpleNew);
const SimpleReadFn = *const @TypeOf(simpleRead);
const SimpleFreeFn = *const @TypeOf(simpleFree);
const StrErrorFn = *const @TypeOf(strError);

//
// High level API
//

pub const InputCapture = struct {
    pulse_simple_handle: DynLib,
    connection: *Simple,

    //
    // Loaded function pointers
    //

    simpleNewFn: SimpleNewFn,
    simpleReadFn: SimpleReadFn,
    simpleFreeFn: SimpleFreeFn,
    strErrorFn: StrErrorFn,

    pub fn init(self: *@This()) !void {
        self.pulse_simple_handle = DynLib.open("libpulse-simple.so.0") catch
            return error.LinkPulseSimpleFail;

        self.simpleNewFn = self.pulse_simple_handle.lookup(SimpleNewFn, "pa_simple_new") orelse
            return error.LookupFailed;
        self.simpleReadFn = self.pulse_simple_handle.lookup(SimpleReadFn, "pa_simple_read") orelse
            return error.LookupFailed;
        self.simpleFreeFn = self.pulse_simple_handle.lookup(SimpleFreeFn, "pa_simple_free") orelse
            return error.LookupFailed;
        self.strErrorFn = self.pulse_simple_handle.lookup(StrErrorFn, "pa_strerror") orelse
            return error.LookupFailed;

        const server_buffer_size = @divFloor(44100, 15) * @sizeOf(u16);

        const buffer_attributes = BufferAttr{
            .max_length = std.math.maxInt(u32),
            .tlength = std.math.maxInt(u32),
            .minreq = std.math.maxInt(u32),
            .prebuf = server_buffer_size,
            .fragsize = server_buffer_size,
        };
        // TODO: Allow to be user configurable
        const sample_spec = SampleSpec{
            .format = .s16le,
            .rate = 44100,
            .channels = 1,
        };
        var errcode: i32 = undefined;
        self.connection = self.simpleNewFn(null, "reel", .record, null, "main", &sample_spec, null, &buffer_attributes, &errcode) orelse {
            const error_message = self.strErrorFn(errcode);
            std.log.err("pulse: {s}", .{error_message});
            return error.CreateConnectionFail;
        };
    }

    pub inline fn read(self: @This(), comptime Type: type, buffer: *[]Type) !void {
        var errcode: i32 = undefined;
        if (self.simpleReadFn(self.connection, @ptrCast([*]u8, buffer.ptr), buffer.len * @sizeOf(Type), &errcode) < 0) {
            std.log.err("pulse: read input fail", .{});
            return error.ReadInputDeviceFail;
        }
    }

    pub fn deinit(self: @This()) void {
        self.simpleFreeFn(self.connection);
    }
};
