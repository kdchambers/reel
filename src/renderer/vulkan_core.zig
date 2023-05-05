// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const vulkan_config = @import("vulkan_config.zig");

const clib = @cImport({
    @cInclude("dlfcn.h");
});

const vulkan_engine_version = vk.makeApiVersion(0, 0, 1, 0);
const vulkan_engine_name = "No engine";
const vulkan_application_version = vk.makeApiVersion(0, 0, 1, 0);
const application_name = "reel";

var vkGetInstanceProcAddr: *const fn (instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction = undefined;

/// Enable Vulkan validation layers
const enable_validation_layers = if (builtin.mode == .Debug) true else false;

const device_extensions = [_][*:0]const u8{vk.extension_info.khr_swapchain.name};
const surface_extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_wayland_surface" };

const validation_layers = if (enable_validation_layers)
    [1][*:0]const u8{"VK_LAYER_KHRONOS_validation"}
else
    [*:0]const u8{};

/// Version of Vulkan to use
/// https://www.khronos.org/registry/vulkan/
const vulkan_api_version = vk.API_VERSION_1_1;

//
// Limits
//

const physical_device_max = 10;
const extension_properties_max = 256;
const max_family_queues: u32 = 16;

//
// Public Variables
//

pub var base_dispatch: vulkan_config.BaseDispatch = undefined;
pub var instance_dispatch: vulkan_config.InstanceDispatch = undefined;
pub var device_dispatch: vulkan_config.DeviceDispatch = undefined;

pub var instance: vk.Instance = undefined;
pub var physical_device: vk.PhysicalDevice = undefined;
pub var logical_device: vk.Device = undefined;

//
// TODO: Split graphics + presenting
//
pub var graphics_present_queue: vk.Queue = undefined; // Same queue used for graphics + presenting
pub var graphics_present_queue_index: u32 = undefined;

pub var command_pool: vk.CommandPool = undefined;
pub var surface: vk.SurfaceKHR = undefined;

pub fn init(wayland_display: *vk.wl_display, wayland_surface: *vk.wl_surface) !void {
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
            .display = wayland_display,
            .surface = wayland_surface,
            .flags = .{},
        };

        surface = try instance_dispatch.createWaylandSurfaceKHR(
            instance,
            &wayland_surface_create_info,
            null,
        );
    }
    errdefer instance_dispatch.destroySurfaceKHR(instance, surface, null);

    physical_device = (try selectPhysicalDevice()) orelse return error.NoSuitablePhysicalDevice;

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

    command_pool = try device_dispatch.createCommandPool(logical_device, &vk.CommandPoolCreateInfo{
        .queue_family_index = graphics_present_queue_index,
        .flags = .{},
    }, null);
}

// Find a suitable physical device (GPU/APU) to use
// Criteria:
//   1. Supports defined list of device extensions. See `device_extensions` above
//   2. Has a graphics queue that supports presentation on our selected surface
fn selectPhysicalDevice() !?vk.PhysicalDevice {
    var physical_device_buffer: [physical_device_max]vk.PhysicalDevice = undefined;
    const physical_devices = blk: {
        var device_count: u32 = 0;
        if (.success != (try instance_dispatch.enumeratePhysicalDevices(instance, &device_count, null))) {
            std.log.warn("Failed to query physical device count", .{});
            return error.PhysicalDeviceQueryFailure;
        }

        if (device_count > physical_device_max) {
            std.log.warn("renderer: Max limit of {d} physical (vulkan) devices. Found {d}. Remaining devices will be ignored", .{
                physical_device_max,
                device_count,
            });
            device_count = physical_device_max;
        }

        if (device_count == 0) {
            std.log.warn("renderer: No physical (vulkan) devices found. Is a valid vulkan driver installed?", .{});
            return error.NoDevicesFound;
        }

        // TODO: Handle ret code
        _ = try instance_dispatch.enumeratePhysicalDevices(instance, &device_count, &physical_device_buffer);

        break :blk physical_device_buffer[0..device_count];
    };
    std.log.info("renderer: {d} physical (vulkan) devices found", .{physical_devices.len});

    for (physical_devices, 0..) |device, device_i| {
        const device_supports_extensions = blk: {
            var extension_count: u32 = undefined;
            if (.success != (try instance_dispatch.enumerateDeviceExtensionProperties(device, null, &extension_count, null))) {
                std.log.warn("Failed to get device extension property count for physical device index {d}", .{device_i});
                continue;
            }

            //
            // TODO: Fallback to using an allocator
            //
            if (extension_count > extension_properties_max) {
                std.log.warn("renderer: Max limit of {d} extension properties per device. Found {d}. Remaining will be ignored", .{
                    extension_properties_max,
                    extension_count,
                });
                extension_count = extension_properties_max;
            }

            var extension_properties_buffer: [extension_properties_max]vk.ExtensionProperties = undefined;

            if (.success != (try instance_dispatch.enumerateDeviceExtensionProperties(device, null, &extension_count, &extension_properties_buffer))) {
                std.log.warn("renderer: Failed to load device extension properties for physical device index {d}", .{device_i});
                continue;
            }

            if (builtin.mode == .Debug) {
                const print = std.debug.print;
                print("Supported extensions:\n", .{});
                var i: usize = 0;
                while (i < extension_count) : (i += 1) {
                    print("  {s}\n", .{extension_properties_buffer[i].extension_name});
                }
            }

            const extensions = extension_properties_buffer[0..extension_count];

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

        if (queue_family_count > max_family_queues) {
            std.log.warn("renderer: Some family queues for selected device ignored", .{});
        }

        var queue_families: [max_family_queues]vk.QueueFamilyProperties = undefined;
        instance_dispatch.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, &queue_families);

        std.debug.print("** Queue Families found on device **\n\n", .{});
        printVulkanQueueFamilies(queue_families[0..queue_family_count], 0);

        for (queue_families[0..queue_family_count], 0..) |queue_family, queue_family_i| {
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
                    return device;
                }
            }
        }
        // If we reach here, we couldn't find a suitable present_queue an will
        // continue to the next device
    }
    return null;
}

fn printVulkanQueueFamilies(queue_families: []vk.QueueFamilyProperties, comptime indent_level: u32) void {
    const print = std.debug.print;
    const base_indent = "  " ** indent_level;
    for (queue_families, 0..) |queue_family, queue_family_i| {
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
