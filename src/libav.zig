// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

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
pub const AV_OPT_SEARCH_CHILDREN = libav.AV_OPT_SEARCH_CHILDREN;
pub const AVIO_FLAG_WRITE = libav.AVIO_FLAG_WRITE;
pub const ERROR_EOF = libav.AVERROR_EOF;
pub const AV_PICTURE_TYPE_NONE = libav.AV_PICTURE_TYPE_NONE;
pub const PIXEL_FORMAT_RGB0 = libav.AV_PIX_FMT_RGB0;

pub const CodecContext = libav.AVCodecContext;
pub const CodecParameters = libav.AVCodecParameters;
pub const BufferRef = libav.AVBufferRef;
pub const FormatContext = libav.AVFormatContext;
pub const OutputFormat = libav.AVOutputFormat;
pub const Frame = libav.AVFrame;
pub const Stream = libav.AVStream;
pub const Packet = libav.AVPacket;
pub const InputFormat = libav.AVInputFormat;
pub const IOContext = libav.AVIOContext;
pub const MediaType = libav.AVMediaType;
pub const Dictionary = libav.AVDictionary;
pub const Codec = libav.AVCodec;
pub const FilterGraph = libav.AVFilterGraph;
pub const FilterContext = libav.AVFilterContext;
pub const Filter = libav.AVFilter;
pub const FilterInOut = libav.AVFilterInOut;
pub const FilterLink = libav.AVFilterLink;
pub const Rational = libav.AVRational;

pub extern fn avio_open(
    context: *?*IOContext,
    url: [*:0]const u8,
    flags: i32,
) callconv(.C) i32;
pub extern fn avio_closep(context: **IOContext) callconv(.C) i32;

pub extern fn av_buffer_ref(buffer: *BufferRef) callconv(.C) ?*BufferRef;
pub extern fn av_buffersink_get_hw_frames_ctx(context: *FilterContext) callconv(.C) ?*BufferRef;
pub extern fn av_buffersink_get_frame(context: *FilterContext, frame: *Frame) callconv(.C) i32;

pub extern fn av_buffersrc_add_frame(context: *FilterContext, frame: *Frame) callconv(.C) i32;
pub extern fn av_buffersrc_add_frame_flags(buffer_src: *FilterContext, frame: ?*Frame, flags: i32) callconv(.C) i32;

pub extern fn avfilter_graph_alloc() callconv(.C) *FilterGraph;
pub extern fn avfilter_get_by_name(name: [*:0]const u8) callconv(.C) ?*Filter;
pub extern fn avfilter_graph_create_filter(
    filter_context: **FilterContext,
    filter: *Filter,
    name: [*:0]const u8,
    args: ?[*:0]const u8,
    data: ?*void,
    graph_context: *FilterGraph,
) callconv(.C) i32;
pub extern fn avfilter_inout_alloc() callconv(.C) ?*FilterInOut;
pub extern fn avfilter_inout_free(inout: **FilterInOut) callconv(.C) void;

pub extern fn avfilter_graph_config(graph_context: *FilterGraph, log_context: ?*void) callconv(.C) i32;

pub extern fn av_frame_free(frame: **Frame) callconv(.C) void;
pub extern fn av_frame_get_buffer(frame: *Frame, alignment: i32) callconv(.C) i32;

pub extern fn av_init_packet(packet: *Packet) callconv(.C) void;
pub extern fn av_packet_rescale_ts(
    packet: *Packet,
    tb_src: Rational,
    tb_dst: Rational,
) callconv(.C) void;
pub extern fn av_packet_unref(packet: *Packet) callconv(.C) void;
pub extern fn av_interleaved_write_frame(context: *FormatContext, packet: *Packet) callconv(.C) i32;
pub extern fn av_write_trailer(context: *FormatContext) callconv(.C) i32;

pub extern fn av_opt_set(
    object: *void,
    name: [*:0]const u8,
    value: [*:0]const u8,
    search_flags: i32,
) callconv(.C) i32;

pub extern fn av_opt_set_bin(
    object: *void,
    name: [*:0]const u8,
    value: [*]const u8,
    size: i32,
    search_flags: i32,
) callconv(.C) i32;
pub extern fn avfilter_graph_parse_ptr(
    filter_graph: *FilterGraph,
    filters: [*:0]const u8,
    inputs: ?**FilterInOut,
    outputs: ?**FilterInOut,
    log_context: ?*void,
) callconv(.C) i32;

