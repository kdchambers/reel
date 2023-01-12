// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const DynLib = std.DynLib;

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
        self.pulse_simple_handle = DynLib.open("libpulse-simple.so") catch
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
