// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const graphics = @import("graphics.zig");

const Color = graphics.RGB(f32);

pub const bottom_bar_color = Color.fromInt(20, 25, 40);
pub const enable_preview_button_color = Color.fromInt(20, 25, 40); 

pub const checkbox_checked_color = Color.fromInt(55, 55, 55); 

pub const screen_preview = struct {
    pub const margin_left_pixels = 20;
    pub const margin_top_pixels = 20;
    pub const border_width_pixels = 1;
    pub const background_color = Color.fromInt(20, 25, 40);
};