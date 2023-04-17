// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;
const DynLib = std.DynLib;

const audio = @import("../audio.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
});

const pw = @cImport({
    @cInclude("spa/param/audio/format-utils.h");
    @cInclude("spa/debug/types.h");
    @cInclude("spa/param/video/type-info.h");
    @cInclude("pipewire/pipewire.h");
});

const version_stream_events = 2;
const id_any: u32 = 0xffffffff;

const StreamEvents = extern struct {
    version: u32 = version_stream_events,
    destroy: ?*const fn (data: ?*anyopaque) callconv(.C) void = null,
    state_changed: ?*const fn (data: ?*anyopaque, old_state: StreamState, new_state: StreamState, error_string: ?[*:0]const u8) callconv(.C) void = null,
    control_info: ?*const fn (data: ?*anyopaque, id: u32, control: *const StreamControl) callconv(.C) void = null,
    io_changed: ?*const fn (data: ?*anyopaque, id: u32, area: *anyopaque, size: u32) callconv(.C) void = null,
    param_changed: ?*const fn (data: ?*anyopaque, id: u32, param: *const spa.Pod) callconv(.C) void = null,
    add_buffer: ?*const fn (data: ?*anyopaque, buffer: *Buffer) callconv(.C) void = null,
    remove_buffer: ?*const fn (data: ?*anyopaque, buffer: *Buffer) callconv(.C) void = null,
    process: ?*const fn (data: ?*anyopaque) callconv(.C) void = null,
    drained: ?*const fn (data: ?*anyopaque) callconv(.C) void = null,
    command: ?*const fn (data: ?*anyopaque, command: *const spa.Command) callconv(.C) void = null,
    trigger_done: ?*const fn (data: ?*anyopaque) callconv(.C) void = null,
};

const Stream = opaque {};
const ThreadLoop = opaque {};
const Loop = opaque {};
const Properties = opaque {};
const Remote = opaque {};
const StreamControl = opaque {};
const Time = opaque {};

const Buffer = extern struct {
    buffer: *spa.Buffer,
    user_data: ?*anyopaque,
    size: u64,
    requested: u64,
};

var stream: *Stream = undefined;
var thread_loop: *ThreadLoop = undefined;

var libpipewire_handle_opt: ?DynLib = null;

pub const InitErrors = error{
    PipewireConnectServerFail,
    CreateThreadFail,
    CreateStreamFail,
    ConnectStreamFail,
};

pub const OpenErrors = error{
    PipewireStreamCreateFail,
};

var stream_state: audio.State = .closed;

var onReadSamplesCallback: *const audio.OnReadSamplesFn = undefined;

var onInitFailCallback: *const audio.InitFailCallbackFn = undefined;
var onInitSuccessCallback: *const audio.InitSuccessCallbackFn = undefined;

var onOpenFailCallback: *const audio.OpenFailCallbackFn = undefined;
var onOpenSuccessCallback: *const audio.OpenSuccessCallbackFn = undefined;

var is_stream_ready: bool = false;

pub fn isSupported() bool {
    if (libpipewire_handle_opt == null) {
        libpipewire_handle_opt = DynLib.open("libpipewire-0.3.so.0") catch return false;
        symbols.load(&(libpipewire_handle_opt.?)) catch return false;
    }

    if (is_stream_ready)
        return true;

    //
    // It seems we need to actually create a stream to determine if
    // we can actually use pipewire.
    //
    setupStream() catch return false;
    is_stream_ready = true;

    return true;
}

