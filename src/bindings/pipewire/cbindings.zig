// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const spa = @import("../spa/spa.zig");

pub const version_stream_events = 2;
pub const id_any: u32 = 0xffffffff;

pub const keys = struct {
    pub const media_type = "media.type";
    pub const media_category = "media.category";
    pub const media_role = "media.role";
    pub const media_class = "media.class";
    pub const media_name = "media.name";
    pub const media_title = "media.title";
    pub const media_artist = "media.artist";
    pub const media_copyright = "media.copyright";
    pub const media_software = "media.software";
    pub const media_language = "media.language";
    pub const media_filename = "media.filename";
    pub const media_icon = "media.icon";
    pub const media_icon_name = "media.icon-name";
};

pub const pw_stream = opaque {};
pub const pw_thread_loop = opaque {};
pub const pw_loop = opaque {};
pub const pw_properties = opaque {};
pub const pw_remote = opaque {};
pub const pw_stream_control = opaque {};
pub const pw_time = opaque {};

pub const pw_stream_events = extern struct {
    version: u32 = version_stream_events,
    destroy: ?*const fn (data: ?*anyopaque) callconv(.C) void = null,
    state_changed: ?*const fn (data: ?*anyopaque, old_state: pw_stream_state, new_state: pw_stream_state, error_string: ?[*:0]const u8) callconv(.C) void = null,
    control_info: ?*const fn (data: ?*anyopaque, id: u32, control: *const pw_stream_control) callconv(.C) void = null,
    io_changed: ?*const fn (data: ?*anyopaque, id: u32, area: *anyopaque, size: u32) callconv(.C) void = null,
    param_changed: ?*const fn (data: ?*anyopaque, id: u32, param: *const spa.Pod) callconv(.C) void = null,
    add_buffer: ?*const fn (data: ?*anyopaque, buffer: *pw_buffer) callconv(.C) void = null,
    remove_buffer: ?*const fn (data: ?*anyopaque, buffer: *pw_buffer) callconv(.C) void = null,
    process: ?*const fn (data: ?*anyopaque) callconv(.C) void = null,
    drained: ?*const fn (data: ?*anyopaque) callconv(.C) void = null,
    command: ?*const fn (data: ?*anyopaque, command: *const spa.Command) callconv(.C) void = null,
    trigger_done: ?*const fn (data: ?*anyopaque) callconv(.C) void = null,
};

pub const pw_buffer = extern struct {
    buffer: *spa.Buffer,
    user_data: ?*anyopaque,
    size: u64,
    requested: u64,
};

pub const pw_thread_loop_events = extern struct {
    version: u32,
    destroy: *const fn (data: ?*anyopaque) void,
};

pub const pw_stream_state = enum(i32) {
    @"error" = -1,
    unconnected,
    connecting,
    paused,
    streaming,
};

