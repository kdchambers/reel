// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

pub const Simple = opaque {};
pub const StreamDirection = enum(i32) {
    no_direction = 0,
    playback = 1,
    record = 2,
    upload = 3,
};

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

//
// Function alias'
//

pub const simpleNew = pa_simple_new;
pub const simpleRead = pa_simple_read;
pub const simpleFree = pa_simple_free;