const stream_events = StreamEvents{
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

comptime {
    assert(@enumToInt(StreamState.connecting) == pw.PW_STREAM_STATE_CONNECTING);
}

const StreamState = enum(i32) {
    @"error" = -1,
    unconnected,
    connecting,
    paused,
    streaming,
};

const StreamFlags = packed struct(i32) {
    autoconnect: bool = false,
    inactive: bool = false,
    map_buffers: bool = false,
    driver: bool = false,
    rt_process: bool = false,
    no_convert: bool = false,
    exclusive: bool = false,
    dont_reconnect: bool = false,
    alloc_buffers: bool = false,
    trigger: bool = false,
    reserved: u22 = 0,
};

comptime {
    assert(@bitCast(i32, StreamFlags{ .driver = true }) == pw.PW_STREAM_FLAG_DRIVER);
    assert(@bitCast(i32, StreamFlags{ .rt_process = true, .trigger = true }) == (pw.PW_STREAM_FLAG_RT_PROCESS | pw.PW_STREAM_FLAG_TRIGGER));
}

const Direction = enum(i32) {
    input,
    output,
};

pub const SymbolList = struct {
    pw_init: bool = false,
    pw_deinit: bool = false,

    pw_properties_new: bool = false,
    pw_properties_new_dict: bool = false,
    pw_properties_new_string: bool = false,
    pw_properties_copy: bool = false,
    pw_properties_clear: bool = false,
    pw_properties_update: bool = false,
    pw_properties_free: bool = false,
    pw_properties_set: bool = false,
    pw_properties_setf: bool = false,
    pw_properties_get: bool = false,
    pw_properties_iterate: bool = false,

    pw_thread_loop_new: bool = false,
    pw_thread_loop_destroy: bool = false,
    pw_thread_loop_start: bool = false,
    pw_thread_loop_stop: bool = false,
    pw_thread_loop_lock: bool = false,
    pw_thread_loop_unlock: bool = false,
    pw_thread_loop_signal: bool = false,
    pw_thread_loop_wait: bool = false,
    pw_thread_loop_timed_wait: bool = false,
    pw_thread_loop_accept: bool = false,
    pw_thread_loop_in_thread: bool = false,
    pw_thread_loop_new_full: bool = false,
    pw_thread_loop_add_listener: bool = false,
    pw_thread_loop_get_loop: bool = false,

    pw_stream_dequeue_buffer: bool = false,
    pw_stream_queue_buffer: bool = false,
    pw_stream_flush: bool = false,
    pw_stream_new_simple: bool = false,
    pw_stream_add_listener: bool = false,
    pw_stream_get_state: bool = false,
    pw_stream_get_name: bool = false,
    pw_stream_get_remote: bool = false,
    pw_stream_get_properties: bool = false,
    pw_stream_update_properties: bool = false,
    pw_stream_set_control: bool = false,
    pw_stream_get_control: bool = false,

    pw_stream_state_as_string: bool = false,
    pw_stream_new: bool = false,
    pw_stream_destroy: bool = false,
    pw_stream_connect: bool = false,

    pw_stream_get_node_id: bool = false,
    pw_stream_disconnect: bool = false,
    pw_stream_finish_format: bool = false,
    pw_stream_get_time: bool = false,
    pw_stream_set_active: bool = false,
};

pub fn Symbols(comptime s: SymbolList) type {
    return struct {
        pw_init: if (s.pw_init) *const @TypeOf(pw_init) else void,
        pw_deinit: if (s.pw_deinit) *const @TypeOf(pw_deinit) else void,

        pw_properties_new: if (s.pw_properties_new) *const @TypeOf(pw_properties_new) else void,
        pw_properties_new_dict: if (s.pw_properties_new_dict) *const @TypeOf(pw_properties_new_dict) else void,
        pw_properties_new_string: if (s.pw_properties_new_string) *const @TypeOf(pw_properties_new_string) else void,
        pw_properties_copy: if (s.pw_properties_copy) *const @TypeOf(pw_properties_copy) else void,
        pw_properties_clear: if (s.pw_properties_clear) *const @TypeOf(pw_properties_clear) else void,
        pw_properties_update: if (s.pw_properties_update) *const @TypeOf(pw_properties_update) else void,
        pw_properties_free: if (s.pw_properties_free) *const @TypeOf(pw_properties_free) else void,
        pw_properties_set: if (s.pw_properties_set) *const @TypeOf(pw_properties_set) else void,
        pw_properties_setf: if (s.pw_properties_setf) *const @TypeOf(pw_properties_setf) else void,
        pw_properties_get: if (s.pw_properties_get) *const @TypeOf(pw_properties_get) else void,
        pw_properties_iterate: if (s.pw_properties_iterate) *const @TypeOf(pw_properties_iterate) else void,

        pw_thread_loop_new: if (s.pw_thread_loop_new) *const @TypeOf(pw_thread_loop_new) else void,
        pw_thread_loop_destroy: if (s.pw_thread_loop_destroy) *const @TypeOf(pw_thread_loop_destroy) else void,
        pw_thread_loop_start: if (s.pw_thread_loop_start) *const @TypeOf(pw_thread_loop_start) else void,
        pw_thread_loop_stop: if (s.pw_thread_loop_stop) *const @TypeOf(pw_thread_loop_stop) else void,
        pw_thread_loop_lock: if (s.pw_thread_loop_lock) *const @TypeOf(pw_thread_loop_lock) else void,
        pw_thread_loop_unlock: if (s.pw_thread_loop_unlock) *const @TypeOf(pw_thread_loop_unlock) else void,
        pw_thread_loop_signal: if (s.pw_thread_loop_signal) *const @TypeOf(pw_thread_loop_signal) else void,
        pw_thread_loop_wait: if (s.pw_thread_loop_wait) *const @TypeOf(pw_thread_loop_wait) else void,
        pw_thread_loop_timed_wait: if (s.pw_thread_loop_timed_wait) *const @TypeOf(pw_thread_loop_timed_wait) else void,
        pw_thread_loop_accept: if (s.pw_thread_loop_accept) *const @TypeOf(pw_thread_loop_accept) else void,
        pw_thread_loop_in_thread: if (s.pw_thread_loop_in_thread) *const @TypeOf(pw_thread_loop_in_thread) else void,
        pw_thread_loop_add_listener: if (s.pw_thread_loop_add_listener) *const @TypeOf(pw_thread_loop_add_listener) else void,
        pw_thread_loop_get_loop: if (s.pw_thread_loop_get_loop) *const @TypeOf(pw_thread_loop_get_loop) else void,

        pw_stream_dequeue_buffer: if (s.pw_stream_dequeue_buffer) *const @TypeOf(pw_stream_dequeue_buffer) else void,
        pw_stream_queue_buffer: if (s.pw_stream_queue_buffer) *const @TypeOf(pw_stream_queue_buffer) else void,
        pw_stream_flush: if (s.pw_stream_flush) *const @TypeOf(pw_stream_flush) else void,
        pw_stream_new_simple: if (s.pw_stream_new_simple) *const @TypeOf(pw_stream_new_simple) else void,
        pw_stream_add_listener: if (s.pw_stream_add_listener) *const @TypeOf(pw_stream_add_listener) else void,
        pw_stream_get_state: if (s.pw_stream_get_state) *const @TypeOf(pw_stream_get_state) else void,
        pw_stream_get_name: if (s.pw_stream_get_name) *const @TypeOf(pw_stream_get_name) else void,
        pw_stream_get_remote: if (s.pw_stream_get_remote) *const @TypeOf(pw_stream_get_remote) else void,
        pw_stream_get_properties: if (s.pw_stream_get_properties) *const @TypeOf(pw_stream_get_properties) else void,
        pw_stream_update_properties: if (s.pw_stream_update_properties) *const @TypeOf(pw_stream_update_properties) else void,
        pw_stream_set_control: if (s.pw_stream_set_control) *const @TypeOf(pw_stream_set_control) else void,
        pw_stream_get_control: if (s.pw_stream_get_control) *const @TypeOf(pw_stream_get_control) else void,

        pw_stream_state_as_string: if (s.pw_stream_state_as_string) *const @TypeOf(pw_stream_state_as_string) else void,
        pw_stream_new: if (s.pw_stream_new) *const @TypeOf(pw_stream_new) else void,
        pw_stream_destroy: if (s.pw_stream_destroy) *const @TypeOf(pw_stream_destroy) else void,
        pw_stream_connect: if (s.pw_stream_connect) *const @TypeOf(pw_stream_connect) else void,
        pw_stream_get_node_id: if (s.pw_stream_get_node_id) *const @TypeOf(pw_stream_get_node_id) else void,
        pw_stream_disconnect: if (s.pw_stream_disconnect) *const @TypeOf(pw_stream_disconnect) else void,
        pw_stream_finish_format: if (s.pw_stream_finish_format) *const @TypeOf(pw_stream_finish_format) else void,
        pw_stream_get_time: if (s.pw_stream_get_time) *const @TypeOf(pw_stream_get_time) else void,
        pw_stream_set_active: if (s.pw_stream_set_active) *const @TypeOf(pw_stream_set_active) else void,

        pub fn load(self: *@This(), handle: *DynLib) error{SymbolLookupFail}!void {
            if (comptime s.pw_init)
                self.pw_init = handle.lookup(@TypeOf(self.pw_init), "pw_init") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_deinit)
                self.pw_deinit = handle.lookup(@TypeOf(self.pw_deinit), "pw_deinit") orelse
                    return error.SymbolLookupFail;

            if (comptime s.pw_properties_new)
                self.pw_properties_new = handle.lookup(@TypeOf(self.pw_properties_new), "pw_properties_new") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_properties_new_dict)
                self.pw_properties_new_dict = handle.lookup(@TypeOf(self.pw_properties_new_dict), "pw_properties_new_dict") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_properties_new_string)
                self.pw_properties_new_string = handle.lookup(@TypeOf(self.pw_properties_new_string), "pw_properties_new_string") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_properties_copy)
                self.pw_properties_copy = handle.lookup(@TypeOf(self.pw_properties_copy), "pw_properties_copy") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_properties_clear)
                self.pw_properties_clear = handle.lookup(@TypeOf(self.pw_properties_clear), "pw_properties_clear") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_properties_update)
                self.pw_properties_update = handle.lookup(@TypeOf(self.pw_properties_update), "pw_properties_update") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_properties_free)
                self.pw_properties_free = handle.lookup(@TypeOf(self.pw_properties_free), "pw_properties_free") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_properties_set)
                self.pw_properties_set = handle.lookup(@TypeOf(self.pw_properties_set), "pw_properties_set") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_properties_setf)
                self.pw_properties_setf = handle.lookup(@TypeOf(self.pw_properties_setf), "pw_properties_setf") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_properties_get)
                self.pw_properties_get = handle.lookup(@TypeOf(self.pw_properties_get), "pw_properties_get") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_properties_iterate)
                self.pw_properties_iterate = handle.lookup(@TypeOf(self.pw_properties_iterate), "pw_properties_iterate") orelse
                    return error.SymbolLookupFail;

            if (comptime s.pw_thread_loop_new)
                self.pw_thread_loop_new = handle.lookup(@TypeOf(self.pw_thread_loop_new), "pw_thread_loop_new") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_thread_loop_destroy)
                self.pw_thread_loop_destroy = handle.lookup(@TypeOf(self.pw_thread_loop_destroy), "pw_thread_loop_destroy") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_thread_loop_start)
                self.pw_thread_loop_start = handle.lookup(@TypeOf(self.pw_thread_loop_start), "pw_thread_loop_start") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_thread_loop_stop)
                self.pw_thread_loop_stop = handle.lookup(@TypeOf(self.pw_thread_loop_stop), "pw_thread_loop_stop") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_thread_loop_lock)
                self.pw_thread_loop_lock = handle.lookup(@TypeOf(self.pw_thread_loop_lock), "pw_thread_loop_lock") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_thread_loop_unlock)
                self.pw_thread_loop_unlock = handle.lookup(@TypeOf(self.pw_thread_loop_unlock), "pw_thread_loop_unlock") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_thread_loop_signal)
                self.pw_thread_loop_signal = handle.lookup(@TypeOf(self.pw_thread_loop_signal), "pw_thread_loop_signal") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_thread_loop_wait)
                self.pw_thread_loop_wait = handle.lookup(@TypeOf(self.pw_thread_loop_wait), "pw_thread_loop_wait") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_thread_loop_timed_wait)
                self.pw_thread_loop_timed_wait = handle.lookup(@TypeOf(self.pw_thread_loop_timed_wait), "pw_thread_loop_timed_wait") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_thread_loop_accept)
                self.pw_thread_loop_accept = handle.lookup(@TypeOf(self.pw_thread_loop_accept), "pw_thread_loop_accept") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_thread_loop_in_thread)
                self.pw_thread_loop_in_thread = handle.lookup(@TypeOf(self.pw_thread_loop_in_thread), "pw_thread_loop_in_thread") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_thread_loop_add_listener)
                self.pw_thread_loop_add_listener = handle.lookup(@TypeOf(self.pw_thread_loop_add_listener), "pw_thread_loop_add_listener") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_thread_loop_get_loop)
                self.pw_thread_loop_get_loop = handle.lookup(@TypeOf(self.pw_thread_loop_get_loop), "pw_thread_loop_get_loop") orelse
                    return error.SymbolLookupFail;

            if (comptime s.pw_stream_dequeue_buffer)
                self.pw_stream_dequeue_buffer = handle.lookup(@TypeOf(self.pw_stream_dequeue_buffer), "pw_stream_dequeue_buffer") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_queue_buffer)
                self.pw_stream_queue_buffer = handle.lookup(@TypeOf(self.pw_stream_queue_buffer), "pw_stream_queue_buffer") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_flush)
                self.pw_stream_flush = handle.lookup(@TypeOf(self.pw_stream_flush), "pw_stream_flush") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_new_simple)
                self.pw_stream_new_simple = handle.lookup(@TypeOf(self.pw_stream_new_simple), "pw_stream_new_simple") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_add_listener)
                self.pw_stream_add_listener = handle.lookup(@TypeOf(self.pw_stream_add_listener), "pw_stream_add_listener") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_get_state)
                self.pw_stream_get_state = handle.lookup(@TypeOf(self.pw_stream_get_state), "pw_stream_get_state") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_get_name)
                self.pw_stream_get_name = handle.lookup(@TypeOf(self.pw_stream_get_name), "pw_stream_get_name") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_get_remote)
                self.pw_stream_get_remote = handle.lookup(@TypeOf(self.pw_stream_get_remote), "pw_stream_get_remote") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_get_properties)
                self.pw_stream_get_properties = handle.lookup(@TypeOf(self.pw_stream_get_properties), "pw_stream_get_properties") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_update_properties)
                self.pw_stream_update_properties = handle.lookup(@TypeOf(self.pw_stream_update_properties), "pw_stream_update_properties") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_set_control)
                self.pw_stream_set_control = handle.lookup(@TypeOf(self.pw_stream_set_control), "pw_stream_set_control") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_get_control)
                self.pw_stream_get_control = handle.lookup(@TypeOf(self.pw_stream_get_control), "pw_stream_get_control") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_state_as_string)
                self.pw_stream_state_as_string = handle.lookup(@TypeOf(self.pw_stream_state_as_string), "pw_stream_state_as_string") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_new)
                self.pw_stream_new = handle.lookup(@TypeOf(self.pw_stream_new), "pw_stream_new") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_destroy)
                self.pw_stream_destroy = handle.lookup(@TypeOf(self.pw_stream_destroy), "pw_stream_destroy") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_connect)
                self.pw_stream_connect = handle.lookup(@TypeOf(self.pw_stream_connect), "pw_stream_connect") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_get_node_id)
                self.pw_stream_get_node_id = handle.lookup(@TypeOf(self.pw_stream_get_node_id), "pw_stream_get_node_id") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_disconnect)
                self.pw_stream_disconnect = handle.lookup(@TypeOf(self.pw_stream_disconnect), "pw_stream_disconnect") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_finish_format)
                self.pw_stream_finish_format = handle.lookup(@TypeOf(self.pw_stream_finish_format), "pw_stream_finish_format") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_get_time)
                self.pw_stream_get_time = handle.lookup(@TypeOf(self.pw_stream_get_time), "pw_stream_get_time") orelse
                    return error.SymbolLookupFail;
            if (comptime s.pw_stream_set_active)
                self.pw_stream_set_active = handle.lookup(@TypeOf(self.pw_stream_set_active), "pw_stream_set_active") orelse
                    return error.SymbolLookupFail;
        }
    };
}

