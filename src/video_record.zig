// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const graphics = @import("graphics.zig");
const geometry = @import("geometry.zig");

const libav = @import("libav.zig");

const RingBuffer = @import("utils.zig").RingBuffer;

const EAGAIN: i32 = -11;
const EINVAL: i32 = -22;

pub const PixelType = graphics.RGBA(u8);

pub const State = enum {
    uninitialized,
    encoding,
    closed,
};

pub const RecordOptions = struct {
    fps: u32,
    dimensions: geometry.Dimensions2D(u32),
    output_path: [*:0]const u8,
};

pub var state: State = .uninitialized;

var video_codec_context: *libav.CodecContext = undefined;
var format_context: *libav.FormatContext = undefined;
var video_stream: *libav.Stream = undefined;
var output_format: *libav.OutputFormat = undefined;
var video_filter_source_context: *libav.FilterContext = undefined;
var video_filter_sink_context: *libav.FilterContext = undefined;
var video_filter_graph: *libav.FilterGraph = undefined;
var hw_frame_context: ?*libav.BufferRef = null;
var video_frame: *libav.Frame = undefined;

var audio_stream: *libav.Stream = undefined;
var audio_codec_context: *libav.CodecContext = undefined;
var audio_frame: *libav.Frame = undefined;

var video_frames_written: usize = 0;
var processing_thread: std.Thread = undefined;
var request_close: bool = false;

const sample_rate = 44100;
var samples_written: usize = 0;

var context: struct {
    dimensions: geometry.Dimensions2D(u32),
} = undefined;

const Frame = struct {
    pixels: [*]const PixelType,
    audio_buffer: []const f32,
    frame_index: u64,
};

var ring_buffer = RingBuffer(Frame, 4).init;

fn eventLoop() void {
    outer: while (true) {
        while (ring_buffer.pop()) |entry| {
            const encode_start = std.time.nanoTimestamp();
            writeFrame(entry.pixels, entry.audio_buffer, @intCast(u32, entry.frame_index)) catch |err| {
                std.log.err("Failed to write frame. Error {}", .{err});
            };
            const duration = std.time.nanoTimestamp() - encode_start;
            std.log.info("Frame encoded in {d}ms", .{@divTrunc(duration, std.time.ns_per_ms)});
        }
        if (request_close)
            break :outer;
        std.time.sleep(std.time.ns_per_ms * 4);
    }
    finishVideoStream();
}

pub fn write(pixels: [*]const graphics.RGBA(u8), audio_samples: []const f32, frame_index: u64) !void {
    ring_buffer.push(.{
        .pixels = pixels,
        .audio_buffer = audio_samples,
        .frame_index = frame_index,
    }) catch {
        std.log.warn("Buffer full, failed to write frame", .{});
        std.debug.assert(false);
    };
}

pub fn close() void {
    request_close = true;
    std.log.info("video_encoder: waiting for video_record thread to terminate..", .{});
    processing_thread.join();

    request_close = false;
    state = .closed;
    std.log.info("video_encoder: shutdown successful", .{});

    libav.filterGraphFree(&video_filter_graph);

    ring_buffer = RingBuffer(Frame, 4).init;

    const audio_written = (@intToFloat(f32, samples_written) / 44100.0) / 2.0;
    std.log.info("{d} seconds of audio written", .{audio_written});

    const ms_per_frame: f32 = 1000.0 / 30.0;
    const video_written = @intToFloat(f32, video_frames_written) * ms_per_frame;
    std.log.info("{d} seconds of video written", .{video_written / 1000.0});
}