pub const pw_stream_flags = packed struct(i32) {
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

pub const pw_direction = enum(i32) {
    input,
    output,
};

//
// Core bindings
//

pub extern fn pw_init(argc: *i32, argv: *[*][*:0]const u8) callconv(.C) void;
pub extern fn pw_deinit() callconv(.C) void;

//
// Properties bindings
//

pub extern fn pw_properties_new(key: [*:0]const u8, ...) callconv(.C) *pw_properties;
pub extern fn pw_properties_new_dict(dict: *spa.Dict) callconv(.C) *pw_properties;
pub extern fn pw_properties_new_string(string: [*:0]const u8) callconv(.C) *pw_properties;
pub extern fn pw_properties_copy(properties: *const pw_properties) callconv(.C) *pw_properties;
pub extern fn pw_properties_clear(properties: *pw_properties) callconv(.C) void;
pub extern fn pw_properties_update(properties: *pw_properties, dict: *spa.Dict) callconv(.C) i32;
pub extern fn pw_properties_free(properties: *pw_properties) callconv(.C) void;
pub extern fn pw_properties_set(properties: *pw_properties, key: [*:0]const u8, value: [*:0]const u8) callconv(.C) i32;
pub extern fn pw_properties_setf(properties: *pw_properties, key: [*:0]const u8, format: [*:0]const u8, ...) callconv(.C) i32;
pub extern fn pw_properties_get(properties: *pw_properties, key: [*:0]const u8) callconv(.C) [*:0]const u8;
pub extern fn pw_properties_iterate(properties: *pw_properties, state_data: *?*anyopaque) callconv(.C) [*:0]const u8;

//
// ThreadLoop bindings
//

pub extern fn pw_thread_loop_new(name: [*:0]const u8, properties: ?*const spa.Dict) callconv(.C) *pw_thread_loop;
pub extern fn pw_thread_loop_destroy(loop: *pw_thread_loop) callconv(.C) void;
pub extern fn pw_thread_loop_start(loop: *pw_thread_loop) callconv(.C) i32;
pub extern fn pw_thread_loop_stop(loop: *pw_thread_loop) callconv(.C) void;
pub extern fn pw_thread_loop_lock(loop: *pw_thread_loop) callconv(.C) void;
pub extern fn pw_thread_loop_unlock(loop: *pw_thread_loop) callconv(.C) void;
pub extern fn pw_thread_loop_signal(loop: *pw_thread_loop, wait_for_accept: bool) callconv(.C) void;
pub extern fn pw_thread_loop_wait(loop: *pw_thread_loop) callconv(.C) void;
pub extern fn pw_thread_loop_timed_wait(loop: *pw_thread_loop, wait_max_seconds: i32) callconv(.C) i32;
pub extern fn pw_thread_loop_accept(loop: *pw_thread_loop) callconv(.C) void;
pub extern fn pw_thread_loop_in_thread(loop: *pw_thread_loop) callconv(.C) bool;

pub extern fn pw_thread_loop_new_full(loop: *pw_loop, name: [*:0]const u8, properties: ?*const spa.Dict) callconv(.C) *pw_thread_loop;
pub extern fn pw_thread_loop_add_listener(loop: *pw_thread_loop, listener: *spa.Hook, events: *const pw_thread_loop_events, data: ?*anyopaque) callconv(.C) void;
pub extern fn pw_thread_loop_get_loop(loop: *pw_thread_loop) callconv(.C) *pw_loop;

//
// Stream bindings
//

pub extern fn pw_stream_dequeue_buffer(stream: *pw_stream) callconv(.C) *pw_buffer;
pub extern fn pw_stream_queue_buffer(stream: *pw_stream, buffer: *pw_buffer) callconv(.C) i32;
pub extern fn pw_stream_flush(stream: *pw_stream, drain: bool) callconv(.C) i32;
pub extern fn pw_stream_new_simple(
    loop: *pw_loop,
    name: [*:0]const u8,
    properties: *pw_properties,
    stream_events: *const pw_stream_events,
    data: ?*anyopaque,
) callconv(.C) ?*pw_stream;
pub extern fn pw_stream_add_listener(stream: *pw_stream, listener: *spa.Hook, stream_events: *pw_stream_events, data: ?*anyopaque) callconv(.C) void;
pub extern fn pw_stream_get_state(stream: *pw_stream, error_string: *[*:0]const u8) callconv(.C) pw_stream_state;
pub extern fn pw_stream_get_name(stream: *pw_stream) callconv(.C) [*:0]const u8;
pub extern fn pw_stream_get_remote(stream: *pw_stream) callconv(.C) *pw_remote;
pub extern fn pw_stream_get_properties(stream: *pw_stream) callconv(.C) *pw_properties;
pub extern fn pw_stream_update_properties(stream: *pw_stream, dict: *const spa.Dict) callconv(.C) i32;
pub extern fn pw_stream_set_control(stream: *pw_stream, id: u32, value: f32, ...) callconv(.C) i32;
pub extern fn pw_stream_get_control(stream: *pw_stream, id: u32) callconv(.C) *pw_stream_control;

pub extern fn pw_stream_state_as_string(pw_stream_state: pw_stream_state) callconv(.C) [*:0]const u8;
pub extern fn pw_stream_new(remote: *pw_remote, name: [*:0]const u8, properties: *pw_properties) callconv(.C) *pw_stream;
pub extern fn pw_stream_destroy(stream: *pw_stream) callconv(.C) void;
pub extern fn pw_stream_connect(
    stream: *pw_stream,
    direction: pw_direction,
    target_id: u32,
    flags: pw_stream_flags,
    params: *[*]spa.Pod,
    params_count: u32,
) callconv(.C) i32;
pub extern fn pw_stream_get_node_id(stream: *pw_stream) callconv(.C) u32;
pub extern fn pw_stream_disconnect(stream: *pw_stream) callconv(.C) i32;
pub extern fn pw_stream_finish_format(stream: *pw_stream, res: i32, params: *const [*]spa.Pod, params_count: u32) callconv(.C) void;
pub extern fn pw_stream_get_time(stream: *pw_stream, time: *pw_loop) callconv(.C) i32;
pub extern fn pw_stream_set_active(stream: *pw_stream, active: bool) callconv(.C) i32;