const required_symbols = SymbolList{
    .pw_init = true,
    .pw_deinit = true,
    .pw_properties_new = true,
    .pw_thread_loop_new = true,
    .pw_thread_loop_destroy = true,
    .pw_thread_loop_start = true,
    .pw_thread_loop_stop = true,
    .pw_thread_loop_lock = true,
    .pw_thread_loop_unlock = true,
    .pw_thread_loop_get_loop = true,
    .pw_stream_dequeue_buffer = true,
    .pw_stream_queue_buffer = true,
    .pw_stream_new_simple = true,
    .pw_stream_state_as_string = true,
    .pw_stream_destroy = true,
    .pw_stream_connect = true,
};

var symbols: Symbols(required_symbols) = undefined;

//
// Core bindings
//

extern fn pw_init(argc: *i32, argv: *[*][*:0]const u8) callconv(.C) void;
extern fn pw_deinit() callconv(.C) void;

//
// Properties bindings
//

extern fn pw_properties_new(key: [*:0]const u8, ...) callconv(.C) *Properties;
extern fn pw_properties_new_dict(dict: *spa.Dict) callconv(.C) *Properties;
extern fn pw_properties_new_string(string: [*:0]const u8) callconv(.C) *Properties;
extern fn pw_properties_copy(properties: *const Properties) callconv(.C) *Properties;
extern fn pw_properties_clear(properties: *Properties) callconv(.C) void;
extern fn pw_properties_update(properties: *Properties, dict: *spa.Dict) callconv(.C) i32;
extern fn pw_properties_free(properties: *Properties) callconv(.C) void;
extern fn pw_properties_set(properties: *Properties, key: [*:0]const u8, value: [*:0]const u8) callconv(.C) i32;
extern fn pw_properties_setf(properties: *Properties, key: [*:0]const u8, format: [*:0]const u8, ...) callconv(.C) i32;
extern fn pw_properties_get(properties: *Properties, key: [*:0]const u8) callconv(.C) [*:0]const u8;
extern fn pw_properties_iterate(properties: *Properties, state_data: *?*anyopaque) callconv(.C) [*:0]const u8;