pub fn open(options: RecordOptions) !void {
    context.dimensions = options.dimensions;
    if (builtin.mode == .Debug)
        libav.av_log_set_level(libav.LOG_DEBUG);

    output_format = libav.guessFormat(null, options.output_path, null) orelse {
        std.log.err("Failed to determine output format", .{});
        return;
    };

    std.log.info("Video output format: {s}", .{output_format.name});

    var ret_code: i32 = 0;
    var format_context_opt: ?*libav.FormatContext = null;
    ret_code = libav.formatAllocOutputContext2(
        &format_context_opt,
        null,
        output_format.name,
        options.output_path,
    );
    std.debug.assert(ret_code == 0);

    if (format_context_opt) |fc| {
        format_context = fc;
    } else {
        std.log.err("Failed to allocate output context", .{});
        return error.AllocateOutputContextFail;
    }

    const video_codec: *libav.Codec = libav.codecFindEncoder(.h264) orelse {
        std.log.err("Failed to find h264 encoder", .{});
        return error.FindVideoEncoderFail;
    };

    //
    // video_stream is cleaned up along with format_context
    // https://ffmpeg.org/doxygen/trunk/group__lavf__core.html#gadcb0fd3e507d9b58fe78f61f8ad39827
    //
    video_stream = libav.formatNewStream(format_context, video_codec) orelse {
        std.log.err("Failed to create video stream", .{});
        return;
    };
    video_codec_context = libav.codecAllocContext3(video_codec) orelse {
        std.log.err("Failed to allocate context for codec", .{});
        return;
    };

    video_codec_context.width = @intCast(i32, options.dimensions.width);
    video_codec_context.height = @intCast(i32, options.dimensions.height);
    video_codec_context.color_range = @enumToInt(libav.ColorRange.jpeg);
    video_codec_context.bit_rate = 1024 * 1024 * 8;
    video_codec_context.time_base = .{ .num = 1, .den = @intCast(i32, options.fps) };
    // video_codec_context.gop_size = 300;
    // video_codec_context.max_b_frames = 1;
    video_codec_context.pix_fmt = @enumToInt(libav.PixelFormat.YUV444P);

    video_frame = libav.frameAlloc() orelse return error.AllocateFrameFailed;

    if (hw_frame_context) |frame_context| {
        video_codec_context.hw_frames_ctx = libav.bufferRef(frame_context);
    }

    var ffmpeg_options: ?*libav.Dictionary = null;

    _ = libav.dictSet(&ffmpeg_options, "preset", "ultrafast", 0);
    _ = libav.dictSet(&ffmpeg_options, "crf", "35", 0);
    _ = libav.dictSet(&ffmpeg_options, "tune", "zerolatency", 0);

    // _ = libav.dictSet(&ffmpeg_options, "preset", "slow", 0);
    // _ = libav.dictSet(&ffmpeg_options, "crf", "20", 0);
    // _ = libav.dictSet(&ffmpeg_options, "tune", "animation", 0);

    if (libav.codecOpen2(video_codec_context, video_codec, &ffmpeg_options) < 0) {
        std.log.err("Failed to open codec", .{});
        return;
    }
    libav.dictFree(&ffmpeg_options);

    if (libav.codecParametersFromContext(video_stream.codecpar, video_codec_context) < 0) {
        std.log.err("Failed to avcodec_parameters_from_context", .{});
        return;
    }

    //
    // Setup Audio Stream
    //

    const audio_codec: *libav.Codec = libav.codecFindEncoder(.AAC) orelse {
        std.log.err("Failed to find AAC encoder", .{});
        return error.FindAudioEncoderFail;
    };

    if (audio_codec.sample_fmts) |sample_formats| {
        std.log.info("Supported Audio sample formats", .{});
        var i: usize = 0;
        while (sample_formats[i] != -1) : (i += 1) {
            std.log.info("{s}", .{@tagName(@intToEnum(libav.SampleFormat, sample_formats[i]))});
        }
    }

    audio_stream = libav.formatNewStream(format_context, audio_codec) orelse {
        std.log.err("Failed to create audio stream", .{});
        return;
    };
    audio_codec_context = libav.codecAllocContext3(audio_codec) orelse {
        std.log.err("Failed to allocate audio context for codec", .{});
        return;
    };

    audio_codec_context.sample_rate = 44100;
    audio_codec_context.channels = 2;
    audio_codec_context.channel_layout = libav.ChannelLayout.stereo;
    audio_codec_context.sample_fmt = @enumToInt(libav.SampleFormat.fltp);
    audio_codec_context.bit_rate = 96000;

    var audio_codec_options: ?*libav.Dictionary = null;
    if (libav.codecOpen2(audio_codec_context, audio_codec, &audio_codec_options) < 0) {
        std.log.err("Failed to open audio codec", .{});
        return;
    }

    if (libav.codecParametersFromContext(audio_stream.codecpar, audio_codec_context) < 0) {
        std.log.err("Failed to audio avcodec_parameters_from_context", .{});
        return;
    }

    audio_frame = libav.frameAlloc() orelse return error.AllocateFrameFailed;

    audio_frame.format = @enumToInt(libav.SampleFormat.fltp);
    audio_frame.channel_layout = libav.ChannelLayout.stereo;
    audio_frame.nb_samples = audio_codec_context.frame_size;

    if (libav.frameGetBuffer(audio_frame, 0) != 0) {
        std.log.err("Failed to allocate audio frame buffer", .{});
        return error.AllocateAudioFrameBufferFailed;
    }

    libav.dumpFormat(format_context, 0, options.output_path, 1);

    ret_code = libav.ioOpen(
        &format_context.pb,
        options.output_path,
        libav.AVIO_FLAG_WRITE,
    );
    if (ret_code < 0) {
        std.log.err("Failed to open AVIO context", .{});
        return error.OpenAVIOContextFailed;
    }

    ret_code = libav.formatWriteHeader(
        format_context,
        null,
    );
    if (ret_code < 0) {
        std.log.err("Failed to write screen recording header", .{});
        return error.WriteFormatHeaderFailed;
    }

    std.log.info("video stream timebase: {d} / {d}", .{
        video_stream.time_base.num,
        video_stream.time_base.den,
    });
    std.log.info("Video context timebase: {d} / {d}", .{
        video_codec_context.time_base.num,
        video_codec_context.time_base.den,
    });

    std.log.info("Audio stream timebase: {d} / {d}", .{
        audio_stream.time_base.num,
        audio_stream.time_base.den,
    });
    std.log.info("Audio context timebase: {d} / {d}", .{
        audio_codec_context.time_base.num,
        audio_codec_context.time_base.den,
    });

    std.log.info("Audio codec. Sample rate: {d} bitrate: {d}, channels: {d}, Layout: {}, Sample format: {}", .{
        audio_codec_context.sample_rate,
        audio_codec_context.bit_rate,
        audio_codec_context.channels,
        audio_codec_context.channel_layout,
        @intToEnum(libav.SampleFormat, audio_codec_context.sample_fmt),
    });

    const samples_buffer_size = libav.samplesGetBufferSize(null, 2, 2940, .fltp, 0);
    std.debug.assert(samples_buffer_size >= 0);
    std.log.info("Buffer size for 2940 samples: {d} expected {d}", .{
        samples_buffer_size,
        2940 * 2 * 4,
    });

    processing_thread = try std.Thread.spawn(.{}, eventLoop, .{});
    state = .encoding;
}

