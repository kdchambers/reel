// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const vulkan_config = @import("vulkan_config.zig");
const shaders = @import("shaders");
const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");
const img = @import("zigimg");

// TODO: Fontana shouldn't be referenced here
const Atlas = @import("fontana").Atlas;

const clib = @cImport({
    @cInclude("dlfcn.h");
});

var vkGetInstanceProcAddr: *const fn (instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction = undefined;

/// Enable Vulkan validation layers
const enable_validation_layers = if (builtin.mode == .Debug) true else false;

const vulkan_engine_version = vk.makeApiVersion(0, 0, 1, 0);
const vulkan_engine_name = "No engine";
const vulkan_application_version = vk.makeApiVersion(0, 0, 1, 0);
const application_name = "reel";

// NOTE: The max texture size that is guaranteed is 4096 * 4096
//       Support for larger textures will need to be queried
// https://github.com/gpuweb/gpuweb/issues/1327
pub const texture_layer_dimensions = geometry.Dimensions2D(TexturePixelBaseType){
    .width = 512,
    .height = 512,
};

/// Size in bytes of each texture layer (Not including padding, etc)
const texture_layer_size = @sizeOf(graphics.RGBA(f32)) * @intCast(u64, texture_layer_dimensions.width) * texture_layer_dimensions.height;
const texture_size_bytes = texture_layer_dimensions.width * texture_layer_dimensions.height * @sizeOf(graphics.RGBA(f32));

const background_color = graphics.RGBA(f32).fromInt(u8, 35, 35, 35, 255);

const indices_range_index_begin = 0;
const indices_range_size = max_texture_quads_per_render * @sizeOf(u16) * 6; // 12 kb
const indices_range_count = indices_range_size / @sizeOf(u16);
const vertices_range_index_begin = indices_range_size;
const vertices_range_size = max_texture_quads_per_render * @sizeOf(graphics.GenericVertex) * 4; // 80 kb
const vertices_range_count = vertices_range_size / @sizeOf(graphics.GenericVertex);
const memory_size = indices_range_size + vertices_range_size;

const device_extensions = [_][*:0]const u8{vk.extension_info.khr_swapchain.name};
const surface_extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_wayland_surface" };

const validation_layers = if (enable_validation_layers)
    [1][*:0]const u8{"VK_LAYER_KHRONOS_validation"}
else
    [*:0]const u8{};

/// Maximum number of screen framebuffers to use
/// 2-3 would be recommented to avoid screen tearing
const max_frames_in_flight: u32 = 2;

/// Determines the memory allocated for storing mesh data
/// Represents the number of quads that will be able to be drawn
/// This can be a colored quad, or a textured quad such as a charactor
const max_texture_quads_per_render: u32 = 1024;

/// Enables transparency on the selected surface
const transparancy_enabled = true;

/// The transparency of the selected surface
/// Valid values between 0.0 (no transparency) and 1.0 (full)
/// Ignored if `transparancy_enabled` is false
const transparancy_level = 0.0;

/// Version of Vulkan to use
/// https://www.khronos.org/registry/vulkan/
const vulkan_api_version = vk.API_VERSION_1_1;

/// Options to print various vulkan objects that will be selected at
/// runtime based on the hardware / system that is available
const print_vulkan_objects = struct {
    /// Capabilities of all available memory types
    const memory_type_all: bool = true;
    /// Capabilities of the selected surface
    /// VSync, transparency, etc
    const surface_abilties: bool = true;
};

// NOTE: The following points aren't used in the code, but are useful to know
// http://anki3d.org/vulkan-coordinate-system/
const ScreenPoint = geometry.Coordinates2D(ScreenNormalizedBaseType);
const point_top_left = ScreenPoint{ .x = -1.0, .y = -1.0 };
const point_top_right = ScreenPoint{ .x = 1.0, .y = -1.0 };
const point_bottom_left = ScreenPoint{ .x = -1.0, .y = 1.0 };
const point_bottom_right = ScreenPoint{ .x = 1.0, .y = 1.0 };

/// Defines the entire surface area of a screen in vulkans coordinate system
/// I.e normalized device coordinates right (ndc right)
const full_screen_extent = geometry.Extent2D(ScreenNormalizedBaseType){
    .x = -1.0,
    .y = -1.0,
    .width = 2.0,
    .height = 2.0,
};

/// Defines the entire surface area of a texture
const full_texture_extent = geometry.Extent2D(TextureNormalizedBaseType){
    .x = 0.0,
    .y = 0.0,
    .width = 1.0,
    .height = 1.0,
};

var texture_image_view: vk.ImageView = undefined;
var texture_image: vk.Image = undefined;

var multisampled_image: vk.Image = undefined;
var multisampled_image_view: vk.ImageView = undefined;
var multisampled_image_memory: vk.DeviceMemory = undefined;

var texture_memory_map: [*]graphics.RGBA(f32) = undefined;

var mapped_device_memory: [*]u8 = undefined;

var quad_buffer: []graphics.QuadFace = undefined;

var current_frame: u32 = 0;
var previous_frame: u32 = 0;

pub var texture_atlas: *Atlas = undefined;

var alpha_mode: vk.CompositeAlphaFlagsKHR = .{ .opaque_bit_khr = true };

var jobs_command_buffer: vk.CommandBuffer = undefined;

/// Push constant structure that is used in our fragment shader
const PushConstant = packed struct {
    width: f32,
    height: f32,
    frame: f32,
};

//
// Graphics context
//

pub var base_dispatch: vulkan_config.BaseDispatch = undefined;
pub var instance_dispatch: vulkan_config.InstanceDispatch = undefined;
pub var device_dispatch: vulkan_config.DeviceDispatch = undefined;

var vertex_shader_module: vk.ShaderModule = undefined;
var fragment_shader_module: vk.ShaderModule = undefined;

var render_pass: vk.RenderPass = undefined;
var framebuffers: []vk.Framebuffer = undefined;
var graphics_pipeline: vk.Pipeline = undefined;
var descriptor_pool: vk.DescriptorPool = undefined;
var descriptor_sets: []vk.DescriptorSet = undefined;
var descriptor_set_layouts: []vk.DescriptorSetLayout = undefined;
var pipeline_layout: vk.PipelineLayout = undefined;

var instance: vk.Instance = undefined;
var surface: vk.SurfaceKHR = undefined;
var swapchain_surface_format: vk.SurfaceFormatKHR = undefined;
var physical_device: vk.PhysicalDevice = undefined;
// TODO:
pub var logical_device: vk.Device = undefined;
var graphics_present_queue: vk.Queue = undefined; // Same queue used for graphics + presenting
var graphics_present_queue_index: u32 = undefined;
var swapchain_min_image_count: u32 = undefined;
var swapchain: vk.SwapchainKHR = undefined;
pub var swapchain_extent: vk.Extent2D = undefined;
var swapchain_images: []vk.Image = undefined;
var swapchain_image_views: []vk.ImageView = undefined;
var command_pool: vk.CommandPool = undefined;
var command_buffers: []vk.CommandBuffer = undefined;
var images_available: []vk.Semaphore = undefined;
var renders_finished: []vk.Semaphore = undefined;
var inflight_fences: []vk.Fence = undefined;
var sampler: vk.Sampler = undefined;

var antialias_sample_count: vk.SampleCountFlags = undefined;
var selected_memory_index: u32 = undefined;

pub var vertices_buffer: []graphics.GenericVertex = undefined;
pub var indices_buffer: []u16 = undefined;

var vulkan_vertices_buffer: vk.Buffer = undefined;
var vulkan_indices_buffer: vk.Buffer = undefined;

// Has a precision of 2^12 = 4096
pub const ImageHandle = packed struct(u64) {
    texture_array_index: u8,
    x: u12,
    y: u12,
    _width: u12,
    _height: u12,
    reserved: u8,

    pub inline fn width(self: @This()) u16 {
        return @intCast(u16, self._width);
    }

    pub inline fn height(self: @This()) u16 {
        return @intCast(u16, self._height);
    }

    pub inline fn extent(self: @This()) geometry.Extent2D(f32) {
        return .{
            .x = @intToFloat(f32, self.x) / 512,
            .y = @intToFloat(f32, self.y) / 512,
            .width = @intToFloat(f32, self._width) / 512,
            .height = @intToFloat(f32, self._height) / 512,
        };
    }
};

pub const Surface = opaque {};
pub const Display = opaque {};

const ScreenPixelBaseType = u16;
const ScreenNormalizedBaseType = f32;

const TexturePixelBaseType = u16;
const TextureNormalizedBaseType = f32;

pub fn recreateSwapchain(screen_dimensions: geometry.Dimensions2D(u16)) !void {
    const recreate_swapchain_start = std.time.nanoTimestamp();

    _ = try device_dispatch.waitForFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &inflight_fences[previous_frame]),
        vk.TRUE,
        std.math.maxInt(u64),
    );

    //
    // Destroy and recreate multisampled image
    //
    device_dispatch.destroyImage(logical_device, multisampled_image, null);
    device_dispatch.destroyImageView(logical_device, multisampled_image_view, null);
    device_dispatch.freeMemory(logical_device, multisampled_image_memory, null);

    try createMultiSampledImage(screen_dimensions.width, screen_dimensions.height, selected_memory_index);

    for (swapchain_image_views) |image_view| {
        device_dispatch.destroyImageView(logical_device, image_view, null);
    }

    swapchain_extent.width = screen_dimensions.width;
    swapchain_extent.height = screen_dimensions.height;

    const old_swapchain = swapchain;
    swapchain = try device_dispatch.createSwapchainKHR(logical_device, &vk.SwapchainCreateInfoKHR{
        .surface = surface,
        .min_image_count = swapchain_min_image_count,
        .image_format = swapchain_surface_format.format,
        .image_color_space = swapchain_surface_format.color_space,
        .image_extent = swapchain_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .pre_transform = .{ .identity_bit_khr = true },
        .composite_alpha = alpha_mode,
        .present_mode = .fifo_khr,
        .clipped = vk.TRUE,
        .flags = .{},
        .old_swapchain = old_swapchain,
    }, null);

    device_dispatch.destroySwapchainKHR(logical_device, old_swapchain, null);

    var image_count: u32 = undefined;
    {
        if (.success != (try device_dispatch.getSwapchainImagesKHR(logical_device, swapchain, &image_count, null))) {
            return error.FailedToGetSwapchainImagesCount;
        }
        //
        // TODO: handle this
        //
        std.debug.assert(image_count == swapchain_images.len);
    }

    if (.success != (try device_dispatch.getSwapchainImagesKHR(logical_device, swapchain, &image_count, swapchain_images.ptr))) {
        return error.FailedToGetSwapchainImages;
    }
    try createSwapchainImageViews();

    for (framebuffers) |framebuffer| {
        device_dispatch.destroyFramebuffer(logical_device, framebuffer, null);
    }

    {
        var framebuffer_create_info = vk.FramebufferCreateInfo{
            .render_pass = render_pass,
            .attachment_count = 2,
            // We assign to `p_attachments` below in the loop
            .p_attachments = undefined,
            .width = screen_dimensions.width,
            .height = screen_dimensions.height,
            .layers = 1,
            .flags = .{},
        };
        var attachment_buffer = [2]vk.ImageView{ multisampled_image_view, undefined };
        var i: u32 = 0;
        while (i < swapchain_image_views.len) : (i += 1) {
            // We reuse framebuffer_create_info for each framebuffer we create,
            // only updating the swapchain_image_view that is attached
            attachment_buffer[1] = swapchain_image_views[i];
            framebuffer_create_info.p_attachments = &attachment_buffer;
            framebuffers[i] = try device_dispatch.createFramebuffer(logical_device, &framebuffer_create_info, null);
        }
    }

    const recreate_swapchain_end = std.time.nanoTimestamp();
    std.debug.assert(recreate_swapchain_end >= recreate_swapchain_start);
    const recreate_swapchain_duration = @intCast(u64, recreate_swapchain_end - recreate_swapchain_start);

    std.log.info("Swapchain resized to {}x{} in {}", .{
        screen_dimensions.width,
        screen_dimensions.height,
        std.fmt.fmtDuration(recreate_swapchain_duration),
    });
}