//
// ThreadLoop bindings
//

extern fn pw_thread_loop_new(name: [*:0]const u8, properties: ?*const spa.Dict) callconv(.C) *ThreadLoop;
extern fn pw_thread_loop_destroy(loop: *ThreadLoop) callconv(.C) void;
extern fn pw_thread_loop_start(loop: *ThreadLoop) callconv(.C) i32;
extern fn pw_thread_loop_stop(loop: *ThreadLoop) callconv(.C) void;
extern fn pw_thread_loop_lock(loop: *ThreadLoop) callconv(.C) void;
extern fn pw_thread_loop_unlock(loop: *ThreadLoop) callconv(.C) void;
extern fn pw_thread_loop_signal(loop: *ThreadLoop, wait_for_accept: bool) callconv(.C) void;
extern fn pw_thread_loop_wait(loop: *ThreadLoop) callconv(.C) void;
extern fn pw_thread_loop_timed_wait(loop: *ThreadLoop, wait_max_seconds: i32) callconv(.C) i32;
extern fn pw_thread_loop_accept(loop: *ThreadLoop) callconv(.C) void;
extern fn pw_thread_loop_in_thread(loop: *ThreadLoop) callconv(.C) bool;

const ThreadLoopEvents = extern struct {
    version: u32,
    destroy: *const fn (data: ?*anyopaque) void,
};