fn finishVideoStream() void {
    //
    // TODO: Don't use encodeFrame here, we need to flush internal buffers
    //       and make sure we get an EOF return code
    //

    //
    // Flush audio frames
    //
    var code = libav.codecSendFrame(audio_codec_context, null);
    if (code < 0) {
        std.log.err("Failed to send frame for encoding", .{});
    }

    while (code >= 0) {
        var packet: libav.Packet = undefined;
        libav.initPacket(&packet);
        packet.data = null;
        packet.size = 0;

        code = libav.codecReceivePacket(audio_codec_context, &packet);
        if (code == libav.ERROR_EOF)
            break;

        if (code == EAGAIN or code < 0) {
            std.log.err("Failed to recieve encoded frame (packet)", .{});
        }

        std.log.info("Writing audio packet", .{});

        //
        // Finish Frame
        //
        libav.packetRescaleTS(&packet, audio_codec_context.time_base, audio_stream.time_base);
        packet.stream_index = audio_stream.index;
        std.debug.assert(audio_stream.index != video_stream.index);

        code = libav.interleavedWriteFrame(format_context, &packet);
        if (code != 0) {
            std.log.warn("Interleaved write frame failed", .{});
        }
        libav.packetUnref(&packet);
    }

    //
    // Flush video frames
    //

    encodeFrame(null) catch |err| {
        std.log.err("Failed to encode frame. Error: {}", .{err});
    };
    _ = libav.writeTrailer(format_context);

    _ = libav.codecFreeContext(&video_codec_context);
    _ = libav.codecFreeContext(&audio_codec_context);
    _ = libav.formatFreeContext(format_context);

    libav.frameFree(&video_frame);
    libav.frameFree(&audio_frame);
}

