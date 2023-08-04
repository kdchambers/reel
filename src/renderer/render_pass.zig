// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const builtin = @import("builtin");
const vk = @import("vulkan");

const geometry = @import("../geometry.zig");
const Dimensions2D = geometry.Dimensions2D;
const Extent2D = geometry.Extent2D;

const vulkan_core = @import("vulkan_core.zig");

pub var antialias_sample_count: vk.SampleCountFlags = undefined;

var multisampled_image: vk.Image = undefined;
pub var multisampled_image_view: vk.ImageView = undefined;
var multisampled_image_memory: vk.DeviceMemory = undefined;

var depth_image: vk.Image = undefined;
pub var depth_image_view: vk.ImageView = undefined;
var depth_image_memory: vk.DeviceMemory = undefined;

pub var pass: vk.RenderPass = undefined;

pub var have_multisample: bool = false;

const cache = struct {
    var multi_sampled_image_memory_index: u32 = 0;
};

var current_depth_image_requirements: vk.MemoryRequirements = undefined;
var current_multisample_image_requirements: vk.MemoryRequirements = undefined;

pub fn init(
    swapchain_dimensions: Dimensions2D(u32),
    swapchain_format: vk.Format,
    multi_sampled_image_memory_index: u32,
) !void {
    cache.multi_sampled_image_memory_index = multi_sampled_image_memory_index;
    try createDepthImage(
        swapchain_dimensions.width,
        swapchain_dimensions.height,
        cache.multi_sampled_image_memory_index,
    );

    if (have_multisample) {
        try createMultiSampledImage(swapchain_dimensions, multi_sampled_image_memory_index);
    }
    pass = try createRenderPass(swapchain_format);
}