pub extern fn av_dict_set(dict: *?*Dictionary, key: [*:0]const u8, value: [*:0]const u8, flags: i32) callconv(.C) i32;
pub extern fn av_dict_free(dict: *?*Dictionary) callconv(.C) void;
pub extern fn av_frame_alloc() callconv(.C) ?*Frame;
pub extern fn av_frame_unref(frame: *Frame) callconv(.C) void;
pub extern fn av_log_set_level(level: i32) callconv(.C) void;
pub extern fn av_find_input_format(short_name: [*:0]const u8) callconv(.C) ?*InputFormat;
pub extern fn av_guess_format(short_name: ?[*:0]const u8, filename: [*:0]const u8, mime_type: ?[*:0]const u8) callconv(.C) ?*OutputFormat;
pub extern fn av_strdup(value: [*:0]const u8) callconv(.C) ?[*:0]u8;

pub extern fn avcodec_find_encoder(codec_id: CodecID) callconv(.C) ?*Codec;

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
pub extern fn avcodec_alloc_context3(codec: ?*Codec) callconv(.C) ?*CodecContext;
pub extern fn avcodec_parameters_from_context(params: *CodecParameters, codec: *const CodecContext) callconv(.C) i32;
pub extern fn avcodec_send_frame(context: *CodecContext, frame: ?*Frame) callconv(.C) i32;
pub extern fn avcodec_receive_packet(context: *CodecContext, packet: *Packet) callconv(.C) i32;
pub extern fn avcodec_free_context(context: **CodecContext) callconv(.C) void;

pub extern fn avdevice_register_all() callconv(.C) void;
pub extern fn avformat_alloc_context() callconv(.C) ?*FormatContext;
pub extern fn avformat_open_input(
    format_context: **FormatContext,
    input_path: [*:0]const u8,
    input_format: *InputFormat,
    options: *?*Dictionary,
) callconv(.C) i32;
pub extern fn avformat_find_stream_info(format_context: *FormatContext, options: ?*?*Dictionary) callconv(.C) i32;
pub extern fn avformat_new_stream(stream_context: *FormatContext, codec: *Codec) callconv(.C) ?*Stream;
pub extern fn avformat_write_header(
    context: *FormatContext,
    options: ?**Dictionary,
) callconv(.C) i32;
pub extern fn avformat_free_context(context: *FormatContext) callconv(.C) void;

pub extern fn avcodec_fill_audio_frame(
    frame: *Frame,
    nb_channels: i32,
    sample_fmt: SampleFormat,
    buffer: [*]const u8,
    buffer_size: i32,
    alignment: i32,
) callconv(.C) i32;

extern fn av_strerror(err_num: i32, err_buffer: [*]u8, err_buffer_size: u64) callconv(.C) i32;

pub const strError = av_strerror;

pub const ioOpen = avio_open;
pub const ioClosep = avio_closep;

pub const bufferRef = av_buffer_ref;
pub const buffersinkGetHwFramesCtx = av_buffersink_get_hw_frames_ctx;
pub const buffersinkGetFrame = av_buffersink_get_frame;

pub const buffersrcAddFrame = av_buffersrc_add_frame;
pub const buffersrcAddFrameFlags = av_buffersrc_add_frame_flags;

pub const filterGetByName = avfilter_get_by_name;

pub const filterGraphAlloc = avfilter_graph_alloc;
pub const filterGraphCreateFilter = avfilter_graph_create_filter;
pub const filterGraphParsePtr = avfilter_graph_parse_ptr;
pub const filterGraphConfig = avfilter_graph_config;

pub const filterInOutAlloc = avfilter_inout_alloc;
pub const filterInOutFree = avfilter_inout_free;

pub const frameFree = av_frame_free;
pub const frameGetBuffer = av_frame_get_buffer;

pub const initPacket = av_init_packet;
pub const packetUnref = av_packet_unref;

pub const packetRescaleTS = av_packet_rescale_ts;
pub const interleavedWriteFrame = av_interleaved_write_frame;
pub const writeTrailer = av_write_trailer;

pub const optSet = av_opt_set;
pub const optSetBin = av_opt_set_bin;

pub const guessFormat = av_guess_format;
pub const formatAllocOutputContext2 = avformat_alloc_output_context2;
pub const codecFindEncoder = avcodec_find_encoder;

pub const strdup = av_strdup;
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
pub const formatWriteHeader = avformat_write_header;
pub const formatFreeContext = avformat_free_context;