fn encodeAudioFrames(samples: []const f32) !void {
    std.debug.assert(samples.len % 2048 == 0);

    for (samples) |sample| {
        std.debug.assert(sample <= 1.0);
        std.debug.assert(sample >= -1.0);
    }

    audio_frame.format = @enumToInt(libav.SampleFormat.fltp);
    audio_frame.nb_samples = audio_codec_context.frame_size;

    std.debug.assert(audio_codec_context.frame_size == 1024);
    var planar_buffer: [2048]f32 = [1]f32{1.1} ** 2048;

    var sample_index: usize = 0;
    outer: while (sample_index < samples.len) {
        const channel_count = 2;
        const max_samples_per_write = @intCast(usize, audio_codec_context.frame_size) * channel_count;
        const samples_remaining: usize = samples.len - sample_index;
        const samples_to_write: usize = @min(samples_remaining, max_samples_per_write);
        std.debug.assert(samples_to_write == max_samples_per_write);
        std.debug.assert(max_samples_per_write == 1024 * 2);
        const samples_per_channel: usize = @divExact(samples_to_write, 2);
        std.debug.assert(samples_per_channel == 1024);
        for (0..samples_per_channel) |i| {
            planar_buffer[i] = samples[i * 2];
            planar_buffer[i + samples_per_channel] = samples[(i * 2) + 1];
        }
        for (planar_buffer[0..samples_to_write]) |sample| {
            std.debug.assert(sample <= 1.0);
            std.debug.assert(sample >= -1.0);
        }

        std.debug.assert(samples_to_write > 0);
        std.debug.assert(samples_to_write % 2048 == 0);

        sample_index += samples_to_write;
        audio_frame.nb_samples = @divExact(@intCast(i32, samples_to_write), channel_count);

        std.debug.assert(audio_frame.nb_samples == audio_codec_context.frame_size);

        const bytes_per_frame = @intCast(i32, samples_to_write * @sizeOf(f32));
        var fill_audio_frame_code: i32 = libav.codecFillAudioFrame(
            audio_frame,
            @as(i32, channel_count),
            libav.SampleFormat.fltp,
            @ptrCast([*]const u8, &planar_buffer),
            bytes_per_frame,
            0,
        );
        if (fill_audio_frame_code < 0) {
            var error_message_buffer: [512]u8 = undefined;
            _ = libav.strError(fill_audio_frame_code, &error_message_buffer, 512);
            std.log.err("Failed to fill audio frame: {d} {s}", .{ fill_audio_frame_code, error_message_buffer });
            std.debug.assert(false);
        }

        audio_frame.pts = @intCast(i64, samples_written);

        samples_written += samples_per_channel;

        const send_frame_code = libav.codecSendFrame(audio_codec_context, audio_frame);
        if (send_frame_code == EAGAIN) {
            //
            // The encoder isn't accepting any input until we receive the next output packet
            //
            while (true) {
                var packet: libav.Packet = undefined;
                libav.initPacket(&packet);
                packet.data = null;
                packet.size = 0;
                packet.pts = audio_frame.pts;
                std.log.info("Packet pts: {d}", .{packet.pts});

                var receive_packet_code = libav.codecReceivePacket(audio_codec_context, &packet);
                if (receive_packet_code == EAGAIN) {
                    //
                    // Wants input again, write the frame (input) that we previously couldn't
                    // and return to top of loop
                    //
                    const resend_frame_code = libav.codecSendFrame(audio_codec_context, audio_frame);
                    if (resend_frame_code < 0) {
                        return error.ResendFrameFail;
                    }
                    continue :outer;
                }

                if (receive_packet_code == libav.ERROR_EOF) {
                    std.debug.assert(false);
                    return error.UnexpectedEOF;
                }

                if (receive_packet_code < 0) {
                    std.debug.assert(false);
                    return error.RecievePacketFail;
                }

                libav.packetRescaleTS(&packet, audio_codec_context.time_base, audio_stream.time_base);
                packet.stream_index = audio_stream.index;

                const write_packet_code = libav.interleavedWriteFrame(format_context, &packet);
                if (write_packet_code != 0) {
                    std.log.warn("Interleaved write frame failed. {d}", .{write_packet_code});
                    std.debug.assert(false);
                }
                libav.packetUnref(&packet);
            }
        } else if (send_frame_code < 0) {
            std.log.err("Failed to send frame to encoder. Error: {d}", .{send_frame_code});
            return error.SendFrameFail;
        }
    }
}

