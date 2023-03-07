// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");

const libav = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libavutil/samplefmt.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libavdevice/avdevice.h");
    @cInclude("libswscale/swscale.h");
    @cInclude("libavfilter/avfilter.h");
    @cInclude("libavfilter/buffersink.h");
    @cInclude("libavfilter/buffersrc.h");
});

const av = @import("libav.zig");
const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");

const EAGAIN: i32 = -11;
const EINVAL: i32 = -22;

pub const WebcamStream = struct {
    decoder_context: *av.CodecContext,
    format_context: *av.FormatContext,
    video_frame: ?*av.Frame,
    converted_frame: ?*av.Frame,
    input_format: *av.InputFormat,
    video_stream: ?*av.Stream,
    video_dst_data: [4][*]u8,
    video_dst_linesize: [4]i32,
    video_dst_bufsize: i32,
    video_stream_index: i32,
    packet: *av.Packet,
    video_frame_count: i32,

    pub fn create(
        input_name: [*:0]const u8,
        width: u32,
        height: u32,
        // desired_fps: u32,
    ) !@This() {
        _ = height;
        _ = width;

        var webcam_stream: WebcamStream = undefined;
        webcam_stream.video_frame_count = 0;

        var ret_code: i32 = 0;
        var options: ?*av.Dictionary = null;

        if (builtin.mode == .Debug)
            av.logSetLevel(libav.AV_LOG_DEBUG);

        av.deviceRegisterAll();

        webcam_stream.input_format = av.findInputFormat("video4linux2") orelse return error.GetInputFormatFail;

        webcam_stream.format_context = av.formatAllocContext() orelse return error.AllocateFormatContextFail;
        webcam_stream.format_context.flags |= libav.AVFMT_FLAG_NONBLOCK;

        _ = av.dictSet(&options, "framerate", "15", 0);
        _ = av.dictSet(&options, "video_size", "320x224", 0);

        ret_code = av.formatOpenInput(
            &webcam_stream.format_context,
            input_name,
            webcam_stream.input_format,
            &options,
        );
        if (ret_code < 0) {
            return error.OpenInputFail;
        }

        ret_code = av.formatFindStreamInfo(webcam_stream.format_context, null);
        if (ret_code < 0) {
            return error.FindStreamInfoFail;
        }

        var codec_params: libav.AVCodecParameters = undefined;
        var stream: *av.Stream = undefined;
        var decoder: ?*av.Codec = null;
        var codec_options: ?*av.Dictionary = null;

        ret_code = av.findBestStream(webcam_stream.format_context, libav.AVMEDIA_TYPE_VIDEO, -1, -1, null, 0);
        if (ret_code < 0)
            return error.FindBestStreamFail;

        webcam_stream.video_stream_index = ret_code;
        stream = webcam_stream.format_context.streams[@intCast(usize, webcam_stream.video_stream_index)];

        decoder = av.codecFindDecoder(stream.codecpar[0].codec_id);
        if (decoder == null)
            return error.FindDecoderFail;

        _ = av.dictSet(&codec_options, "refcounted_frames", "1", 0);

        webcam_stream.decoder_context = libav.avcodec_alloc_context3(decoder);

        const stream_codec_params = stream.codecpar[0];
        webcam_stream.decoder_context.width = stream_codec_params.width;
        webcam_stream.decoder_context.height = stream_codec_params.height;
        webcam_stream.decoder_context.pix_fmt = stream_codec_params.format;

        std.log.info("Opening decoder. Dimensions {d}x{d} pixel format: {d}", .{
            webcam_stream.decoder_context.width,
            webcam_stream.decoder_context.height,
            webcam_stream.decoder_context.pix_fmt,
        });

        ret_code = av.codecOpen2(webcam_stream.decoder_context, decoder.?, &codec_options);
        if (ret_code < 0)
            return error.OpenDecoderFail;

        ret_code = libav.avcodec_parameters_from_context(stream.codecpar, webcam_stream.decoder_context);
        if (ret_code < 0)
            return error.CopyContextParametersFail;

        webcam_stream.video_stream = webcam_stream.format_context.streams[@intCast(usize, webcam_stream.video_stream_index)];
        codec_params = webcam_stream.video_stream.?.codecpar[0];
        ret_code = av.imageAlloc(
            &webcam_stream.video_dst_data,
            &webcam_stream.video_dst_linesize,
            codec_params.width,
            codec_params.height,
            codec_params.format,
            1,
        );

        if (ret_code < 0)
            return error.AllocateImageFail;

        webcam_stream.video_dst_bufsize = ret_code;

        if (builtin.mode == .Debug)
            av.dumpFormat(webcam_stream.format_context, 0, input_name, 0);

        if (webcam_stream.video_stream == null)
            return error.SetupVideoStreamFail;

        webcam_stream.video_frame = av.frameAlloc();
        if (webcam_stream.video_frame == null)
            return error.AllocateVideoFrameFail;

        webcam_stream.packet = libav.av_packet_alloc();
        webcam_stream.converted_frame = av.frameAlloc();
        ret_code = libav.av_image_alloc(
            @ptrCast([*c][*c]u8, &webcam_stream.converted_frame.?.data[0]),
            &webcam_stream.converted_frame.?.linesize,
            webcam_stream.decoder_context.width,
            webcam_stream.decoder_context.height,
            libav.AV_PIX_FMT_RGBA,
            1,
        );

        return webcam_stream;
    }

    pub fn flushFrameBuffer(self: *@This()) void {
        var ret_code: i32 = 0;
        while (ret_code == 0) {
            ret_code = libav.av_read_frame(self.format_context, self.packet);
        }
    }

    pub fn getFrame(
        self: *@This(),
        output_buffer: [*]graphics.RGBA(f32),
        dst_x: u32,
        dst_y: u32,
        stride: u32,
    ) !void {
        var ret_code = libav.av_read_frame(self.format_context, self.packet);

        if (ret_code < 0) {
            if (ret_code == EAGAIN) {
                std.log.warn("getFrame: EAGAIN", .{});
                return;
            }
            return error.ReadFrameFail;
        }

        if (self.packet.stream_index != self.video_stream_index)
            return error.InvalidFrame;

        //
        // Send encoded packet to decoder
        //
        ret_code = av.codecSendPacket(self.decoder_context, self.packet);

        if (ret_code != 0)
            return error.DecodePacketFail;

        //
        // Read decoded frame from decoder
        //
        ret_code = av.codecReceiveFrame(self.decoder_context, self.video_frame.?);
        if (ret_code == EAGAIN)
            return error.again;

        if (ret_code != 0)
            return error.EncodeFrameFailed;

        //
        // We have a decoded frame, but we need to convert it into our desired
        // pixel format before returning
        //

        const width = @intCast(usize, self.decoder_context.width);
        const height = @intCast(usize, self.decoder_context.height);

        var conversion = libav.sws_getContext(
            self.decoder_context.width,
            self.decoder_context.height,
            self.decoder_context.pix_fmt,
            self.decoder_context.width,
            self.decoder_context.height,
            libav.AV_PIX_FMT_RGBA,
            libav.SWS_FAST_BILINEAR | libav.SWS_FULL_CHR_H_INT | libav.SWS_ACCURATE_RND,
            null,
            null,
            null,
        );
        _ = libav.sws_scale(
            conversion,
            &self.video_frame.?.data,
            &self.video_frame.?.linesize,
            0,
            self.decoder_context.height,
            &self.converted_frame.?.data,
            &self.converted_frame.?.linesize,
        );
        libav.sws_freeContext(conversion);
        libav.av_packet_unref(self.packet);

        const pixel_count = width * height;
        const frame_pixels = @ptrCast([*]graphics.RGBA(u8), &self.converted_frame.?.data[0][0])[0..pixel_count];
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const src_index = x + (y * width);
                const dst_index = (x + dst_x) + ((y + dst_y) * stride);
                output_buffer[dst_index].r = @intToFloat(f32, frame_pixels[src_index].r) / 255;
                output_buffer[dst_index].g = @intToFloat(f32, frame_pixels[src_index].g) / 255;
                output_buffer[dst_index].b = @intToFloat(f32, frame_pixels[src_index].b) / 255;
                output_buffer[dst_index].a = 1.0;
            }
        }
        self.video_frame_count += 1;
    }

    pub fn deinit(self: *@This()) !void {
        libav.av_packet_unref(self.packet);
        libav.av_freep(@ptrCast(*anyopaque, &self.converted_frame.?.data[0]));
        libav.av_frame_free(&self.video_frame);
        libav.av_frame_free(&self.converted_frame);
        libav.av_free(self.video_dst_data[0]);

        _ = libav.avcodec_close(self.decoder_context);
        libav.avformat_close_input(
            @ptrCast([*c][*c]av.FormatContext, &self.format_context),
        );
    }
};