extern fn pw_thread_loop_new_full(loop: *Loop, name: [*:0]const u8, properties: ?*const spa.Dict) callconv(.C) *ThreadLoop;
extern fn pw_thread_loop_add_listener(loop: *ThreadLoop, listener: *spa.Hook, events: *const ThreadLoopEvents, data: ?*anyopaque) callconv(.C) void;
extern fn pw_thread_loop_get_loop(loop: *ThreadLoop) callconv(.C) *Loop;

// extern fn () callconv(.C) ;
// extern fn () callconv(.C) ;

//
// Stream bindings
//

extern fn pw_stream_dequeue_buffer(stream: *Stream) callconv(.C) *Buffer;
extern fn pw_stream_queue_buffer(stream: *Stream, buffer: *Buffer) callconv(.C) i32;
extern fn pw_stream_flush(stream: *Stream, drain: bool) callconv(.C) i32;
extern fn pw_stream_new_simple(
    loop: *Loop,
    name: [*:0]const u8,
    properties: *Properties,
    stream_events: *const StreamEvents,
    data: ?*anyopaque,
) callconv(.C) ?*Stream;
extern fn pw_stream_add_listener(stream: *Stream, listener: *spa.Hook, stream_events: *StreamEvents, data: ?*anyopaque) callconv(.C) void;
extern fn pw_stream_get_state(stream: *Stream, error_string: *[*:0]const u8) callconv(.C) StreamState;
extern fn pw_stream_get_name(stream: *Stream) callconv(.C) [*:0]const u8;
extern fn pw_stream_get_remote(stream: *Stream) callconv(.C) *Remote;
extern fn pw_stream_get_properties(stream: *Stream) callconv(.C) *Properties;
extern fn pw_stream_update_properties(stream: *Stream, dict: *const spa.Dict) callconv(.C) i32;
extern fn pw_stream_set_control(stream: *Stream, id: u32, value: f32, ...) callconv(.C) i32;
extern fn pw_stream_get_control(stream: *Stream, id: u32) callconv(.C) *StreamControl;

