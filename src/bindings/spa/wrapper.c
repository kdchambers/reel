// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

#include <spa/param/audio/format-utils.h>

//
// These functions are implemented as inline functions in spa header files. Zig isn't able to
// translate / import them. So instead we're wrapping them to effectively un-inline them.
// The signatures for these functions are defined in bindings/spa/cbindings.zig 
//

int _spa_format_parse(const struct spa_pod *format, uint32_t *media_type, uint32_t *media_subtype) {
    return spa_format_parse(format, media_type, media_subtype); 
}

int _spa_format_audio_raw_parse(const struct spa_pod* format, struct spa_audio_info_raw *info) {
    return spa_format_audio_raw_parse(format, info); 
}
