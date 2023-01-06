// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const libav = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libavdevice/avdevice.h");
    @cInclude("libswscale/swscale.h");
    @cInclude("libavfilter/avfilter.h");
    @cInclude("libavfilter/buffersink.h");
    @cInclude("libavfilter/buffersrc.h");
});

const EAGAIN: i32 = -11;
const EINVAL: i32 = -22;

var avframe: *libav.AVFrame = undefined;
var video_codec_context: *libav.AVCodecContext = undefined;
var sws_context: *libav.SwsContext = undefined;
var format_context: *libav.AVFormatContext = undefined;
var video_stream: *libav.AVStream = undefined;
var output_format: *libav.AVOutputFormat = undefined;
var video_filter_source_context: *libav.AVFilterContext = undefined;
var video_filter_sink_context: *libav.AVFilterContext = undefined;
var video_filter_graph: *libav.AVFilterGraph = undefined;
var hw_device_context: ?*libav.AVBufferRef = null;
var hw_frame_context: ?*libav.AVBufferRef = null;
var video_frame: *libav.AVFrame = undefined;

fn init() void {
    if (builtin.mode == .Debug)
        libav.av_log_set_level(libav.AV_LOG_DEBUG);

    output_format = libav.av_guess_format(null, output_file_path, null) orelse {
        std.log.err("Failed to determine output format", .{});
        return;
    };

    var ret_code: i32 = 0;
    ret_code = libav.avformat_alloc_output_context2(
        @ptrCast([*c][*c]libav.AVFormatContext, &format_context),
        null,
        "mp4",
        output_file_path,
    );
    std.debug.assert(ret_code == 0);

    const video_codec: *libav.AVCodec = libav.avcodec_find_encoder(libav.AV_CODEC_ID_H264);
    video_stream = libav.avformat_new_stream(format_context, video_codec) orelse {
        std.log.err("Failed to create video stream", .{});
        return;
    };

    video_codec_context = libav.avcodec_alloc_context3(video_codec);

    video_codec_context.width = 1920;
    video_codec_context.height = 1080;
    video_codec_context.color_range = libav.AVCOL_RANGE_JPEG;
    video_codec_context.bit_rate = 400000;
    video_codec_context.time_base = .{ .num = 1000, .den = input_fps * 1000 };
    video_codec_context.gop_size = 10;
    video_codec_context.max_b_frames = 1;
    video_codec_context.pix_fmt = libav.AV_PIX_FMT_YUV420P;

    initVideoFilters() catch |err| {
        std.log.err("Failed to init video filters. Error: {}", .{err});
        return;
    };

    if (hw_frame_context) |context| {
        video_codec_context.hw_frames_ctx = libav.av_buffer_ref(context);
    }

    var options: ?*libav.AVDictionary = null;

    _ = libav.av_dict_set(&options, "preset", "ultrafast", 0);
    _ = libav.av_dict_set(&options, "crf", "35", 0);
    _ = libav.av_dict_set(&options, "tune", "zerolatency", 0);

    if (libav.avcodec_open2(video_codec_context, video_codec, &options) < 0) {
        std.log.err("Failed to open codec", .{});
        return;
    }
    libav.av_dict_free(&options);

    if (libav.avcodec_parameters_from_context(video_stream.codecpar, video_codec_context) < 0) {
        std.log.err("Failed to avcodec_parameters_from_context", .{});
        return;
    }

    libav.av_dump_format(format_context, 0, output_file_path, 1);

    ret_code = libav.avio_open(
        @ptrCast([*c][*c]libav.AVIOContext, &format_context.pb),
        output_file_path,
        libav.AVIO_FLAG_WRITE,
    );
    if (ret_code < 0) {
        std.log.err("Failed to open AVIO context", .{});
        return error.OpenAVIOContextFailed;
    }

    var dummy_dict: ?*libav.AVDictionary = null;
    ret_code = libav.avformat_write_header(
        format_context,
        @ptrCast([*c]?*libav.AVDictionary, &dummy_dict),
    );
    if (ret_code < 0) {
        std.log.err("Failed to write screen recording header", .{});
        return error.WriteFormatHeaderFailed;
    }

    libav.av_dict_free(&dummy_dict);
}

