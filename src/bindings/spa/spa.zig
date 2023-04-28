// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const b = @import("cbindings.zig");

pub const Dict = opaque {};
pub const Hook = opaque {};
pub const Command = opaque {};

pub const AudioFormat = b.spa_audio_format;
pub const AudioChannel = b.spa_audio_channel;

pub const Buffer = extern struct {
    n_metas: u32,
    n_datas: u32,
    metas: [*]Meta,
    datas: [*]Data,
};

pub const Meta = extern struct {
    pub const Type = enum(u32) {
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

pub const Data = extern struct {
    type: u32,
    flags: u32,
    fd: i64,
    map_offset: u32,
    map_size: u32,
    data: ?*anyopaque,
    chunk: *Chunk,
};

pub const Chunk = extern struct {
    offset: u32,
    size: u32,
    stride: i32,
    flags: i32,
};

pub const Callbacks = extern struct {
    version: u32,
    overflow: *const fn (data: ?*anyopaque, size: u32) i32,
};

pub const Pod = extern struct {
    kind: u32,
    size: u32,
};

pub const ParamType = enum(i32) {
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

pub const PodType = enum(u32) {
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

pub const Format = enum(u32) {
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

pub const MediaType = enum(u32) {
    unknown,
    audio,
    video,
    image,
    binary,
    stream,
    application,
};

pub const MediaSubtype = enum(u32) {
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
