// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");

const graphics = @import("graphics.zig");
const geometry = @import("geometry.zig");

const libav = @import("libav.zig");

const EAGAIN: i32 = -11;
const EINVAL: i32 = -22;

var video_codec_context: *libav.CodecContext = undefined;
var sws_context: *libav.SwsContext = undefined;
var format_context: *libav.FormatContext = undefined;
var video_stream: *libav.Stream = undefined;
var output_format: *libav.OutputFormat = undefined;
var video_filter_source_context: *libav.FilterContext = undefined;
var video_filter_sink_context: *libav.FilterContext = undefined;
var video_filter_graph: *libav.FilterGraph = undefined;
var hw_device_context: ?*libav.BufferRef = null;
var hw_frame_context: ?*libav.BufferRef = null;
var video_frame: *libav.Frame = undefined;

var audio_stream: *libav.Stream = undefined;
var audio_codec_context: *libav.CodecContext = undefined;

pub const State = enum {
    uninitialized,
    encoding,
    closed,
};

pub const PixelType = graphics.RGBA(u8);

pub const RecordOptions = struct {
    fps: u32,
    dimensions: geometry.Dimensions2D(u32),
    output_path: [*:0]const u8,
    base_index: u64,
};

const Fence = u32;

var processing_thread: std.Thread = undefined;
var fence_buffer: [8]bool = undefined;
var image_buffer: [8][*]const PixelType = undefined;
var current_index: u32 = 0;
var request_close: bool = false;
var once: bool = true;

pub var state: State = .uninitialized;

fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        mutex: std.Thread.Mutex,
        buffer: [capacity]T,
        head: u16,
        len: u16,

        pub const init = @This(){
            .head = 0,
            .len = 0,
            .buffer = undefined,
            .mutex = undefined,
        };

        pub fn peek(self: @This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len == 0)
                return null;

            return self.buffer[self.head];
        }

        pub fn push(self: *@This(), value: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len == capacity)
                return error.Full;

            const dst_index: usize = (self.head + self.len) % capacity;
            self.buffer[dst_index] = value;
            self.len += 1;
        }

        pub fn pop(self: *@This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len == 0)
                return null;

            const index = self.head;
            self.head = (self.head + 1) % @as(u16, capacity);
            self.len -= 1;

            return self.buffer[index];
        }
    };
}

const Context = struct {
    dimensions: geometry.Dimensions2D(u32),
};
var context: Context = undefined;

const Frame = struct {
    pixels: [*]const PixelType,
    frame_index: u64,
};

var ring_buffer = RingBuffer(Frame, 4).init;

fn eventLoop() void {
    outer: while (true) {
        while (ring_buffer.len == 0) {
            std.time.sleep(std.time.ns_per_ms * 8);
            if (request_close) break :outer;
        }
        const entry = ring_buffer.pop() orelse continue;
        writeFrame(entry.pixels, @intCast(u32, entry.frame_index)) catch |err| {
            std.log.err("Failed to write frame. Error {}", .{err});
        };
    }
    finishVideoStream();
}

pub fn write(pixels: [*]const graphics.RGBA(u8), frame_index: u64) !void {
    ring_buffer.push(.{
        .pixels = pixels,
        .frame_index = frame_index,
    }) catch {
        std.log.warn("Buffer full, failed to write frame", .{});
    };
}

pub fn close() void {
    request_close = true;
    std.log.info("video_encoder: waiting for video_record thread to terminate..", .{});
    processing_thread.join();
    state = .closed;
    std.log.info("video_encoder: shutdown successful", .{});
}

