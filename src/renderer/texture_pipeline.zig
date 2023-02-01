// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");

const vulkan_core = @import("vulkan_core.zig");
const vulkan_config = @import("vulkan_config.zig");
const shaders = @import("shaders");
const geometry = @import("../geometry.zig");
const graphics = @import("../graphics.zig");

const shared_render_pass = @import("render_pass.zig");

const Pixel = graphics.RGBA(u8);

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
};

pub var descriptor_set_layout_buffer: [8]vk.DescriptorSetLayout = undefined;
pub var descriptor_set_layout_count: u32 = 0;

pub var descriptor_set_buffer: [8]vk.DescriptorSet = undefined;
pub var descriptor_set_count: u32 = 0;
var descriptor_pool: vk.DescriptorPool = undefined;

var sampler: vk.Sampler = undefined;

pub var pipeline_layout: vk.PipelineLayout = undefined;
pub var graphics_pipeline: vk.Pipeline = undefined;

var vertex_shader_module: vk.ShaderModule = undefined;
var fragment_shader_module: vk.ShaderModule = undefined;

pub var texture_image: vk.Image = undefined;
pub var texture_image_view: vk.ImageView = undefined;

pub var unscaled_image: vk.Image = undefined;

pub var vertices_buffer: []Vertex = undefined;
pub var indices_buffer: []u16 = undefined;
pub var vulkan_vertices_buffer: vk.Buffer = undefined;
pub var vulkan_indices_buffer: vk.Buffer = undefined;

pub var memory_map: []Pixel = undefined;

pub fn createUnscaledImage(memory_index: u32) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    const queue = vulkan_core.graphics_present_queue;

    // TODO:
    const unscaled_image_dimensions = geometry.Dimensions2D(u32){
        .width = 2000,
        .height = 1100,
    };

    const texture_pixel_count = @intCast(usize, unscaled_image_dimensions.width) * unscaled_image_dimensions.height;
    const texture_size_bytes: usize = texture_pixel_count * @sizeOf(Pixel);

    {
        const image_create_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .tiling = .linear,
            .extent = vk.Extent3D{
                .width = unscaled_image_dimensions.width,
                .height = unscaled_image_dimensions.height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .initial_layout = .preinitialized,
            .usage = .{ .transfer_src_bit = true },
            .samples = .{ .@"1_bit" = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        };

        unscaled_image = try device_dispatch.createImage(logical_device, &image_create_info, null);
    }

    const memory_requirements = device_dispatch.getImageMemoryRequirements(logical_device, unscaled_image);

    var memory = try device_dispatch.allocateMemory(logical_device, &vk.MemoryAllocateInfo{
        .allocation_size = memory_requirements.size,
        .memory_type_index = memory_index,
    }, null);

    try device_dispatch.bindImageMemory(logical_device, unscaled_image, memory, 0);
    const mapped_memory_opt = (try device_dispatch.mapMemory(
        logical_device,
        memory,
        0,
        texture_size_bytes,
        .{},
    ));

    if (mapped_memory_opt == null) {
        std.log.err("renderer: Failed to map shader memory", .{});
        return error.MapMemoryFail;
    }

    memory_map = @ptrCast([*]Pixel, mapped_memory_opt.?)[0..texture_pixel_count];
    std.mem.set(Pixel, memory_map, .{ .r = 0, .g = 0, .b = 0, .a = 255 });

    //
    // Transition from preinitialized to general
    //
    const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = vulkan_core.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };

    var command_buffer: vk.CommandBuffer = undefined;
    try device_dispatch.allocateCommandBuffers(
        logical_device,
        &command_buffer_allocate_info,
        @ptrCast([*]vk.CommandBuffer, &command_buffer),
    );

    try device_dispatch.beginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    const barrier = [_]vk.ImageMemoryBarrier{
        .{
            .src_access_mask = .{},
            .dst_access_mask = .{},
            .old_layout = .preinitialized,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = unscaled_image,
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
        const dst_stage = vk.PipelineStageFlags{ .bottom_of_pipe_bit = true };
        const dependency_flags = vk.DependencyFlags{};
        device_dispatch.cmdPipelineBarrier(
            command_buffer,
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

    try device_dispatch.endCommandBuffer(command_buffer);

    const submit_command_infos = [_]vk.SubmitInfo{.{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &command_buffer),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    }};

    const fence = try device_dispatch.createFence(logical_device, &.{ .flags = .{} }, null);

    try device_dispatch.queueSubmit(
        queue,
        1,
        &submit_command_infos,
        fence,
    );

    //
    // TODO: Check return
    //
    _ = try device_dispatch.waitForFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &fence),
        vk.TRUE,
        std.time.ns_per_s * 4,
    );

    device_dispatch.destroyFence(logical_device, fence, null);
    device_dispatch.freeCommandBuffers(
        logical_device,
        vulkan_core.command_pool,
        1,
        @ptrCast([*]const vk.CommandBuffer, &command_buffer),
    );
}