pub const codecReceiveFrame = avcodec_receive_frame;
pub const codecSendPacket = avcodec_send_packet;
pub const codecOpen2 = avcodec_open2;
pub const codecFindDecoder = avcodec_find_decoder;
pub const codecAllocContext3 = avcodec_alloc_context3;
pub const codecParametersFromContext = avcodec_parameters_from_context;
pub const codecSendFrame = avcodec_send_frame;
pub const codecReceivePacket = avcodec_receive_packet;
pub const codecFreeContext = avcodec_free_context;

pub const codecFillAudioFrame = avcodec_fill_audio_frame;

pub const Channel = struct {
    pub const front_left = 0x00000001;
    pub const front_right = 0x00000002;
    pub const front_center = 0x00000004;
    pub const low_frequency = 0x00000008;
    pub const back_left = 0x00000010;
    pub const back_right = 0x00000020;
    pub const front_left_of_center = 0x00000040;
    pub const front_right_of_center = 0x00000080;
    pub const back_center = 0x00000100;
    pub const side_left = 0x00000200;
    pub const side_right = 0x00000400;
    pub const top_center = 0x00000800;
    pub const top_front_left = 0x00001000;
    pub const top_front_center = 0x00002000;
    pub const top_front_right = 0x00004000;
    pub const top_back_left = 0x00008000;
    pub const top_back_center = 0x00010000;
    pub const top_back_right = 0x00020000;
    pub const stereo_left = 0x20000000;
    pub const stereo_right = 0x40000000;
    pub const wide_left = 0x0000000080000000;
    pub const wide_right = 0x0000000100000000;
    pub const surround_direct_left = 0x0000000200000000;
    pub const surround_direct_right = 0x0000000400000000;
    pub const low_frequency_2 = 0x0000000800000000;
};

pub const ChannelLayout = struct {
    pub const stereo = Channel.front_left | Channel.front_right;
};

pub const ColorRange = enum(u32) {
    unspecified = 0,
    mpeg = 1,
    jpeg = 2,
};