pub fn recordRenderPass(
    indices_count: u32,
    screen_dimensions: geometry.Dimensions2D(u16),
) !void {
    std.debug.assert(command_buffers.len > 0);
    std.debug.assert(swapchain_images.len == command_buffers.len);
    std.debug.assert(screen_dimensions.width == swapchain_extent.width);
    std.debug.assert(screen_dimensions.height == swapchain_extent.height);

    _ = try device_dispatch.waitForFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &inflight_fences[previous_frame]),
        vk.TRUE,
        std.math.maxInt(u64),
    );

    try device_dispatch.resetCommandPool(logical_device, command_pool, .{});

    const clear_color = graphics.RGBA(f32){ .r = 0.12, .g = 0.12, .b = 0.12, .a = 1.0 };
    const clear_colors = [2]vk.ClearValue{
        .{
            .color = vk.ClearColorValue{
                .float_32 = @bitCast([4]f32, clear_color),
            },
        },
        .{
            .color = vk.ClearColorValue{
                .float_32 = @bitCast([4]f32, clear_color),
            },
        },
    };

    for (command_buffers) |command_buffer, i| {
        try device_dispatch.beginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
            .flags = .{},
            .p_inheritance_info = null,
        });

        device_dispatch.cmdBeginRenderPass(command_buffer, &vk.RenderPassBeginInfo{
            .render_pass = render_pass,
            .framebuffer = framebuffers[i],
            .render_area = vk.Rect2D{
                .offset = vk.Offset2D{
                    .x = 0,
                    .y = 0,
                },
                .extent = swapchain_extent,
            },
            .clear_value_count = clear_colors.len,
            .p_clear_values = &clear_colors,
        }, .@"inline");

        device_dispatch.cmdBindPipeline(command_buffer, .graphics, graphics_pipeline);

        {
            const viewports = [1]vk.Viewport{
                vk.Viewport{
                    .x = 0.0,
                    .y = 0.0,
                    .width = @intToFloat(f32, screen_dimensions.width),
                    .height = @intToFloat(f32, screen_dimensions.height),
                    .min_depth = 0.0,
                    .max_depth = 1.0,
                },
            };
            device_dispatch.cmdSetViewport(command_buffer, 0, 1, @ptrCast([*]const vk.Viewport, &viewports));
        }
        {
            const scissors = [1]vk.Rect2D{
                vk.Rect2D{
                    .offset = vk.Offset2D{
                        .x = 0,
                        .y = 0,
                    },
                    .extent = vk.Extent2D{
                        .width = screen_dimensions.width,
                        .height = screen_dimensions.height,
                    },
                },
            };
            device_dispatch.cmdSetScissor(command_buffer, 0, 1, @ptrCast([*]const vk.Rect2D, &scissors));
        }

        device_dispatch.cmdBindVertexBuffers(command_buffer, 0, 1, &[1]vk.Buffer{vulkan_vertices_buffer}, &[1]vk.DeviceSize{0});
        device_dispatch.cmdBindIndexBuffer(command_buffer, vulkan_indices_buffer, 0, .uint16);
        device_dispatch.cmdBindDescriptorSets(
            command_buffer,
            .graphics,
            pipeline_layout,
            0,
            1,
            &[1]vk.DescriptorSet{descriptor_sets[i]},
            0,
            undefined,
        );

        const push_constant = PushConstant{
            .width = @intToFloat(f32, screen_dimensions.width),
            .height = @intToFloat(f32, screen_dimensions.height),
            .frame = 0.0,
        };

        device_dispatch.cmdPushConstants(
            command_buffer,
            pipeline_layout,
            .{ .fragment_bit = true },
            0,
            @sizeOf(PushConstant),
            &push_constant,
        );
        device_dispatch.cmdDrawIndexed(command_buffer, indices_count, 1, 0, 0, 0);

        device_dispatch.cmdEndRenderPass(command_buffer);
        try device_dispatch.endCommandBuffer(command_buffer);
    }
}

pub const Texture = struct {
    pixels: [*]graphics.RGBA(f32),
    width: u32,
    height: u32,
};

pub fn textureGet() !Texture {
    try transitionTextureToGeneral();
    const pixel_count = @intCast(u32, texture_layer_dimensions.width) * texture_layer_dimensions.height;
    return Texture{
        .pixels = texture_memory_map[0..pixel_count],
        .width = texture_layer_dimensions.width,
        .height = texture_layer_dimensions.height,
    };
}

pub fn textureCommit() !void {
    try transitionTextureToOptimal();
}

fn transitionTextureToGeneral() !void {
    const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };

    try device_dispatch.allocateCommandBuffers(
        logical_device,
        &command_buffer_allocate_info,
        @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
    );

    try device_dispatch.beginCommandBuffer(jobs_command_buffer, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    const barrier = [_]vk.ImageMemoryBarrier{
        .{
            .src_access_mask = .{ .shader_read_bit = true },
            .dst_access_mask = .{},
            .old_layout = .shader_read_only_optimal,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = texture_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        },
    };
    const src_stage = vk.PipelineStageFlags{ .fragment_shader_bit = true };
    const dst_stage = vk.PipelineStageFlags{ .bottom_of_pipe_bit = true };
    const dependency_flags = vk.DependencyFlags{};
    device_dispatch.cmdPipelineBarrier(
        jobs_command_buffer,
        src_stage,
        dst_stage,
        dependency_flags,
        0,
        undefined,
        0,
        undefined,
        1,
        &barrier,
    );

    try device_dispatch.endCommandBuffer(jobs_command_buffer);

    const submit_command_infos = [_]vk.SubmitInfo{.{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    }};

    const job_fence = try device_dispatch.createFence(
        logical_device,
        &.{ .flags = .{ .signaled_bit = false } },
        null,
    );

    try device_dispatch.queueSubmit(graphics_present_queue, 1, &submit_command_infos, job_fence);
    _ = try device_dispatch.waitForFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &job_fence),
        vk.TRUE,
        std.time.ns_per_s * 2,
    );
    device_dispatch.destroyFence(logical_device, job_fence, null);
    device_dispatch.freeCommandBuffers(
        logical_device,
        command_pool,
        1,
        @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
    );
}