fn writeFrame(pixels: [*]const PixelType, audio_buffer: []const f32, frame_index: u32) !void {

    rgbaToPlanarYuv(pixels, context.dimensions, &yuv_output_buffer);

    const pixel_count: u32 = context.dimensions.width * context.dimensions.height;

    const u_channel_base: u32 = 0;
    const y_channel_base: u32 = pixel_count;
    const v_channel_base: u32 = pixel_count * 2;

    video_frame.data[0] = &(yuv_output_buffer[y_channel_base]);
    video_frame.data[1] = &(yuv_output_buffer[u_channel_base]);
    video_frame.data[2] = &(yuv_output_buffer[v_channel_base]);

    const plane_stride: i32 = @divExact(3 * @intCast(i32, context.dimensions.width), 3);
    video_frame.linesize[0] = plane_stride;
    video_frame.linesize[1] = plane_stride;
    video_frame.linesize[2] = plane_stride;

    video_frame.format = @enumToInt(libav.PixelFormat.YUV444P);
    video_frame.width = @intCast(i32, context.dimensions.width);
    video_frame.height = @intCast(i32, context.dimensions.height);

    video_frames_written += 1;
    video_frame.pts = frame_index;

    video_frame.pict_type = libav.AV_PICTURE_TYPE_NONE;

    try encodeFrame(video_frame);

    if (audio_buffer.len != 0) {
        try encodeAudioFrames(audio_buffer);
    }
}

fn encodeFrame(frame: ?*libav.Frame) !void {
    var code = libav.codecSendFrame(video_codec_context, frame);
    if (code < 0) {
        var error_message_buffer: [512]u8 = undefined;
        _ = libav.strError(code, &error_message_buffer, 512);
        std.log.err("Failed to send frame for encoding: {d} {s}", .{ code, error_message_buffer });
        return error.EncodeFrameFailed;
    }

    while (code >= 0) {
        var packet: libav.Packet = undefined;
        libav.initPacket(&packet);
        packet.data = null;
        packet.size = 0;

        code = libav.codecReceivePacket(video_codec_context, &packet);
        if (code == EAGAIN or code == libav.ERROR_EOF)
            return;

        if (code < 0) {
            std.log.err("Failed to recieve encoded frame (packet)", .{});
            return error.ReceivePacketFailed;
        }

        std.log.info("Writing video packet. Pts: {d} {d}", .{
            packet.pts,
            @intToFloat(f32, packet.pts) / 30.0,
        });

        //
        // Finish Frame
        //
        libav.packetRescaleTS(&packet, video_codec_context.time_base, video_stream.time_base);
        packet.stream_index = video_stream.index;

        code = libav.interleavedWriteFrame(format_context, &packet);
        if (code != 0) {
            std.log.warn("Interleaved write frame failed", .{});
        }
        libav.packetUnref(&packet);
    }
}