pub const SampleFormat = enum(i32) {
    none = -1,
    u8 = 0,
    s16 = 1,
    s32 = 2,
    flt = 3,
    dbl = 4,
    u8p = 5,
    s16p = 6,
    s32p = 7,
    fltp = 8,
    dblp = 9,
    s64 = 10,
    s64p = 11,
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
    NUV,
    KMVC,
    FLASHSV,
    CAVS,
    JPEG2000,
    VMNC,
    VP5,
    VP6,
    VP6F,
    TARGA,
    DSICINVIDEO,
    TIERTEXSEQVIDEO,
    TIFF,
    GIF,
    DXA,
    DNXHD,
    THP,
    SGI,
    C93,
    BETHSOFTVID,
    PTX,
    TXD,
    VP6A,
    AMV,
    VB,
    PCX,
    SUNRAST,
    INDEO4,
    INDEO5,
    MIMIC,
    RL2,
    ESCAPE124,
    DIRAC,
    BFI,
    CMV,
    MOTIONPIXELS,
    TGV,
    TGQ,
    TQI,
    AURA,
    AURA2,
    V210X,
    TMV,
    V210,
    DPX,
    MAD,
    FRWU,
    FLASHSV2,
    CDGRAPHICS,
    R210,
    ANM,
    BINKVIDEO,
    IFF_ILBM,
    KGV1,
    YOP,
    VP8,
    PICTOR,
    ANSI,
    A64_MULTI,
    A64_MULTI5,
    R10K,
    MXPEG,
    LAGARITH,
    PRORES,
    JV,
    DFA,
    WMV3IMAGE,
    VC1IMAGE,
    UTVIDEO,
    BMV_VIDEO,
    VBLE,
    DXTORY,
    V410,
    XWD,
    CDXL,
    XBM,
    ZEROCODEC,
    MSS1,
    MSA1,
    TSCC2,
    MTS2,
    CLLC,
    MSS2,
    VP9,
    AIC,
    ESCAPE130,
    G2M,
    WEBP,
    HNM4_VIDEO,
    HEVC,
    FIC,
    ALIAS_PIX,
    BRENDER_PIX,
    PAF_VIDEO,
    EXR,
    VP7,
    SANM,
    SGIRLE,
    MVC1,
    MVC2,
    HQX,
    TDSC,
    HQ_HQA,
    HAP,
    DDS,
    DXV,
    SCREENPRESSO,
    RSCC,
    AVS2,
    PGX,
    AVS3,
    MSP2,
    VVC,
    Y41P = 0x8000,
    AVRP,
    @"012V",
    AVUI,
    AYUV,
    TARGA_Y216,
    V308,
    V408,
    YUV4,
    AVRN,
    CPIA,
    XFACE,
    SNOW,
    SMVJPEG,
    APNG,
    DAALA,
    CFHD,
    TRUEMOTION2RT,
    M101,
    MAGICYUV,
    SHEERVIDEO,
    YLC,
    PSD,
    PIXLET,
    SPEEDHQ,
    FMVC,
    SCPR,
    CLEARVIDEO,
    XPM,
    AV1,
    BITPACKED,
    MSCC,
    SRGC,
    SVG,
    GDV,
    FITS,
    IMM4,
    PROSUMER,
    MWSC,
    WCMV,
    RASC,
    HYMT,
    ARBC,
    AGM,
    LSCR,
    VP4,
    IMM5,
    MVDV,
    MVHA,
    CDTOONS,
    MV30,
    NOTCHLC,
    PFM,
    MOBICLIP,
    PHOTOCD,
    IPU,
    ARGO,
    CRI,
    SIMBIOSIS_IMX,
    SGA_VIDEO,
    GEM,
    VBN,
    JPEGXL,
    QOI,
    PHM,
    RADIANCE_HDR,
    WBMP,
    MEDIA100,
    VQC,
    //
    // Audio Codecs
    //
    PCM_S16LE = 0x10000,
    PCM_S16BE,
    PCM_U16LE,
    PCM_U16BE,
    PCM_S8,
    PCM_U8,
    PCM_MULAW,
    PCM_ALAW,
    PCM_S32LE,
    PCM_S32BE,
    PCM_U32LE,
    PCM_U32BE,
    PCM_S24LE,
    PCM_S24BE,
    PCM_U24LE,
    PCM_U24BE,
    PCM_S24DAUD,
    PCM_ZORK,
    PCM_S16LE_PLANAR,
    PCM_DVD,
    PCM_F32BE,
    PCM_F32LE,
    PCM_F64BE,
    PCM_F64LE,
    PCM_BLURAY,
    PCM_LXF,
    S302M,
    PCM_S8_PLANAR,
    PCM_S24LE_PLANAR,
    PCM_S32LE_PLANAR,
    PCM_S16BE_PLANAR,
    PCM_S64LE = 0x10800,
    PCM_S64BE,
    PCM_F16LE,
    PCM_F24LE,
    PCM_VIDC,
    PCM_SGA,
    ADPCM_IMA_QT = 0x11000,
    ADPCM_IMA_WAV,
    ADPCM_IMA_DK3,
    ADPCM_IMA_DK4,
    ADPCM_IMA_WS,
    ADPCM_IMA_SMJPEG,
    ADPCM_MS,
    ADPCM_4XM,
    ADPCM_XA,
    ADPCM_ADX,
    ADPCM_EA,
    ADPCM_G726,
    ADPCM_CT,
    ADPCM_SWF,
    ADPCM_YAMAHA,
    ADPCM_SBPRO_4,
    ADPCM_SBPRO_3,
    ADPCM_SBPRO_2,
    ADPCM_THP,
    ADPCM_IMA_AMV,
    ADPCM_EA_R1,
    ADPCM_EA_R3,
    ADPCM_EA_R2,
    ADPCM_IMA_EA_SEAD,
    ADPCM_IMA_EA_EACS,
    ADPCM_EA_XAS,
    ADPCM_EA_MAXIS_XA,
    ADPCM_IMA_ISS,
    ADPCM_G722,
    ADPCM_IMA_APC,
    ADPCM_VIMA,
    ADPCM_AFC = 0x11800,
    ADPCM_IMA_OKI,
    ADPCM_DTK,
    ADPCM_IMA_RAD,
    ADPCM_G726LE,
    ADPCM_THP_LE,
    ADPCM_PSX,
    ADPCM_AICA,
    ADPCM_IMA_DAT4,
    ADPCM_MTAF,
    ADPCM_AGM,
    ADPCM_ARGO,
    ADPCM_IMA_SSI,
    ADPCM_ZORK,
    ADPCM_IMA_APM,
    ADPCM_IMA_ALP,
    ADPCM_IMA_MTF,
    ADPCM_IMA_CUNNING,
    ADPCM_IMA_MOFLEX,
    ADPCM_IMA_ACORN,
    ADPCM_XMD,
    AMR_NB = 0x12000,
    AMR_WB,
    RA_144 = 0x13000,
    RA_288,
    ROQ_DPCM = 0x14000,
    INTERPLAY_DPCM,
    XAN_DPCM,
    SOL_DPCM,
    SDX2_DPCM = 0x14800,
    GREMLIN_DPCM,
    DERF_DPCM,
    WADY_DPCM,
    CBD2_DPCM,
    MP2 = 0x15000,
    MP3,
    AAC,
    AC3,
    DTS,
    VORBIS,
    DVAUDIO,
    WMAV1,
    WMAV2,
    MACE3,
    MACE6,
    VMDAUDIO,
    FLAC,
    MP3ADU,
    MP3ON4,
    SHORTEN,
    ALAC,
    WESTWOOD_SND1,
    GSM,
    QDM2,
    COOK,
    TRUESPEECH,
    TTA,
    SMACKAUDIO,
    QCELP,
    WAVPACK,
    DSICINAUDIO,
    IMC,
    MUSEPACK7,
    MLP,
    GSM_MS,
    ATRAC3,
    APE,
    NELLYMOSER,
    MUSEPACK8,
    SPEEX,
    WMAVOICE,
    WMAPRO,
    WMALOSSLESS,
    ATRAC3P,
    EAC3,
    SIPR,
    MP1,
    TWINVQ,
    TRUEHD,
    MP4ALS,
    ATRAC1,
    BINKAUDIO_RDFT,
    BINKAUDIO_DCT,
    AAC_LATM,
    QDMC,
    CELT,
    G723_1,
    G729,
    @"8SVX_EXP",
    @"8SVX_FIB",
    BMV_AUDIO,
    RALF,
    IAC,
    ILBC,
    OPUS,
    COMFORT_NOISE,
    TAK,
    METASOUND,
    PAF_AUDIO,
    ON2AVC,
    DSS_SP,
    CODEC2,
    FFWAVESYNTH = 0x15800,
    SONIC,
    SONIC_LS,
    EVRC,
    SMV,
    DSD_LSBF,
    DSD_MSBF,
    DSD_LSBF_PLANAR,
    DSD_MSBF_PLANAR,
    @"4GV",
    INTERPLAY_ACM,
    XMA1,
    XMA2,
    DST,
    ATRAC3AL,
    ATRAC3PAL,
    DOLBY_E,
    APTX,
    APTX_HD,
    SBC,
    ATRAC9,
    HCOM,
    ACELP_KELVIN,
    MPEGH_3D_AUDIO,
    SIREN,
    HCA,
    FASTAUDIO,
    MSNSIREN,
    DFPWM,
    BONK,
    MISC4,
    APAC,
    FTR,
    WAVARC,
    RKA,
    //
    // Subtitles
    //
    // FIRST_SUBTITLE = 0x17000,
    DVD_SUBTITLE = 0x17000,
    DVB_SUBTITLE,
    TEXT,
    XSUB,
    SSA,
    MOV_TEXT,
    HDMV_PGS_SUBTITLE,
    DVB_TELETEXT,
    SRT,
    MICRODVD = 0x17800,
    EIA_608,
    JACOSUB,
    SAMI,
    REALTEXT,
    STL,
    SUBVIEWER1,
    SUBVIEWER,
    SUBRIP,
    WEBVTT,
    MPL2,
    VPLAYER,
    PJS,
    ASS,
    HDMV_TEXT_SUBTITLE,
    TTML,
    ARIB_CAPTION,
    // FIRST_UNKNOWN = 0x18000,
    TTF = 0x18000,
    SCTE_35,
    EPG,
    BINTEXT = 0x18800,
    XBIN,
    IDF,
    OTF,
    SMPTE_KLV,
    DVD_NAV,
    TIMED_ID3,
    BIN_DATA,
    PROBE = 0x19000,
    MPEG2TS = 0x20000,
    MPEG4SYSTEMS = 0x20001,
    FFMETADATA = 0x21000,
    WRAPPED_AVFRAME = 0x21001,
    VNULL,
    ANULL,
};

comptime {
    // TODO: More checks
    std.debug.assert(@enumToInt(CodecID.AAC) == libav.AV_CODEC_ID_AAC);
}

pub const PixelFormat = enum(i32) {
    NONE = -1,
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
