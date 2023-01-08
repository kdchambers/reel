// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Keith Chambers

const std = @import("std");
const vk = @import("vulkan");

pub const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
});

pub const InstanceDispatch = vk.InstanceWrapper(.{
    .destroyInstance = true,
    .createDevice = true,
    .destroySurfaceKHR = true,
    .enumeratePhysicalDevices = true,
    .getPhysicalDeviceProperties = true,
    .enumerateDeviceExtensionProperties = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .getPhysicalDeviceMemoryProperties = true,
    .getDeviceProcAddr = true,
    .createWaylandSurfaceKHR = true,
});

pub const DeviceDispatch = vk.DeviceWrapper(.{
    .destroyDevice = true,
    .getDeviceQueue = true,
    .createSemaphore = true,
    .createFence = true,
    .createImageView = true,
    .destroyImage = true,
    .destroyImageView = true,
    .destroySemaphore = true,
    .destroyFence = true,
    .getSwapchainImagesKHR = true,
    .createSwapchainKHR = true,
    .destroySwapchainKHR = true,
    .acquireNextImageKHR = true,
    .deviceWaitIdle = true,
    .waitForFences = true,
    .resetFences = true,
    .queueSubmit = true,
    .queuePresentKHR = true,
    .createCommandPool = true,
    .destroyCommandPool = true,
    .allocateCommandBuffers = true,
    .freeCommandBuffers = true,
    .queueWaitIdle = true,
    .createShaderModule = true,
    .destroyShaderModule = true,
    .createPipelineLayout = true,
    .destroyPipelineLayout = true,
    .createRenderPass = true,
    .destroyRenderPass = true,
    .createGraphicsPipelines = true,
    .destroyPipeline = true,
    .createFramebuffer = true,
    .destroyFramebuffer = true,
    .beginCommandBuffer = true,
    .endCommandBuffer = true,
    .allocateMemory = true,
    .freeMemory = true,
    .createBuffer = true,
    .destroyBuffer = true,
    .getBufferMemoryRequirements = true,
    .mapMemory = true,
    .unmapMemory = true,
    .bindBufferMemory = true,
    .cmdBeginRenderPass = true,
    .cmdEndRenderPass = true,
    .cmdBindPipeline = true,
    .cmdDraw = true,
    .cmdSetViewport = true,
    .cmdSetScissor = true,
    .cmdBindVertexBuffers = true,
    .cmdCopyBuffer = true,
    .cmdDrawIndexed = true,
    .createImage = true,
    .getImageMemoryRequirements = true,
    .bindImageMemory = true,
    .cmdPipelineBarrier = true,
    .createDescriptorSetLayout = true,
    .createDescriptorPool = true,
    .allocateDescriptorSets = true,
    .createSampler = true,
    .updateDescriptorSets = true,
    .resetCommandPool = true,
    .resetCommandBuffer = true,
    .cmdBindIndexBuffer = true,
    .cmdBindDescriptorSets = true,
    .cmdPushConstants = true,
    .cmdCopyBufferToImage = true,
});

/// The features that we request to be enabled on our selected physical device
pub const enabled_device_features = vk.PhysicalDeviceFeatures{
    .sampler_anisotropy = vk.TRUE,
    // The rest are set to false
    // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/VkPhysicalDeviceFeatures.html
    .robust_buffer_access = vk.FALSE,
    .full_draw_index_uint_32 = vk.FALSE,
    .image_cube_array = vk.FALSE,
    .independent_blend = vk.FALSE,
    .geometry_shader = vk.FALSE,
    .tessellation_shader = vk.FALSE,
    .sample_rate_shading = vk.FALSE,
    .dual_src_blend = vk.FALSE,
    .logic_op = vk.FALSE,
    .multi_draw_indirect = vk.FALSE,
    .draw_indirect_first_instance = vk.FALSE,
    .depth_clamp = vk.FALSE,
    .depth_bias_clamp = vk.FALSE,
    .fill_mode_non_solid = vk.FALSE,
    .depth_bounds = vk.FALSE,
    .wide_lines = vk.FALSE,
    .large_points = vk.FALSE,
    .alpha_to_one = vk.FALSE,
    .multi_viewport = vk.FALSE,
    .texture_compression_etc2 = vk.FALSE,
    .texture_compression_astc_ldr = vk.FALSE,
    .texture_compression_bc = vk.FALSE,
    .occlusion_query_precise = vk.FALSE,
    .pipeline_statistics_query = vk.FALSE,
    .vertex_pipeline_stores_and_atomics = vk.FALSE,
    .fragment_stores_and_atomics = vk.FALSE,
    .shader_tessellation_and_geometry_point_size = vk.FALSE,
    .shader_image_gather_extended = vk.FALSE,
    .shader_storage_image_extended_formats = vk.FALSE,
    .shader_storage_image_multisample = vk.FALSE,
    .shader_storage_image_read_without_format = vk.FALSE,
    .shader_storage_image_write_without_format = vk.FALSE,
    .shader_uniform_buffer_array_dynamic_indexing = vk.FALSE,
    .shader_sampled_image_array_dynamic_indexing = vk.FALSE,
    .shader_storage_buffer_array_dynamic_indexing = vk.FALSE,
    .shader_storage_image_array_dynamic_indexing = vk.FALSE,
    .shader_clip_distance = vk.FALSE,
    .shader_cull_distance = vk.FALSE,
    .shader_float_64 = vk.FALSE,
    .shader_int_64 = vk.FALSE,
    .shader_int_16 = vk.FALSE,
    .shader_resource_residency = vk.FALSE,
    .shader_resource_min_lod = vk.FALSE,
    .sparse_binding = vk.FALSE,
    .sparse_residency_buffer = vk.FALSE,
    .sparse_residency_image_2d = vk.FALSE,
    .sparse_residency_image_3d = vk.FALSE,
    .sparse_residency_2_samples = vk.FALSE,
    .sparse_residency_4_samples = vk.FALSE,
    .sparse_residency_8_samples = vk.FALSE,
    .sparse_residency_16_samples = vk.FALSE,
    .sparse_residency_aliased = vk.FALSE,
    .variable_multisample_rate = vk.FALSE,
    .inherited_queries = vk.FALSE,
};