fn transitionTextureToOptimal() !void {
    const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    try device_dispatch.allocateCommandBuffers(
        logical_device,
        &command_buffer_allocate_info,
        @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
    );
    try device_dispatch.beginCommandBuffer(jobs_command_buffer, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    const barrier = [_]vk.ImageMemoryBarrier{
        .{
            .src_access_mask = .{},
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .general,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = texture_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        },
    };

    {
        const src_stage = vk.PipelineStageFlags{ .top_of_pipe_bit = true };
        const dst_stage = vk.PipelineStageFlags{ .fragment_shader_bit = true };
        const dependency_flags = vk.DependencyFlags{};
        device_dispatch.cmdPipelineBarrier(
            jobs_command_buffer,
            src_stage,
            dst_stage,
            dependency_flags,
            0,
            undefined,
            0,
            undefined,
            1,
            &barrier,
        );
    }

    try device_dispatch.endCommandBuffer(jobs_command_buffer);

    const submit_command_infos = [_]vk.SubmitInfo{.{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    }};

    const job_fence = try device_dispatch.createFence(logical_device, &.{ .flags = .{ .signaled_bit = false } }, null);
    try device_dispatch.queueSubmit(graphics_present_queue, 1, &submit_command_infos, job_fence);
    _ = try device_dispatch.waitForFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &job_fence),
        vk.TRUE,
        std.time.ns_per_s * 2,
    );
    device_dispatch.destroyFence(logical_device, job_fence, null);
    device_dispatch.freeCommandBuffers(
        logical_device,
        command_pool,
        1,
        @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
    );
}

pub fn addTexture(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: [*]graphics.RGBA(u8),
) !ImageHandle {
    _ = try device_dispatch.waitForFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &inflight_fences[previous_frame]),
        vk.TRUE,
        std.math.maxInt(u64),
    );
    try transitionTextureToGeneral();

    const dst_extent = try texture_atlas.reserve(geometry.Extent2D(u32), allocator, width, height);
    var src_y: u32 = 0;
    while (src_y < height) : (src_y += 1) {
        var src_x: u32 = 0;
        while (src_x < width) : (src_x += 1) {
            const src_index = src_x + (src_y * width);
            const dst_index = dst_extent.x + src_x + ((dst_extent.y + src_y) * texture_layer_dimensions.width);
            texture_memory_map[dst_index].r = 1.0; // @intToFloat(f32, pixels[src_index].r) / 255;
            texture_memory_map[dst_index].g = 1.0; // @intToFloat(f32, pixels[src_index].g) / 255;
            texture_memory_map[dst_index].b = 1.0; // @intToFloat(f32, pixels[src_index].b) / 255;
            texture_memory_map[dst_index].a = @intToFloat(f32, pixels[src_index].a) / 255;
        }
    }
    std.debug.assert(dst_extent.width == width);
    std.debug.assert(dst_extent.height == height);

    try transitionTextureToOptimal();

    return ImageHandle{
        .texture_array_index = 0,
        .x = @intCast(u12, dst_extent.x),
        .y = @intCast(u12, dst_extent.y),
        ._width = @intCast(u12, dst_extent.width),
        ._height = @intCast(u12, dst_extent.height),
        .reserved = 0,
    };
}

pub fn renderFrame(screen_dimensions: geometry.Dimensions2D(u16)) !void {
    _ = try device_dispatch.waitForFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &inflight_fences[current_frame]),
        vk.TRUE,
        std.math.maxInt(u64),
    );

    try device_dispatch.resetFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &inflight_fences[current_frame]),
    );

    const acquire_image_result = try device_dispatch.acquireNextImageKHR(
        logical_device,
        swapchain,
        std.math.maxInt(u64),
        images_available[current_frame],
        .null_handle,
    );

    // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/vkAcquireNextImageKHR.html
    switch (acquire_image_result.result) {
        .success => {},
        .error_out_of_date_khr, .suboptimal_khr => {
            std.log.warn("error_out_of_date_khr or suboptimal_khr", .{});
            try recreateSwapchain(screen_dimensions);
            return;
        },
        .error_out_of_host_memory => return error.VulkanHostOutOfMemory,
        .error_out_of_device_memory => return error.VulkanDeviceOutOfMemory,
        .error_device_lost => return error.VulkanDeviceLost,
        .error_surface_lost_khr => return error.VulkanSurfaceLost,
        .error_full_screen_exclusive_mode_lost_ext => return error.VulkanFullScreenExclusiveModeLost,
        .timeout => return error.VulkanAcquireFramebufferImageTimeout,
        .not_ready => return error.VulkanAcquireFramebufferImageNotReady,
        else => return error.VulkanAcquireNextImageUnknown,
    }

    const swapchain_image_index = acquire_image_result.image_index;

    const wait_semaphores = [1]vk.Semaphore{images_available[current_frame]};
    const wait_stages = [1]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
    const signal_semaphores = [1]vk.Semaphore{renders_finished[current_frame]};

    const command_submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &wait_semaphores,
        .p_wait_dst_stage_mask = @ptrCast([*]align(4) const vk.PipelineStageFlags, &wait_stages),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]vk.CommandBuffer, &command_buffers[swapchain_image_index]),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = &signal_semaphores,
    };

    try device_dispatch.queueSubmit(
        graphics_present_queue,
        1,
        @ptrCast([*]const vk.SubmitInfo, &command_submit_info),
        inflight_fences[current_frame],
    );

    const swapchains = [1]vk.SwapchainKHR{swapchain};
    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &signal_semaphores,
        .swapchain_count = 1,
        .p_swapchains = &swapchains,
        .p_image_indices = @ptrCast([*]const u32, &swapchain_image_index),
        .p_results = null,
    };

    const present_result = try device_dispatch.queuePresentKHR(graphics_present_queue, &present_info);

    // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/vkQueuePresentKHR.html
    switch (present_result) {
        .success => {},
        .error_out_of_date_khr, .suboptimal_khr => {
            try recreateSwapchain(screen_dimensions);
            return;
        },
        .error_out_of_host_memory => return error.VulkanHostOutOfMemory,
        .error_out_of_device_memory => return error.VulkanDeviceOutOfMemory,
        .error_device_lost => return error.VulkanDeviceLost,
        .error_surface_lost_khr => return error.VulkanSurfaceLost,
        .error_full_screen_exclusive_mode_lost_ext => return error.VulkanFullScreenExclusiveModeLost,
        .timeout => return error.VulkanAcquireFramebufferImageTimeout,
        .not_ready => return error.VulkanAcquireFramebufferImageNotReady,
        else => {
            return error.VulkanQueuePresentUnknown;
        },
    }

    previous_frame = current_frame;
    current_frame = (current_frame + 1) % max_frames_in_flight;
}

