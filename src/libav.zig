// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

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

pub const EAGAIN: i32 = -11;
pub const EINVAL: i32 = -22;

pub const LOG_DEBUG = libav.AV_LOG_DEBUG;

pub const CodecContext = libav.AVCodecContext;
pub const FormatContext = libav.AVFormatContext;
pub const OutputFormat = libav.AVOutputFormat;
pub const Frame = libav.AVFrame;
pub const Stream = libav.AVStream;
pub const Packet = libav.AVPacket;
pub const InputFormat = libav.AVInputFormat;
pub const MediaType = libav.AVMediaType;
pub const Dictionary = libav.AVDictionary;
pub const Codec = libav.AVCodec;
pub const FilterGraph = libav.AVFilterGraph;

pub extern fn av_dict_set(dict: *?*Dictionary, key: [*:0]const u8, value: [*:0]const u8, flags: i32) callconv(.C) i32;
pub extern fn av_dict_free(dict: **Dictionary) callconv(.C) void;
pub extern fn av_frame_alloc() callconv(.C) *Frame;
pub extern fn av_frame_unref(frame: *Frame) callconv(.C) void;
pub extern fn av_log_set_level(level: i32) callconv(.C) void;
pub extern fn av_find_input_format(short_name: [*:0]const u8) callconv(.C) ?*InputFormat;
pub extern fn av_guess_format(short_name: ?[*:0]const u8, filename: [*:0]const u8, mime_type: ?[*:0]const u8) ?*OutputFormat;
pub extern fn avcodec_find_encoder(codec_id: CodecID) ?*Codec;

pub extern fn avformat_alloc_output_context2(
    context: *?*FormatContext,
    oformat: ?*OutputFormat,
    format_name: ?[*:0]const u8,
    filename: ?[*:0]const u8,
) callconv(.C) i32;

pub extern fn av_find_best_stream(
    ic: *FormatContext,
    media_type: MediaType,
    wanted_stream: i32,
    related_stream: i32,
    out_decoder: ?**Codec,
    flags: i32,
) callconv(.C) i32;

pub extern fn av_dump_format(
    format_context: *FormatContext,
    index: i32,
    url: [*:0]const u8,
    is_output: i32,
) callconv(.C) void;

pub extern fn av_image_alloc(
    pointers: [*][*]u8,
    linesizes: *[4]i32,
    width: i32,
    height: i32,
    pixel_format: libav.AVPixelFormat,
    alignment: i32,
) callconv(.C) i32;

pub extern fn avcodec_find_decoder(id: CodecID) callconv(.C) *Codec;
pub extern fn avcodec_open2(context: *CodecContext, codec: *const Codec, options: *?*Dictionary) callconv(.C) i32;
pub extern fn avcodec_send_packet(context: *CodecContext, packet: *const Packet) callconv(.C) i32;
pub extern fn avcodec_receive_frame(context: *CodecContext, frame: *Frame) callconv(.C) i32;
pub extern fn avcodec_alloc_context3(codec: ?*Codec) ?*CodecContext;

pub extern fn avdevice_register_all() callconv(.C) void;

pub extern fn avformat_alloc_context() callconv(.C) ?*FormatContext;
pub extern fn avformat_open_input(
    format_context: **FormatContext,
    input_path: [*:0]const u8,
    input_format: *InputFormat,
    options: *?*Dictionary,
) callconv(.C) i32;
pub extern fn avformat_find_stream_info(format_context: *FormatContext, options: ?*?*Dictionary) callconv(.C) i32;
pub extern fn avformat_new_stream(stream_context: *FormatContext, codec: *Codec) ?*Stream;

pub const guessFormat = av_guess_format;
pub const formatAllocOutputContext2 = avformat_alloc_output_context2;
pub const codecFindEncoder = avcodec_find_encoder;

pub const dictSet = av_dict_set;
pub const dictFree = av_dict_free;
pub const frameUnref = av_frame_unref;
pub const frameAlloc = av_frame_alloc;
pub const logSetLevel = av_log_set_level;
pub const findInputFormat = av_find_input_format;
pub const findBestStream = av_find_best_stream;
pub const dumpFormat = av_dump_format;
pub const imageAlloc = av_image_alloc;

pub const deviceRegisterAll = avdevice_register_all;

pub const formatFindStreamInfo = avformat_find_stream_info;
pub const formatOpenInput = avformat_open_input;
pub const formatAllocContext = avformat_alloc_context;
pub const formatNewStream = avformat_new_stream;

pub const codecReceiveFrame = avcodec_receive_frame;
pub const codecSendPacket = avcodec_send_packet;
pub const codecOpen2 = avcodec_open2;
pub const codecFindDecoder = avcodec_find_decoder;
pub const codecAllocContext3 = avcodec_alloc_context3;

pub const ColorRange = enum(u32) {
    unspecified = 0,
    mpeg = 1,
    jpeg = 2,
};

pub const CodecID = enum(i32) {
    none = 0,
    MPEG1VIDEO,
    MPEG2VIDEO,
    H261,
    H263,
    RV10,
    RV20,
    MJPEG,
    MJPEGB,
    LJPEG,
    SP5X,
    JPEGLS,
    MPEG4,
    RAWVIDEO,
    MSMPEG4V1,
    MSMPEG4V2,
    MSMPEG4V3,
    WMV1,
    WMV2,
    H263P,
    H263I,
    FLV1,
    SVQ1,
    SVQ3,
    DVVIDEO,
    HUFFYUV,
    CYUV,
    h264,
    INDEO3,
    VP3,
    THEORA,
    ASV1,
    ASV2,
    FFV1,
    @"4XM",
    VCR1,
    CLJR,
    MDEC,
    ROQ,
    INTERPLAY_VIDEO,
    XAN_WC3,
    XAN_WC4,
    RPZA,
    CINEPAK,
    WS_VQA,
    MSRLE,
    MSVIDEO1,
    IDCIN,
    @"8BPS",
    SMC,
    FLIC,
    TRUEMOTION1,
    VMDVIDEO,
    MSZH,
    ZLIB,
    QTRLE,
    TSCC,
    ULTI,
    QDRAW,
    VIXL,
    QPEG,
    PNG,
    PPM,
    PBM,
    PGM,
    PGMYUV,
    PAM,
    FFVHUFF,
    RV30,
    RV40,
    VC1,
    WMV3,
    LOCO,
    WNV1,
    AASC,
    INDEO2,
    FRAPS,
    TRUEMOTION2,
    BMP,
    CSCD,
    MMVIDEO,
    ZMBV,
    AVS,
    SMACKVIDEO,
};

