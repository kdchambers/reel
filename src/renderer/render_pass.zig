// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const builtin = @import("builtin");
const vk = @import("vulkan");

const geometry = @import("../geometry.zig");

const vulkan_core = @import("vulkan_core.zig");

pub var multisampled_image: vk.Image = undefined;
pub var multisampled_image_view: vk.ImageView = undefined;
pub var multisampled_image_memory: vk.DeviceMemory = undefined;
pub var antialias_sample_count: vk.SampleCountFlags = undefined;
pub var pass: vk.RenderPass = undefined;

pub var have_multisample: bool = false;

const cache = struct {
    var multi_sampled_image_memory_index: u32 = 0;
};

pub fn init(
    swapchain_extent: vk.Extent2D,
    swapchain_format: vk.Format,
    multi_sampled_image_memory_index: u32,
) !void {
    cache.multi_sampled_image_memory_index = multi_sampled_image_memory_index;

    antialias_sample_count = blk: {
        const physical_device_properties = vulkan_core.instance_dispatch.getPhysicalDeviceProperties(vulkan_core.physical_device);
        const sample_counts = physical_device_properties.limits.framebuffer_color_sample_counts;

        //
        // Choose the highest sample rate from 16 bit
        // Ignore 32 and 64 bit options
        //

        have_multisample = true;

        if (sample_counts.@"16_bit")
            break :blk .{ .@"16_bit" = true };

        if (sample_counts.@"8_bit")
            break :blk .{ .@"8_bit" = true };

        if (sample_counts.@"4_bit")
            break :blk .{ .@"4_bit" = true };

        if (sample_counts.@"2_bit")
            break :blk .{ .@"2_bit" = true };

        have_multisample = false;

        break :blk .{ .@"1_bit" = true };
    };

    if (have_multisample) {
        try createMultiSampledImage(swapchain_extent.width, swapchain_extent.height, multi_sampled_image_memory_index);
    }
    pass = try createRenderPass(swapchain_format);
}

pub fn resizeSwapchain(screen_dimensions: geometry.Dimensions2D(u16)) !void {
    if (!have_multisample)
        return;

    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    device_dispatch.destroyImage(logical_device, multisampled_image, null);
    device_dispatch.destroyImageView(logical_device, multisampled_image_view, null);
    //
    // TODO: See can you reuse the memory
    //
    device_dispatch.freeMemory(logical_device, multisampled_image_memory, null);
    try createMultiSampledImage(
        screen_dimensions.width,
        screen_dimensions.height,
        cache.multi_sampled_image_memory_index,
    );
}

fn createRenderPass(swapchain_format: vk.Format) !vk.RenderPass {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    const attachments: [2]vk.AttachmentDescription = if (have_multisample) .{
        //
        // [0] Multisampled Image
        //
        .{
            .format = swapchain_format,
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
            .format = swapchain_format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .dont_care,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
            .flags = .{},
        },
    } else .{
        //
        // [0] Swapchain
        //
        .{
            .format = swapchain_format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
            .flags = .{},
        },
        undefined,
    };

    const subpasses: [1]vk.SubpassDescription = if (have_multisample) .{
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
    } else .{
        .{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = 1,
            .p_color_attachments = &[1]vk.AttachmentReference{
                vk.AttachmentReference{
                    .attachment = 0,
                    .layout = .color_attachment_optimal,
                },
            },
            .input_attachment_count = 0,
            .p_input_attachments = undefined,
            .p_resolve_attachments = null,
            .p_depth_stencil_attachment = null,
            .preserve_attachment_count = 0,
            .p_preserve_attachments = undefined,
            .flags = .{},
        },
    };

    const dependencies: [2]vk.SubpassDependency = if (have_multisample) .{
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
    } else .{
        .{
            .src_subpass = vk.SUBPASS_EXTERNAL,
            .dst_subpass = 0,
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{},
            .dst_access_mask = .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
            .dependency_flags = .{},
        },
        undefined,
    };

    return try device_dispatch.createRenderPass(logical_device, &vk.RenderPassCreateInfo{
        .attachment_count = if (have_multisample) 2 else 1,
        .p_attachments = &attachments,
        .subpass_count = 1,
        .p_subpasses = &subpasses,
        .dependency_count = if (have_multisample) 2 else 1,
        .p_dependencies = &dependencies,
        .flags = .{},
    }, null);
}

fn createMultiSampledImage(width: u32, height: u32, memory_heap_index: u32) !void {
    assert(have_multisample);

    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
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