fn createSwapchainImageViews() !void {
    for (swapchain_image_views) |*image_view, image_view_i| {
        const image_view_create_info = vk.ImageViewCreateInfo{
            .image = swapchain_images[image_view_i],
            .view_type = .@"2d",
            .format = swapchain_surface_format.format,
            .components = vk.ComponentMapping{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = vk.ImageSubresourceRange{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .flags = .{},
        };
        image_view.* = try device_dispatch.createImageView(logical_device, &image_view_create_info, null);
    }
}

fn createRenderPass() !vk.RenderPass {
    return try device_dispatch.createRenderPass(logical_device, &vk.RenderPassCreateInfo{
        .attachment_count = 2,
        .p_attachments = &[2]vk.AttachmentDescription{
            //
            // [0] Multisampled Image
            //
            .{
                .format = swapchain_surface_format.format,
                .samples = antialias_sample_count,
                .load_op = .clear,
                .store_op = .dont_care,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .undefined,
                .final_layout = .color_attachment_optimal,
                .flags = .{},
            },
            //
            // [1] Swapchain
            //
            .{
                .format = swapchain_surface_format.format,
                .samples = .{ .@"1_bit" = true },
                .load_op = .dont_care,
                .store_op = .store,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .undefined,
                .final_layout = .present_src_khr,
                .flags = .{},
            },
        },
        .subpass_count = 1,
        .p_subpasses = &[1]vk.SubpassDescription{
            .{
                .pipeline_bind_point = .graphics,
                .color_attachment_count = 1,
                .p_color_attachments = &[1]vk.AttachmentReference{
                    vk.AttachmentReference{
                        .attachment = 0, // multisampled
                        .layout = .color_attachment_optimal,
                    },
                },
                .input_attachment_count = 0,
                .p_input_attachments = undefined,
                .p_resolve_attachments = &[1]vk.AttachmentReference{
                    vk.AttachmentReference{
                        .attachment = 1, // swapchain
                        .layout = .color_attachment_optimal,
                    },
                },
                .p_depth_stencil_attachment = null,
                .preserve_attachment_count = 0,
                .p_preserve_attachments = undefined,
                .flags = .{},
            },
        },
        .dependency_count = 2,
        .p_dependencies = &[2]vk.SubpassDependency{
            .{
                .src_subpass = vk.SUBPASS_EXTERNAL,
                .dst_subpass = 0,
                .src_stage_mask = .{ .bottom_of_pipe_bit = true },
                .dst_stage_mask = .{ .color_attachment_output_bit = true },
                .src_access_mask = .{ .memory_read_bit = true },
                .dst_access_mask = .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
                .dependency_flags = .{ .by_region_bit = true },
            },
            .{
                .src_subpass = 0,
                .dst_subpass = vk.SUBPASS_EXTERNAL,
                .src_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_stage_mask = .{ .bottom_of_pipe_bit = true },
                .src_access_mask = .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
                .dst_access_mask = .{ .memory_read_bit = true },
                .dependency_flags = .{ .by_region_bit = true },
            },
        },
        .flags = .{},
    }, null);
}

fn createDescriptorPool() !vk.DescriptorPool {
    const image_count: u32 = @intCast(u32, swapchain_image_views.len);
    const descriptor_pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .type = .sampler,
            .descriptor_count = image_count,
        },
        .{
            .type = .sampled_image,
            .descriptor_count = image_count,
        },
    };
    const create_pool_info = vk.DescriptorPoolCreateInfo{
        .pool_size_count = descriptor_pool_sizes.len,
        .p_pool_sizes = &descriptor_pool_sizes,
        .max_sets = image_count,
        .flags = .{},
    };
    return try device_dispatch.createDescriptorPool(logical_device, &create_pool_info, null);
}

fn createDescriptorSetLayouts(allocator: std.mem.Allocator) !void {
    descriptor_set_layouts = try allocator.alloc(vk.DescriptorSetLayout, swapchain_image_views.len);
    {
        const descriptor_set_layout_bindings = [_]vk.DescriptorSetLayoutBinding{vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_immutable_samplers = null,
            .stage_flags = .{ .fragment_bit = true },
        }};
        const descriptor_set_layout_create_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = 1,
            .p_bindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, &descriptor_set_layout_bindings[0]),
            .flags = .{},
        };
        descriptor_set_layouts[0] = try device_dispatch.createDescriptorSetLayout(logical_device, &descriptor_set_layout_create_info, null);

        // We can copy the same descriptor set layout for each swapchain image
        var x: u32 = 1;
        while (x < swapchain_image_views.len) : (x += 1) {
            descriptor_set_layouts[x] = descriptor_set_layouts[0];
        }
    }
}

fn createDescriptorSets(allocator: std.mem.Allocator) !void {
    const swapchain_image_count: u32 = @intCast(u32, swapchain_image_views.len);

    // 1. Allocate DescriptorSets from DescriptorPool
    descriptor_sets = try allocator.alloc(vk.DescriptorSet, swapchain_image_count);
    {
        const descriptor_set_allocator_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = swapchain_image_count,
            .p_set_layouts = descriptor_set_layouts.ptr,
        };
        try device_dispatch.allocateDescriptorSets(logical_device, &descriptor_set_allocator_info, @ptrCast([*]vk.DescriptorSet, descriptor_sets.ptr));
    }

    // 2. Create Sampler that will be written to DescriptorSet
    const sampler_create_info = vk.SamplerCreateInfo{
        .flags = .{},
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0.0,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 16.0,
        .border_color = .int_opaque_black,
        .min_lod = 0.0,
        .max_lod = 0.0,
        .unnormalized_coordinates = vk.FALSE,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .mipmap_mode = .linear,
    };
    sampler = try device_dispatch.createSampler(logical_device, &sampler_create_info, null);

    // 3. Write to DescriptorSets
    var i: u32 = 0;
    while (i < swapchain_image_count) : (i += 1) {
        const descriptor_image_info = [_]vk.DescriptorImageInfo{
            .{
                .image_layout = .shader_read_only_optimal,
                .image_view = texture_image_view,
                .sampler = sampler,
            },
        };
        const write_descriptor_set = [_]vk.WriteDescriptorSet{.{
            .dst_set = descriptor_sets[i],
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .p_image_info = &descriptor_image_info,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }};
        device_dispatch.updateDescriptorSets(logical_device, 1, &write_descriptor_set, 0, undefined);
    }
}

fn createPipelineLayout() !vk.PipelineLayout {
    const push_constant = vk.PushConstantRange{
        .stage_flags = .{ .fragment_bit = true },
        .offset = 0,
        .size = @sizeOf(PushConstant),
    };
    const pipeline_layout_create_info = vk.PipelineLayoutCreateInfo{
        .set_layout_count = 1,
        .p_set_layouts = descriptor_set_layouts.ptr,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast([*]const vk.PushConstantRange, &push_constant),
        .flags = .{},
    };
    return device_dispatch.createPipelineLayout(logical_device, &pipeline_layout_create_info, null);
}

fn createGraphicsPipeline(
    screen_dimensions: geometry.Dimensions2D(u16),
) !void {
    const vertex_input_attribute_descriptions = [_]vk.VertexInputAttributeDescription{
        vk.VertexInputAttributeDescription{ // inPosition
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = 0,
        },
        vk.VertexInputAttributeDescription{ // inTexCoord
            .binding = 0,
            .location = 1,
            .format = .r32g32_sfloat,
            .offset = 8,
        },
        vk.VertexInputAttributeDescription{ // inColor
            .binding = 0,
            .location = 2,
            .format = .r32g32b32a32_sfloat,
            .offset = 16,
        },
    };

    const vertex_shader_stage_info = vk.PipelineShaderStageCreateInfo{
        .stage = .{ .vertex_bit = true },
        .module = vertex_shader_module,
        .p_name = "main",
        .p_specialization_info = null,
        .flags = .{},
    };

    const fragment_shader_stage_info = vk.PipelineShaderStageCreateInfo{
        .stage = .{ .fragment_bit = true },
        .module = fragment_shader_module,
        .p_name = "main",
        .p_specialization_info = null,
        .flags = .{},
    };

    const shader_stages = [2]vk.PipelineShaderStageCreateInfo{
        vertex_shader_stage_info,
        fragment_shader_stage_info,
    };

    const vertex_input_binding_descriptions = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(graphics.GenericVertex),
        .input_rate = .vertex,
    };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = @intCast(u32, 1),
        .vertex_attribute_description_count = @intCast(u32, 3),
        .p_vertex_binding_descriptions = @ptrCast([*]const vk.VertexInputBindingDescription, &vertex_input_binding_descriptions),
        .p_vertex_attribute_descriptions = @ptrCast([*]const vk.VertexInputAttributeDescription, &vertex_input_attribute_descriptions),
        .flags = .{},
    };

    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
        .flags = .{},
    };

    const viewports = [1]vk.Viewport{
        vk.Viewport{
            .x = 0.0,
            .y = 0.0,
            .width = @intToFloat(f32, screen_dimensions.width),
            .height = @intToFloat(f32, screen_dimensions.height),
            .min_depth = 0.0,
            .max_depth = 1.0,
        },
    };

    const scissors = [1]vk.Rect2D{
        vk.Rect2D{
            .offset = vk.Offset2D{
                .x = 0,
                .y = 0,
            },
            .extent = vk.Extent2D{
                .width = screen_dimensions.width,
                .height = screen_dimensions.height,
            },
        },
    };

    const viewport_state = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = &viewports,
        .scissor_count = 1,
        .p_scissors = &scissors,
        .flags = .{},
    };

    const rasterizer = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .line_width = 1.0,
        .cull_mode = .{},
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_clamp = 0.0,
        .depth_bias_slope_factor = 0.0,
        .flags = .{},
    };

    const multisampling = vk.PipelineMultisampleStateCreateInfo{
        .sample_shading_enable = vk.FALSE,
        .rasterization_samples = antialias_sample_count,
        .min_sample_shading = 0.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
        .flags = .{},
    };

    const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .blend_enable = vk.TRUE,
        .alpha_blend_op = .add,
        .color_blend_op = .add,
        .dst_alpha_blend_factor = .one,
        .src_alpha_blend_factor = .one,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .src_color_blend_factor = .src_alpha,
    };

    const blend_constants = [1]f32{0.0} ** 4;
    const color_blending = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast([*]const vk.PipelineColorBlendAttachmentState, &color_blend_attachment),
        .blend_constants = blend_constants,
        .flags = .{},
    };

    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic_state_create_info = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = 2,
        .p_dynamic_states = @ptrCast([*]const vk.DynamicState, &dynamic_states),
        .flags = .{},
    };

    const pipeline_create_infos = [1]vk.GraphicsPipelineCreateInfo{
        vk.GraphicsPipelineCreateInfo{
            .stage_count = 2,
            .p_stages = &shader_stages,
            .p_vertex_input_state = &vertex_input_info,
            .p_input_assembly_state = &input_assembly,
            .p_tessellation_state = null,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisampling,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &color_blending,
            .p_dynamic_state = &dynamic_state_create_info,
            .layout = pipeline_layout,
            .render_pass = render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = 0,
            .flags = .{},
        },
    };

    // TODO: Check vkResult
    _ = try device_dispatch.createGraphicsPipelines(
        logical_device,
        .null_handle,
        1,
        &pipeline_create_infos,
        null,
        @ptrCast([*]vk.Pipeline, &graphics_pipeline),
    );
}