fn finishVideoStream() void {
    var packet: libav.AVPacket = undefined;
    libav.av_init_packet(&packet);

    try encodeFrame(null, &packet);
    _ = libav.av_write_trailer(format_context);
    _ = libav.avio_closep(
        @ptrCast([*c][*c]libav.AVIOContext, &format_context.pb),
    );

    _ = libav.avcodec_free_context(@ptrCast([*c][*c]libav.AVCodecContext, &video_codec_context));
    _ = libav.avformat_free_context(format_context);

    std.log.info("Terminated cleanly", .{});
}

fn writeVideoFrame(current_frame_index: u32) !void {
    //
    // Prepare frame
    //
    const stride = [1]i32{4 * @intCast(i32, screen_capture_info.width)};
    video_frame = libav.av_frame_alloc() orelse return error.AllocateFrameFailed;

    video_frame.data[0] = shared_memory_map.ptr;
    video_frame.linesize[0] = stride[0];
    video_frame.format = libav.AV_PIX_FMT_RGB0;
    video_frame.width = @intCast(i32, screen_capture_info.width);
    video_frame.height = @intCast(i32, screen_capture_info.height);

    video_frame.pts = current_frame_index;

    var code = libav.av_buffersrc_add_frame_flags(video_filter_source_context, video_frame, 0);
    if (code < 0) {
        std.log.err("Failed to add frame to source", .{});
        return;
    }

    while (true) {
        var filtered_frame: *libav.AVFrame = libav.av_frame_alloc() orelse return error.AllocateFilteredFrameFailed;
        code = libav.av_buffersink_get_frame(
            video_filter_sink_context,
            @ptrCast([*]libav.AVFrame, filtered_frame),
        );
        if (code < 0) {
            //
            // End of stream
            //
            if (code == libav.AVERROR_EOF) return;
            //
            // No error, just no frames to read
            //
            if (code == EAGAIN) break;
            //
            // An actual error
            //
            std.log.err("Failed to get filtered frame", .{});
            libav.av_frame_free(@ptrCast([*c][*c]libav.AVFrame, &filtered_frame));
            return error.GetFilteredFrameFailed;
        }

        filtered_frame.pict_type = libav.AV_PICTURE_TYPE_NONE;
        var packet: libav.AVPacket = undefined;
        libav.av_init_packet(&packet);
        packet.data = null;
        packet.size = 0;

        try encodeFrame(filtered_frame, &packet);
        libav.av_frame_free(@ptrCast([*c][*c]libav.AVFrame, &filtered_frame));
    }
    libav.av_frame_free(@ptrCast([*c][*c]libav.AVFrame, &video_frame));
}

fn encodeFrame(filtered_frame: ?*libav.AVFrame, packet: *libav.AVPacket) !void {
    var code = libav.avcodec_send_frame(video_codec_context, filtered_frame);
    if (code < 0) {
        std.log.err("Failed to send frame for encoding", .{});
        return error.EncodeFrameFailed;
    }

    while (code >= 0) {
        code = libav.avcodec_receive_packet(video_codec_context, packet);
        if (code == EAGAIN or code == libav.AVERROR_EOF)
            return;
        if (code < 0) {
            std.log.err("Failed to recieve encoded frame (packet)", .{});
            return error.ReceivePacketFailed;
        }
        //
        // Finish Frame
        //
        libav.av_packet_rescale_ts(packet, video_codec_context.time_base, video_stream.time_base);
        packet.stream_index = video_stream.index;

        code = libav.av_interleaved_write_frame(format_context, packet);
        if (code != 0) {
            std.log.warn("Interleaved write frame failed", .{});
        }
        libav.av_packet_unref(packet);
    }
}