extern fn pw_stream_state_as_string(pw_stream_state: StreamState) callconv(.C) [*:0]const u8;
extern fn pw_stream_new(remote: *Remote, name: [*:0]const u8, properties: *Properties) callconv(.C) *Stream;
extern fn pw_stream_destroy(stream: *Stream) callconv(.C) void;
extern fn pw_stream_connect(
    stream: *Stream,
    direction: Direction,
    target_id: u32,
    flags: StreamFlags,
    params: *[*]spa.Pod,
    params_count: u32,
) callconv(.C) i32;
extern fn pw_stream_get_node_id(stream: *Stream) callconv(.C) u32;
extern fn pw_stream_disconnect(stream: *Stream) callconv(.C) i32;
extern fn pw_stream_finish_format(stream: *Stream, res: i32, params: *const [*]spa.Pod, params_count: u32) callconv(.C) void;
extern fn pw_stream_get_time(stream: *Stream, time: *Time) callconv(.C) i32;
extern fn pw_stream_set_active(stream: *Stream, active: bool) callconv(.C) i32;

fn onStateChangedCallback(_: ?*anyopaque, old: StreamState, new: StreamState, error_message: [*c]const u8) callconv(.C) void {
    _ = old;
    const error_string: [*c]const u8 = error_message orelse "none";
    std.log.warn("pipewire state changed. \"{s}\". Error: {s}", .{ symbols.pw_stream_state_as_string(new), error_string });
}