pub fn open(options: RecordOptions) !void {
    std.debug.assert(once);
    once = false;

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
    video_codec_context.pix_fmt = @enumToInt(libav.PixelFormat.YUV420P);

    initVideoFilters(options) catch |err| {
        std.log.err("Failed to init video filters. Error: {}", .{err});
        return;
    };

    if (hw_frame_context) |frame_context| {
        video_codec_context.hw_frames_ctx = libav.bufferRef(frame_context);
    }

    var ffmpeg_options: ?*libav.Dictionary = null;

    _ = libav.dictSet(&ffmpeg_options, "preset", "slow", 0);
    _ = libav.dictSet(&ffmpeg_options, "crf", "20", 0);
    _ = libav.dictSet(&ffmpeg_options, "tune", "animation", 0);

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

    audio_stream.time_base.den = 96000;
    audio_stream.time_base.num = 1;

    var audio_codec_options: ?*libav.Dictionary = null;
    if (libav.codecOpen2(audio_codec_context, audio_codec, &audio_codec_options) < 0) {
        std.log.err("Failed to open audio codec", .{});
        return;
    }

    if (libav.codecParametersFromContext(audio_stream.codecpar, audio_codec_context) < 0) {
        std.log.err("Failed to audio avcodec_parameters_from_context", .{});
        return;
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

    processing_thread = try std.Thread.spawn(.{}, eventLoop, .{});
    state = .encoding;
}

fn finishVideoStream() void {
    var packet: libav.Packet = undefined;
    libav.initPacket(&packet);

    encodeFrame(null, &packet) catch |err| {
        std.log.err("Failed to encode frame. Error: {}", .{err});
    };
    _ = libav.writeTrailer(format_context);

    //
    // TODO: Audit. This is changing type from AVFormatContext
    // was opened by avio_open ?
    //
    // _ = libav.ioClosep(@ptrCast(**libav.IOContext, &format_context.pb[0]));

    _ = libav.codecFreeContext(&video_codec_context);
    _ = libav.formatFreeContext(format_context);
}

fn writeFrame(pixels: [*]const PixelType, frame_index: u32) !void {
    //
    // Prepare frame
    //
    const stride = [1]i32{4 * @intCast(i32, context.dimensions.width)};
    video_frame = libav.frameAlloc() orelse return error.AllocateFrameFailed;

    //
    // NOTE: intToPtr used here instead of ptrCast to get rid of const qualifier.
    //       The pixels won't be modified, but I'd need to port AVFrame to zig
    //       to add that constaint and appease the type system
    //
    video_frame.data[0] = @intToPtr([*]u8, @ptrToInt(pixels));
    video_frame.linesize[0] = stride[0];
    video_frame.format = libav.PIXEL_FORMAT_RGB0; // @enumToInt(libav.PixelFormat.RGB0);
    video_frame.width = @intCast(i32, context.dimensions.width);
    video_frame.height = @intCast(i32, context.dimensions.height);

    video_frame.pts = frame_index;

    var code = libav.buffersrcAddFrameFlags(video_filter_source_context, video_frame, 0);
    if (code < 0) {
        std.log.err("Failed to add frame to source", .{});
        return;
    }

    while (true) {
        var filtered_frame: *libav.Frame = libav.frameAlloc() orelse return error.AllocateFilteredFrameFailed;
        code = libav.buffersinkGetFrame(
            video_filter_sink_context,
            filtered_frame,
        );
        if (code < 0) {
            //
            // End of stream
            //
            if (code == libav.ERROR_EOF) return;
            //
            // No error, just no frames to read
            //
            if (code == EAGAIN) break;
            //
            // An actual error
            //
            std.log.err("Failed to get filtered frame", .{});
            libav.frameFree(&filtered_frame);
            return error.GetFilteredFrameFailed;
        }

        filtered_frame.pict_type = libav.AV_PICTURE_TYPE_NONE;
        var packet: libav.Packet = undefined;
        libav.initPacket(&packet);
        packet.data = null;
        packet.size = 0;

        try encodeFrame(filtered_frame, &packet);
        libav.frameFree(&filtered_frame);
    }
    libav.frameFree(&video_frame);
}

fn encodeFrame(filtered_frame: ?*libav.Frame, packet: *libav.Packet) !void {
    var code = libav.codecSendFrame(video_codec_context, filtered_frame);
    if (code < 0) {
        std.log.err("Failed to send frame for encoding", .{});
        return error.EncodeFrameFailed;
    }

    while (code >= 0) {
        code = libav.codecReceivePacket(video_codec_context, packet);
        if (code == EAGAIN or code == libav.ERROR_EOF)
            return;
        if (code < 0) {
            std.log.err("Failed to recieve encoded frame (packet)", .{});
            return error.ReceivePacketFailed;
        }
        //
        // Finish Frame
        //
        libav.packetRescaleTS(packet, video_codec_context.time_base, video_stream.time_base);
        packet.stream_index = video_stream.index;

        code = libav.interleavedWriteFrame(format_context, packet);
        if (code != 0) {
            std.log.warn("Interleaved write frame failed", .{});
        }
        libav.packetUnref(packet);
    }
}

fn initVideoFilters(options: RecordOptions) !void {
    video_filter_graph = libav.filterGraphAlloc();
    _ = libav.optSet(@ptrCast(*void, video_filter_graph), "scale_sws_opts", "flags=fast_bilinear:src_range=1:dst_range=1", 0);

    const source = libav.filterGetByName("buffer") orelse return error.FailedToGetSourceFilter;
    const sink = libav.filterGetByName("buffersink") orelse return error.FailedToGetSinkFilter;

    var buffer_filter_config_buffer: [512]u8 = undefined;
    const buffer_filter_config = try std.fmt.bufPrintZ(
        buffer_filter_config_buffer[0..],
        "video_size={d}x{d}:pix_fmt={d}:time_base={d}/{d}:pixel_aspect=1/1",
        .{
            1920,
            1080,
            libav.PIXEL_FORMAT_RGB0,
            1,
            options.fps,
        },
    );

    var code = libav.filterGraphCreateFilter(
        &video_filter_source_context,
        source,
        "Source",
        buffer_filter_config,
        null,
        video_filter_graph,
    );
    if (code < 0) {
        std.log.err("Failed to create video source filter", .{});
        return error.CreateVideoSourceFilterFailed;
    }

    code = libav.filterGraphCreateFilter(
        &video_filter_sink_context,
        sink,
        "Sink",
        null,
        null,
        video_filter_graph,
    );
    if (code < 0) {
        std.log.err("Failed to create video sink filter", .{});
        return error.CreateVideoSinkFilterFailed;
    }

    const supported_pixel_formats = [2]libav.PixelFormat{
        .YUV444P,
        .NONE,
    };

    code = libav.optSetBin(
        @ptrCast(*void, video_filter_sink_context),
        "pix_fmts",
        @ptrCast([*]const u8, &supported_pixel_formats),
        @sizeOf(libav.PixelFormat),
        libav.AV_OPT_SEARCH_CHILDREN,
    );
    if (code < 0) {
        std.log.err("Failed to set pix_fmt option", .{});
        return error.SetPixFmtOptionFailed;
    }

    var outputs: *libav.FilterInOut = libav.filterInOutAlloc() orelse return error.AllocateInputFilterFailed;
    outputs.name = libav.strdup("in") orelse return error.LibavOutOfMemory;
    outputs.filter_ctx = video_filter_source_context;
    outputs.pad_idx = 0;
    outputs.next = null;

    var inputs: *libav.FilterInOut = libav.filterInOutAlloc() orelse return error.AllocateOutputFilterFailed;
    inputs.name = libav.strdup("out");
    inputs.filter_ctx = video_filter_sink_context;
    inputs.pad_idx = 0;
    inputs.next = null;

    code = libav.filterGraphParsePtr(
        video_filter_graph,
        "null",
        &inputs,
        &outputs,
        null,
    );
    if (code < 0) {
        std.log.err("Failed to parse graph filter", .{});
        return error.ParseGraphFilterFailed;
    }

    if (hw_device_context) |frame_context| {
        std.debug.assert(false);
        var i: usize = 0;
        while (i < video_filter_graph.nb_filters) : (i += 1) {
            video_filter_graph.filters[i][0].hw_device_ctx = libav.bufferRef(frame_context);
        }
    }

    code = libav.filterGraphConfig(video_filter_graph, null);
    if (code < 0) {
        std.log.err("Failed to configure graph filter", .{});
        return error.ConfigureGraphFilterFailed;
    }

    const filter_output: *libav.FilterLink = video_filter_sink_context.inputs[0];
    video_codec_context.width = filter_output.w;
    video_codec_context.height = filter_output.h;
    video_codec_context.pix_fmt = filter_output.format;
    video_codec_context.time_base = .{ .num = 1, .den = @intCast(i32, options.fps) };
    video_codec_context.framerate = filter_output.frame_rate;
    video_codec_context.sample_aspect_ratio = filter_output.sample_aspect_ratio;

    hw_frame_context = libav.buffersinkGetHwFramesCtx(video_filter_sink_context);

    libav.filterInOutFree(&inputs);
    libav.filterInOutFree(&outputs);
}