fn cleanupSwapchain(allocator: std.mem.Allocator) void {
    device_dispatch.freeCommandBuffers(
        logical_device,
        command_pool,
        @intCast(u32, command_buffers.len),
        command_buffers.ptr,
    );
    allocator.free(command_buffers);

    for (swapchain_image_views) |image_view| {
        device_dispatch.destroyImageView(logical_device, image_view, null);
    }
    device_dispatch.destroySwapchainKHR(logical_device, swapchain, null);
}

fn createFramebuffers(
    allocator: std.mem.Allocator,
    screen_dimensions: geometry.Dimensions2D(u16),
) !void {
    std.debug.assert(swapchain_image_views.len > 0);
    var framebuffer_create_info = vk.FramebufferCreateInfo{
        .render_pass = render_pass,
        .attachment_count = 2,
        .p_attachments = undefined,
        .width = screen_dimensions.width,
        .height = screen_dimensions.height,
        .layers = 1,
        .flags = .{},
    };

    framebuffers = try allocator.alloc(vk.Framebuffer, swapchain_image_views.len);
    var attachment_buffer = [2]vk.ImageView{ multisampled_image_view, undefined };
    var i: u32 = 0;
    while (i < swapchain_image_views.len) : (i += 1) {
        // We reuse framebuffer_create_info for each framebuffer we create,
        // only updating the swapchain_image_view that is attached
        attachment_buffer[1] = swapchain_image_views[i];
        framebuffer_create_info.p_attachments = &attachment_buffer;
        framebuffers[i] = try device_dispatch.createFramebuffer(logical_device, &framebuffer_create_info, null);
    }
}

pub fn deinit(allocator: std.mem.Allocator) void {
    device_dispatch.deviceWaitIdle(logical_device) catch std.time.sleep(std.time.ns_per_ms * 20);

    cleanupSwapchain(allocator);

    allocator.free(images_available);
    allocator.free(renders_finished);
    allocator.free(inflight_fences);

    allocator.free(swapchain_image_views);
    allocator.free(swapchain_images);

    allocator.free(descriptor_set_layouts);
    allocator.free(descriptor_sets);
    allocator.free(framebuffers);

    instance_dispatch.destroySurfaceKHR(instance, surface, null);
}

fn createFragmentShaderModule() !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = shaders.fragment_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shaders.fragment_spv)),
        .flags = .{},
    };
    return try device_dispatch.createShaderModule(logical_device, &create_info, null);
}

fn createVertexShaderModule() !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = shaders.vertex_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shaders.vertex_spv)),
        .flags = .{},
    };
    return try device_dispatch.createShaderModule(logical_device, &create_info, null);
}

fn selectSurfaceFormat(
    allocator: std.mem.Allocator,
    color_space: vk.ColorSpaceKHR,
    surface_format: vk.Format,
) !?vk.SurfaceFormatKHR {
    var format_count: u32 = undefined;
    if (.success != (try instance_dispatch.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null))) {
        return error.FailedToGetSurfaceFormats;
    }

    if (format_count == 0) {
        // NOTE: This should not happen. As per spec:
        //       "The number of format pairs supported must be greater than or equal to 1"
        // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/vkGetPhysicalDeviceSurfaceFormatsKHR.html
        std.log.err("Selected surface doesn't support any formats. This may be a vulkan driver bug", .{});
        return error.VulkanSurfaceContainsNoSupportedFormats;
    }

    var formats: []vk.SurfaceFormatKHR = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
    defer allocator.free(formats);

    if (.success != (try instance_dispatch.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, formats.ptr))) {
        return error.FailedToGetSurfaceFormats;
    }

    for (formats) |format| {
        if (format.format == surface_format and format.color_space == color_space) {
            return format;
        }
    }
    return null;
}

