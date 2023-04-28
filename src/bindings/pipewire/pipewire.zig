// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const DynLib = std.DynLib;

const b = @import("cbindings.zig");

pub const version_stream_events = b.version_stream_events;
pub const id_any: u32 = b.id_any;
pub const keys = b.keys;

pub const Stream = b.pw_stream;
pub const ThreadLoop = b.pw_thread_loop;
pub const Loop = b.pw_loop;
pub const Properties = b.pw_properties;
pub const Remote = b.pw_remote;
pub const StreamControl = b.pw_stream_control;
pub const Time = b.pw_time;
pub const StreamEvents = b.pw_stream_events;
pub const Buffer = b.pw_buffer;
pub const ThreadLoopEvents = b.pw_thread_loop_events;
pub const StreamState = b.pw_stream_state;
pub const StreamFlags = b.pw_stream_flags;
pub const Direction = b.pw_direction;

pub const init = b.pw_init;
pub const deinit = b.pw_deinit;

pub const propertiesNew = b.pw_properties_new;
pub const propertiesNewDict = b.pw_properties_new_dict;
pub const propertiesNewString = b.pw_properties_new_string;
pub const propertiesCopy = b.pw_properties_copy;
pub const propertiesClear = b.pw_properties_clear;
pub const propertiesUpdate = b.pw_properties_update;
pub const propertiesFree = b.pw_properties_free;
pub const propertiesSet = b.pw_properties_set;
pub const propertiesSetF = b.pw_properties_setf;
pub const propertiesGet = b.pw_properties_get;
pub const propertiesIterate = b.pw_properties_iterate;

pub const threadLoopNew = b.pw_thread_loop_new;
pub const threadLoopDestroy = b.pw_thread_loop_destroy;
pub const threadLoopStart = b.pw_thread_loop_start;
pub const threadLoopStop = b.pw_thread_loop_stop;
pub const threadLoopLock = b.pw_thread_loop_lock;
pub const threadLoopUnlock = b.pw_thread_loop_unlock;
pub const threadLoopSignal = b.pw_thread_loop_signal;
pub const threadLoopWait = b.pw_thread_loop_wait;
pub const threadLoopTimedWait = b.pw_thread_loop_timed_wait;
pub const threadLoopAccept = b.pw_thread_loop_accept;
pub const threadLoopInThread = b.pw_thread_loop_in_thread;
pub const threadLoopNewFull = b.pw_thread_loop_new_full;
pub const threadLoopAddListener = b.pw_thread_loop_add_listener;
pub const threadLoopGetLoop = b.pw_thread_loop_get_loop;

pub const streamDequeueBuffer = b.pw_stream_dequeue_buffer;
pub const streamQueueBuffer = b.pw_stream_queue_buffer;
pub const streamFlush = b.pw_stream_flush;
pub const streamNewSimple = b.pw_stream_new_simple;
pub const streamAddListener = b.pw_stream_add_listener;
pub const streamGetState = b.pw_stream_get_state;
pub const streamGetName = b.pw_stream_get_name;
pub const streamGetRemote = b.pw_stream_get_remote;
pub const streamGetProperties = b.pw_stream_get_properties;
pub const streamUpdateProperties = b.pw_stream_update_properties;
pub const streamSetControl = b.pw_stream_set_control;
pub const streamGetControl = b.pw_stream_get_control;
pub const streamStateAsString = b.pw_stream_state_as_string;
pub const streamNew = b.pw_stream_new;
pub const streamDestroy = b.pw_stream_destroy;
pub const streamConnect = b.pw_stream_connect;
pub const streamGetNodeID = b.pw_stream_get_node_id;
pub const streamDisconnect = b.pw_stream_disconnect;
pub const streamFinishFormat = b.pw_stream_finish_format;
pub const streamGetTime = b.pw_stream_get_time;
pub const streamSetActive = b.pw_stream_set_active;

