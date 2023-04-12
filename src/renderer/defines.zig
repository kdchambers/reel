// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const geometry = @import("../geometry.zig");
const graphics = @import("../graphics.zig");

const video_pipeline = @import("texture_pipeline.zig");

pub const ScreenPixelBaseType = u16;
pub const ScreenNormalizedBaseType = f32;

pub const TexturePixelBaseType = u16;
pub const TextureNormalizedBaseType = f32;

pub const memory = struct {
    pub const device_local = struct {
        // 0. Texture Image
        const size_bytes = pipeline_generic.texture_image_size * 2;
        // 1. Anit Aliasing Resolve (dynamically sized)
    };

    pub const host_local = struct {
        // 0. Vertex Buffer
        // 1. Index Buffer
        // 2. Video Stream Buffer
        // TODO: Actually implement a device_local heap
        pub const size_bytes = pipeline_generic.memory_size + pipeline_video.memory_size + device_local.size_bytes;
    };

    pub const pipeline_generic = struct {
        /// Determines the memory allocated for storing mesh data
        /// Represents the number of quads that will be able to be drawn
        /// This can be a colored quad, or a textured quad such as a charactor
        pub const max_texture_quads_per_render: u32 = 1024;

        pub const memory_range_start = 0;

        pub const indices_range_index_begin = 0;
        pub const indices_range_size = max_texture_quads_per_render * @sizeOf(u16) * 6; // 12 kb
        pub const indices_range_count = indices_range_size / @sizeOf(u16);

        pub const vertices_range_index_begin = indices_range_size;
        pub const vertices_range_size = max_texture_quads_per_render * @sizeOf(graphics.GenericVertex) * 4; // 80 kb
        pub const vertices_range_count = vertices_range_size / @sizeOf(graphics.GenericVertex);

        pub const Pixel = graphics.RGBA(f32);
        pub const texture_image_dimensions = geometry.Dimensions2D(u32){
            .width = 512,
            .height = 512,
        };
        pub const texture_image_size = texture_image_dimensions.width * texture_image_dimensions.height * @sizeOf(Pixel);
        pub const memory_size = indices_range_size + vertices_range_size;
    };

    pub const pipeline_video = struct {
        const Vertex = video_pipeline.Vertex;
        pub const max_texture_quads_per_render: u32 = 10;
        pub const memory_range_start = pipeline_generic.memory_range_end;

        pub const indices_range_index_begin = memory_range_start;
        pub const indices_range_size = max_texture_quads_per_render * @sizeOf(u16) * 6;
        pub const indices_range_count = indices_range_size / @sizeOf(u16);

        pub const vertices_range_index_begin = indices_range_size;
        pub const vertices_range_size = max_texture_quads_per_render * @sizeOf(Vertex) * 4;
        pub const vertices_range_count = vertices_range_size / @sizeOf(Vertex);

        pub const Pixel = graphics.RGBA(u8);

        pub const video_image_dimensions = geometry.Dimensions2D(u32){
            .width = 2048,
            .height = 2048,
        };
        pub const video_image_size = video_image_dimensions.width * video_image_dimensions.height * @sizeOf(Pixel);

        pub const unscaled_image_dimensions = geometry.Dimensions2D(u32){
            .width = 4096,
            .height = 4096,
        };
        pub const unscaled_image_size = unscaled_image_dimensions.width * unscaled_image_dimensions.height * @sizeOf(Pixel);

        pub const memory_size = indices_range_size + vertices_range_size + video_image_size + unscaled_image_size;

        pub const framebuffer_dimensions = struct {
            pub const width = 2048;
            pub const height = 2048;
        };
    };
};

pub const initial_screen_dimensions = geometry.Dimensions2D(u16){
    .width = 1040,
    .height = 640,
};

/// Maximum number of screen framebuffers to use
/// 2-3 would be recommented to avoid screen tearing
pub const max_frames_in_flight: u32 = 2;

/// Enables transparency on the selected surface
pub const transparancy_enabled = false;

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
