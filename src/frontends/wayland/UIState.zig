// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const widgets = @import("widgets.zig");

record_button: widgets.Button,
enable_preview_checkbox: widgets.Checkbox,
audio_input_spectogram: widgets.AudioSpectogram,
audio_volume_level: widgets.AudioVolumeLevelHorizontal,

audio_input_mel_bins: []f32,