//
// TODO: Heap allocate this
//
var yuv_output_buffer: [1080 * 1920 * 3]u8 = undefined;

//
// Calculations based on:
// https://learn.microsoft.com/en-us/windows/win32/medfound/recommended-8-bit-yuv-formats-for-video-rendering
//      Y = ( (  66 * R + 129 * G +  25 * B + 128) >> 8) +  16
//      U = ( ( -38 * R -  74 * G + 112 * B + 128) >> 8) + 128
//      V = ( ( 112 * R -  94 * G -  18 * B + 128) >> 8) + 128
//
fn rgbaToPlanarYuv(pixels: [*]const graphics.RGBA(u8), dimensions: geometry.Dimensions2D(u32), out_buffer: []u8) void {
    const pixel_count = dimensions.width * dimensions.height;

    const u_channel_base: u32 = 0;
    const y_channel_base: u32 = pixel_count;
    const v_channel_base: u32 = pixel_count * 2;

    const y_const_a = @splat(8, @as(i32, 66));
    const y_const_b = @splat(8, @as(i32, 129));
    const y_const_c = @splat(8, @as(i32, 25));
    const y_const_d = @splat(8, @as(i32, 128));
    const y_const_e = @splat(8, @as(i32, 16));

    const u_const_a = @splat(8, @as(i32, -38));
    const u_const_b = @splat(8, @as(i32, 74));
    const u_const_c = @splat(8, @as(i32, 112));
    const u_const_d = @splat(8, @as(i32, 128));
    const u_const_e = @splat(8, @as(i32, 128));

    const v_const_a = @splat(8, @as(i32, 112));
    const v_const_b = @splat(8, @as(i32, 94));
    const v_const_c = @splat(8, @as(i32, 18));
    const v_const_d = @splat(8, @as(i32, 128));
    const v_const_e = @splat(8, @as(i32, 128));

    const divider = @splat(8, @as(i32, 8));

    var i: usize = 0;
    while (i < pixel_count) : (i += 8) {
        const r = @Vector(8, i32){
            pixels[i + 0].r,
            pixels[i + 1].r,
            pixels[i + 2].r,
            pixels[i + 3].r,
            pixels[i + 4].r,
            pixels[i + 5].r,
            pixels[i + 6].r,
            pixels[i + 7].r,
        };

        const g = @Vector(8, i32){
            pixels[i + 0].g,
            pixels[i + 1].g,
            pixels[i + 2].g,
            pixels[i + 3].g,
            pixels[i + 4].g,
            pixels[i + 5].g,
            pixels[i + 6].g,
            pixels[i + 7].g,
        };

        const b = @Vector(8, i32){
            pixels[i + 0].b,
            pixels[i + 1].b,
            pixels[i + 2].b,
            pixels[i + 3].b,
            pixels[i + 4].b,
            pixels[i + 5].b,
            pixels[i + 6].b,
            pixels[i + 7].b,
        };

        const y_vector: @Vector(8, i32) = (((y_const_a * r) + (y_const_b * g) + (y_const_c * b) + y_const_d) >> divider) + y_const_e;
        inline for (0..8) |offset|
            out_buffer[i + y_channel_base + offset] = @intCast(u8, y_vector[offset]);

        const u_vector: @Vector(8, i32) = (((u_const_a * r) - (u_const_b * g) + (u_const_c * b) + u_const_d) >> divider) + u_const_e;
        inline for (0..8) |offset|
            out_buffer[i + u_channel_base + offset] = @intCast(u8, u_vector[offset]);

        const v_vector: @Vector(8, i32) = (((v_const_a * r) - (v_const_b * g) - (v_const_c * b) + v_const_d) >> divider) + v_const_e;
        inline for (0..8) |offset|
            out_buffer[i + v_channel_base + offset] = @intCast(u8, v_vector[offset]);
    }
}
