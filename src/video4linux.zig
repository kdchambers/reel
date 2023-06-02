// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;
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

var decoder_context: *av.CodecContext = undefined;
var format_context: *av.FormatContext = undefined;
var video_frame: ?*av.Frame = undefined;
var converted_frame: ?*av.Frame = undefined;
var input_format: *av.InputFormat = undefined;
var video_stream: ?*av.Stream = undefined;
var video_dst_data: [4][*]u8 = undefined;
var video_dst_linesize: [4]i32 = undefined;
var video_dst_bufsize: i32 = undefined;
var video_stream_index: i32 = 0;
var packet: *av.Packet = undefined;
var video_frame_count: i32 = 0;
var initialized: bool = false;
var device_buffer: [8]Device = undefined;
var device_count: u32 = 0;

var opened_stream_count: u32 = 0;
var opened_stream_buffer: [8]u16 = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    if (builtin.mode == .Debug)
        av.logSetLevel(libav.AV_LOG_DEBUG);
    av.deviceRegisterAll();
    input_format = av.findInputFormat("video4linux2") orelse return error.GetInputFormatFail;
    initialized = true;

    var path_buffer: [256]u8 = undefined;
    var name_path_buffer: [256]u8 = undefined;

    var device_index: usize = 0;
    register_devices: while (device_count < 64) : (device_index += 1) {
        const device_path = std.fmt.bufPrint(&path_buffer, "/dev/video{d}", .{device_index}) catch continue;
        //
        // We assume devices are named sequencially from 0..N without gaps. Once we reach device that
        // doesn't exist we break.
        //
        std.fs.accessAbsolute(device_path, .{}) catch break;
        const device_name_path = std.fmt.bufPrint(&name_path_buffer, "/sys/class/video4linux/video{d}/name", .{device_index}) catch continue;
        const file_handle = std.fs.cwd().openFile(device_name_path, .{ .mode = .read_only }) catch continue;
        defer file_handle.close();

        const max_size_bytes = 1024;
        const device_name_untrimmed = file_handle.readToEndAlloc(allocator, max_size_bytes) catch continue;
        //
        // Remove the newline char at the end of the file
        //
        const device_name = std.mem.trimRight(u8, device_name_untrimmed, "\n");
        std.log.info("video4linux device found: {s}", .{device_name});

        var index: usize = 0;
        while (index < device_index) : (index += 1) {
            //
            // If we've already enumerated a device with this name, just skip
            // TODO: Obviously this should use a proper ID instead of name
            //
            if (std.mem.eql(u8, device_buffer[@intCast(usize, index)].name, device_name)) {
                std.log.warn("Skipping \"{s}\". Device already registered", .{device_name});
                allocator.free(device_name_untrimmed);
                continue :register_devices;
            }
        }
        device_buffer[device_index].name = device_name;
        device_buffer[device_index].path = try allocator.dupeZ(u8, device_path);
        device_buffer[device_index].allocated_name_size = @intCast(u16, device_name_untrimmed.len);
        device_count += 1;
    }
}

pub const Device = struct {
    name: []const u8,
    path: [:0]const u8,

    //
    // We trim the end of the `name` field, so we retain this length
    // so that we can pass back the original slice to the allocator
    //
    allocated_name_size: u16,
};

pub fn devices() []const Device {
    return device_buffer[0..device_count];
}

pub fn open(
    device_index: u32,
    wanted_dimensions: geometry.Dimensions2D(u32),
) !void {
    assert(initialized);

    var ret_code: i32 = 0;
    var options: ?*av.Dictionary = null;

    format_context = av.formatAllocContext() orelse return error.AllocateFormatContextFail;
    format_context.flags |= libav.AVFMT_FLAG_NONBLOCK;

    _ = av.dictSet(&options, "framerate", "60", 0);

    var dimensions_buffer: [64]u8 = undefined;
    const dimensions_string = std.fmt.bufPrintZ(&dimensions_buffer, "{d}x{d}", .{
        wanted_dimensions.width,
        wanted_dimensions.height,
    }) catch unreachable;
    _ = av.dictSet(&options, "video_size", dimensions_string, 0);

    ret_code = av.formatOpenInput(
        &format_context,
        device_buffer[device_index].path,
        input_format,
        &options,
    );
    if (ret_code < 0) {
        var error_message_buffer: [512]u8 = undefined;
        _ = av.strError(ret_code, &error_message_buffer, 512);
        std.log.err("Failed to open webcam device. Error ({d}): {s}", .{ ret_code, error_message_buffer });
        return error.OpenInputFail;
    }

    ret_code = av.formatFindStreamInfo(format_context, null);
    if (ret_code < 0) {
        return error.FindStreamInfoFail;
    }

    var codec_params: libav.AVCodecParameters = undefined;
    var stream: *av.Stream = undefined;
    var decoder: ?*av.Codec = null;
    var codec_options: ?*av.Dictionary = null;

    ret_code = av.findBestStream(format_context, libav.AVMEDIA_TYPE_VIDEO, -1, -1, null, 0);
    if (ret_code < 0)
        return error.FindBestStreamFail;

    video_stream_index = ret_code;
    stream = format_context.streams[@intCast(usize, video_stream_index)];

    const codec_id = @intToEnum(av.CodecID, stream.codecpar[0].codec_id);
    decoder = av.codecFindDecoder(codec_id);
    if (decoder == null)
        return error.FindDecoderFail;

    _ = av.dictSet(&codec_options, "refcounted_frames", "1", 0);

    decoder_context = libav.avcodec_alloc_context3(decoder);

    const stream_codec_params = stream.codecpar[0];
    decoder_context.width = stream_codec_params.width;
    decoder_context.height = stream_codec_params.height;
    decoder_context.pix_fmt = stream_codec_params.format;

    std.log.info("Opening decoder. Dimensions {d}x{d} pixel format: {d}", .{
        decoder_context.width,
        decoder_context.height,
        decoder_context.pix_fmt,
    });

    ret_code = av.codecOpen2(decoder_context, decoder.?, &codec_options);
    if (ret_code < 0)
        return error.OpenDecoderFail;

    ret_code = libav.avcodec_parameters_from_context(stream.codecpar, decoder_context);
    if (ret_code < 0)
        return error.CopyContextParametersFail;

    video_stream = format_context.streams[@intCast(usize, video_stream_index)];
    codec_params = video_stream.?.codecpar[0];
    ret_code = av.imageAlloc(
        &video_dst_data,
        &video_dst_linesize,
        codec_params.width,
        codec_params.height,
        codec_params.format,
        1,
    );

    if (ret_code < 0)
        return error.AllocateImageFail;

    video_dst_bufsize = ret_code;

    if (builtin.mode == .Debug)
        av.dumpFormat(format_context, 0, device_buffer[device_index].path, 0);

    if (video_stream == null)
        return error.SetupVideoStreamFail;

    video_frame = av.frameAlloc();
    if (video_frame == null)
        return error.AllocateVideoFrameFail;

    packet = libav.av_packet_alloc();
    converted_frame = av.frameAlloc();
    ret_code = libav.av_image_alloc(
        @ptrCast([*c][*c]u8, &converted_frame.?.data[0]),
        &converted_frame.?.linesize,
        decoder_context.width,
        decoder_context.height,
        libav.AV_PIX_FMT_RGBA,
        1,
    );
}