fn initVideoFilters() !void {
    video_filter_graph = libav.avfilter_graph_alloc() orelse return error.FailedToAllocateGraphFilter;
    _ = libav.av_opt_set(video_filter_graph, "scale_sws_opts", "flags=fast_bilinear:src_range=1:dst_range=1", 0);

    const source = libav.avfilter_get_by_name("buffer") orelse return error.FailedToGetSourceFilter;
    const sink = libav.avfilter_get_by_name("buffersink") orelse return error.FailedToGetSinkFilter;

    var buffer_filter_config_buffer: [512]u8 = undefined;
    const buffer_filter_config = try std.fmt.bufPrintZ(
        buffer_filter_config_buffer[0..],
        "video_size={d}x{d}:pix_fmt={d}:time_base={d}/{d}:pixel_aspect=1/1",
        .{
            1920,
            1080,
            libav.AV_PIX_FMT_RGB0,
            1000,
            input_fps * 1000,
        },
    );

    var code = libav.avfilter_graph_create_filter(
        @ptrCast([*c][*c]libav.AVFilterContext, &video_filter_source_context),
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

    code = libav.avfilter_graph_create_filter(
        @ptrCast([*c][*c]libav.AVFilterContext, &video_filter_sink_context),
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

    const supported_pixel_formats = [2]libav.AVPixelFormat{
        libav.AV_PIX_FMT_YUV420P,
        libav.AV_PIX_FMT_NONE,
    };

    code = libav.av_opt_set_bin(
        video_filter_sink_context,
        "pix_fmts",
        @ptrCast([*]const u8, &supported_pixel_formats),
        @sizeOf(libav.AVPixelFormat),
        libav.AV_OPT_SEARCH_CHILDREN,
    );
    if (code < 0) {
        std.log.err("Failed to set pix_fmt option", .{});
        return error.SetPixFmtOptionFailed;
    }

    var outputs: *libav.AVFilterInOut = libav.avfilter_inout_alloc() orelse return error.AllocateInputFilterFailed;
    outputs.name = libav.av_strdup("in");
    outputs.filter_ctx = video_filter_source_context;
    outputs.pad_idx = 0;
    outputs.next = null;

    var inputs: *libav.AVFilterInOut = libav.avfilter_inout_alloc() orelse return error.AllocateOutputFilterFailed;
    inputs.name = libav.av_strdup("out");
    inputs.filter_ctx = video_filter_sink_context;
    inputs.pad_idx = 0;
    inputs.next = null;

    code = libav.avfilter_graph_parse_ptr(
        video_filter_graph,
        "null",
        @ptrCast([*c][*c]libav.AVFilterInOut, &inputs),
        @ptrCast([*c][*c]libav.AVFilterInOut, &outputs),
        null,
    );
    if (code < 0) {
        std.log.err("Failed to parse graph filter", .{});
        return error.ParseGraphFilterFailed;
    }

    if (hw_device_context) |context| {
        std.debug.assert(false);
        var i: usize = 0;
        while (i < video_filter_graph.nb_filters) : (i += 1) {
            video_filter_graph.filters[i][0].hw_device_ctx = libav.av_buffer_ref(context);
        }
    }

    code = libav.avfilter_graph_config(video_filter_graph, null);
    if (code < 0) {
        std.log.err("Failed to configure graph filter", .{});
        return error.ConfigureGraphFilterFailed;
    }

    const filter_output: *libav.AVFilterLink = video_filter_sink_context.inputs[0];
    video_codec_context.width = filter_output.w;
    video_codec_context.height = filter_output.h;
    video_codec_context.pix_fmt = filter_output.format;
    video_codec_context.time_base = .{ .num = 1000, .den = input_fps * 1000 };
    video_codec_context.framerate = filter_output.frame_rate;
    video_codec_context.sample_aspect_ratio = filter_output.sample_aspect_ratio;

    hw_frame_context = libav.av_buffersink_get_hw_frames_ctx(video_filter_sink_context);

    libav.avfilter_inout_free(@ptrCast([*c][*c]libav.AVFilterInOut, &inputs));
    libav.avfilter_inout_free(@ptrCast([*c][*c]libav.AVFilterInOut, &outputs));
}