pub fn requiredMemoryTypeIndices() !u64 {
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

    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    var required_bits: u64 = std.math.maxInt(u64);
    {
        const image_create_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = .d32_sfloat,
            .tiling = .optimal,
            .extent = vk.Extent3D{
                .width = 1920,
                .height = 1080,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .initial_layout = .undefined,
            .usage = .{ .transient_attachment_bit = true, .depth_stencil_attachment_bit = true },
            .samples = antialias_sample_count,
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        };
        const temp_image = try device_dispatch.createImage(logical_device, &image_create_info, null);
        const memory_requirements = device_dispatch.getImageMemoryRequirements(logical_device, temp_image);
        required_bits &= memory_requirements.memory_type_bits;
        device_dispatch.destroyImage(logical_device, temp_image, null);
    }

    {
        const image_create_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = .b8g8r8a8_unorm,
            .tiling = .optimal,
            .extent = vk.Extent3D{
                .width = 1920,
                .height = 1080,
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
        const temp_image = try device_dispatch.createImage(logical_device, &image_create_info, null);
        const memory_requirements = device_dispatch.getImageMemoryRequirements(logical_device, temp_image);
        required_bits &= memory_requirements.memory_type_bits;
        device_dispatch.destroyImage(logical_device, temp_image, null);
    }
    return required_bits;
}

fn resizeDepthBuffer(dimensions: geometry.Dimensions2D(u32)) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    device_dispatch.destroyImage(logical_device, depth_image, null);
    device_dispatch.destroyImageView(logical_device, depth_image_view, null);

    const depth_image_create_info = vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = .d32_sfloat,
        .tiling = .optimal,
        .extent = vk.Extent3D{
            .width = dimensions.width,
            .height = dimensions.height,
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .initial_layout = .undefined,
        .usage = .{ .depth_stencil_attachment_bit = true },
        .samples = antialias_sample_count,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    depth_image = try device_dispatch.createImage(logical_device, &depth_image_create_info, null);
    const depth_image_requirements = device_dispatch.getImageMemoryRequirements(logical_device, depth_image);

    const alignment_fine: bool = depth_image_requirements.alignment > current_depth_image_requirements.alignment;
    const memory_type_fine: bool = depth_image_requirements.memory_type_bits == current_depth_image_requirements.memory_type_bits;
    const size_fine: bool = depth_image_requirements.size <= current_depth_image_requirements.size;

    if (!alignment_fine or !memory_type_fine or !size_fine) {
        //
        // We can't reuse the memory we have allocated for the depth buffer, we have to free and reallocate
        //
        current_depth_image_requirements = depth_image_requirements;
        device_dispatch.freeMemory(logical_device, depth_image_memory, null);

        depth_image_memory = try device_dispatch.allocateMemory(logical_device, &vk.MemoryAllocateInfo{
            .allocation_size = depth_image_requirements.size,
            .memory_type_index = cache.multi_sampled_image_memory_index,
        }, null);

        try device_dispatch.bindImageMemory(logical_device, depth_image, depth_image_memory, 0);
    }

    depth_image_view = try device_dispatch.createImageView(logical_device, &vk.ImageViewCreateInfo{
        .flags = .{},
        .image = depth_image,
        .view_type = .@"2d_array",
        .format = .d32_sfloat,
        .subresource_range = .{
            .aspect_mask = .{ .depth_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
    }, null);
}

fn resizeMultisampleBuffer(dimensions: geometry.Dimensions2D(u32)) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    device_dispatch.destroyImage(logical_device, multisampled_image, null);
    device_dispatch.destroyImageView(logical_device, multisampled_image_view, null);

    const image_create_info = vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = .b8g8r8a8_unorm,
        .tiling = .optimal,
        .extent = vk.Extent3D{
            .width = dimensions.width,
            .height = dimensions.height,
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
    const image_requirements = device_dispatch.getImageMemoryRequirements(logical_device, multisampled_image);

    const alignment_fine: bool = image_requirements.alignment > current_multisample_image_requirements.alignment;
    const memory_type_fine: bool = image_requirements.memory_type_bits == current_multisample_image_requirements.memory_type_bits;
    const size_fine: bool = image_requirements.size <= current_multisample_image_requirements.size;

    if (!alignment_fine or !memory_type_fine or !size_fine) {
        //
        // We can't reuse the memory we have allocated for the depth buffer, we have to free and reallocate
        //
        current_multisample_image_requirements = image_requirements;
        device_dispatch.freeMemory(logical_device, multisampled_image_memory, null);

        multisampled_image_memory = try device_dispatch.allocateMemory(logical_device, &vk.MemoryAllocateInfo{
            .allocation_size = image_requirements.size,
            .memory_type_index = cache.multi_sampled_image_memory_index,
        }, null);

        try device_dispatch.bindImageMemory(logical_device, multisampled_image, multisampled_image_memory, 0);
    }

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

pub fn resizeSwapchain(screen_dimensions: geometry.Dimensions2D(u32)) !void {
    try resizeDepthBuffer(screen_dimensions);
    if (have_multisample) {
        try resizeMultisampleBuffer(screen_dimensions);
    }
}

fn createRenderPass(swapchain_format: vk.Format) !vk.RenderPass {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    //
    // TODO: If you reorder these so that multisampled image is last, then all you need to do is
    //       change the length of the array based on have_multisample
    //
    const attachments: [3]vk.AttachmentDescription = if (have_multisample) .{
        //
        // [0] Swapchain
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
        //
        // [1] Depth Buffer
        //
        .{
            .format = .d32_sfloat,
            .samples = antialias_sample_count,
            .load_op = .clear,
            .store_op = .dont_care,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .depth_stencil_attachment_optimal,
            .flags = .{},
        },
        //
        // [2] Multisampled Image
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
        //
        // [1] Depth Buffer
        //
        .{
            .format = .d32_sfloat,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .depth_stencil_attachment_optimal,
            .flags = .{},
        },
        undefined,
    };

    const depth_attachment_ref = vk.AttachmentReference{
        .attachment = 1,
        .layout = .depth_stencil_attachment_optimal,
    };

    const subpasses: [1]vk.SubpassDescription = if (have_multisample) .{
        .{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = 1,
            .p_color_attachments = &[1]vk.AttachmentReference{
                vk.AttachmentReference{
                    .attachment = 2, // multisampled
                    .layout = .color_attachment_optimal,
                },
            },
            .input_attachment_count = 0,
            .p_input_attachments = undefined,
            .p_resolve_attachments = &[1]vk.AttachmentReference{
                vk.AttachmentReference{
                    .attachment = 0, // swapchain
                    .layout = .color_attachment_optimal,
                },
            },
            .p_depth_stencil_attachment = &depth_attachment_ref,
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
            .p_depth_stencil_attachment = &depth_attachment_ref,
            .preserve_attachment_count = 0,
            .p_preserve_attachments = undefined,
            .flags = .{},
        },
    };

    const dependencies: [3]vk.SubpassDependency = .{
        // Swapchain
        .{
            .src_subpass = vk.SUBPASS_EXTERNAL,
            .dst_subpass = 0,
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{},
            .dst_access_mask = .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
            .dependency_flags = .{},
        },
        // Depth buffer
        .{
            .src_subpass = vk.SUBPASS_EXTERNAL,
            .dst_subpass = 0,
            .src_stage_mask = .{ .top_of_pipe_bit = true },
            .dst_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
            .src_access_mask = .{},
            .dst_access_mask = .{ .depth_stencil_attachment_write_bit = true, .depth_stencil_attachment_read_bit = true },
            .dependency_flags = .{},
        },
        // Multisample image
        .{
            .src_subpass = 0,
            .dst_subpass = vk.SUBPASS_EXTERNAL,
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_stage_mask = .{ .bottom_of_pipe_bit = true },
            .src_access_mask = .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
            .dst_access_mask = .{ .memory_read_bit = true },
            .dependency_flags = .{ .by_region_bit = true },
        },
    };

    return try device_dispatch.createRenderPass(logical_device, &vk.RenderPassCreateInfo{
        .attachment_count = if (have_multisample) 3 else 2,
        .p_attachments = &attachments,
        .subpass_count = 1,
        .p_subpasses = &subpasses,
        .dependency_count = if (have_multisample) 3 else 2,
        .p_dependencies = &dependencies,
        .flags = .{},
    }, null);
}

fn createMultiSampledImage(swapchain_dimensions: Dimensions2D(u32), memory_heap_index: u32) !void {
    assert(have_multisample);

    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    const image_create_info = vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = .b8g8r8a8_unorm,
        .tiling = .optimal,
        .extent = vk.Extent3D{
            .width = swapchain_dimensions.width,
            .height = swapchain_dimensions.height,
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

    current_multisample_image_requirements = multisampled_image_requirements;

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

fn createDepthImage(width: u32, height: u32, memory_heap_index: u32) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    const image_create_info = vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = .d32_sfloat,
        .tiling = .optimal,
        .extent = vk.Extent3D{
            .width = width,
            .height = height,
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .initial_layout = .undefined,
        .usage = .{ .depth_stencil_attachment_bit = true },
        .samples = antialias_sample_count,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    depth_image = try device_dispatch.createImage(logical_device, &image_create_info, null);

    const depth_image_requirements = device_dispatch.getImageMemoryRequirements(logical_device, depth_image);

    current_depth_image_requirements = depth_image_requirements;

    depth_image_memory = try device_dispatch.allocateMemory(logical_device, &vk.MemoryAllocateInfo{
        .allocation_size = depth_image_requirements.size,
        .memory_type_index = memory_heap_index,
    }, null);

    try device_dispatch.bindImageMemory(logical_device, depth_image, depth_image_memory, 0);

    depth_image_view = try device_dispatch.createImageView(logical_device, &vk.ImageViewCreateInfo{
        .flags = .{},
        .image = depth_image,
        .view_type = .@"2d_array",
        .format = .d32_sfloat,
        .subresource_range = .{
            .aspect_mask = .{ .depth_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
    }, null);
}
