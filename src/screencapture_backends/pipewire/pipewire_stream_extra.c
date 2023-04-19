// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

//
// This file exists because I didn't feel like spending a day+ porting 
// pipewire inline functions and macros to zig. Easier to just do it in C
// and link in the object file
//

#include <spa/debug/types.h>
#include <spa/param/video/format-utils.h>
#include <spa/param/video/type-info.h>
#include <spa/param/video/format.h>
#include <spa/debug/format.h>
#include <pipewire/pipewire.h>

typedef enum SupportedPixelFormat {
    SUPPORTED_PIXEL_FORMAT_RGBA,
    SUPPORTED_PIXEL_FORMAT_RGBX,
    SUPPORTED_PIXEL_FORMAT_RGB,
    SUPPORTED_PIXEL_FORMAT_BGRA,
    SUPPORTED_PIXEL_FORMAT_BGRX,
    SUPPORTED_PIXEL_FORMAT_BGR,
} SupportedPixelFormat;

typedef struct StreamFormat {
    SupportedPixelFormat format;
    uint32_t width;
    uint32_t height;
    uint32_t padding;
} StreamFormat;

StreamFormat parseStreamFormat(const struct spa_pod *param) {

    StreamFormat result = {
        0, // format
        0, // width
        0, // height
        0, // padding
    };
    
    uint32_t media_type = 0;
    uint32_t media_subtype = 0;
    if (spa_format_parse(param, &media_type, &media_subtype) < 0)
        return result;
 
    if (media_type != SPA_MEDIA_TYPE_video)
        return result;
 
    if (media_subtype != SPA_MEDIA_SUBTYPE_raw)
        return result;

    struct spa_video_info_raw info_raw;
    spa_format_video_raw_parse(param, &info_raw);
    uint32_t width = info_raw.size.width;
    uint32_t height = info_raw.size.height;

    fprintf(stderr, "Dimensions %u %u\n", width, height);

    result.width = info_raw.size.width;
    result.height = info_raw.size.height;

    if(info_raw.format == SPA_VIDEO_FORMAT_RGB)
        result.format = SUPPORTED_PIXEL_FORMAT_RGB;
    else if (info_raw.format == SPA_VIDEO_FORMAT_RGBA)
        result.format = SUPPORTED_PIXEL_FORMAT_RGBA;
    else if (info_raw.format == SPA_VIDEO_FORMAT_RGBx)
        result.format = SUPPORTED_PIXEL_FORMAT_RGBX;
    else if (info_raw.format == SPA_VIDEO_FORMAT_BGRA)
        result.format = SUPPORTED_PIXEL_FORMAT_BGRA;
    else if (info_raw.format == SPA_VIDEO_FORMAT_BGRx)
        result.format = SUPPORTED_PIXEL_FORMAT_BGRX;
    else if (info_raw.format == SPA_VIDEO_FORMAT_BGR)
        result.format = SUPPORTED_PIXEL_FORMAT_BGR;

    return result;
}

struct spa_pod* buildPipewireParams(struct spa_pod_builder *builder) {
    return spa_pod_builder_add_object(
        builder, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat, SPA_FORMAT_mediaType,
        SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype,
        SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), SPA_FORMAT_VIDEO_format,
        SPA_POD_CHOICE_ENUM_Id(6, SPA_VIDEO_FORMAT_RGB, SPA_VIDEO_FORMAT_RGB,
                               SPA_VIDEO_FORMAT_RGBA, SPA_VIDEO_FORMAT_RGBx,
                               SPA_VIDEO_FORMAT_BGR, SPA_VIDEO_FORMAT_BGRx),
        SPA_FORMAT_VIDEO_size,
        SPA_POD_CHOICE_RANGE_Rectangle(&SPA_RECTANGLE(1080, 1920),
                                       &SPA_RECTANGLE(1, 1),
                                       &SPA_RECTANGLE(4096, 4096)),
        SPA_FORMAT_VIDEO_framerate,
        SPA_POD_CHOICE_RANGE_Fraction(&SPA_FRACTION(60, 1), &SPA_FRACTION(0, 1),
                                      &SPA_FRACTION(1000, 1)));
}