pub fn createMultiSampledImage(width: u32, height: u32, memory_heap_index: u32) !void {
    const image_create_info = vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = .b8g8r8a8_unorm,
        .tiling = .optimal,
        .extent = vk.Extent3D{
            .width = width,
            .height = height,
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .initial_layout = .undefined,
        .usage = .{ .transient_attachment_bit = true, .color_attachment_bit = true },
        .samples = antialias_sample_count,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    multisampled_image = try device_dispatch.createImage(logical_device, &image_create_info, null);

    const multisampled_image_requirements = device_dispatch.getImageMemoryRequirements(logical_device, multisampled_image);

    multisampled_image_memory = try device_dispatch.allocateMemory(logical_device, &vk.MemoryAllocateInfo{
        .allocation_size = multisampled_image_requirements.size,
        .memory_type_index = memory_heap_index,
    }, null);

    try device_dispatch.bindImageMemory(logical_device, multisampled_image, multisampled_image_memory, 0);

    multisampled_image_view = try device_dispatch.createImageView(logical_device, &vk.ImageViewCreateInfo{
        .flags = .{},
        .image = multisampled_image,
        .view_type = .@"2d_array",
        .format = .b8g8r8a8_unorm,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
    }, null);
}

pub fn init(
    allocator: std.mem.Allocator,
    screen_dimensions: geometry.Dimensions2D(u16),
    wayland_display: *Display,
    wayland_surface: *Surface,
    atlas: *Atlas,
) !void {
    texture_atlas = atlas;

    if (clib.dlopen("libvulkan.so.1", clib.RTLD_NOW)) |vulkan_loader| {
        const vk_get_instance_proc_addr_fn_opt = @ptrCast(?*const fn (instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction, clib.dlsym(vulkan_loader, "vkGetInstanceProcAddr"));
        if (vk_get_instance_proc_addr_fn_opt) |vk_get_instance_proc_addr_fn| {
            vkGetInstanceProcAddr = vk_get_instance_proc_addr_fn;
            base_dispatch = try vulkan_config.BaseDispatch.load(vkGetInstanceProcAddr);
        } else {
            std.log.err("Failed to load vkGetInstanceProcAddr function from vulkan loader", .{});
            return error.FailedToGetVulkanSymbol;
        }
    } else {
        std.log.err("Failed to load vulkan loader (libvulkan.so.1)", .{});
        return error.FailedToGetVulkanSymbol;
    }

    base_dispatch = try vulkan_config.BaseDispatch.load(vkGetInstanceProcAddr);

    instance = try base_dispatch.createInstance(&vk.InstanceCreateInfo{
        .p_application_info = &vk.ApplicationInfo{
            .p_application_name = application_name,
            .application_version = vulkan_application_version,
            .p_engine_name = vulkan_engine_name,
            .engine_version = vulkan_engine_version,
            .api_version = vulkan_api_version,
        },
        .enabled_extension_count = surface_extensions.len,
        .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, &surface_extensions),
        .enabled_layer_count = if (enable_validation_layers) validation_layers.len else 0,
        .pp_enabled_layer_names = if (enable_validation_layers) &validation_layers else undefined,
        .flags = .{},
    }, null);

    instance_dispatch = try vulkan_config.InstanceDispatch.load(instance, vkGetInstanceProcAddr);
    errdefer instance_dispatch.destroyInstance(instance, null);

    {
        const wayland_surface_create_info = vk.WaylandSurfaceCreateInfoKHR{
            .display = @ptrCast(*vk.wl_display, wayland_display),
            .surface = @ptrCast(*vk.wl_surface, wayland_surface),
            .flags = .{},
        };

        surface = try instance_dispatch.createWaylandSurfaceKHR(
            instance,
            &wayland_surface_create_info,
            null,
        );
    }
    errdefer instance_dispatch.destroySurfaceKHR(instance, surface, null);

    // Find a suitable physical device (GPU/APU) to use
    // Criteria:
    //   1. Supports defined list of device extensions. See `device_extensions` above
    //   2. Has a graphics queue that supports presentation on our selected surface
    const best_physical_device_opt = outer: {
        const physical_devices = blk: {
            var device_count: u32 = 0;
            if (.success != (try instance_dispatch.enumeratePhysicalDevices(instance, &device_count, null))) {
                std.log.warn("Failed to query physical device count", .{});
                return error.PhysicalDeviceQueryFailure;
            }

            if (device_count == 0) {
                std.log.warn("No physical devices found", .{});
                return error.NoDevicesFound;
            }

            const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
            _ = try instance_dispatch.enumeratePhysicalDevices(instance, &device_count, devices.ptr);

            break :blk devices;
        };
        defer allocator.free(physical_devices);

        for (physical_devices) |device, device_i| {
            std.log.info("Physical vulkan devices found: {d}", .{physical_devices.len});

            const device_supports_extensions = blk: {
                var extension_count: u32 = undefined;
                if (.success != (try instance_dispatch.enumerateDeviceExtensionProperties(device, null, &extension_count, null))) {
                    std.log.warn("Failed to get device extension property count for physical device index {d}", .{device_i});
                    continue;
                }

                const extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
                defer allocator.free(extensions);

                if (.success != (try instance_dispatch.enumerateDeviceExtensionProperties(device, null, &extension_count, extensions.ptr))) {
                    std.log.warn("Failed to load device extension properties for physical device index {d}", .{device_i});
                    continue;
                }

                dev_extensions: for (device_extensions) |requested_extension| {
                    for (extensions) |available_extension| {
                        // NOTE: We are relying on device_extensions to only contain c strings up to 255 charactors
                        //       available_extension.extension_name will always be a null terminated string in a 256 char buffer
                        // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/VK_MAX_EXTENSION_NAME_SIZE.html
                        if (std.cstr.cmp(requested_extension, @ptrCast([*:0]const u8, &available_extension.extension_name)) == 0) {
                            continue :dev_extensions;
                        }
                    }
                    break :blk false;
                }
                break :blk true;
            };

            if (!device_supports_extensions) {
                continue;
            }

            var queue_family_count: u32 = 0;
            instance_dispatch.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

            if (queue_family_count == 0) {
                continue;
            }

            const max_family_queues: u32 = 16;
            if (queue_family_count > max_family_queues) {
                std.log.warn("Some family queues for selected device ignored", .{});
            }

            var queue_families: [max_family_queues]vk.QueueFamilyProperties = undefined;
            instance_dispatch.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, &queue_families);

            std.debug.print("** Queue Families found on device **\n\n", .{});
            printVulkanQueueFamilies(queue_families[0..queue_family_count], 0);

            for (queue_families[0..queue_family_count]) |queue_family, queue_family_i| {
                if (queue_family.queue_count <= 0) {
                    continue;
                }
                if (queue_family.queue_flags.graphics_bit) {
                    const present_support = try instance_dispatch.getPhysicalDeviceSurfaceSupportKHR(
                        device,
                        @intCast(u32, queue_family_i),
                        surface,
                    );
                    if (present_support != 0) {
                        graphics_present_queue_index = @intCast(u32, queue_family_i);
                        break :outer device;
                    }
                }
            }
            // If we reach here, we couldn't find a suitable present_queue an will
            // continue to the next device
        }
        break :outer null;
    };

    if (best_physical_device_opt) |best_physical_device| {
        physical_device = best_physical_device;
    } else return error.NoSuitablePhysicalDevice;

    antialias_sample_count = blk: {
        const physical_device_properties = instance_dispatch.getPhysicalDeviceProperties(physical_device);
        const sample_counts = physical_device_properties.limits.framebuffer_color_sample_counts;

        std.log.info("Framebuffer color sample counts:", .{});
        std.log.info("1 bit: {}", .{sample_counts.@"1_bit"});
        std.log.info("2 bit: {}", .{sample_counts.@"2_bit"});
        std.log.info("4 bit: {}", .{sample_counts.@"4_bit"});
        std.log.info("8 bit: {}", .{sample_counts.@"8_bit"});
        std.log.info("16 bit: {}", .{sample_counts.@"16_bit"});
        std.log.info("32 bit: {}", .{sample_counts.@"32_bit"});
        std.log.info("64 bit: {}", .{sample_counts.@"64_bit"});

        //
        // Choose the highest sample rate from 16 bit
        // Ignore 32 and 64 bit options
        //

        if (sample_counts.@"16_bit")
            break :blk .{ .@"16_bit" = true };

        if (sample_counts.@"8_bit")
            break :blk .{ .@"8_bit" = true };

        if (sample_counts.@"4_bit")
            break :blk .{ .@"4_bit" = true };

        if (sample_counts.@"2_bit")
            break :blk .{ .@"2_bit" = true };

        break :blk .{ .@"1_bit" = true };
    };

    {
        const device_create_info = vk.DeviceCreateInfo{
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast([*]vk.DeviceQueueCreateInfo, &vk.DeviceQueueCreateInfo{
                .queue_family_index = graphics_present_queue_index,
                .queue_count = 1,
                .p_queue_priorities = &[1]f32{1.0},
                .flags = .{},
            }),
            .p_enabled_features = &vulkan_config.enabled_device_features,
            .enabled_extension_count = device_extensions.len,
            .pp_enabled_extension_names = &device_extensions,
            .enabled_layer_count = if (enable_validation_layers) validation_layers.len else 0,
            .pp_enabled_layer_names = if (enable_validation_layers) &validation_layers else undefined,
            .flags = .{},
        };

        logical_device = try instance_dispatch.createDevice(
            physical_device,
            &device_create_info,
            null,
        );
    }

    device_dispatch = try vulkan_config.DeviceDispatch.load(
        logical_device,
        instance_dispatch.dispatch.vkGetDeviceProcAddr,
    );
    graphics_present_queue = device_dispatch.getDeviceQueue(
        logical_device,
        graphics_present_queue_index,
        0,
    );

    // Query and select appropriate surface format for swapchain

    const surface_format_opt = try selectSurfaceFormat(allocator, .srgb_nonlinear_khr, .b8g8r8a8_unorm);
    if (surface_format_opt) |format| {
        swapchain_surface_format = format;
    } else {
        return error.RequiredSurfaceFormatUnavailable;
    }

    const mesh_memory_index: u32 = blk: {
        // Find the best memory type for storing mesh + texture data
        // Requirements:
        //   - Sufficient space (20mib)
        //   - Host visible (Host refers to CPU. Allows for direct access without needing DMA)
        // Preferable
        //  - Device local (Memory on the GPU / APU)

        const memory_properties = instance_dispatch.getPhysicalDeviceMemoryProperties(physical_device);
        if (print_vulkan_objects.memory_type_all) {
            std.debug.print("\n** Memory heaps found on system **\n\n", .{});
            printVulkanMemoryHeaps(memory_properties, 0);
            std.debug.print("\n", .{});
        }

        const kib: u32 = 1024;
        const mib: u32 = kib * 1024;
        const minimum_space_required: u32 = mib * 20;

        var memory_type_index: u32 = 0;
        var memory_type_count = memory_properties.memory_type_count;

        var suitable_memory_type_index_opt: ?u32 = null;

        while (memory_type_index < memory_type_count) : (memory_type_index += 1) {
            const memory_entry = memory_properties.memory_types[memory_type_index];
            const heap_index = memory_entry.heap_index;

            if (heap_index == memory_properties.memory_heap_count) {
                std.log.warn("Invalid heap index {d} for memory type at index {d}. Skipping", .{ heap_index, memory_type_index });
                continue;
            }

            const heap_size = memory_properties.memory_heaps[heap_index].size;

            if (heap_size < minimum_space_required) {
                continue;
            }

            const memory_flags = memory_entry.property_flags;
            if (memory_flags.host_visible_bit) {
                suitable_memory_type_index_opt = memory_type_index;
                if (memory_flags.device_local_bit) {
                    std.log.info("Selected memory for mesh buffer: Heap index ({d}) Memory index ({d})", .{ heap_index, memory_type_index });
                    break :blk memory_type_index;
                }
            }
        }

        if (suitable_memory_type_index_opt) |suitable_memory_type_index| {
            break :blk suitable_memory_type_index;
        }

        return error.NoValidVulkanMemoryTypes;
    };

    // TODO:
    selected_memory_index = mesh_memory_index;

    {
        const image_create_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = .r32g32b32a32_sfloat,
            .tiling = .linear,
            .extent = vk.Extent3D{
                .width = texture_layer_dimensions.width,
                .height = texture_layer_dimensions.height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .initial_layout = .undefined,
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
            .samples = .{ .@"1_bit" = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        };

        texture_image = try device_dispatch.createImage(logical_device, &image_create_info, null);
    }

    const texture_memory_requirements = device_dispatch.getImageMemoryRequirements(logical_device, texture_image);

    var image_memory = try device_dispatch.allocateMemory(logical_device, &vk.MemoryAllocateInfo{
        .allocation_size = texture_memory_requirements.size,
        .memory_type_index = mesh_memory_index,
    }, null);

    try device_dispatch.bindImageMemory(logical_device, texture_image, image_memory, 0);

    const surface_capabilities = try instance_dispatch.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);

    if (print_vulkan_objects.surface_abilties) {
        std.debug.print("** Selected surface capabilites **\n\n", .{});
        printSurfaceCapabilities(surface_capabilities, 1);
        std.debug.print("\n", .{});
    }

    if (transparancy_enabled) {
        // Check to see if the compositor supports transparent windows and what
        // transparency mode needs to be set when creating the swapchain
        const supported = surface_capabilities.supported_composite_alpha;
        if (supported.pre_multiplied_bit_khr) {
            alpha_mode = .{ .pre_multiplied_bit_khr = true };
        } else if (supported.post_multiplied_bit_khr) {
            alpha_mode = .{ .post_multiplied_bit_khr = true };
        } else if (supported.inherit_bit_khr) {
            alpha_mode = .{ .inherit_bit_khr = true };
        } else {
            std.log.info("Alpha windows not supported", .{});
        }
    }

    if (surface_capabilities.current_extent.width == 0xFFFFFFFF or surface_capabilities.current_extent.height == 0xFFFFFFFF) {
        swapchain_extent.width = screen_dimensions.width;
        swapchain_extent.height = screen_dimensions.height;
    }

    std.debug.assert(swapchain_extent.width >= surface_capabilities.min_image_extent.width);
    std.debug.assert(swapchain_extent.height >= surface_capabilities.min_image_extent.height);

    std.debug.assert(swapchain_extent.width <= surface_capabilities.max_image_extent.width);
    std.debug.assert(swapchain_extent.height <= surface_capabilities.max_image_extent.height);

    swapchain_min_image_count = surface_capabilities.min_image_count + 1;

    // TODO: Perhaps more flexibily should be allowed here. I'm unsure if an application is
    //       supposed to match the rotation of the system / monitor, but I would assume not..
    //       It is also possible that the inherit_bit_khr bit would be set in place of identity_bit_khr
    if (surface_capabilities.current_transform.identity_bit_khr == false) {
        std.log.err("Selected surface does not have the option to leave framebuffer image untransformed." ++
            "This is likely a vulkan bug.", .{});
        return error.VulkanSurfaceTransformInvalid;
    }

    swapchain = try device_dispatch.createSwapchainKHR(logical_device, &vk.SwapchainCreateInfoKHR{
        .surface = surface,
        .min_image_count = swapchain_min_image_count,
        .image_format = swapchain_surface_format.format,
        .image_color_space = swapchain_surface_format.color_space,
        .image_extent = swapchain_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_src_bit = true },
        .image_sharing_mode = .exclusive,
        // NOTE: Only valid when `image_sharing_mode` is CONCURRENT
        // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/VkSwapchainCreateInfoKHR.html
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .pre_transform = .{ .identity_bit_khr = true },
        .composite_alpha = alpha_mode,
        // NOTE: FIFO_KHR is required to be available for all vulkan capable devices
        //       For that reason we don't need to query for it on our selected device
        // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/VkPresentModeKHR.html
        .present_mode = .fifo_khr,
        .clipped = vk.TRUE,
        .flags = .{},
        .old_swapchain = .null_handle,
    }, null);

    swapchain_images = blk: {
        var image_count: u32 = undefined;
        if (.success != (try device_dispatch.getSwapchainImagesKHR(logical_device, swapchain, &image_count, null))) {
            return error.FailedToGetSwapchainImagesCount;
        }

        var images = try allocator.alloc(vk.Image, image_count);
        if (.success != (try device_dispatch.getSwapchainImagesKHR(logical_device, swapchain, &image_count, images.ptr))) {
            return error.FailedToGetSwapchainImages;
        }

        break :blk images;
    };

    swapchain_image_views = try allocator.alloc(vk.ImageView, swapchain_images.len);
    try createSwapchainImageViews();

    try createMultiSampledImage(swapchain_extent.width, swapchain_extent.height, mesh_memory_index);

    command_pool = try device_dispatch.createCommandPool(logical_device, &vk.CommandPoolCreateInfo{
        .queue_family_index = graphics_present_queue_index,
        .flags = .{},
    }, null);

    {
        const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        try device_dispatch.allocateCommandBuffers(
            logical_device,
            &command_buffer_allocate_info,
            @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
        );
    }

    {
        command_buffers = try allocator.alloc(vk.CommandBuffer, swapchain_images.len);
        const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = @intCast(u32, command_buffers.len),
        };
        try device_dispatch.allocateCommandBuffers(
            logical_device,
            &command_buffer_allocate_info,
            command_buffers.ptr,
        );
    }

    try device_dispatch.beginCommandBuffer(jobs_command_buffer, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    std.debug.assert(texture_layer_size <= texture_memory_requirements.size);
    std.debug.assert(texture_memory_requirements.alignment >= 16);
    const last_index: usize = (@intCast(usize, texture_layer_dimensions.width) * texture_layer_dimensions.height) - 1;
    {
        var mapped_memory_ptr = (try device_dispatch.mapMemory(logical_device, image_memory, 0, texture_layer_size, .{})).?;
        texture_memory_map = @ptrCast([*]graphics.RGBA(f32), @alignCast(16, mapped_memory_ptr));
        std.mem.set(graphics.RGBA(f32), texture_memory_map[0..last_index], .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 });
    }

    // Not sure if this is a hack, but because we multiply the texture sample by the
    // color in the fragment shader, we need pixel in the texture that we known will return 1.0
    // Here we're setting the last pixel to 1.0, which corresponds to a texture mapping of 1.0, 1.0
    texture_memory_map[last_index].r = 1.0;
    texture_memory_map[last_index].g = 1.0;
    texture_memory_map[last_index].b = 1.0;
    texture_memory_map[last_index].a = 1.0;

    // Regardless of whether a staging buffer was used, and the type of memory that backs the texture
    // It is neccessary to transition to image layout to SHADER_OPTIMAL
    const barrier = [_]vk.ImageMemoryBarrier{
        .{
            .src_access_mask = .{},
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .undefined,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = texture_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        },
    };

    {
        const src_stage = vk.PipelineStageFlags{ .top_of_pipe_bit = true };
        const dst_stage = vk.PipelineStageFlags{ .fragment_shader_bit = true };
        const dependency_flags = vk.DependencyFlags{};
        device_dispatch.cmdPipelineBarrier(
            jobs_command_buffer,
            src_stage,
            dst_stage,
            dependency_flags,
            0,
            undefined,
            0,
            undefined,
            1,
            &barrier,
        );
    }

    try device_dispatch.endCommandBuffer(jobs_command_buffer);

    const submit_command_infos = [_]vk.SubmitInfo{.{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    }};

    {
        const fence_create_info = vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = false },
        };
        const fence = try device_dispatch.createFence(logical_device, &fence_create_info, null);

        try device_dispatch.queueSubmit(
            graphics_present_queue,
            1,
            &submit_command_infos,
            fence,
        );

        _ = try device_dispatch.waitForFences(
            logical_device,
            1,
            @ptrCast([*]const vk.Fence, &fence),
            vk.TRUE,
            std.time.ns_per_s * 3,
        );
        device_dispatch.destroyFence(logical_device, fence, null);
        device_dispatch.freeCommandBuffers(
            logical_device,
            command_pool,
            1,
            @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
        );
    }

    texture_image_view = try device_dispatch.createImageView(logical_device, &vk.ImageViewCreateInfo{
        .flags = .{},
        .image = texture_image,
        .view_type = .@"2d_array",
        .format = .r32g32b32a32_sfloat,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
    }, null);

    std.debug.assert(vertices_range_index_begin + vertices_range_size <= memory_size);

    var mesh_memory = try device_dispatch.allocateMemory(logical_device, &vk.MemoryAllocateInfo{
        .allocation_size = memory_size,
        .memory_type_index = mesh_memory_index,
    }, null);

    {
        const buffer_create_info = vk.BufferCreateInfo{
            .size = vertices_range_size,
            .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
            .sharing_mode = .exclusive,
            // NOTE: Only valid when `sharing_mode` is CONCURRENT
            // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/VkBufferCreateInfo.html
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
            .flags = .{},
        };

        vulkan_vertices_buffer = try device_dispatch.createBuffer(logical_device, &buffer_create_info, null);
        try device_dispatch.bindBufferMemory(logical_device, vulkan_vertices_buffer, mesh_memory, vertices_range_index_begin);
    }

    {
        const buffer_create_info = vk.BufferCreateInfo{
            .size = indices_range_size,
            .usage = .{ .transfer_dst_bit = true, .index_buffer_bit = true },
            .sharing_mode = .exclusive,
            // NOTE: Only valid when `sharing_mode` is CONCURRENT
            // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/VkBufferCreateInfo.html
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
            .flags = .{},
        };

        vulkan_indices_buffer = try device_dispatch.createBuffer(logical_device, &buffer_create_info, null);
        try device_dispatch.bindBufferMemory(logical_device, vulkan_indices_buffer, mesh_memory, indices_range_index_begin);
    }

    mapped_device_memory = @ptrCast([*]u8, (try device_dispatch.mapMemory(logical_device, mesh_memory, 0, memory_size, .{})).?);

    {
        const Vertex = graphics.GenericVertex;
        const vertex_ptr = @ptrCast([*]Vertex, @alignCast(@alignOf(Vertex), &mapped_device_memory[vertices_range_index_begin]));
        vertices_buffer = vertex_ptr[0..vertices_range_count];
        const indices_ptr = @ptrCast([*]u16, @alignCast(16, &mapped_device_memory[indices_range_index_begin]));
        indices_buffer = indices_ptr[0..indices_range_count];
    }

    images_available = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    renders_finished = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    inflight_fences = try allocator.alloc(vk.Fence, max_frames_in_flight);

    const semaphore_create_info = vk.SemaphoreCreateInfo{
        .flags = .{},
    };

    const fence_create_info = vk.FenceCreateInfo{
        .flags = .{ .signaled_bit = true },
    };

    var i: u32 = 0;
    while (i < max_frames_in_flight) {
        images_available[i] = try device_dispatch.createSemaphore(logical_device, &semaphore_create_info, null);
        renders_finished[i] = try device_dispatch.createSemaphore(logical_device, &semaphore_create_info, null);
        inflight_fences[i] = try device_dispatch.createFence(logical_device, &fence_create_info, null);
        i += 1;
    }

    vertex_shader_module = try createVertexShaderModule();
    fragment_shader_module = try createFragmentShaderModule();

    std.debug.assert(swapchain_images.len > 0);

    render_pass = try createRenderPass();

    try createDescriptorSetLayouts(allocator);
    pipeline_layout = try createPipelineLayout();
    descriptor_pool = try createDescriptorPool();
    try createDescriptorSets(allocator);
    try createGraphicsPipeline(screen_dimensions);
    try createFramebuffers(allocator, screen_dimensions);
}

