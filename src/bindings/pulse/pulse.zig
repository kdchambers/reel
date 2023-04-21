// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const DynLib = std.DynLib;

const b = @import("c-bindings.zig");

pub const ThreadedMainloop = b.pa_threaded_mainloop;
pub const MainloopApi = b.pa_mainloop_api;
pub const Context = b.pa_context;
pub const Stream = b.pa_stream;

pub const CardInfo = b.pa_card_info;
pub const SourceInfo = b.pa_source_info;
pub const SinkInfo = b.pa_sink_info;
pub const StreamFlags = b.pa_stream_flags_t;
pub const BufferAttr = b.pa_buffer_attr;
pub const SampleSpec = b.pa_sample_spec;

pub const SymbolList = struct {
    threaded_mainloop_new: bool = false,
    threaded_mainloop_get_api: bool = false,
    threaded_mainloop_start: bool = false,
    threaded_mainloop_free: bool = false,
    threaded_mainloop_stop: bool = false,
    threaded_mainloop_unlock: bool = false,
    threaded_mainloop_lock: bool = false,
    threaded_mainloop_wait: bool = false,

    context_new: bool = false,
    context_new_with_proplist: bool = false,
    context_connect: bool = false,
    context_disconnect: bool = false,
    context_unref: bool = false,
    context_set_state_callback: bool = false,
    context_get_state: bool = false,
    //
    // See comment below
    //
    // context_get_sink_info_list: bool = false,
    context_get_source_info_list: bool = false,
    context_get_card_info_list: bool = false,
    context_get_source_info_by_index: bool = false,

    stream_new: bool = false,
    stream_set_read_callback: bool = false,
    stream_peek: bool = false,
    stream_drop: bool = false,
    stream_get_state: bool = false,
    stream_set_state_callback: bool = false,
    stream_connect_record: bool = false,
    stream_unref: bool = false,
    stream_get_sample_spec: bool = false,
    stream_get_channel_map: bool = false,
    stream_get_device_name: bool = false,
    stream_get_device_index: bool = false,
};