fn onProcessCallback(_: ?*anyopaque) callconv(.C) void {
    const buffer = symbols.pw_stream_dequeue_buffer(stream);
    const buffer_bytes = buffer.*.buffer.*.datas[0].data orelse return;
    const buffer_size_bytes = buffer.*.buffer.*.datas[0].chunk.*.size;
    const sample_count = @divExact(buffer_size_bytes, @sizeOf(i16));
    onReadSamplesCallback(@ptrCast([*]i16, @alignCast(2, buffer_bytes))[0..sample_count]);
    _ = symbols.pw_stream_queue_buffer(stream, buffer);
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

pub fn createInterface(read_samples_callback: *const audio.OnReadSamplesFn) audio.Interface {
    onReadSamplesCallback = read_samples_callback;
    return .{
        .init = &init,
        .open = &open,
        .close = &close,
        .state = &state,
        .inputList = &inputList,
    };
}

fn inputList(allocator: std.mem.Allocator, callback: *const audio.InputListCallbackFn) void {
    _ = allocator;
    _ = callback;
    @panic("Not implemented");
}

pub fn state() audio.State {
    return stream_state;
}

const keys = struct {
    const media_type = "media.type";
    const media_category = "media.category";
    const media_role = "media.role";
    const media_class = "media.class";
    const media_name = "media.name";
    const media_title = "media.title";
    const media_artist = "media.artist";
    const media_copyright = "media.copyright";
    const media_software = "media.software";
    const media_language = "media.language";
    const media_filename = "media.filename";
    const media_icon = "media.icon";
    const media_icon_name = "media.icon-name";
};

fn setupStream() error{ PipewireConnectServerFail, CreateStreamFail, ConnectStreamFail }!void {
    var argc: i32 = 1;
    var argv = [_][*:0]const u8{"reel"};

    symbols.pw_init(@ptrCast(*i32, &argc), @ptrCast(*[*][*:0]const u8, &argv));

    thread_loop = symbols.pw_thread_loop_new("Pipewire thread loop", null);

    if (symbols.pw_thread_loop_start(thread_loop) < 0) {
        return error.PipewireConnectServerFail;
    }
    symbols.pw_thread_loop_lock(thread_loop);

    const stream_properties = symbols.pw_properties_new(
        keys.media_type,
        // pw.PW_KEY_MEDIA_TYPE,
        "Audio",
        keys.media_category,
        // pw.PW_KEY_MEDIA_CATEGORY,
        "Capture",
        keys.media_role,
        // pw.PW_KEY_MEDIA_ROLE,
        "Music",
        // @as(usize, 0),
        c.NULL,
    );

    stream = symbols.pw_stream_new_simple(
        symbols.pw_thread_loop_get_loop(thread_loop),
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
                .value = @enumToInt(AudioFormat.s16_le),
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
                .value = @enumToInt(AudioChannel.fr),
                .padding = @enumToInt(AudioChannel.fl),
            },
        },
    };

    var param_ptr = &audio_format_param;
    var ret_code = symbols.pw_stream_connect(
        stream,
        .input,
        id_any,
        .{
            // .autoconnect = true,
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

pub fn init(
    onSuccess: *const audio.InitSuccessCallbackFn,
    onFail: *const audio.InitFailCallbackFn,
) InitErrors!void {
    std.debug.assert(stream_state == .closed);

    onInitFailCallback = onFail;
    onInitSuccessCallback = onSuccess;

    if (!is_stream_ready) {
        try setupStream();
        is_stream_ready = true;
    }

    stream_state = .initialized;
    onInitSuccessCallback();
}

pub fn close() void {
    symbols.pw_thread_loop_lock(thread_loop);
    symbols.pw_thread_loop_stop(thread_loop);
    symbols.pw_stream_destroy(stream);
    symbols.pw_thread_loop_destroy(thread_loop);
    symbols.pw_deinit();
}

pub fn open(
    device_name_opt: ?[*:0]const u8,
    onSuccess: *const audio.OpenSuccessCallbackFn,
    onFail: *const audio.OpenFailCallbackFn,
) OpenErrors!void {
    _ = device_name_opt;

    onOpenFailCallback = onFail;
    onOpenSuccessCallback = onSuccess;

    std.debug.assert(stream_state == .initialized);

    //
    // Activate the read thread
    //
    symbols.pw_thread_loop_unlock(thread_loop);

    onOpenSuccessCallback();
}

const AudioFormat = enum(u32) {
    unknown,
    encodeded,
    start_interleaved = 0x100,
    s8,
    u8,
    s16_le,
    s16_be,
    u16_le,
    u16_be,
    s24_32_le,
    s24_32_be,
    u24_32_le,
    u24_32_be,
    s32_le,
    s32_be,
    u32_le,
    u32_be,
    s24_le,
    s24_be,
    u24_le,
    u24_be,
    s20_le,
    s20_be,
    u20_le,
    u20_be,
    s18_le,
    s18_be,
    u18_le,
    u18_be,
    f32_le,
    f32_be,
    f64_le,
    f64_be,
    ulaw,
    alaw,
    //
    // Planar
    //
    start_planar = 0x200,
    u8p,
    s16p,
    s24_32p,
    s32p,
    s24p,
    f32p,
    f64p,
    s8p,
};

const AudioChannel = enum(u32) {
    unknown,
    na,
    mono,
    fl,
    fr,
    fc,
    lfe,
    sl,
    sr,
    flc,
    frc,
    rc,
    rl,
    rr,
    tc,
    tfl,
    tfc,
    tfr,
    trl,
    trc,
    trr,
    rlc,
    rrc,
    flw,
    frw,
    lfe2,
    flh,
    fch,
    frh,
    tflc,
    tfrc,
    tsl,
    tsr,
    llfe,
    rlfe,
    bc,
    blc,
    brc,

    aux0 = 0x1000,
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
    aux32,
    aux33,
    aux34,
    aux35,
    aux36,
    aux37,
    aux38,
    aux39,
    aux40,
    aux41,
    aux42,
    aux43,
    aux44,
    aux45,
    aux46,
    aux47,
    aux48,
    aux49,
    aux50,
    aux51,
    aux52,
    aux53,
    aux54,
    aux55,
    aux56,
    aux57,
    aux58,
    aux59,
    aux60,
    aux61,
    aux62,
    aux63,

    last_aux = 0x1fff,
    start_custom = 0x10000,
};

const spa = struct {
    const Dict = opaque {};
    const Hook = opaque {};
    const Command = opaque {};

    const Buffer = extern struct {
        n_metas: u32,
        n_datas: u32,
        metas: [*]Meta,
        datas: [*]Data,
    };

    const Meta = extern struct {
        const Type = enum(u32) {
            invalid,
            header,
            video_crop,
            video_damage,
            bitmap,
            cursor,
            busy,
            video_transform,
        };

        type: Type,
        size: u32,
        data: ?*anyopaque,
    };

    const Data = extern struct {
        type: u32,
        flags: u32,
        fd: i64,
        map_offset: u32,
        map_size: u32,
        data: ?*anyopaque,
        chunk: *Chunk,
    };

    const Chunk = extern struct {
        offset: u32,
        size: u32,
        stride: i32,
        flags: i32,
    };

    const Callbacks = extern struct {
        version: u32,
        overflow: *const fn (data: ?*anyopaque, size: u32) i32,
    };

    const Pod = extern struct {
        kind: u32,
        size: u32,
    };

    const ParamType = enum(i32) {
        invalid,
        prop_info,
        props,
        enum_format,
        format,
        buffers,
        meta,
        io,
        enum_profile,
        profile,
        enum_port_config,
        port_config,
        enum_route,
        route,
        control,
        latency,
        process_latency,
    };

    const PodType = enum(u32) {
        start,
        none,
        bool,
        id,
        int,
        long,
        float,
        double,
        string,
        bytes,
        rectangle,
        fraction,
        bitmap,
        array,
        @"struct",
        object,
        sequence,
        pointer,
        fd,
        choice,
        pod,
        //
        // Pointers
        //
        pointer_start = 0x10000,
        pointer_buffer,
        pointer_meta,
        pointer_dict,
        //
        // Events
        //
        event_start = 0x20000,
        event_device,
        event_node,
        //
        // Commands
        //
        command_start = 0x30000,
        command_device,
        command_node,
        //
        // Objects
        //
        object_start = 0x40000,
        object_prop_info,
        object_props,
        object_format,
        object_param_buffers,
        object_param_meta,
        object_param_io,
        object_param_profile,
        object_param_port_config,
        object_param_route,
        object_profiler,
        object_param_latency,
        object_param_process_latency,
        object_vender_pipewire = 0x02000000,
        object_vender_other = 0x7f000000,
    };

    const Format = enum(u32) {
        start,
        media_type,
        media_subtype,
        //
        // Audio format keys
        //
        start_audio = 0x10000,
        audio_format,
        audio_flags,
        audio_rate,
        audio_channels,
        audio_position,
        audio_iec958_codec,
        audio_bitorder,
        audio_interleave,
        audio_bitrate,
        audio_block_align,
        audio_aac_stream_format,
        audio_wma_profile,
        audio_amr_bandmode,
        //
        // Video format keys
        //
        start_video = 0x20000,
        video_format,
        video_modifier,
        video_size,
        video_framerate,
        video_max_framerate,
        video_views,
        video_interlace_mode,
        video_pixel_aspect_ratio,
        video_multiview_mode,
        video_multiview_flags,
        video_chroma_site,
        video_color_range,
        video_color_matrix,
        video_transfer_function,
        video_color_primaries,
        video_profile,
        video_level,
        video_h264_stream_format,
        video_h264_alignment,
    };

    const MediaType = enum(u32) {
        unknown,
        audio,
        video,
        image,
        binary,
        stream,
        application,
    };

    const MediaSubtype = enum(u32) {
        unknown,
        raw,
        dsp,
        iec958,
        dsd,
        start_audio = 0x10000,
        mp3,
        aac,
        vorbis,
        wma,
        ra,
        sbc,
        adpcm,
        g723,
        g726,
        g729,
        amr,
        gsm,
        alac,
        flac,
        ape,
        opus,
        //
        // Video
        //
        video_start = 0x20000,
        h264,
        mjpg,
        dv,
        mpegts,
        h263,
        mpeg1,
        mpeg2,
        mpeg4,
        xvid,
        vc1,
        vp8,
        vp9,
        bayer,
        //
        // Image
        //
        start_image = 0x30000,
        jpeg,
        //
        // Etc
        //
        start_binary = 0x40000,
        start_stream = 0x50000,
        midi,
        start_application = 0x60000,
        control,
    };
};