//
// Print Functions
//

fn printVulkanMemoryHeap(memory_properties: vk.PhysicalDeviceMemoryProperties, heap_index: u32, comptime indent_level: u32) void {
    const heap_count: u32 = memory_properties.memory_heap_count;
    std.debug.assert(heap_index <= heap_count);
    const base_indent = "  " ** indent_level;

    const heap_properties = memory_properties.memory_heaps[heap_index];

    const print = std.debug.print;
    print(base_indent ++ "Heap Index #{d}\n", .{heap_index});
    print(base_indent ++ "  Capacity:       {}\n", .{std.fmt.fmtIntSizeDec(heap_properties.size)});
    print(base_indent ++ "  Device Local:   {}\n", .{heap_properties.flags.device_local_bit});
    print(base_indent ++ "  Multi Instance: {}\n", .{heap_properties.flags.multi_instance_bit});
    print(base_indent ++ "  Memory Types:\n", .{});

    const memory_type_count = memory_properties.memory_type_count;

    var memory_type_i: u32 = 0;
    while (memory_type_i < memory_type_count) : (memory_type_i += 1) {
        if (memory_properties.memory_types[memory_type_i].heap_index == heap_index) {
            print(base_indent ++ "    Memory Index #{}\n", .{memory_type_i});
            const memory_flags = memory_properties.memory_types[memory_type_i].property_flags;
            print(base_indent ++ "      Device Local:     {}\n", .{memory_flags.device_local_bit});
            print(base_indent ++ "      Host Visible:     {}\n", .{memory_flags.host_visible_bit});
            print(base_indent ++ "      Host Coherent:    {}\n", .{memory_flags.host_coherent_bit});
            print(base_indent ++ "      Host Cached:      {}\n", .{memory_flags.host_cached_bit});
            print(base_indent ++ "      Lazily Allocated: {}\n", .{memory_flags.lazily_allocated_bit});
            print(base_indent ++ "      Protected:        {}\n", .{memory_flags.protected_bit});
        }
    }
}