pub fn DynamicLoader(comptime s: SymbolList) type {
    return struct {
        threaded_mainloop_new: if (s.threaded_mainloop_new) *const @TypeOf(b.pa_threaded_mainloop_new) else void,
        threaded_mainloop_get_api: if (s.threaded_mainloop_get_api) *const @TypeOf(b.pa_threaded_mainloop_get_api) else void,
        threaded_mainloop_start: if (s.threaded_mainloop_start) *const @TypeOf(b.pa_threaded_mainloop_start) else void,
        threaded_mainloop_free: if (s.threaded_mainloop_free) *const @TypeOf(b.pa_threaded_mainloop_free) else void,
        threaded_mainloop_stop: if (s.threaded_mainloop_stop) *const @TypeOf(b.pa_threaded_mainloop_stop) else void,
        threaded_mainloop_unlock: if (s.threaded_mainloop_unlock) *const @TypeOf(b.pa_threaded_mainloop_unlock) else void,
        threaded_mainloop_lock: if (s.threaded_mainloop_lock) *const @TypeOf(b.pa_threaded_mainloop_lock) else void,
        threaded_mainloop_wait: if (s.threaded_mainloop_wait) *const @TypeOf(b.pa_threaded_mainloop_wait) else void,

        context_new: if (s.context_new) *const @TypeOf(b.pa_context_new) else void,
        context_new_with_proplist: if (s.context_new_with_proplist) *const @TypeOf(b.pa_context_new_with_proplist) else void,
        context_connect: if (s.context_connect) *const @TypeOf(b.pa_context_connect) else void,
        context_disconnect: if (s.context_disconnect) *const @TypeOf(b.pa_context_disconnect) else void,
        context_unref: if (s.context_unref) *const @TypeOf(b.pa_context_unref) else void,
        context_set_state_callback: if (s.context_set_state_callback) *const @TypeOf(b.pa_context_set_state_callback) else void,
        context_get_state: if (s.context_get_state) *const @TypeOf(b.pa_context_get_state) else void,
        //
        // TODO: For some reason this triggers an error about struct needing comptime because of this field. No idea why
        //
        // context_get_sink_info_list: if (s.context_get_sink_info_list) *const @TypeOf(b.pa_context_get_sink_info_list) else void,
        context_get_source_info_list: if (s.context_get_source_info_list) *const @TypeOf(b.pa_context_get_source_info_list) else void,
        context_get_card_info_list: if (s.context_get_card_info_list) *const @TypeOf(b.pa_context_get_card_info_list) else void,
        context_get_source_info_by_index: if (s.context_get_source_info_by_index) *const @TypeOf(b.pa_context_get_source_info_by_index) else void,

        stream_new: if (s.stream_new) *const @TypeOf(b.pa_stream_new) else void,
        stream_set_read_callback: if (s.stream_set_read_callback) *const @TypeOf(b.pa_stream_set_read_callback) else void,
        stream_peek: if (s.stream_peek) *const @TypeOf(b.pa_stream_peek) else void,
        stream_drop: if (s.stream_drop) *const @TypeOf(b.pa_stream_drop) else void,
        stream_get_state: if (s.stream_get_state) *const @TypeOf(b.pa_stream_get_state) else void,
        stream_set_state_callback: if (s.stream_set_state_callback) *const @TypeOf(b.pa_stream_set_state_callback) else void,
        stream_connect_record: if (s.stream_connect_record) *const @TypeOf(b.pa_stream_connect_record) else void,
        stream_unref: if (s.stream_unref) *const @TypeOf(b.pa_stream_unref) else void,
        stream_get_sample_spec: if (s.stream_get_sample_spec) *const @TypeOf(b.pa_stream_get_sample_spec) else void,
        stream_get_channel_map: if (s.stream_get_channel_map) *const @TypeOf(b.pa_stream_get_channel_map) else void,
        stream_get_device_name: if (s.stream_get_device_name) *const @TypeOf(b.pa_stream_get_device_name) else void,
        stream_get_device_index: if (s.stream_get_device_index) *const @TypeOf(b.pa_stream_get_device_index) else void,

        pub fn load(self: *@This(), handle: *DynLib) error{SymbolLookupFail}!void {
            if (comptime s.threaded_mainloop_new)
                self.threaded_mainloop_new = handle.lookup(@TypeOf(self.threaded_mainloop_new), "pa_threaded_mainloop_new") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threaded_mainloop_get_api)
                self.threaded_mainloop_get_api = handle.lookup(@TypeOf(self.threaded_mainloop_get_api), "pa_threaded_mainloop_get_api") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threaded_mainloop_start)
                self.threaded_mainloop_start = handle.lookup(@TypeOf(self.threaded_mainloop_start), "pa_threaded_mainloop_start") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threaded_mainloop_free)
                self.threaded_mainloop_free = handle.lookup(@TypeOf(self.threaded_mainloop_free), "pa_threaded_mainloop_free") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threaded_mainloop_stop)
                self.threaded_mainloop_stop = handle.lookup(@TypeOf(self.threaded_mainloop_stop), "pa_threaded_mainloop_stop") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threaded_mainloop_unlock)
                self.threaded_mainloop_unlock = handle.lookup(@TypeOf(self.threaded_mainloop_unlock), "pa_threaded_mainloop_unlock") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threaded_mainloop_lock)
                self.threaded_mainloop_lock = handle.lookup(@TypeOf(self.threaded_mainloop_lock), "pa_threaded_mainloop_lock") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threaded_mainloop_wait)
                self.threaded_mainloop_wait = handle.lookup(@TypeOf(self.threaded_mainloop_wait), "pa_threaded_mainloop_wait") orelse
                    return error.SymbolLookupFail;

            if (comptime s.context_new)
                self.context_new = handle.lookup(@TypeOf(self.context_new), "pa_context_new") orelse
                    return error.SymbolLookupFail;
            if (comptime s.context_new_with_proplist)
                self.context_new_with_proplist = handle.lookup(@TypeOf(self.context_new_with_proplist), "pa_context_new_with_proplist") orelse
                    return error.SymbolLookupFail;
            if (comptime s.context_connect)
                self.context_connect = handle.lookup(@TypeOf(self.context_connect), "pa_context_connect") orelse
                    return error.SymbolLookupFail;
            if (comptime s.context_disconnect)
                self.context_disconnect = handle.lookup(@TypeOf(self.context_disconnect), "pa_context_disconnect") orelse
                    return error.SymbolLookupFail;
            if (comptime s.context_unref)
                self.context_unref = handle.lookup(@TypeOf(self.context_unref), "pa_context_unref") orelse
                    return error.SymbolLookupFail;
            if (comptime s.context_set_state_callback)
                self.context_set_state_callback = handle.lookup(@TypeOf(self.context_set_state_callback), "pa_context_set_state_callback") orelse
                    return error.SymbolLookupFail;
            if (comptime s.context_get_state)
                self.context_get_state = handle.lookup(@TypeOf(self.context_get_state), "pa_context_get_state") orelse
                    return error.SymbolLookupFail;
            //
            // See comment above
            //
            // if (comptime s.context_get_sink_info_list)
            //     self.context_get_sink_info_list = handle.lookup(@TypeOf(self.context_get_sink_info_list), "pa_context_get_sink_info_list") orelse
            //         return error.SymbolLookupFail;
            if (comptime s.context_get_source_info_list)
                self.context_get_source_info_list = handle.lookup(@TypeOf(self.context_get_source_info_list), "pa_context_get_source_info_list") orelse
                    return error.SymbolLookupFail;
            if (comptime s.context_get_card_info_list)
                self.context_get_card_info_list = handle.lookup(@TypeOf(self.context_get_card_info_list), "pa_context_get_card_info_list") orelse
                    return error.SymbolLookupFail;
            if (comptime s.context_get_source_info_by_index)
                self.context_get_source_info_by_index = handle.lookup(@TypeOf(self.context_get_source_info_by_index), "pa_context_get_source_info_by_index") orelse
                    return error.SymbolLookupFail;

            if (comptime s.stream_new)
                self.stream_new = handle.lookup(@TypeOf(self.stream_new), "pa_stream_new") orelse
                    return error.SymbolLookupFail;
            if (comptime s.stream_set_read_callback)
                self.stream_set_read_callback = handle.lookup(@TypeOf(self.stream_set_read_callback), "pa_stream_set_read_callback") orelse
                    return error.SymbolLookupFail;
            if (comptime s.stream_peek)
                self.stream_peek = handle.lookup(@TypeOf(self.stream_peek), "pa_stream_peek") orelse
                    return error.SymbolLookupFail;
            if (comptime s.stream_drop)
                self.stream_drop = handle.lookup(@TypeOf(self.stream_drop), "pa_stream_drop") orelse
                    return error.SymbolLookupFail;
            if (comptime s.stream_get_state)
                self.stream_get_state = handle.lookup(@TypeOf(self.stream_get_state), "pa_stream_get_state") orelse
                    return error.SymbolLookupFail;
            if (comptime s.stream_set_state_callback)
                self.stream_set_state_callback = handle.lookup(@TypeOf(self.stream_set_state_callback), "pa_stream_set_state_callback") orelse
                    return error.SymbolLookupFail;
            if (comptime s.stream_connect_record)
                self.stream_connect_record = handle.lookup(@TypeOf(self.stream_connect_record), "pa_stream_connect_record") orelse
                    return error.SymbolLookupFail;
            if (comptime s.stream_unref)
                self.stream_unref = handle.lookup(@TypeOf(self.stream_unref), "pa_stream_unref") orelse
                    return error.SymbolLookupFail;
            if (comptime s.stream_get_sample_spec)
                self.stream_get_sample_spec = handle.lookup(@TypeOf(self.stream_get_sample_spec), "pa_stream_get_sample_spec") orelse
                    return error.SymbolLookupFail;
            if (comptime s.stream_get_channel_map)
                self.stream_get_channel_map = handle.lookup(@TypeOf(self.stream_get_channel_map), "pa_stream_get_channel_map") orelse
                    return error.SymbolLookupFail;
            if (comptime s.stream_get_device_name)
                self.stream_get_device_name = handle.lookup(@TypeOf(self.stream_get_device_name), "pa_stream_get_device_name") orelse
                    return error.SymbolLookupFail;
            if (comptime s.stream_get_device_index)
                self.stream_get_device_index = handle.lookup(@TypeOf(self.stream_get_device_index), "pa_stream_get_device_index") orelse
                    return error.SymbolLookupFail;
        }
    };
}