pub fn init(
    texture_dimensions: geometry.Dimensions2D(u32),
    texture_memory_index: u32,
    swapchain_image_count: u32,
    initial_viewport_dimensions: geometry.Dimensions2D(u16),
    mesh_memory: vk.DeviceMemory,
    memory_offset: u32,
    indices_range_size: u32,
    vertices_range_size: u32,
    mapped_device_memory: [*]u8,
) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    const queue = vulkan_core.graphics_present_queue;

    try createUnscaledImage(texture_memory_index);

    {
        const image_create_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .tiling = .linear,
            .extent = vk.Extent3D{
                .width = texture_dimensions.width,
                .height = texture_dimensions.height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .initial_layout = .preinitialized,
            .usage = .{ .sampled_bit = true, .transfer_dst_bit = true },
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
        .memory_type_index = texture_memory_index,
    }, null);

    try device_dispatch.bindImageMemory(logical_device, texture_image, image_memory, 0);
    texture_image_view = try device_dispatch.createImageView(logical_device, &vk.ImageViewCreateInfo{
        .flags = .{},
        .image = texture_image,
        .view_type = .@"2d_array",
        .format = .r8g8b8a8_unorm,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
    }, null);

    try layoutToOptimal(
        device_dispatch,
        logical_device,
        queue,
    );

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
        try device_dispatch.bindBufferMemory(
            logical_device,
            vulkan_vertices_buffer,
            mesh_memory,
            memory_offset,
        );
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
        try device_dispatch.bindBufferMemory(
            logical_device,
            vulkan_indices_buffer,
            mesh_memory,
            memory_offset + vertices_range_size,
        );
    }

    const indices_range_index_begin = memory_offset + vertices_range_size;
    const indices_range_count = @divExact(indices_range_size, @sizeOf(u16));
    const vertices_range_count = @divExact(vertices_range_size, @sizeOf(Vertex));

    {
        const vertex_ptr = @ptrCast([*]Vertex, @alignCast(@alignOf(Vertex), &mapped_device_memory[memory_offset]));
        vertices_buffer = vertex_ptr[0..vertices_range_count];
        const indices_ptr = @ptrCast([*]u16, @alignCast(16, &mapped_device_memory[indices_range_index_begin]));
        indices_buffer = indices_ptr[0..indices_range_count];
    }

    vertex_shader_module = try createVertexShaderModule(device_dispatch, logical_device);
    fragment_shader_module = try createFragmentShaderModule(device_dispatch, logical_device);

    try createDescriptorSetLayouts(device_dispatch, logical_device, swapchain_image_count);

    const pipeline_layout_create_info = vk.PipelineLayoutCreateInfo{
        .set_layout_count = 1,
        .p_set_layouts = &descriptor_set_layout_buffer,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
        .flags = .{},
    };

    pipeline_layout = try device_dispatch.createPipelineLayout(logical_device, &pipeline_layout_create_info, null);
    try createDescriptorPool(device_dispatch, logical_device, swapchain_image_count);
    try createDescriptorSets(device_dispatch, logical_device, swapchain_image_count);
    try createGraphicsPipeline(device_dispatch, logical_device, initial_viewport_dimensions);
}

fn createDescriptorPool(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    create_count: u32,
) !void {
    const descriptor_pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .type = .combined_image_sampler,
            .descriptor_count = create_count,
        },
    };
    const create_pool_info = vk.DescriptorPoolCreateInfo{
        .pool_size_count = descriptor_pool_sizes.len,
        .p_pool_sizes = &descriptor_pool_sizes,
        .max_sets = create_count,
        .flags = .{},
    };
    descriptor_pool = try device_dispatch.createDescriptorPool(logical_device, &create_pool_info, null);
}