pub const SymbolList = struct {
    init: bool = false,
    deinit: bool = false,

    propertiesNew: bool = false,
    propertiesNewDict: bool = false,
    propertiesNewString: bool = false,
    propertiesCopy: bool = false,
    propertiesClear: bool = false,
    propertiesUpdate: bool = false,
    propertiesFree: bool = false,
    propertiesSet: bool = false,
    propertiesSetF: bool = false,
    propertiesGet: bool = false,
    propertiesIterate: bool = false,

    threadLoopNew: bool = false,
    threadLoopDestroy: bool = false,
    threadLoopStart: bool = false,
    threadLoopStop: bool = false,
    threadLoopLock: bool = false,
    threadLoopUnlock: bool = false,
    threadLoopSignal: bool = false,
    threadLoopWait: bool = false,
    threadLoopTimedWait: bool = false,
    threadLoopAccept: bool = false,
    threadLoopInThread: bool = false,
    threadLoopNewFull: bool = false,
    threadLoopAddListener: bool = false,
    threadLoopGetLoop: bool = false,

    streamDequeueBuffer: bool = false,
    streamQueueBuffer: bool = false,
    streamFlush: bool = false,
    streamNewSimple: bool = false,
    streamAddListener: bool = false,
    streamGetState: bool = false,
    streamGetName: bool = false,
    streamGetRemote: bool = false,
    streamGetProperties: bool = false,
    streamUpdateProperties: bool = false,
    streamSetControl: bool = false,
    streamGetControl: bool = false,
    streamStateAsString: bool = false,
    streamNew: bool = false,
    streamDestroy: bool = false,
    streamConnect: bool = false,
    streamGetNodeID: bool = false,
    streamDisconnect: bool = false,
    streamFinishFormat: bool = false,
    streamGetTime: bool = false,
    streamSetActive: bool = false,
};