pub const PixelFormat = enum(i32) {
    YUV420P = 0,
    YUYV422,
    RGB24,
    BGR24,
    YUV422P,
    YUV444P,
    YUV410P,
    YUV411P,
    GRAY8,
    MONOWHITE,
    MONOBLACK,
    PAL8,
    YUVJ420P,
    YUVJ422P,
    YUVJ444P,
    UYVY422,
    UYYVYY411,
    BGR8,
    BGR4,
    BGR4_BYTE,
    RGB8,
    RGB4,
    RGB4_BYTE,
    NV12,
    NV21,
    ARGB,
    RGBA,
    ABGR,
    BGRA,
    GRAY16BE,
    GRAY16LE,
    YUV440P,
    YUVJ440P,
    YUVA420P,
    RGB48BE,
    RGB48LE,
    RGB565BE,
    RGB565LE,
    RGB555BE,
    RGB555LE,
    VAAPI,
    YUV420P16LE,
    YUV420P16BE,
    YUV422P16LE,
    YUV422P16BE,
    YUV444P16LE,
    YUV444P16BE,
    DXVA2_VLD,
    RGB444LE,
    RGB444BE,
    BGR444LE,
    BGR444BE,
    YA8,
    BGR48BE,
    BGR48LE,
    YUV420P9BE,
    YUV420P9LE,
    YUV420P10BE,
    YUV420P10LE,
    YUV422P10BE,
    YUV422P10LE,
    YUV444P9BE,
    YUV444P9LE,
    YUV444P10BE,
    YUV444P10LE,
    YUV422P9BE,
    YUV422P9LE,
    GBRP,
    GBRP9BE,
    GBRP9LE,
    GBRP10BE,
    GBRP10LE,
    GBRP16BE,
    GBRP16LE,
    YUVA422P,
    YUVA444P,
    YUVA420P9BE,
    YUVA420P9LE,
    YUVA422P9BE,
    YUVA422P9LE,
    YUVA444P9BE,
    YUVA444P9LE,
    YUVA420P10BE,
    YUVA420P10LE,
    YUVA422P10BE,
    YUVA422P10LE,
    YUVA444P10BE,
    YUVA444P10LE,
    YUVA420P16BE,
    YUVA420P16LE,
    YUVA422P16BE,
    YUVA422P16LE,
    YUVA444P16BE,
    YUVA444P16LE,
    VDPAU,
    XYZ12LE,
    XYZ12BE,
    NV16,
    NV20LE,
    NV20BE,
    RGBA64BE,
    RGBA64LE,
    BGRA64BE,
    BGRA64LE,
    YVYU422,
    YA16BE,
    YA16LE,
    GBRAP,
    GBRAP16BE,
    GBRAP16LE,
    QSV,
    MMAL,
    D3D11VA_VLD,
    CUDA,
    @"0RGB",
    RGB0,
    @"0BGR",
    BGR0,
    YUV420P12BE,
    YUV420P12LE,
    YUV420P14BE,
    YUV420P14LE,
    YUV422P12BE,
    YUV422P12LE,
    YUV422P14BE,
    YUV422P14LE,
    YUV444P12BE,
    YUV444P12LE,
    YUV444P14BE,
    YUV444P14LE,
    GBRP12BE,
    GBRP12LE,
    GBRP14BE,
    GBRP14LE,
    YUVJ411P,
    BAYER_BGGR8,
    BAYER_RGGB8,
    BAYER_GBRG8,
    BAYER_GRBG8,
    BAYER_BGGR16LE,
    BAYER_BGGR16BE,
    BAYER_RGGB16LE,
    BAYER_RGGB16BE,
    BAYER_GBRG16LE,
    BAYER_GBRG16BE,
    BAYER_GRBG16LE,
    BAYER_GRBG16BE,
    XVMC,
    YUV440P10LE,
    YUV440P10BE,
    YUV440P12LE,
    YUV440P12BE,
    AYUV64LE,
    AYUV64BE,
    VIDEOTOOLBOX,
    P010LE,
    P010BE,
    GBRAP12BE,
    GBRAP12LE,
    GBRAP10BE,
    GBRAP10LE,
    MEDIACODEC,
    GRAY12BE,
    GRAY12LE,
    GRAY10BE,
    GRAY10LE,
    P016LE,
    P016BE,
    D3D11,
    GRAY9BE,
    GRAY9LE,
    GBRPF32BE,
    GBRPF32LE,
    GBRAPF32BE,
    GBRAPF32LE,
    DRM_PRIME,
    OPENCL,
    GRAY14BE,
    GRAY14LE,
    GRAYF32BE,
    GRAYF32LE,
    YUVA422P12BE,
    YUVA422P12LE,
    YUVA444P12BE,
    YUVA444P12LE,
    NV24,
    NV42,
    VULKAN,
    Y210BE,
    Y210LE,
    X2RGB10LE,
    X2RGB10BE,
    NB,
};