pub fn dimensions() geometry.Dimensions2D(u32) {
    return .{
        .width = @intCast(u32, decoder_context.width),
        .height = @intCast(u32, decoder_context.height),
    };
}

pub fn flushFrameBuffer() void {
    var ret_code: i32 = 0;
    while (ret_code == 0) {
        ret_code = libav.av_read_frame(format_context, packet);
    }
}

pub fn getFrame(
    output_buffer: [*]graphics.RGBA(u8),
    dst_offset_x: u32,
    dst_offset_y: u32,
    stride: u32,
) !bool {
    var ret_code = libav.av_read_frame(format_context, packet);

    if (ret_code < 0) {
        //
        // There is no new output to read, return false to indicate that
        // no new frame was copied into `output_buffer`
        //
        if (ret_code == EAGAIN) {
            return false;
        }
        return error.ReadFrameFail;
    }

    if (packet.stream_index != video_stream_index)
        return error.InvalidFrame;

    //
    // Send encoded packet to decoder
    //
    ret_code = av.codecSendPacket(decoder_context, packet);

    if (ret_code != 0)
        return error.DecodePacketFail;

    //
    // Read decoded frame from decoder
    //
    ret_code = av.codecReceiveFrame(decoder_context, video_frame.?);
    if (ret_code == EAGAIN)
        return error.again;

    if (ret_code != 0)
        return error.EncodeFrameFailed;

    //
    // We have a decoded frame, but we need to convert it into our desired
    // pixel format before returning
    //

    const width = @intCast(usize, decoder_context.width);
    const height = @intCast(usize, decoder_context.height);

    var conversion = libav.sws_getContext(
        decoder_context.width,
        decoder_context.height,
        decoder_context.pix_fmt,
        decoder_context.width,
        decoder_context.height,
        libav.AV_PIX_FMT_RGBA,
        libav.SWS_FAST_BILINEAR | libav.SWS_FULL_CHR_H_INT | libav.SWS_ACCURATE_RND,
        null,
        null,
        null,
    );
    _ = libav.sws_scale(
        conversion,
        &video_frame.?.data,
        &video_frame.?.linesize,
        0,
        decoder_context.height,
        &converted_frame.?.data,
        &converted_frame.?.linesize,
    );
    libav.sws_freeContext(conversion);
    libav.av_packet_unref(packet);

    const pixel_count = width * height;

    const src_stride = @intCast(usize, @divExact(converted_frame.?.linesize[0], @sizeOf(graphics.RGBA(u8))));

    const frame_pixels = @ptrCast([*]graphics.RGBA(u8), &converted_frame.?.data[0][0])[0..pixel_count];

    var dst_x = dst_offset_x;
    var dst_y = dst_offset_y;
    var dst_index = (dst_y * stride) + dst_x;
    var src_index: usize = 0;
    for (0..height) |_| {
        std.mem.copy(
            graphics.RGBA(u8),
            output_buffer[dst_index .. dst_index + width],
            frame_pixels[src_index .. src_index + width],
        );
        src_index += src_stride;
        dst_index += stride;
    }
    video_frame_count += 1;
    return true;
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (!initialized)
        return;

    for (device_buffer[0..device_count]) |*device| {
        allocator.free(device.path);
        allocator.free(device.name.ptr[0..device.allocated_name_size]);
    }

    if (opened_stream_count == 0)
        return;

    libav.av_packet_unref(packet);
    libav.av_freep(@ptrCast(*anyopaque, &converted_frame.?.data[0]));
    libav.av_frame_free(&video_frame);
    libav.av_frame_free(&converted_frame);
    libav.av_free(video_dst_data[0]);

    _ = libav.avcodec_close(decoder_context);
    libav.avformat_close_input(
        @ptrCast([*c][*c]av.FormatContext, &format_context),
    );
}