fn createDescriptorSetLayouts(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    create_count: u32,
) !void {
    const descriptor_set_layout_bindings = [_]vk.DescriptorSetLayoutBinding{vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_immutable_samplers = null,
        .stage_flags = .{ .fragment_bit = true },
    }};
    const descriptor_set_layout_create_info = vk.DescriptorSetLayoutCreateInfo{
        .binding_count = 1,
        .p_bindings = &descriptor_set_layout_bindings,
        .flags = .{},
    };
    descriptor_set_layout_buffer[0] = try device_dispatch.createDescriptorSetLayout(
        logical_device,
        &descriptor_set_layout_create_info,
        null,
    );

    // We can copy the same descriptor set layout for each image
    var x: u32 = 1;
    while (x < create_count) : (x += 1) {
        descriptor_set_layout_buffer[x] = descriptor_set_layout_buffer[0];
    }
}

fn createDescriptorSets(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    create_count: u32,
) !void {
    {
        const descriptor_set_allocator_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = create_count,
            .p_set_layouts = &descriptor_set_layout_buffer,
        };
        try device_dispatch.allocateDescriptorSets(
            logical_device,
            &descriptor_set_allocator_info,
            &descriptor_set_buffer,
        );
    }

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

    var i: u32 = 0;
    while (i < create_count) : (i += 1) {
        const descriptor_image_info = [_]vk.DescriptorImageInfo{
            .{
                .image_layout = .general,
                .image_view = texture_image_view,
                .sampler = sampler,
            },
        };
        const write_descriptor_set = [_]vk.WriteDescriptorSet{.{
            .dst_set = descriptor_set_buffer[i],
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

fn layoutToOptimal(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    queue: vk.Queue,
) !void {
    const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = vulkan_core.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };

    var command_buffer: vk.CommandBuffer = undefined;
    try device_dispatch.allocateCommandBuffers(
        logical_device,
        &command_buffer_allocate_info,
        @ptrCast([*]vk.CommandBuffer, &command_buffer),
    );

    try device_dispatch.beginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    const barrier = [_]vk.ImageMemoryBarrier{
        .{
            .src_access_mask = .{},
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .preinitialized,
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

    {
        const src_stage = vk.PipelineStageFlags{ .top_of_pipe_bit = true };
        const dst_stage = vk.PipelineStageFlags{ .fragment_shader_bit = true };
        const dependency_flags = vk.DependencyFlags{};
        device_dispatch.cmdPipelineBarrier(
            command_buffer,
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

    try device_dispatch.endCommandBuffer(command_buffer);

    const submit_command_infos = [_]vk.SubmitInfo{.{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &command_buffer),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    }};

    const fence = try device_dispatch.createFence(logical_device, &.{ .flags = .{} }, null);

    try device_dispatch.queueSubmit(
        queue,
        1,
        &submit_command_infos,
        fence,
    );

    //
    // TODO: Check return
    //
    _ = try device_dispatch.waitForFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &fence),
        vk.TRUE,
        std.time.ns_per_s * 4,
    );

    device_dispatch.destroyFence(logical_device, fence, null);
    device_dispatch.freeCommandBuffers(
        logical_device,
        vulkan_core.command_pool,
        1,
        @ptrCast([*]const vk.CommandBuffer, &command_buffer),
    );
}

fn createGraphicsPipeline(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    initial_viewport_dimensions: geometry.Dimensions2D(u16),
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

    const vertex_input_binding_descriptions = [_]vk.VertexInputBindingDescription{
        .{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .input_rate = .vertex,
        },
    };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = @intCast(u32, vertex_input_binding_descriptions.len),
        .vertex_attribute_description_count = @intCast(u32, vertex_input_attribute_descriptions.len),
        .p_vertex_binding_descriptions = &vertex_input_binding_descriptions,
        .p_vertex_attribute_descriptions = &vertex_input_attribute_descriptions,
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
            .width = @intToFloat(f32, initial_viewport_dimensions.width),
            .height = @intToFloat(f32, initial_viewport_dimensions.height),
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
                .width = initial_viewport_dimensions.width,
                .height = initial_viewport_dimensions.height,
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
        .rasterization_samples = shared_render_pass.antialias_sample_count,
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
        .dynamic_state_count = @intCast(u32, dynamic_states.len),
        .p_dynamic_states = &dynamic_states,
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
            .render_pass = shared_render_pass.pass,
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

fn createFragmentShaderModule(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = shaders.texture_fragment_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shaders.texture_fragment_spv)),
        .flags = .{},
    };
    return try device_dispatch.createShaderModule(logical_device, &create_info, null);
}

fn createVertexShaderModule(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = shaders.texture_vertex_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shaders.texture_vertex_spv)),
        .flags = .{},
    };
    return try device_dispatch.createShaderModule(logical_device, &create_info, null);
}
