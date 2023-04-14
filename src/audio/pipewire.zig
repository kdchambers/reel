// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const audio = @import("../audio.zig");

const c = @cImport({
    @cInclude("stdio.h");
});

const pw = @cImport({
    @cInclude("spa/param/audio/format-utils.h");
    @cInclude("spa/debug/types.h");
    @cInclude("spa/param/video/type-info.h");
    @cInclude("pipewire/pipewire.h");
});

var stream: *pw.pw_stream = undefined;
var thread_loop: *pw.pw_thread_loop = undefined;

pub const InitErrors = error{
    PipewireConnectServerFail,
    CreateThreadFail,
    CreateStreamFail,
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

pub fn isSupported() bool {
    return true;
}

const stream_events = pw.pw_stream_events{
    .version = pw.PW_VERSION_STREAM_EVENTS,
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

fn onStateChangedCallback(_: ?*anyopaque, old: pw.pw_stream_state, new: pw.pw_stream_state, error_message: [*c]const u8) callconv(.C) void {
    _ = old;
    const error_string: [*c]const u8 = error_message orelse "none";
    std.log.warn("pipewire state changed. \"{s}\". Error: {s}", .{ pw.pw_stream_state_as_string(new), error_string });
}

fn onProcessCallback(_: ?*anyopaque) callconv(.C) void {
    const buffer = pw.pw_stream_dequeue_buffer(stream);
    const buffer_bytes = buffer.*.buffer.*.datas[0].data orelse return;
    const buffer_size_bytes = buffer.*.buffer.*.datas[0].chunk.*.size;
    const sample_count = @divExact(buffer_size_bytes, @sizeOf(i16));
    onReadSamplesCallback(@ptrCast([*]i16, @alignCast(2, buffer_bytes))[0..sample_count]);
    _ = pw.pw_stream_queue_buffer(stream, buffer);
}

fn onParamChangedCallback(_: ?*anyopaque, id: u32, params: [*c]const pw.spa_pod) callconv(.C) void {
    _ = params;
    std.log.info("Param changed format (unknown) {d}", .{id});
    if (id == pw.SPA_PARAM_Format) {
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

pub fn init(
    onSuccess: *const audio.InitSuccessCallbackFn,
    onFail: *const audio.InitFailCallbackFn,
) InitErrors!void {
    std.debug.assert(stream_state == .closed);

    onInitFailCallback = onFail;
    onInitSuccessCallback = onSuccess;

    var argc: i32 = 1;
    var argv = [_][*:0]const u8{"reel"};

    pw.pw_init(@ptrCast([*]i32, &argc), @ptrCast([*c][*c][*c]u8, &argv));

    thread_loop = pw.pw_thread_loop_new("Pipewire thread loop", null) orelse return error.CreateThreadFail;

    if (pw.pw_thread_loop_start(thread_loop) < 0) {
        return error.PipewireConnectServerFail;
    }
    pw.pw_thread_loop_lock(thread_loop);

    const stream_properties = pw.pw_properties_new(
        pw.PW_KEY_MEDIA_TYPE,
        "Audio",
        pw.PW_KEY_MEDIA_CATEGORY,
        "Capture",
        pw.PW_KEY_MEDIA_ROLE,
        "Music",
        c.NULL,
    );

    stream = pw.pw_stream_new_simple(
        pw.pw_thread_loop_get_loop(thread_loop),
        "audio-capture",
        stream_properties,
        &stream_events,
        null,
    ) orelse return error.CreateStreamFail;

    const AudioFormatParam = extern struct {
        const KeyPair = extern struct {
            key: Format,
            flags: u32 = 0,
            size: u32 = 4,
            kind: PodType,
            value: u32,
            padding: u32 = 0,
        };

        size: u32,
        kind: PodType,
        object_kind: PodType,
        object_id: ParamType,
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
                .value = @enumToInt(MediaType.audio),
            },
            .{
                .key = .media_subtype,
                .kind = .id,
                .value = @enumToInt(MediaSubtype.raw),
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
    var ret_code = pw.pw_stream_connect(
        stream,
        pw.PW_DIRECTION_INPUT,
        pw.PW_ID_ANY,
        pw.PW_STREAM_FLAG_AUTOCONNECT | pw.PW_STREAM_FLAG_MAP_BUFFERS | pw.PW_STREAM_FLAG_RT_PROCESS,
        @ptrCast([*c][*c]pw.spa_pod, &param_ptr),
        1,
    );
    if (ret_code != 0) {
        std.log.info("Failed to connect to stream. Error {d}", .{ret_code});
        return;
    }

    stream_state = .initialized;
    onInitSuccessCallback();
}

pub fn close() void {
    pw.pw_thread_loop_lock(thread_loop);
    pw.pw_thread_loop_stop(thread_loop);
    pw.pw_stream_destroy(stream);
    pw.pw_thread_loop_destroy(thread_loop);
    pw.pw_deinit();
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
    pw.pw_thread_loop_unlock(thread_loop);

    onOpenSuccessCallback();
}

const Callbacks = extern struct {
    version: u32,
    overflow: *const fn (data: *void, size: u32) i32,
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
