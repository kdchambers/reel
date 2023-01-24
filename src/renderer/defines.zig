// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const geometry = @import("../geometry.zig");
const graphics = @import("../graphics.zig");

pub const ScreenPixelBaseType = u16;
pub const ScreenNormalizedBaseType = f32;

pub const TexturePixelBaseType = u16;
pub const TextureNormalizedBaseType = f32;

pub const indices_range_index_begin = 0;
pub const indices_range_size = max_texture_quads_per_render * @sizeOf(u16) * 6; // 12 kb
pub const indices_range_count = indices_range_size / @sizeOf(u16);
pub const vertices_range_index_begin = indices_range_size;
pub const vertices_range_size = max_texture_quads_per_render * @sizeOf(graphics.GenericVertex) * 4; // 80 kb
pub const vertices_range_count = vertices_range_size / @sizeOf(graphics.GenericVertex);
pub const memory_size = indices_range_size + vertices_range_size;

pub const initial_screen_dimensions = geometry.Dimensions2D(u16){
    .width = 1920,
    .height = 1080,
};

/// Determines the memory allocated for storing mesh data
/// Represents the number of quads that will be able to be drawn
/// This can be a colored quad, or a textured quad such as a charactor
pub const max_texture_quads_per_render: u32 = 1024;

/// Maximum number of screen framebuffers to use
/// 2-3 would be recommented to avoid screen tearing
pub const max_frames_in_flight: u32 = 2;

/// Enables transparency on the selected surface
pub const transparancy_enabled = true;

/// The transparency of the selected surface
/// Valid values between 0.0 (no transparency) and 1.0 (full)
/// Ignored if `transparancy_enabled` is false
pub const transparancy_level = 0.0;

/// Options to print various vulkan objects that will be selected at
/// runtime based on the hardware / system that is available
pub const print_vulkan_objects = struct {
    /// Capabilities of all available memory types
    pub const memory_type_all: bool = true;
    /// Capabilities of the selected surface
    /// VSync, transparency, etc
    pub const surface_abilties: bool = true;
};

// NOTE: The max texture size that is guaranteed is 4096 * 4096
//       Support for larger textures will need to be queried
// https://github.com/gpuweb/gpuweb/issues/1327
pub const texture_layer_dimensions = geometry.Dimensions2D(TexturePixelBaseType){
    .width = 512,
    .height = 512,
};

/// Size in bytes of each texture layer (Not including padding, etc)
pub const texture_layer_size = @sizeOf(graphics.RGBA(f32)) * @intCast(u64, texture_layer_dimensions.width) * texture_layer_dimensions.height;
pub const texture_size_bytes = texture_layer_dimensions.width * texture_layer_dimensions.height * @sizeOf(graphics.RGBA(f32));

pub const background_color = graphics.RGBA(f32).fromInt(u8, 35, 35, 35, 255);

// NOTE: The following points aren't used in the code, but are useful to know
// http://anki3d.org/vulkan-coordinate-system/
pub const ScreenPoint = geometry.Coordinates2D(ScreenNormalizedBaseType);
pub const point_top_left = ScreenPoint{ .x = -1.0, .y = -1.0 };
pub const point_top_right = ScreenPoint{ .x = 1.0, .y = -1.0 };
pub const point_bottom_left = ScreenPoint{ .x = -1.0, .y = 1.0 };
pub const point_bottom_right = ScreenPoint{ .x = 1.0, .y = 1.0 };

const A: if (vertices_range_index_begin + vertices_range_size <= memory_size) void else @compileError("") = undefined;

// std.debug.assert(vertices_range_index_begin + vertices_range_size <= memory_size);
