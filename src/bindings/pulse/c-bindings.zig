// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const timeval = @import("std").os.timeval;

pub const pa_mainloop_api = opaque {};
pub const pa_threaded_mainloop = opaque {};
pub const pa_context = opaque {};
pub const pa_stream = opaque {};
pub const pa_proplist = opaque {};
pub const pa_operation = opaque {};
pub const pa_time_event = opaque {};

//
// channelmap.h
//

pub const pa_channel_position_t = enum(i32) {
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

pub const pa_channel_map = extern struct {
    channels: u8,
    map: [PA_CHANNELS_MAX]pa_channel_position_t,
};

//
// context.h
//

pub const pa_context_notify_cb_t = *const fn (context: *pa_context, userdata: ?*anyopaque) callconv(.C) void;
pub const pa_context_success_cb_t = *const fn (context: *pa_context, success: i32, userdata: ?*anyopaque) callconv(.C) void;
pub const pa_context_event_cb_t = *const fn (
    context: *pa_context,
    name: [*:0]const u8,
    proplist: *pa_proplist,
    userdata: ?*anyopaque,
) callconv(.C) void;

pub extern fn pa_context_new(mainloop: *pa_mainloop_api, name: [*:0]const u8) callconv(.C) ?*pa_context;

pub extern fn pa_context_new_with_proplist(
    mainloop: *pa_mainloop_api,
    name: [*:0]const u8,
    proplist: *const pa_proplist,
) callconv(.C) ?*pa_context;

pub extern fn pa_context_unref(context: *pa_context) callconv(.C) void;
pub extern fn pa_context_ref(context: *pa_context) callconv(.C) *pa_context;

pub extern fn pa_context_set_state_callback(
    context: *pa_context,
    state_callback: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) void;

pub extern fn pa_context_set_event_callback(
    context: *pa_context,
    event_callback: *const pa_context_event_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) void;

pub extern fn pa_context_errno(context: *const pa_context) callconv(.C) i32;
pub extern fn pa_context_is_pending(context: *const pa_context) callconv(.C) i32;
pub extern fn pa_context_get_state(context: *const pa_context) callconv(.C) pa_context_state_t;

pub extern fn pa_context_connect(
    context: *pa_context,
    server: ?[*:0]const u8,
    flags: pa_context_flags_t,
    api: ?*const pa_spawn_api,
) i32;

pub extern fn pa_context_disconnect(context: *pa_context) callconv(.C) void;
pub extern fn pa_context_drain(context: *pa_context, cb: pa_context_notify_cb_t, userdata: ?*anyopaque) callconv(.C) *pa_operation;

pub extern fn pa_context_exit_daemon(
    context: *pa_context,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub extern fn pa_context_set_default_sink(
    context: *pa_context,
    name: [*:0]const u8,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub extern fn pa_context_set_default_source(
    context: *pa_context,
    name: [*:0]const u8,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub extern fn pa_context_is_local(context: *const pa_context) callconv(.C) i32;

pub extern fn pa_context_set_name(
    context: *pa_context,
    name: [*:0]const u8,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub extern fn pa_context_get_server(context: *const pa_context) callconv(.C) [*:0]const u8;
pub extern fn pa_context_get_protocol_version(context: *const pa_context) callconv(.C) u32;
pub extern fn pa_context_get_server_protocol_version(context: *const pa_context) callconv(.C) u32;

pub extern fn pa_context_proplist_update(
    context: *pa_context,
    mode: pa_update_mode_t,
    proplist: *const pa_proplist,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub extern fn pa_context_proplist_remove(
    context: *pa_context,
    keys: [*]const [*:0]const u8,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub extern fn pa_context_get_index(context: *const pa_context) callconv(.C) u32;
pub extern fn pa_context_rttime_new(context: *const pa_context, usec: pa_usec_t, cb: pa_time_event_cb_t, userdata: ?*anyopaque) callconv(.C) *pa_time_event;
pub extern fn pa_context_rttime_restart(context: *const pa_context, event: *pa_time_event, usec: pa_usec_t) callconv(.C) void;
pub extern fn pa_context_get_tile_size(context: *const pa_context, sample_spec: *const pa_sample_spec) callconv(.C) usize;
pub extern fn pa_context_load_cookie_from_file(context: *pa_context, cookie_file_path: [*:0]const u8) callconv(.C) i32;

//
// def.h
//

pub const pa_buffer_attr = extern struct {
    max_length: u32,
    tlength: u32,
    prebuf: u32,
    minreq: u32,
    fragsize: u32,
};

// TODO: pa_timing_info

pub const pa_spawn_api = extern struct {
    prefork: *const fn () callconv(.C) void,
    postfork: *const fn () callconv(.C) void,
    atfork: *const fn () callconv(.C) void,
};

pub const pa_context_state_t = enum(i32) {
    unconnected,
    connecting,
    authorizing,
    setting_name,
    ready,
    failed,
    terminated,
};

pub const pa_stream_state_t = enum(i32) {
    unconnected,
    creating,
    ready,
    failed,
    terminated,
};

pub const pa_operation_state_t = enum(i32) {
    running,
    done,
    cancelled,
};

pub const pa_context_flags_t = packed struct(i32) {
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

pub const pa_direction_t = enum(i32) {
    output = 1,
    input = 2,
};

pub const pa_device_type_t = enum(i32) {
    sink,
    source,
};

pub const pa_stream_direction_t = enum(i32) {
    no_direction,
    playback,
    record,
    upload,
};

pub const pa_stream_flags_t = packed struct(i32) {
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

pub const pa_error_code_t = enum(i32) {
    ok,
    access,
    command,
    invalid,
    exist,
    noentity,
    connectionrefused,
    protocol,
    timeout,
    authkey,
    internal,
    connectionterminated,
    killed,
    invalidserver,
    modinitfailed,
    badstate,
    nodata,
    version,
    toolarge,
    notsupported,
    unknown,
    noextension,
    obsolete,
    notimplemented,
    forked,
    io,
    busy,
};

// TODO: pa_subscription_mask
// TODO: pa_subscription_event_type

pub const pa_seek_mode_t = enum(i32) {
    relative,
    absolute,
    relative_on_read,
    relative_end,
};

pub const pa_sink_flags_t = packed struct(u32) {
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

pub const pa_sink_state_t = enum(i32) {
    invalid_state = -1,
    running = 0,
    idle = 1,
    suspended = 2,
};

pub const pa_source_flags_t = packed struct(u32) {
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

pub const pa_source_state_t = enum(i32) {
    invalid_state = -1,
    running = 0,
    idle = 1,
    suspended = 2,
};

pub const pa_port_available_t = enum(i32) {
    unknown,
    no,
    yes,
};

pub const pa_device_port_type_t = enum(u32) {
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

//
// error.h
//

pub extern fn pa_strerror(err: i32) callconv(.C) [*:0]const u8;

//
// format.h
//

pub const pa_encoding_t = enum(i32) {
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

pub const pa_format_info = extern struct {
    encoding: pa_encoding_t,
    plist: *pa_proplist,
};

//
// introspect.h
//

pub const pa_sink_port_info = extern struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
    priority: u32,
    available: i32,
    availability_group: ?[*:0]const u8,
    type: pa_device_port_type_t,
};

pub const pa_sink_info = extern struct {
    name: [*:0]const u8,
    index: u32,
    description: [*:0]const u8,
    sample_spec: pa_sample_spec,
    channel_map: pa_channel_map,
    owner_module: u32,
    volume: pa_cvolume,
    mute: i32,
    monitor_source: u32,
    monitor_source_name: ?[*:0]const u8,
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

pub const pa_source_port_info = extern struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
    priority: u32,
    available: i32,
    availability_group: ?[*:0]const u8,
    type: pa_device_port_type_t,
};

pub const pa_source_info = extern struct {
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

pub const pa_server_info = extern struct {
    user_name: [*:0]const u8,
    host_name: [*:0]const u8,
    server_version: [*:0]const u8,
    server_name: [*:0]const u8,
    sample_spec: pa_sample_spec,
    default_sink_name: [*:0]const u8,
    default_source_name: [*:0]const u8,
    cookie: u32,
    channel_map: pa_channel_map,
};

pub const pa_module_info = extern struct {
    index: u32,
    name: [*:0]const u8,
    argument: [*:0]const u8,
    n_used: u32,
    proplist: *pa_proplist,
};

pub const pa_client_info = extern struct {
    index: u32,
    name: [*:0]const u8,
    owner_module: u32,
    driver: [*:0]const u8,
    proplist: *pa_proplist,
};

pub const pa_card_profile_info = extern struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
    n_sinks: u32,
    n_sources: u32,
    priority: u32,
};

pub const pa_card_profile_info2 = extern struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
    n_sinks: u32,
    n_sources: u32,
    priority: u32,
    available: i32,
};

pub const pa_card_port_info = extern struct {
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
    type: pa_device_port_type_t,
};

pub const pa_card_info = extern struct {
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

pub const pa_sink_input_info = extern struct {
    index: u32,
    name: [*:0]const u8,
    owner_module: u32,
    client: u32,
    sink: u32,
    sample_spec: pa_sample_spec,
    channel_map: pa_channel_map,
    volume: pa_cvolume,
    buffer_usec: pa_usec_t,
    sink_usec: pa_usec_t,
    resample_method: [*:0]const u8,
    driver: [*:0]const u8,
    mute: i32,
    proplist: *pa_proplist,
    corked: i32,
    has_volume: i32,
    volume_writable: i32,
    format: *pa_format_info,
};

// TODO: pa_source_output_info
// TODO: pa_stat_info
// TODO: pa_sample_info

pub const pa_sink_info_cb_t = *const fn (context: *pa_context, info: *const pa_sink_info, eol: i32, userdata: ?*anyopaque) callconv(.C) void;

pub const pa_context_get_sink_info_by_name = fn (
    context: *pa_context,
    name: [*:0]const u8,
    cb: pa_sink_info_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub const pa_context_get_sink_info_by_index = fn (
    context: *pa_context,
    idx: u32,
    cb: pa_sink_info_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub const pa_context_get_sink_info_list = fn (
    context: *pa_context,
    cb: pa_sink_info_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub const pa_context_set_sink_volume_by_index = fn (
    context: *pa_context,
    idx: u32,
    volume: *const pa_cvolume,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub const pa_context_set_sink_volume_by_name = fn (
    context: *pa_context,
    name: [*:0]const u8,
    volume: *const pa_cvolume,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub const pa_context_set_sink_mute_by_index = fn (
    context: *pa_context,
    idx: u32,
    mute: i32,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub const pa_context_set_sink_mute_by_name = fn (
    context: *pa_context,
    name: [*:0]const u8,
    mute: i32,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub const pa_context_suspend_sink_by_name = fn (
    context: *pa_context,
    sink_name: [*:0]const u8,
    @"suspend": i32,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub const pa_context_suspend_sink_by_index = fn (
    context: *pa_context,
    idx: u32,
    @"suspend": i32,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub const pa_context_set_sink_port_by_index = fn (
    context: *pa_context,
    idx: u32,
    port: [*:0]const u8,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub const pa_context_set_sink_port_by_name = fn (
    context: *pa_context,
    name: [*:0]const u8,
    port: [*:0]const u8,
    cb: pa_context_success_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

//
//
//

pub const pa_source_info_cb_t = *const fn (
    context: *pa_context,
    info: *const pa_source_info,
    eol: i32,
    userdata: ?*anyopaque,
) callconv(.C) void;

// pa_operation * 	pa_context_get_source_info_by_name (pa_context *c, const char *name, pa_source_info_cb_t cb, void *userdata)

pub extern fn pa_context_get_source_info_by_index(
    context: *pa_context,
    index: u32,
    callback: *const pa_source_info_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

pub extern fn pa_context_get_source_info_list(
    context: *pa_context,
    callback: pa_source_info_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

// TODO:
// pa_operation * pa_context_set_source_volume_by_index (pa_context *c, uint32_t idx, const pa_cvolume *volume, pa_context_success_cb_t cb, void *userdata)
// pa_operation * pa_context_set_source_volume_by_name (pa_context *c, const char *name, const pa_cvolume *volume, pa_context_success_cb_t cb, void *userdata)
// pa_operation * pa_context_set_source_mute_by_index (pa_context *c, uint32_t idx, int mute, pa_context_success_cb_t cb, void *userdata)
// pa_operation * pa_context_set_source_mute_by_name (pa_context *c, const char *name, int mute, pa_context_success_cb_t cb, void *userdata)
// pa_operation * pa_context_suspend_source_by_name (pa_context *c, const char *source_name, int suspend, pa_context_success_cb_t cb, void *userdata)
// pa_operation * pa_context_suspend_source_by_index (pa_context *c, uint32_t idx, int suspend, pa_context_success_cb_t cb, void *userdata)
// pa_operation * pa_context_set_source_port_by_index (pa_context *c, uint32_t idx, const char *port, pa_context_success_cb_t cb, void *userdata)
// pa_operation * pa_context_set_source_port_by_name (pa_context *c, const char *name, const char *port, pa_context_success_cb_t cb, void *userdata)

pub const pa_server_info_cb_t = *const fn (context: pa_context, info: *const pa_server_info, userdata: ?*anyopaque) callconv(.C) void;
pub extern fn pa_context_get_server_info(context: *pa_context, cb: pa_server_info_cb_t, userdata: ?*anyopaque) callconv(.C) *pa_operation;

// typedef void(* 	pa_module_info_cb_t) (pa_context *c, const pa_module_info *i, int eol, void *userdata)
// typedef void(* 	pa_context_index_cb_t) (pa_context *c, uint32_t idx, void *userdata)
// pa_operation * 	pa_context_get_module_info (pa_context *c, uint32_t idx, pa_module_info_cb_t cb, void *userdata)
// pa_operation * 	pa_context_get_module_info_list (pa_context *c, pa_module_info_cb_t cb, void *userdata)
// pa_operation * 	pa_context_load_module (pa_context *c, const char *name, const char *argument, pa_context_index_cb_t cb, void *userdata)
// pa_operation * 	pa_context_unload_module (pa_context *c, uint32_t idx, pa_context_success_cb_t cb, void *userdata)

// typedef void(* 	pa_context_string_cb_t) (pa_context *c, int success, char *response, void *userdata)
// pa_operation * 	pa_context_send_message_to_object (pa_context *c, const char *recipient_name, const char *message, const char *message_parameters, pa_context_string_cb_t cb, void *userdata)

// typedef void(* 	pa_client_info_cb_t) (pa_context *c, const pa_client_info *i, int eol, void *userdata)
// pa_operation * 	pa_context_get_client_info (pa_context *c, uint32_t idx, pa_client_info_cb_t cb, void *userdata)
// pa_operation * 	pa_context_get_client_info_list (pa_context *c, pa_client_info_cb_t cb, void *userdata)
// pa_operation * 	pa_context_kill_client (pa_context *c, uint32_t idx, pa_context_success_cb_t cb, void *userdata)

pub const pa_card_info_cb_t = *const fn (context: *pa_context, info: *const pa_card_info, eol: i32, userdata: ?*anyopaque) callconv(.C) void;

// typedef void(* 	pa_card_info_cb_t) (pa_context *c, const pa_card_info *i, int eol, void *userdata)
// pa_operation * 	pa_context_get_card_info_by_index (pa_context *c, uint32_t idx, pa_card_info_cb_t cb, void *userdata)
// pa_operation * 	pa_context_get_card_info_by_name (pa_context *c, const char *name, pa_card_info_cb_t cb, void *userdata)
// pa_operation * 	pa_context_get_card_info_list (pa_context *c, pa_card_info_cb_t cb, void *userdata)

pub extern fn pa_context_get_card_info_list(
    context: *pa_context,
    callback: pa_card_info_cb_t,
    userdata: ?*anyopaque,
) callconv(.C) *pa_operation;

// pa_operation * 	pa_context_set_card_profile_by_index (pa_context *c, uint32_t idx, const char *profile, pa_context_success_cb_t cb, void *userdata)
// pa_operation * 	pa_context_set_card_profile_by_name (pa_context *c, const char *name, const char *profile, pa_context_success_cb_t cb, void *userdata)
// pa_operation * 	pa_context_set_port_latency_offset (pa_context *c, const char *card_name, const char *port_name, int64_t offset, pa_context_success_cb_t cb, void *userdata)

// typedef void(* 	pa_sink_input_info_cb_t) (pa_context *c, const pa_sink_input_info *i, int eol, void *userdata)
// pa_operation * 	pa_context_get_sink_input_info (pa_context *c, uint32_t idx, pa_sink_input_info_cb_t cb, void *userdata)
// pa_operation * 	pa_context_get_sink_input_info_list (pa_context *c, pa_sink_input_info_cb_t cb, void *userdata)
// pa_operation * 	pa_context_move_sink_input_by_name (pa_context *c, uint32_t idx, const char *sink_name, pa_context_success_cb_t cb, void *userdata)
// pa_operation * 	pa_context_move_sink_input_by_index (pa_context *c, uint32_t idx, uint32_t sink_idx, pa_context_success_cb_t cb, void *userdata)
// pa_operation * 	pa_context_set_sink_input_volume (pa_context *c, uint32_t idx, const pa_cvolume *volume, pa_context_success_cb_t cb, void *userdata)
// pa_operation * 	pa_context_set_sink_input_mute (pa_context *c, uint32_t idx, int mute, pa_context_success_cb_t cb, void *userdata)
// pa_operation * 	pa_context_kill_sink_input (pa_context *c, uint32_t idx, pa_context_success_cb_t cb, void *userdata)

// typedef void(* 	pa_source_output_info_cb_t) (pa_context *c, const pa_source_output_info *i, int eol, void *userdata)
// pa_operation * 	pa_context_get_source_output_info (pa_context *c, uint32_t idx, pa_source_output_info_cb_t cb, void *userdata)
// pa_operation * 	pa_context_get_source_output_info_list (pa_context *c, pa_source_output_info_cb_t cb, void *userdata)
// pa_operation * 	pa_context_move_source_output_by_name (pa_context *c, uint32_t idx, const char *source_name, pa_context_success_cb_t cb, void *userdata)
// pa_operation * 	pa_context_move_source_output_by_index (pa_context *c, uint32_t idx, uint32_t source_idx, pa_context_success_cb_t cb, void *userdata)
// pa_operation * 	pa_context_set_source_output_volume (pa_context *c, uint32_t idx, const pa_cvolume *volume, pa_context_success_cb_t cb, void *userdata)
// pa_operation * 	pa_context_set_source_output_mute (pa_context *c, uint32_t idx, int mute, pa_context_success_cb_t cb, void *userdata)
// pa_operation * 	pa_context_kill_source_output (pa_context *c, uint32_t idx, pa_context_success_cb_t cb, void *userdata)

// typedef void(* 	pa_stat_info_cb_t) (pa_context *c, const pa_stat_info *i, void *userdata)
// pa_operation * 	pa_context_stat (pa_context *c, pa_stat_info_cb_t cb, void *userdata)

// typedef void(* 	pa_sample_info_cb_t) (pa_context *c, const pa_sample_info *i, int eol, void *userdata)
// pa_operation * 	pa_context_get_sample_info_by_name (pa_context *c, const char *name, pa_sample_info_cb_t cb, void *userdata)
// pa_operation * 	pa_context_get_sample_info_by_index (pa_context *c, uint32_t idx, pa_sample_info_cb_t cb, void *userdata)
// pa_operation * 	pa_context_get_sample_info_list (pa_context *c, pa_sample_info_cb_t cb, void *userdata)

//
// mainloop-api.h
//

pub const pa_time_event_cb_t = *const fn (api: *pa_mainloop_api, event: *pa_time_event, tv: *timeval, userdata: ?*anyopaque) callconv(.C) void;

//
// proplist.h
//

pub const pa_update_mode_t = enum(i32) {
    set,
    merge,
    replace,
};

//
// sample.h
//

pub const PA_CHANNELS_MAX = 32;
pub const PA_RATE_MAX = 48000 * 8;
pub const PA_SAMPLE_S16NE = pa_sample_format.s16le;
pub const PA_SAMPLE_FLOAT32NE = pa_sample_format.float32le;
pub const PA_SAMPLE_S32NE = pa_sample_format.s32le;
pub const PA_SAMPLE_S24NE = pa_sample_format.s24le;
pub const PA_SAMPLE_S24_32NE = pa_sample_format.s24_32_le;
pub const PA_SAMPLE_S16RE = pa_sample_format.s16be;
pub const PA_SAMPLE_FLOAT32RE = pa_sample_format.float32be;
pub const PA_SAMPLE_S32RE = pa_sample_format.s32be;
pub const PA_SAMPLE_S24RE = pa_sample_format.s24be;
pub const PA_SAMPLE_S24_32RE = pa_sample_format.s24_32_be;

pub const PA_SAMPLE_SPEC_SNPRINT_MAX = 32;
pub const PA_BYTES_SNPRINT_MAX = 11;

pub const pa_usec_t = u64;

pub const pa_sample_spec = extern struct {
    format: pa_sample_format,
    rate: u32,
    channels: u8,
};

pub const pa_sample_format = enum(i32) {
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
    invalid = -1,
};

// size_t pa_bytes_per_second (const pa_sample_spec *spec) PA_GCC_PURE
// size_t pa_frame_size (const pa_sample_spec *spec) PA_GCC_PURE
// size_t pa_sample_size (const pa_sample_spec *spec) PA_GCC_PURE
// size_t pa_sample_size_of_format (pa_sample_format_t f) PA_GCC_PURE
// pa_usec_t pa_bytes_to_usec (uint64_t length, const pa_sample_spec *spec) PA_GCC_PURE
// size_t pa_usec_to_bytes (pa_usec_t t, const pa_sample_spec *spec) PA_GCC_PURE
// pa_sample_spec * pa_sample_spec_init (pa_sample_spec *spec)
// int pa_sample_format_valid (unsigned format) PA_GCC_PURE
// int pa_sample_rate_valid (uint32_t rate) PA_GCC_PURE
// int pa_channels_valid (uint8_t channels) PA_GCC_PURE
// int pa_sample_spec_valid (const pa_sample_spec *spec) PA_GCC_PURE
// int pa_sample_spec_equal (const pa_sample_spec *a, const pa_sample_spec *b) PA_GCC_PURE
// const char * pa_sample_format_to_string (pa_sample_format_t f) PA_GCC_PURE
// pa_sample_format_t pa_parse_sample_format (const char *format) PA_GCC_PURE
// char * pa_sample_spec_snprint (char *s, size_t l, const pa_sample_spec *spec)
// char * pa_bytes_snprint (char *s, size_t l, unsigned v)
// int pa_sample_format_is_le (pa_sample_format_t f) PA_GCC_PURE
// int pa_sample_format_is_be (pa_sample_format_t f) PA_GCC_PURE

//
// stream.h
//

pub const pa_stream_success_cb_t = *const fn (stream: *pa_stream, success: i32, userdata: ?*anyopaque) callconv(.C) void;
pub const pa_stream_request_cb_t = *const fn (stream: *pa_stream, nbytes: usize, userdata: ?*anyopaque) callconv(.C) void;
pub const pa_stream_notify_cb_t = *const fn (stream: *pa_stream, userdata: ?*anyopaque) callconv(.C) void;
pub const pa_stream_event_cb_t = *const fn (stream: *pa_stream, name: [*:0]const u8, proplist: *pa_proplist, userdata: ?*anyopaque) callconv(.C) void;

// pa_stream * 	pa_stream_new (pa_context *c, const char *name, const pa_sample_spec *ss, const pa_channel_map *map)

pub extern fn pa_stream_new(context: *pa_context, name: [*:0]const u8, sample_spec: *const pa_sample_spec, map: ?*const pa_channel_map) callconv(.C) ?*pa_stream;

// pa_stream * 	pa_stream_new_with_proplist (pa_context *c, const char *name, const pa_sample_spec *ss, const pa_channel_map *map, pa_proplist *p)
// pa_stream * 	pa_stream_new_extended (pa_context *c, const char *name, pa_format_info *const *formats, unsigned int n_formats, pa_proplist *p)
// void 	pa_stream_unref (pa_stream *s)

pub extern fn pa_stream_unref(stream: *pa_stream) callconv(.C) void;

// pa_stream * 	pa_stream_ref (pa_stream *s)
// pa_stream_state_t 	pa_stream_get_state (const pa_stream *p)

pub extern fn pa_stream_get_state(stream: *pa_stream) callconv(.C) pa_stream_state_t;

// pa_context * 	pa_stream_get_context (const pa_stream *p)
// uint32_t 	pa_stream_get_index (const pa_stream *s)
// uint32_t 	pa_stream_get_device_index (const pa_stream *s)

pub extern fn pa_stream_get_device_index(stream: *const pa_stream) callconv(.C) u32;

// const char * 	pa_stream_get_device_name (const pa_stream *s)

pub extern fn pa_stream_get_device_name(stream: *const pa_stream) callconv(.C) [*:0]const u8;

// int 	pa_stream_is_suspended (const pa_stream *s)
// int 	pa_stream_is_corked (const pa_stream *s)
// int 	pa_stream_connect_playback (pa_stream *s, const char *dev, const pa_buffer_attr *attr, pa_stream_flags_t flags, const pa_cvolume *volume, pa_stream *sync_stream)
// int 	pa_stream_connect_record (pa_stream *s, const char *dev, const pa_buffer_attr *attr, pa_stream_flags_t flags)

pub extern fn pa_stream_connect_record(
    stream: *pa_stream,
    device: ?[*:0]const u8,
    buffer_attributes: ?*const pa_buffer_attr,
    flags: pa_stream_flags_t,
) callconv(.C) i32;

// int 	pa_stream_disconnect (pa_stream *s)
// int 	pa_stream_begin_write (pa_stream *p, void **data, size_t *nbytes)
// int 	pa_stream_cancel_write (pa_stream *p)
// int 	pa_stream_write (pa_stream *p, const void *data, size_t nbytes, pa_free_cb_t free_cb, int64_t offset, pa_seek_mode_t seek)
// int 	pa_stream_write_ext_free (pa_stream *p, const void *data, size_t nbytes, pa_free_cb_t free_cb, void *free_cb_data, int64_t offset, pa_seek_mode_t seek)
// int 	pa_stream_peek (pa_stream *p, const void **data, size_t *nbytes)
// int 	pa_stream_drop (pa_stream *p)

pub extern fn pa_stream_peek(stream: *pa_stream, data: *?*const void, data_size_bytes: *usize) callconv(.C) i32;
pub extern fn pa_stream_drop(stream: *pa_stream) callconv(.C) i32;

// size_t 	pa_stream_writable_size (const pa_stream *p)
// size_t 	pa_stream_readable_size (const pa_stream *p)

// pa_operation * 	pa_stream_drain (pa_stream *s, pa_stream_success_cb_t cb, void *userdata)
// pa_operation * 	pa_stream_update_timing_info (pa_stream *p, pa_stream_success_cb_t cb, void *userdata)
// void 	pa_stream_set_state_callback (pa_stream *s, pa_stream_notify_cb_t cb, void *userdata)

pub extern fn pa_stream_set_state_callback(stream: *pa_stream, callback: pa_stream_notify_cb_t, userdata: ?*anyopaque) callconv(.C) void;

// void 	pa_stream_set_write_callback (pa_stream *p, pa_stream_request_cb_t cb, void *userdata)
// void 	pa_stream_set_read_callback (pa_stream *p, pa_stream_request_cb_t cb, void *userdata)

pub extern fn pa_stream_set_read_callback(stream: *pa_stream, callback: pa_stream_request_cb_t, userdata: ?*anyopaque) callconv(.C) void;

// void 	pa_stream_set_overflow_callback (pa_stream *p, pa_stream_notify_cb_t cb, void *userdata)
// int64_t 	pa_stream_get_underflow_index (const pa_stream *p)
// void 	pa_stream_set_underflow_callback (pa_stream *p, pa_stream_notify_cb_t cb, void *userdata)
// void 	pa_stream_set_started_callback (pa_stream *p, pa_stream_notify_cb_t cb, void *userdata)
// void 	pa_stream_set_latency_update_callback (pa_stream *p, pa_stream_notify_cb_t cb, void *userdata)
// void 	pa_stream_set_moved_callback (pa_stream *p, pa_stream_notify_cb_t cb, void *userdata)
// void 	pa_stream_set_suspended_callback (pa_stream *p, pa_stream_notify_cb_t cb, void *userdata)
// void 	pa_stream_set_event_callback (pa_stream *p, pa_stream_event_cb_t cb, void *userdata)
// void 	pa_stream_set_buffer_attr_callback (pa_stream *p, pa_stream_notify_cb_t cb, void *userdata)
// pa_operation * 	pa_stream_cork (pa_stream *s, int b, pa_stream_success_cb_t cb, void *userdata)
// pa_operation * 	pa_stream_flush (pa_stream *s, pa_stream_success_cb_t cb, void *userdata)
// pa_operation * 	pa_stream_prebuf (pa_stream *s, pa_stream_success_cb_t cb, void *userdata)
// pa_operation * 	pa_stream_trigger (pa_stream *s, pa_stream_success_cb_t cb, void *userdata)
// pa_operation * 	pa_stream_set_name (pa_stream *s, const char *name, pa_stream_success_cb_t cb, void *userdata)
// int 	pa_stream_get_time (pa_stream *s, pa_usec_t *r_usec)
// int 	pa_stream_get_latency (pa_stream *s, pa_usec_t *r_usec, int *negative)

// const pa_timing_info * 	pa_stream_get_timing_info (pa_stream *s)
// const pa_sample_spec * 	pa_stream_get_sample_spec (pa_stream *s)
// const pa_channel_map * 	pa_stream_get_channel_map (pa_stream *s)

pub extern fn pa_stream_get_sample_spec(stream: *pa_stream) callconv(.C) *const pa_sample_spec;
pub extern fn pa_stream_get_channel_map(stream: *pa_stream) callconv(.C) *const pa_channel_map;

// const pa_format_info * 	pa_stream_get_format_info (const pa_stream *s)
// const pa_buffer_attr * 	pa_stream_get_buffer_attr (pa_stream *s)
// pa_operation * 	pa_stream_set_buffer_attr (pa_stream *s, const pa_buffer_attr *attr, pa_stream_success_cb_t cb, void *userdata)
// pa_operation * 	pa_stream_update_sample_rate (pa_stream *s, uint32_t rate, pa_stream_success_cb_t cb, void *userdata)
// pa_operation * 	pa_stream_proplist_update (pa_stream *s, pa_update_mode_t mode, pa_proplist *p, pa_stream_success_cb_t cb, void *userdata)
// pa_operation * 	pa_stream_proplist_remove (pa_stream *s, const char *const keys[], pa_stream_success_cb_t cb, void *userdata)
// int 	pa_stream_set_monitor_stream (pa_stream *s, uint32_t sink_input_idx)
// uint32_t 	pa_stream_get_monitor_stream (const pa_stream *s)

//
// thread-mainloop.h
//

pub extern fn pa_threaded_mainloop_new() callconv(.C) ?*pa_threaded_mainloop;
pub extern fn pa_threaded_mainloop_free(loop: *pa_threaded_mainloop) callconv(.C) void;
pub extern fn pa_threaded_mainloop_start(loop: *pa_threaded_mainloop) callconv(.C) i32;
pub extern fn pa_threaded_mainloop_stop(loop: *pa_threaded_mainloop) callconv(.C) void;
pub extern fn pa_threaded_mainloop_lock(loop: *pa_threaded_mainloop) callconv(.C) void;
pub extern fn pa_threaded_mainloop_unlock(loop: *pa_threaded_mainloop) callconv(.C) void;
pub extern fn pa_threaded_mainloop_wait(loop: *pa_threaded_mainloop) callconv(.C) void;

// void 	pa_threaded_mainloop_signal (pa_threaded_mainloop *m, int wait_for_accept)
// void 	pa_threaded_mainloop_accept (pa_threaded_mainloop *m)
// int 	pa_threaded_mainloop_get_retval (const pa_threaded_mainloop *m)

pub extern fn pa_threaded_mainloop_get_api(loop: *pa_threaded_mainloop) callconv(.C) ?*pa_mainloop_api;

// int 	pa_threaded_mainloop_in_thread (pa_threaded_mainloop *m)
// void 	pa_threaded_mainloop_set_name (pa_threaded_mainloop *m, const char *name)
// void 	pa_threaded_mainloop_once_unlocked (pa_threaded_mainloop *m, void(*callback)(pa_threaded_mainloop *m, void *userdata), void *userdata)

//
// volume.h
//

pub const pa_volume_t = u32;

pub const pa_cvolume = extern struct {
    channels: u8,
    values: [PA_CHANNELS_MAX]pa_volume_t,
};