fn printVulkanMemoryHeaps(memory_properties: vk.PhysicalDeviceMemoryProperties, comptime indent_level: u32) void {
    var heap_count: u32 = memory_properties.memory_heap_count;
    var heap_i: u32 = 0;
    while (heap_i < heap_count) : (heap_i += 1) {
        printVulkanMemoryHeap(memory_properties, heap_i, indent_level);
    }
}

fn printVulkanQueueFamilies(queue_families: []vk.QueueFamilyProperties, comptime indent_level: u32) void {
    const print = std.debug.print;
    const base_indent = "  " ** indent_level;
    for (queue_families) |queue_family, queue_family_i| {
        print(base_indent ++ "Queue family index #{d}\n", .{queue_family_i});
        printVulkanQueueFamily(queue_family, indent_level + 1);
    }
}

fn printVulkanQueueFamily(queue_family: vk.QueueFamilyProperties, comptime indent_level: u32) void {
    const print = std.debug.print;
    const base_indent = "  " ** indent_level;
    print(base_indent ++ "Queue count: {d}\n", .{queue_family.queue_count});
    print(base_indent ++ "Support\n", .{});
    print(base_indent ++ "  Graphics: {}\n", .{queue_family.queue_flags.graphics_bit});
    print(base_indent ++ "  Transfer: {}\n", .{queue_family.queue_flags.transfer_bit});
    print(base_indent ++ "  Compute:  {}\n", .{queue_family.queue_flags.compute_bit});
}

fn printSurfaceCapabilities(surface_capabilities: vk.SurfaceCapabilitiesKHR, comptime indent_level: u32) void {
    const print = std.debug.print;
    const base_indent = "  " ** indent_level;
    print(base_indent ++ "min_image_count: {d}\n", .{surface_capabilities.min_image_count});
    print(base_indent ++ "max_image_count: {d}\n", .{surface_capabilities.max_image_count});

    print(base_indent ++ "current_extent\n", .{});
    print(base_indent ++ "  width:    {d}\n", .{surface_capabilities.current_extent.width});
    print(base_indent ++ "  height:   {d}\n", .{surface_capabilities.current_extent.height});

    print(base_indent ++ "min_image_extent\n", .{});
    print(base_indent ++ "  width:    {d}\n", .{surface_capabilities.min_image_extent.width});
    print(base_indent ++ "  height:   {d}\n", .{surface_capabilities.min_image_extent.height});

    print(base_indent ++ "max_image_extent\n", .{});
    print(base_indent ++ "  width:    {d}\n", .{surface_capabilities.max_image_extent.width});
    print(base_indent ++ "  height:   {d}\n", .{surface_capabilities.max_image_extent.height});
    print(base_indent ++ "max_image_array_layers: {d}\n", .{surface_capabilities.max_image_array_layers});

    print(base_indent ++ "supported_usages\n", .{});
    const supported_usage_flags = surface_capabilities.supported_usage_flags;
    print(base_indent ++ "  sampled:                          {}\n", .{supported_usage_flags.sampled_bit});
    print(base_indent ++ "  storage:                          {}\n", .{supported_usage_flags.storage_bit});
    print(base_indent ++ "  color_attachment:                 {}\n", .{supported_usage_flags.color_attachment_bit});
    print(base_indent ++ "  depth_stencil:                    {}\n", .{supported_usage_flags.depth_stencil_attachment_bit});
    print(base_indent ++ "  input_attachment:                 {}\n", .{supported_usage_flags.input_attachment_bit});
    print(base_indent ++ "  transient_attachment:             {}\n", .{supported_usage_flags.transient_attachment_bit});
    print(base_indent ++ "  fragment_shading_rate_attachment: {}\n", .{supported_usage_flags.fragment_shading_rate_attachment_bit_khr});
    print(base_indent ++ "  fragment_density_map:             {}\n", .{supported_usage_flags.fragment_density_map_bit_ext});
    print(base_indent ++ "  video_decode_dst:                 {}\n", .{supported_usage_flags.video_decode_dst_bit_khr});
    print(base_indent ++ "  video_decode_dpb:                 {}\n", .{supported_usage_flags.video_decode_dpb_bit_khr});
    print(base_indent ++ "  video_encode_src:                 {}\n", .{supported_usage_flags.video_encode_src_bit_khr});
    print(base_indent ++ "  video_encode_dpb:                 {}\n", .{supported_usage_flags.video_encode_dpb_bit_khr});

    print(base_indent ++ "supportedCompositeAlpha:\n", .{});
    print(base_indent ++ "  Opaque KHR      {}\n", .{surface_capabilities.supported_composite_alpha.opaque_bit_khr});
    print(base_indent ++ "  Pre Mult KHR    {}\n", .{surface_capabilities.supported_composite_alpha.pre_multiplied_bit_khr});
    print(base_indent ++ "  Post Mult KHR   {}\n", .{surface_capabilities.supported_composite_alpha.post_multiplied_bit_khr});
    print(base_indent ++ "  Inherit KHR     {}\n", .{surface_capabilities.supported_composite_alpha.inherit_bit_khr});
}