pub fn Symbols(comptime s: SymbolList) type {
    return struct {
        init: if (s.init) *const @TypeOf(init) else void,
        deinit: if (s.deinit) *const @TypeOf(deinit) else void,

        propertiesNew: if (s.propertiesNew) *const @TypeOf(propertiesNew) else void,
        propertiesNewDict: if (s.propertiesNewDict) *const @TypeOf(propertiesNewDict) else void,
        propertiesNewString: if (s.propertiesNewString) *const @TypeOf(propertiesNewString) else void,
        propertiesCopy: if (s.propertiesCopy) *const @TypeOf(propertiesCopy) else void,
        propertiesClear: if (s.propertiesClear) *const @TypeOf(propertiesClear) else void,
        propertiesUpdate: if (s.propertiesUpdate) *const @TypeOf(propertiesUpdate) else void,
        propertiesFree: if (s.propertiesFree) *const @TypeOf(propertiesFree) else void,
        propertiesSet: if (s.propertiesSet) *const @TypeOf(propertiesSet) else void,
        propertiesSetF: if (s.propertiesSetF) *const @TypeOf(propertiesSetF) else void,
        propertiesGet: if (s.propertiesGet) *const @TypeOf(propertiesGet) else void,
        propertiesIterate: if (s.propertiesIterate) *const @TypeOf(propertiesIterate) else void,

        threadLoopNew: if (s.threadLoopNew) *const @TypeOf(threadLoopNew) else void,
        threadLoopDestroy: if (s.threadLoopDestroy) *const @TypeOf(threadLoopDestroy) else void,
        threadLoopStart: if (s.threadLoopStart) *const @TypeOf(threadLoopStart) else void,
        threadLoopStop: if (s.threadLoopStop) *const @TypeOf(threadLoopStop) else void,
        threadLoopLock: if (s.threadLoopLock) *const @TypeOf(threadLoopLock) else void,
        threadLoopUnlock: if (s.threadLoopUnlock) *const @TypeOf(threadLoopUnlock) else void,
        threadLoopSignal: if (s.threadLoopSignal) *const @TypeOf(threadLoopSignal) else void,
        threadLoopWait: if (s.threadLoopWait) *const @TypeOf(threadLoopWait) else void,
        threadLoopTimedWait: if (s.threadLoopTimedWait) *const @TypeOf(threadLoopTimedWait) else void,
        threadLoopAccept: if (s.threadLoopAccept) *const @TypeOf(threadLoopAccept) else void,
        threadLoopInThread: if (s.threadLoopInThread) *const @TypeOf(threadLoopInThread) else void,
        threadLoopAddListener: if (s.threadLoopAddListener) *const @TypeOf(threadLoopAddListener) else void,
        threadLoopGetLoop: if (s.threadLoopGetLoop) *const @TypeOf(threadLoopGetLoop) else void,

        streamDequeueBuffer: if (s.streamDequeueBuffer) *const @TypeOf(streamDequeueBuffer) else void,
        streamQueueBuffer: if (s.streamQueueBuffer) *const @TypeOf(streamQueueBuffer) else void,
        streamFlush: if (s.streamFlush) *const @TypeOf(streamFlush) else void,
        streamNewSimple: if (s.streamNewSimple) *const @TypeOf(streamNewSimple) else void,
        streamAddListener: if (s.streamAddListener) *const @TypeOf(streamAddListener) else void,
        streamGetState: if (s.streamGetState) *const @TypeOf(streamGetState) else void,
        streamGetName: if (s.streamGetName) *const @TypeOf(streamGetName) else void,
        streamGetRemote: if (s.streamGetRemote) *const @TypeOf(streamGetRemote) else void,
        streamGetProperties: if (s.streamGetProperties) *const @TypeOf(streamGetProperties) else void,
        streamUpdateProperties: if (s.streamUpdateProperties) *const @TypeOf(streamUpdateProperties) else void,
        streamSetControl: if (s.streamSetControl) *const @TypeOf(streamSetControl) else void,
        streamGetControl: if (s.streamGetControl) *const @TypeOf(streamGetControl) else void,

        streamStateAsString: if (s.streamStateAsString) *const @TypeOf(streamStateAsString) else void,
        streamNew: if (s.streamNew) *const @TypeOf(streamNew) else void,
        streamDestroy: if (s.streamDestroy) *const @TypeOf(streamDestroy) else void,
        streamConnect: if (s.streamConnect) *const @TypeOf(streamConnect) else void,
        streamGetNodeID: if (s.streamGetNodeID) *const @TypeOf(streamGetNodeID) else void,
        streamDisconnect: if (s.streamDisconnect) *const @TypeOf(streamDisconnect) else void,
        streamFinishFormat: if (s.streamFinishFormat) *const @TypeOf(streamFinishFormat) else void,
        streamGetTime: if (s.streamGetTime) *const @TypeOf(streamGetTime) else void,
        streamSetActive: if (s.streamSetActive) *const @TypeOf(streamSetActive) else void,

        pub fn load(self: *@This(), handle: *DynLib) error{SymbolLookupFail}!void {
            if (comptime s.init)
                self.init = handle.lookup(@TypeOf(self.init), "pw_init") orelse {
                    std.log.err("Failed to load pw_init", .{});
                    return error.SymbolLookupFail;
                };

            if (comptime s.deinit)
                self.deinit = handle.lookup(@TypeOf(self.deinit), "pw_deinit") orelse {
                    std.log.err("Failed to load pw_deinit", .{});
                    return error.SymbolLookupFail;
                };

            if (comptime s.propertiesNew)
                self.propertiesNew = handle.lookup(@TypeOf(self.propertiesNew), "pw_properties_new") orelse
                    return error.SymbolLookupFail;
            if (comptime s.propertiesNewDict)
                self.propertiesNewDict = handle.lookup(@TypeOf(self.propertiesNewDict), "pw_properties_new_dict") orelse
                    return error.SymbolLookupFail;
            if (comptime s.propertiesNewString)
                self.propertiesNewString = handle.lookup(@TypeOf(self.propertiesNewString), "pw_properties_new_string") orelse
                    return error.SymbolLookupFail;
            if (comptime s.propertiesCopy)
                self.propertiesCopy = handle.lookup(@TypeOf(self.propertiesCopy), "pw_properties_copy") orelse
                    return error.SymbolLookupFail;
            if (comptime s.propertiesClear)
                self.propertiesClear = handle.lookup(@TypeOf(self.propertiesClear), "pw_properties_clear") orelse
                    return error.SymbolLookupFail;
            if (comptime s.propertiesUpdate)
                self.propertiesUpdate = handle.lookup(@TypeOf(self.propertiesUpdate), "pw_properties_update") orelse
                    return error.SymbolLookupFail;
            if (comptime s.propertiesFree)
                self.propertiesFree = handle.lookup(@TypeOf(self.propertiesFree), "pw_properties_free") orelse
                    return error.SymbolLookupFail;
            if (comptime s.propertiesSet)
                self.propertiesSet = handle.lookup(@TypeOf(self.propertiesSet), "pw_properties_set") orelse
                    return error.SymbolLookupFail;
            if (comptime s.propertiesSetF)
                self.propertiesSetF = handle.lookup(@TypeOf(self.propertiesSetF), "pw_properties_setf") orelse
                    return error.SymbolLookupFail;
            if (comptime s.propertiesGet)
                self.propertiesGet = handle.lookup(@TypeOf(self.propertiesGet), "pw_properties_get") orelse
                    return error.SymbolLookupFail;
            if (comptime s.propertiesIterate)
                self.propertiesIterate = handle.lookup(@TypeOf(self.propertiesIterate), "pw_properties_iterate") orelse
                    return error.SymbolLookupFail;

            if (comptime s.threadLoopNew)
                self.threadLoopNew = handle.lookup(@TypeOf(self.threadLoopNew), "pw_thread_loop_new") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threadLoopDestroy)
                self.threadLoopDestroy = handle.lookup(@TypeOf(self.threadLoopDestroy), "pw_thread_loop_destroy") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threadLoopStart)
                self.threadLoopStart = handle.lookup(@TypeOf(self.threadLoopStart), "pw_thread_loop_start") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threadLoopStop)
                self.threadLoopStop = handle.lookup(@TypeOf(self.threadLoopStop), "pw_thread_loop_stop") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threadLoopLock)
                self.threadLoopLock = handle.lookup(@TypeOf(self.threadLoopLock), "pw_thread_loop_lock") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threadLoopUnlock)
                self.threadLoopUnlock = handle.lookup(@TypeOf(self.threadLoopUnlock), "pw_thread_loop_unlock") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threadLoopSignal)
                self.threadLoopSignal = handle.lookup(@TypeOf(self.threadLoopSignal), "pw_thread_loop_signal") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threadLoopWait)
                self.threadLoopWait = handle.lookup(@TypeOf(self.threadLoopWait), "pw_thread_loop_wait") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threadLoopTimedWait)
                self.threadLoopTimedWait = handle.lookup(@TypeOf(self.threadLoopTimedWait), "pw_thread_loop_timed_wait") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threadLoopAccept)
                self.threadLoopAccept = handle.lookup(@TypeOf(self.threadLoopAccept), "pw_thread_loop_accept") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threadLoopInThread)
                self.threadLoopInThread = handle.lookup(@TypeOf(self.threadLoopInThread), "pw_thread_loop_in_thread") orelse
                    return error.SymbolLookupFail;
            // TODO: threadLoopNewFull
            if (comptime s.threadLoopAddListener)
                self.threadLoopAddListener = handle.lookup(@TypeOf(self.threadLoopAddListener), "pw_thread_loop_add_listener") orelse
                    return error.SymbolLookupFail;
            if (comptime s.threadLoopGetLoop)
                self.threadLoopGetLoop = handle.lookup(@TypeOf(self.threadLoopGetLoop), "pw_thread_loop_get_loop") orelse
                    return error.SymbolLookupFail;

            if (comptime s.streamDequeueBuffer)
                self.streamDequeueBuffer = handle.lookup(@TypeOf(self.streamDequeueBuffer), "pw_stream_dequeue_buffer") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamQueueBuffer)
                self.streamQueueBuffer = handle.lookup(@TypeOf(self.streamQueueBuffer), "pw_stream_queue_buffer") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamFlush)
                self.streamFlush = handle.lookup(@TypeOf(self.streamFlush), "pw_stream_flush") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamNewSimple)
                self.streamNewSimple = handle.lookup(@TypeOf(self.streamNewSimple), "pw_stream_new_simple") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamAddListener)
                self.streamAddListener = handle.lookup(@TypeOf(self.streamAddListener), "pw_stream_add_listener") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamGetState)
                self.streamGetState = handle.lookup(@TypeOf(self.streamGetState), "pw_stream_get_state") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamGetName)
                self.streamGetName = handle.lookup(@TypeOf(self.streamGetName), "pw_stream_get_name") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamGetRemote)
                self.streamGetRemote = handle.lookup(@TypeOf(self.streamGetRemote), "pw_stream_get_remote") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamGetProperties)
                self.streamGetProperties = handle.lookup(@TypeOf(self.streamGetProperties), "pw_stream_get_properties") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamUpdateProperties)
                self.streamUpdateProperties = handle.lookup(@TypeOf(self.streamUpdateProperties), "pw_stream_update_properties") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamSetControl)
                self.streamSetControl = handle.lookup(@TypeOf(self.streamSetControl), "pw_stream_set_control") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamGetControl)
                self.streamGetControl = handle.lookup(@TypeOf(self.streamGetControl), "pw_stream_get_control") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamStateAsString)
                self.streamStateAsString = handle.lookup(@TypeOf(self.streamStateAsString), "pw_stream_state_as_string") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamNew)
                self.streamNew = handle.lookup(@TypeOf(self.streamNew), "pw_stream_new") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamDestroy)
                self.streamDestroy = handle.lookup(@TypeOf(self.streamDestroy), "pw_stream_destroy") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamConnect)
                self.streamConnect = handle.lookup(@TypeOf(self.streamConnect), "pw_stream_connect") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamGetNodeID)
                self.streamGetNodeID = handle.lookup(@TypeOf(self.streamGetNodeID), "pw_stream_get_node_id") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamDisconnect)
                self.streamDisconnect = handle.lookup(@TypeOf(self.streamDisconnect), "pw_stream_disconnect") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamFinishFormat)
                self.streamFinishFormat = handle.lookup(@TypeOf(self.streamFinishFormat), "pw_stream_finish_format") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamGetTime)
                self.streamGetTime = handle.lookup(@TypeOf(self.streamGetTime), "pw_stream_get_time") orelse
                    return error.SymbolLookupFail;
            if (comptime s.streamSetActive)
                self.streamSetActive = handle.lookup(@TypeOf(self.streamSetActive), "pw_stream_set_active") orelse
                    return error.SymbolLookupFail;
        }
    };
}
