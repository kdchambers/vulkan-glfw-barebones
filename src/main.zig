const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("vulkan");
const vulkan_config = @import("vulkan_config.zig");
const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");

const clib = @cImport({
    @cInclude("dlfcn.h");
});

/// Enable Vulkan validation layers
const enable_validation_layers = if (builtin.mode == .Debug) true else false;

const vulkan_engine_version = vk.makeApiVersion(0, 0, 1, 0);
const vulkan_engine_name = "No engine";
const vulkan_application_version = vk.makeApiVersion(0, 0, 1, 0);
const application_name = "vulkan-glfw-barebones";

const enable_blending = true;

var alpha_mode: vk.CompositeAlphaFlagsKHR = .{ .opaque_bit_khr = true };

const transparancy_level = 0.0;

/// Version of Vulkan to use
/// https://www.khronos.org/registry/vulkan/
const vulkan_api_version = vk.API_VERSION_1_1;

// NOTE: The max texture size that is guaranteed is 4096 * 4096
//       Support for larger textures will need to be queried
// https://github.com/gpuweb/gpuweb/issues/1327
const texture_layer_dimensions = geometry.Dimensions2D(TexturePixelBaseType){
    .width = 512,
    .height = 512,
};

/// Screen dimensions of the application, as reported by wayland
/// Initial values are arbirary and will be updated once the wayland
/// server reports a change
var screen_dimensions = geometry.Dimensions2D(ScreenPixelBaseType){
    .width = 640,
    .height = 1040,
};

var current_frame: u32 = 0;
var previous_frame: u32 = 0;

/// Defines the entire surface area of a screen in vulkans coordinate system
/// I.e normalized device coordinates right (ndc right)
const full_screen_extent = geometry.Extent2D(ScreenNormalizedBaseType){
    .x = -1.0,
    .y = -1.0,
    .width = 2.0,
    .height = 2.0,
};

var background_color = graphics.RGBA(f32).fromInt(u8, 74, 255, 45, 255);

/// Determines the memory allocated for storing mesh data
/// Represents the number of quads that will be able to be drawn
/// This can be a colored quad, or a textured quad such as a character
const max_texture_quads_per_render: u32 = 1024;

/// Maximum number of screen framebuffers to use
/// 2-3 would be recommented to avoid screen tearing
const max_frames_in_flight: u32 = 2;

/// Size in bytes of each texture layer (Not including padding, etc)
const texture_layer_size = @sizeOf(graphics.RGBA(f32)) * @intCast(u64, texture_layer_dimensions.width) * texture_layer_dimensions.height;

const indices_range_index_begin = 0;
const indices_range_size = max_texture_quads_per_render * @sizeOf(u16) * 6; // 12 kb
const indices_range_count = indices_range_size / @sizeOf(u16);
const vertices_range_index_begin = indices_range_size;
const vertices_range_size = max_texture_quads_per_render * @sizeOf(graphics.GenericVertex) * 4; // 80 kb
const vertices_range_count = vertices_range_size / @sizeOf(graphics.GenericVertex);
const memory_size = indices_range_size + vertices_range_size;

const validation_layers = if (enable_validation_layers)
    [1][*:0]const u8{"VK_LAYER_KHRONOS_validation"}
else
    [*:0]const u8{};

const device_extensions = [_][*:0]const u8{vk.extension_info.khr_swapchain.name};

var vertex_buffer: []graphics.QuadFace(graphics.GenericVertex) = undefined;

var framebuffer_resized: bool = true;
var mapped_device_memory: [*]u8 = undefined;

var texture_image_view: vk.ImageView = undefined;
var texture_image: vk.Image = undefined;
var texture_vertices_buffer: vk.Buffer = undefined;
var texture_indices_buffer: vk.Buffer = undefined;

var texture_memory_map: [*]graphics.RGBA(f32) = undefined;

/// Enables transparency on the selected surface
const transparancy_enabled = true;

const texture_size_bytes = texture_layer_dimensions.width * texture_layer_dimensions.height * @sizeOf(graphics.RGBA(f32));

const ScreenPixelBaseType = u16;
const ScreenNormalizedBaseType = f32;

const TexturePixelBaseType = u16;
const TextureNormalizedBaseType = f32;

const fragment_shader_path = "shaders/generic.frag.spv";
const vertex_shader_path = "shaders/generic.vert.spv";

const GraphicsContext = struct {
    base_dispatch: vulkan_config.BaseDispatch,
    instance_dispatch: vulkan_config.InstanceDispatch,
    device_dispatch: vulkan_config.DeviceDispatch,

    vertex_shader_module: vk.ShaderModule,
    fragment_shader_module: vk.ShaderModule,

    render_pass: vk.RenderPass,
    framebuffers: []vk.Framebuffer,
    graphics_pipeline: vk.Pipeline,
    descriptor_pool: vk.DescriptorPool,
    descriptor_sets: []vk.DescriptorSet,
    descriptor_set_layouts: []vk.DescriptorSetLayout,
    pipeline_layout: vk.PipelineLayout,

    instance: vk.Instance,
    window: glfw.Window,
    surface: vk.SurfaceKHR,
    surface_format: vk.SurfaceFormatKHR,
    physical_device: vk.PhysicalDevice,
    logical_device: vk.Device,
    graphics_present_queue: vk.Queue, // Same queue used for graphics + presenting
    graphics_present_queue_index: u32,
    swapchain_min_image_count: u32,
    swapchain: vk.SwapchainKHR,
    swapchain_extent: vk.Extent2D,
    swapchain_images: []vk.Image,
    swapchain_image_views: []vk.ImageView,
    command_pool: vk.CommandPool,
    command_buffers: []vk.CommandBuffer,
    images_available: []vk.Semaphore,
    renders_finished: []vk.Semaphore,
    inflight_fences: []vk.Fence,
};

var vkGetInstanceProcAddr: *const fn (instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction = undefined;

var quad_face_writer_pool: QuadFaceWriterPool(graphics.GenericVertex) = undefined;

fn onFramebufferResized(window: glfw.Window, width: u32, height: u32) void {
    _ = window;
    screen_dimensions.width = @intCast(u16, width);
    screen_dimensions.height = @intCast(u16, height);
    framebuffer_resized = true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocator = gpa.allocator();

    var graphics_context: GraphicsContext = undefined;
    try setup(allocator, &graphics_context);

    graphics_context.window.setFramebufferSizeCallback(onFramebufferResized);

    while (!graphics_context.window.shouldClose()) {
        try glfw.pollEvents();
        try graphics_context.device_dispatch.deviceWaitIdle(graphics_context.logical_device);
        try recordRenderPass(graphics_context, 6);
        try renderFrame(allocator, &graphics_context);
        // 30 fps
        std.time.sleep(std.time.ns_per_ms * 16 * 2);
    }
    try graphics_context.device_dispatch.deviceWaitIdle(graphics_context.logical_device);

    cleanup(allocator, &graphics_context);
    glfw.terminate();
}

fn cleanup(allocator: std.mem.Allocator, app: *GraphicsContext) void {
    cleanupSwapchain(allocator, app);

    allocator.free(app.images_available);
    allocator.free(app.renders_finished);
    allocator.free(app.inflight_fences);

    allocator.free(app.swapchain_image_views);
    allocator.free(app.swapchain_images);

    allocator.free(app.descriptor_set_layouts);
    allocator.free(app.descriptor_sets);
    allocator.free(app.framebuffers);

    app.instance_dispatch.destroySurfaceKHR(app.instance, app.surface, null);
}

fn toSlice(string: [*:0]const u8) []const u8 {
    var i: usize = 0;
    while (string[i] != 0) : (i += 1) {}
    return string[0..i];
}

fn setup(allocator: std.mem.Allocator, app: *GraphicsContext) !void {
    const vulkan_lib_symbol = comptime switch (builtin.os.tag) {
        .windows => "vulkan-1.dll",
        .macos => "libvulkan.1.dylib",
        .netbsd, .openbsd => "libvulkan.so",
        else => "libvulkan.so.1",
    };

    if (clib.dlopen(vulkan_lib_symbol, clib.RTLD_NOW)) |vulkan_loader| {
        const vk_get_instance_proc_addr_fn_opt = @ptrCast(?*const fn (instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction, clib.dlsym(vulkan_loader, "vkGetInstanceProcAddr"));
        if (vk_get_instance_proc_addr_fn_opt) |vk_get_instance_proc_addr_fn| {
            vkGetInstanceProcAddr = vk_get_instance_proc_addr_fn;
            app.base_dispatch = try vulkan_config.BaseDispatch.load(vkGetInstanceProcAddr);
        } else {
            std.log.err("Failed to load vkGetInstanceProcAddr function from vulkan loader", .{});
            return error.FailedToGetVulkanSymbol;
        }
    } else {
        std.log.err("Failed to load vulkan loader (libvulkan.so)", .{});
        return error.FailedToGetVulkanSymbol;
    }

    //
    // Get required instance extensions
    //
    // TODO: This is a large-ish structuce, better to heap allocate
    var instance_extension_properties: [40]vk.ExtensionProperties = undefined;
    var instance_extension_properties_count: u32 = 0;
    {
        const result = app.base_dispatch.enumerateInstanceExtensionProperties(null, &instance_extension_properties_count, null) catch |err| {
            std.log.err("Failed to enumerate vulkan instance extension properties. Error {}", .{err});
            return err;
        };
        std.debug.assert(result == .success);
    }

    std.log.info("Vulkan instances extensions enumerated: {d}", .{instance_extension_properties_count});
    std.debug.assert(instance_extension_properties_count <= 20);
    {
        const result = app.base_dispatch.enumerateInstanceExtensionProperties(null, &instance_extension_properties_count, &instance_extension_properties) catch |err| {
            std.log.err("Failed to load vulkan instance extension properties. Error {}", .{err});
            return err;
        };
        std.debug.assert(result == .success);
    }

    const SurfaceSupport = struct {
        surface: bool = false,
        wayland: bool = false,
        cocoa: bool = false,
        xlib: bool = false,
        xcb: bool = false,
        windows: bool = false,
    };
    var surface_support = SurfaceSupport{};

    for (instance_extension_properties[0..instance_extension_properties_count]) |*instance_extension_property| {
        const extension = toSlice(@ptrCast([*:0]const u8, &(instance_extension_property.extension_name)));
        if (std.mem.eql(u8, "VK_KHR_wayland_surface", extension)) {
            surface_support.wayland = true;
            continue;
        }
        if (std.mem.eql(u8, "VK_MVK_macos_surface", extension)) {
            surface_support.cocoa = true;
            continue;
        }
        if (std.mem.eql(u8, "VK_KHR_win32_surface", extension)) {
            surface_support.windows = true;
            continue;
        }
        // XCB and XLib may not be chosen even if there is support
        // This is because on Linux, xcb, wayland and xlib can all be supported
        // and will have the following priority: wayland > xcb > xlib
        if (std.mem.eql(u8, "VK_KHR_xcb_surface", extension)) {
            surface_support.xcb = true;
            continue;
        }
        if (std.mem.eql(u8, "VK_KHR_xlib_surface", extension)) {
            surface_support.xlib = true;
            continue;
        }
        // This just refers to surface support in general.
        if (std.mem.eql(u8, "VK_KHR_surface", extension)) {
            surface_support.surface = true;
            continue;
        }
    }

    if (!surface_support.surface) {
        std.log.err("Vulkan does not support outputting to surface", .{});
        return error.SurfaceInstanceExtensionNotFound;
    }

    if ((!surface_support.windows) and (!surface_support.cocoa) and (!surface_support.wayland) and (!surface_support.xcb) and (!surface_support.xlib)) {
        std.log.err("Vulkan has surface support, but not specific surface type found (I.e wayland, cocao, xcb, etc)", .{});
        return error.SpecificSurfaceInstanceExtensionNotFound;
    }

    const required_instance_extensions = [2][*:0]const u8{ "VK_KHR_surface", if (surface_support.windows)
        "VK_KHR_win32_surface"
    else if (surface_support.cocoa)
        "VK_MVK_macos_surface"
    else if (surface_support.wayland)
        "VK_KHR_wayland_surface"
    else if (surface_support.xcb)
        "VK_KHR_xcb_surface"
    else
        "VK_KHR_xlib_surface" };

    app.instance = try app.base_dispatch.createInstance(&vk.InstanceCreateInfo{
        .p_application_info = &vk.ApplicationInfo{
            .p_application_name = application_name,
            .application_version = vulkan_application_version,
            .p_engine_name = vulkan_engine_name,
            .engine_version = vulkan_engine_version,
            .api_version = vulkan_api_version,
        },
        .enabled_extension_count = @intCast(u32, required_instance_extensions.len),
        .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, &required_instance_extensions),
        .enabled_layer_count = if (enable_validation_layers) validation_layers.len else 0,
        .pp_enabled_layer_names = if (enable_validation_layers) &validation_layers else undefined,
        .flags = .{},
    }, null);

    app.instance_dispatch = try vulkan_config.InstanceDispatch.load(app.instance, vkGetInstanceProcAddr);
    errdefer app.instance_dispatch.destroyInstance(app.instance, null);

    const glfw_platform_hint: glfw.PlatformType = blk: {
        if (surface_support.windows) break :blk .win32;
        if (surface_support.cocoa) break :blk .cocoa;
        if (surface_support.wayland) break :blk .wayland;
        if (surface_support.xlib or surface_support.xcb) break :blk .x11;
        unreachable;
    };

    try glfw.init(.{ .platform = glfw_platform_hint });

    if (!glfw.vulkanSupported()) {
        std.log.err("GLFW reports vulkan is not supported", .{});
        return error.GlfwNoVulkanSupport;
    }

    app.window = try glfw.Window.create(640, 480, "vulkan-glfw barebones", null, null, .{ .client_api = .no_api });
    _ = try glfw.createWindowSurface(app.instance, app.window, null, &app.surface);

    errdefer app.instance_dispatch.destroySurfaceKHR(app.instance, app.surface, null);

    // Find a suitable physical device (GPU/APU) to use
    // Criteria:
    //   1. Supports defined list of device extensions. See `device_extensions` above
    //   2. Has a graphics queue that supports presentation on our selected surface
    const best_physical_device = outer: {
        const physical_devices = blk: {
            var device_count: u32 = 0;
            if (.success != (try app.instance_dispatch.enumeratePhysicalDevices(app.instance, &device_count, null))) {
                std.log.warn("Failed to query physical device count", .{});
                return error.PhysicalDeviceQueryFailure;
            }

            if (device_count == 0) {
                std.log.warn("No physical devices found", .{});
                return error.NoDevicesFound;
            }

            const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
            _ = try app.instance_dispatch.enumeratePhysicalDevices(app.instance, &device_count, devices.ptr);

            break :blk devices;
        };
        defer allocator.free(physical_devices);

        for (physical_devices) |physical_device, physical_device_i| {
            std.log.info("Physical vulkan devices found: {d}", .{physical_devices.len});

            const device_supports_extensions = blk: {
                var extension_count: u32 = undefined;
                if (.success != (try app.instance_dispatch.enumerateDeviceExtensionProperties(physical_device, null, &extension_count, null))) {
                    std.log.warn("Failed to get device extension property count for physical device index {d}", .{physical_device_i});
                    continue;
                }

                const extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
                defer allocator.free(extensions);

                if (.success != (try app.instance_dispatch.enumerateDeviceExtensionProperties(physical_device, null, &extension_count, extensions.ptr))) {
                    std.log.warn("Failed to load device extension properties for physical device index {d}", .{physical_device_i});
                    continue;
                }

                dev_extensions: for (device_extensions) |requested_extension| {
                    for (extensions) |available_extension| {
                        // NOTE: We are relying on device_extensions to only contain c strings up to 255 characters
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
            app.instance_dispatch.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);

            if (queue_family_count == 0) {
                continue;
            }

            const max_family_queues: u32 = 16;
            if (queue_family_count > max_family_queues) {
                std.log.warn("Some family queues for selected device ignored", .{});
            }

            var queue_families: [max_family_queues]vk.QueueFamilyProperties = undefined;
            app.instance_dispatch.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, &queue_families);

            for (queue_families[0..queue_family_count]) |queue_family, queue_family_i| {
                if (queue_family.queue_count <= 0) {
                    continue;
                }
                if (queue_family.queue_flags.graphics_bit) {
                    const present_support = try app.instance_dispatch.getPhysicalDeviceSurfaceSupportKHR(
                        physical_device,
                        @intCast(u32, queue_family_i),
                        app.surface,
                    );
                    if (present_support != 0) {
                        app.graphics_present_queue_index = @intCast(u32, queue_family_i);
                        break :outer physical_device;
                    }
                }
            }
            // If we reach here, we couldn't find a suitable present_queue an will
            // continue to the next device
        }
        break :outer null;
    };

    if (best_physical_device) |physical_device| {
        app.physical_device = physical_device;
    } else return error.NoSuitablePhysicalDevice;

    {
        const device_create_info = vk.DeviceCreateInfo{
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast([*]vk.DeviceQueueCreateInfo, &vk.DeviceQueueCreateInfo{
                .queue_family_index = app.graphics_present_queue_index,
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

        app.logical_device = try app.instance_dispatch.createDevice(
            app.physical_device,
            &device_create_info,
            null,
        );
    }

    app.device_dispatch = try vulkan_config.DeviceDispatch.load(
        app.logical_device,
        app.instance_dispatch.dispatch.vkGetDeviceProcAddr,
    );
    app.graphics_present_queue = app.device_dispatch.getDeviceQueue(
        app.logical_device,
        app.graphics_present_queue_index,
        0,
    );

    // Query and select appropriate surface format for swapchain
    if (try selectSurfaceFormat(allocator, app.*, .srgb_nonlinear_khr, .b8g8r8a8_unorm)) |surface_format| {
        app.surface_format = surface_format;
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

        const memory_properties = app.instance_dispatch.getPhysicalDeviceMemoryProperties(app.physical_device);

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
            .initial_layout = .@"undefined",
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
            .samples = .{ .@"1_bit" = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        };

        texture_image = try app.device_dispatch.createImage(app.logical_device, &image_create_info, null);
    }

    const texture_memory_requirements = app.device_dispatch.getImageMemoryRequirements(app.logical_device, texture_image);

    var image_memory = try app.device_dispatch.allocateMemory(app.logical_device, &vk.MemoryAllocateInfo{
        .allocation_size = texture_memory_requirements.size,
        .memory_type_index = mesh_memory_index,
    }, null);

    try app.device_dispatch.bindImageMemory(app.logical_device, texture_image, image_memory, 0);

    const command_pool = try app.device_dispatch.createCommandPool(app.logical_device, &vk.CommandPoolCreateInfo{
        .queue_family_index = app.graphics_present_queue_index,
        .flags = .{},
    }, null);

    var command_buffer: vk.CommandBuffer = undefined;
    {
        const comment_buffer_alloc_info = vk.CommandBufferAllocateInfo{
            .level = .primary,
            .command_pool = command_pool,
            .command_buffer_count = 1,
        };
        try app.device_dispatch.allocateCommandBuffers(app.logical_device, &comment_buffer_alloc_info, @ptrCast([*]vk.CommandBuffer, &command_buffer));
    }

    try app.device_dispatch.beginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    std.debug.assert(texture_layer_size <= texture_memory_requirements.size);
    {
        var mapped_memory_ptr = (try app.device_dispatch.mapMemory(app.logical_device, image_memory, 0, texture_layer_size, .{})).?;
        texture_memory_map = @ptrCast([*]graphics.RGBA(f32), @alignCast(4, mapped_memory_ptr));
        // TODO: Write to texture
    }

    // Not sure if this is a hack, but because we multiply the texture sample by the
    // color in the fragment shader, we need a pixel in the texture that we know will return 1.0
    // Here we're setting the last pixel to 1.0, which corresponds to a texture mapping of 1.0, 1.0
    const last_index: usize = (@intCast(usize, texture_layer_dimensions.width) * texture_layer_dimensions.height) - 1;
    texture_memory_map[last_index].r = 1.0;
    texture_memory_map[last_index].g = 1.0;
    texture_memory_map[last_index].b = 1.0;
    texture_memory_map[last_index].a = 1.0;

    const barrier = [_]vk.ImageMemoryBarrier{
        .{
            .src_access_mask = .{},
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .@"undefined",
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
        app.device_dispatch.cmdPipelineBarrier(command_buffer, src_stage, dst_stage, dependency_flags, 0, undefined, 0, undefined, 1, &barrier);
    }

    try app.device_dispatch.endCommandBuffer(command_buffer);

    const submit_command_infos = [_]vk.SubmitInfo{.{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]vk.CommandBuffer, &command_buffer),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    }};

    try app.device_dispatch.queueSubmit(app.graphics_present_queue, 1, &submit_command_infos, .null_handle);

    texture_image_view = try app.device_dispatch.createImageView(app.logical_device, &vk.ImageViewCreateInfo{
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

    const surface_capabilities = try app.instance_dispatch.getPhysicalDeviceSurfaceCapabilitiesKHR(app.physical_device, app.surface);

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
        app.swapchain_extent.width = screen_dimensions.width;
        app.swapchain_extent.height = screen_dimensions.height;
    }

    std.debug.assert(app.swapchain_extent.width >= surface_capabilities.min_image_extent.width);
    std.debug.assert(app.swapchain_extent.height >= surface_capabilities.min_image_extent.height);

    std.debug.assert(app.swapchain_extent.width <= surface_capabilities.max_image_extent.width);
    std.debug.assert(app.swapchain_extent.height <= surface_capabilities.max_image_extent.height);

    app.swapchain_min_image_count = surface_capabilities.min_image_count + 1;

    // TODO: Perhaps more flexibily should be allowed here. I'm unsure if an application is
    //       supposed to match the rotation of the system / monitor, but I would assume not..
    //       It is also possible that the inherit_bit_khr bit would be set in place of identity_bit_khr
    if (surface_capabilities.current_transform.identity_bit_khr == false) {
        std.log.err("Selected surface does not have the option to leave framebuffer image untransformed." ++
            "This is likely a vulkan bug.", .{});
        return error.VulkanSurfaceTransformInvalid;
    }

    app.swapchain = try app.device_dispatch.createSwapchainKHR(app.logical_device, &vk.SwapchainCreateInfoKHR{
        .surface = app.surface,
        .min_image_count = app.swapchain_min_image_count,
        .image_format = app.surface_format.format,
        .image_color_space = app.surface_format.color_space,
        .image_extent = app.swapchain_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
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

    app.swapchain_images = blk: {
        var image_count: u32 = undefined;
        if (.success != (try app.device_dispatch.getSwapchainImagesKHR(app.logical_device, app.swapchain, &image_count, null))) {
            return error.FailedToGetSwapchainImagesCount;
        }

        var swapchain_images = try allocator.alloc(vk.Image, image_count);
        if (.success != (try app.device_dispatch.getSwapchainImagesKHR(app.logical_device, app.swapchain, &image_count, swapchain_images.ptr))) {
            return error.FailedToGetSwapchainImages;
        }

        break :blk swapchain_images;
    };

    app.swapchain_image_views = try allocator.alloc(vk.ImageView, app.swapchain_images.len);
    try createSwapchainImageViews(app.*);

    std.debug.assert(vertices_range_index_begin + vertices_range_size <= memory_size);

    var mesh_memory = try app.device_dispatch.allocateMemory(app.logical_device, &vk.MemoryAllocateInfo{
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

        texture_vertices_buffer = try app.device_dispatch.createBuffer(app.logical_device, &buffer_create_info, null);
        try app.device_dispatch.bindBufferMemory(app.logical_device, texture_vertices_buffer, mesh_memory, vertices_range_index_begin);
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

        texture_indices_buffer = try app.device_dispatch.createBuffer(app.logical_device, &buffer_create_info, null);
        try app.device_dispatch.bindBufferMemory(app.logical_device, texture_indices_buffer, mesh_memory, indices_range_index_begin);
    }

    mapped_device_memory = @ptrCast([*]u8, (try app.device_dispatch.mapMemory(app.logical_device, mesh_memory, 0, memory_size, .{})).?);

    {
        const required_alignment = @alignOf(graphics.GenericVertex);
        const vertices_addr = @ptrCast([*]align(required_alignment) u8, @alignCast(required_alignment, &mapped_device_memory[vertices_range_index_begin]));
        var background_quad = @ptrCast(*graphics.QuadFace(graphics.GenericVertex), @alignCast(required_alignment, &vertices_addr[0]));
        background_quad.* = graphics.generateQuadColored(graphics.GenericVertex, full_screen_extent, background_color, .top_left);
        const vertices_quad_size: u32 = vertices_range_size / @sizeOf(graphics.GenericVertex);
        quad_face_writer_pool = QuadFaceWriterPool(graphics.GenericVertex).initialize(vertices_addr, vertices_quad_size);
    }

    {
        // We won't be reusing vertices except in making quads so we can pre-generate the entire indices buffer
        var indices = @ptrCast([*]u16, @alignCast(16, &mapped_device_memory[indices_range_index_begin]));

        var j: u32 = 0;
        while (j < (indices_range_count / 6)) : (j += 1) {
            indices[j * 6 + 0] = @intCast(u16, j * 4) + 0; // Top left
            indices[j * 6 + 1] = @intCast(u16, j * 4) + 1; // Top right
            indices[j * 6 + 2] = @intCast(u16, j * 4) + 2; // Bottom right
            indices[j * 6 + 3] = @intCast(u16, j * 4) + 0; // Top left
            indices[j * 6 + 4] = @intCast(u16, j * 4) + 2; // Bottom right
            indices[j * 6 + 5] = @intCast(u16, j * 4) + 3; // Bottom left
        }
    }

    {
        const command_pool_create_info = vk.CommandPoolCreateInfo{
            .queue_family_index = app.graphics_present_queue_index,
            .flags = .{},
        };

        app.command_pool = try app.device_dispatch.createCommandPool(app.logical_device, &command_pool_create_info, null);
    }

    app.images_available = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    app.renders_finished = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    app.inflight_fences = try allocator.alloc(vk.Fence, max_frames_in_flight);

    const semaphore_create_info = vk.SemaphoreCreateInfo{
        .flags = .{},
    };

    const fence_create_info = vk.FenceCreateInfo{
        .flags = .{ .signaled_bit = true },
    };

    var i: u32 = 0;
    while (i < max_frames_in_flight) {
        app.images_available[i] = try app.device_dispatch.createSemaphore(app.logical_device, &semaphore_create_info, null);
        app.renders_finished[i] = try app.device_dispatch.createSemaphore(app.logical_device, &semaphore_create_info, null);
        app.inflight_fences[i] = try app.device_dispatch.createFence(app.logical_device, &fence_create_info, null);
        i += 1;
    }

    app.vertex_shader_module = try createVertexShaderModule(app.*, vertex_shader_path);
    app.fragment_shader_module = try createFragmentShaderModule(app.*, fragment_shader_path);

    std.debug.assert(app.swapchain_images.len > 0);

    {
        app.command_buffers = try allocator.alloc(vk.CommandBuffer, app.swapchain_images.len);
        const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
            .command_pool = app.command_pool,
            .level = .primary,
            .command_buffer_count = @intCast(u32, app.command_buffers.len),
        };
        try app.device_dispatch.allocateCommandBuffers(app.logical_device, &command_buffer_allocate_info, app.command_buffers.ptr);
    }

    app.render_pass = try createRenderPass(app.*);

    app.descriptor_set_layouts = try createDescriptorSetLayouts(allocator, app.*);
    app.pipeline_layout = try createPipelineLayout(app.*, app.descriptor_set_layouts);
    app.descriptor_pool = try createDescriptorPool(app.*);
    app.descriptor_sets = try createDescriptorSets(allocator, app.*, app.descriptor_set_layouts);
    app.graphics_pipeline = try createGraphicsPipeline(app.*, app.pipeline_layout, app.render_pass);
    app.framebuffers = try createFramebuffers(allocator, app.*);
}

fn recreateSwapchain(allocator: std.mem.Allocator, app: *GraphicsContext) !void {
    const recreate_swapchain_start = std.time.nanoTimestamp();

    _ = try app.device_dispatch.waitForFences(
        app.logical_device,
        1,
        @ptrCast([*]const vk.Fence, &app.inflight_fences[previous_frame]),
        vk.TRUE,
        std.math.maxInt(u64),
    );

    for (app.swapchain_image_views) |image_view| {
        app.device_dispatch.destroyImageView(app.logical_device, image_view, null);
    }

    app.swapchain_extent.width = screen_dimensions.width;
    app.swapchain_extent.height = screen_dimensions.height;

    const old_swapchain = app.swapchain;
    app.swapchain = try app.device_dispatch.createSwapchainKHR(app.logical_device, &vk.SwapchainCreateInfoKHR{
        .surface = app.surface,
        .min_image_count = app.swapchain_min_image_count,
        .image_format = app.surface_format.format,
        .image_color_space = app.surface_format.color_space,
        .image_extent = app.swapchain_extent,
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

    app.device_dispatch.destroySwapchainKHR(app.logical_device, old_swapchain, null);

    var image_count: u32 = undefined;
    {
        if (.success != (try app.device_dispatch.getSwapchainImagesKHR(app.logical_device, app.swapchain, &image_count, null))) {
            return error.FailedToGetSwapchainImagesCount;
        }

        if (image_count != app.swapchain_images.len) {
            app.swapchain_images = try allocator.realloc(app.swapchain_images, image_count);
        }
    }

    if (.success != (try app.device_dispatch.getSwapchainImagesKHR(app.logical_device, app.swapchain, &image_count, app.swapchain_images.ptr))) {
        return error.FailedToGetSwapchainImages;
    }
    try createSwapchainImageViews(app.*);

    for (app.framebuffers) |framebuffer| {
        app.device_dispatch.destroyFramebuffer(app.logical_device, framebuffer, null);
    }

    {
        app.framebuffers = try allocator.realloc(app.framebuffers, app.swapchain_image_views.len);
        var framebuffer_create_info = vk.FramebufferCreateInfo{
            .render_pass = app.render_pass,
            .attachment_count = 1,
            // We assign to `p_attachments` below in the loop
            .p_attachments = undefined,
            .width = screen_dimensions.width,
            .height = screen_dimensions.height,
            .layers = 1,
            .flags = .{},
        };
        var i: u32 = 0;
        while (i < app.swapchain_image_views.len) : (i += 1) {
            // We reuse framebuffer_create_info for each framebuffer we create, only we need to update the swapchain_image_view that is attached
            framebuffer_create_info.p_attachments = @ptrCast([*]vk.ImageView, &app.swapchain_image_views[i]);
            app.framebuffers[i] = try app.device_dispatch.createFramebuffer(app.logical_device, &framebuffer_create_info, null);
        }
    }

    const recreate_swapchain_end = std.time.nanoTimestamp();
    std.debug.assert(recreate_swapchain_end >= recreate_swapchain_start);
    const recreate_swapchain_duration = @intCast(u64, recreate_swapchain_end - recreate_swapchain_start);

    std.log.info("Swapchain recreated in {}", .{std.fmt.fmtDuration(recreate_swapchain_duration)});
    framebuffer_resized = false;
}

fn recordRenderPass(
    app: GraphicsContext,
    indices_count: u32,
) !void {
    std.debug.assert(app.command_buffers.len > 0);
    std.debug.assert(app.swapchain_images.len == app.command_buffers.len);

    _ = try app.device_dispatch.waitForFences(
        app.logical_device,
        1,
        @ptrCast([*]const vk.Fence, &app.inflight_fences[previous_frame]),
        vk.TRUE,
        std.math.maxInt(u64),
    );

    try app.device_dispatch.resetCommandPool(app.logical_device, app.command_pool, .{});

    // This value should never been seen, as we draw a background quad over it
    const clear_color = graphics.RGBA(f32){ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 - transparancy_level };
    const clear_colors = [1]vk.ClearValue{
        vk.ClearValue{
            .color = vk.ClearColorValue{
                .float_32 = @bitCast([4]f32, clear_color),
            },
        },
    };

    for (app.command_buffers) |command_buffer, i| {
        try app.device_dispatch.beginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
            .flags = .{},
            .p_inheritance_info = null,
        });

        app.device_dispatch.cmdBeginRenderPass(command_buffer, &vk.RenderPassBeginInfo{
            .render_pass = app.render_pass,
            .framebuffer = app.framebuffers[i],
            .render_area = vk.Rect2D{
                .offset = vk.Offset2D{
                    .x = 0,
                    .y = 0,
                },
                .extent = app.swapchain_extent,
            },
            .clear_value_count = 1,
            .p_clear_values = &clear_colors,
        }, .@"inline");

        app.device_dispatch.cmdBindPipeline(command_buffer, .graphics, app.graphics_pipeline);

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
            app.device_dispatch.cmdSetViewport(command_buffer, 0, 1, @ptrCast([*]const vk.Viewport, &viewports));
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
            app.device_dispatch.cmdSetScissor(command_buffer, 0, 1, @ptrCast([*]const vk.Rect2D, &scissors));
        }

        app.device_dispatch.cmdBindVertexBuffers(command_buffer, 0, 1, &[1]vk.Buffer{texture_vertices_buffer}, &[1]vk.DeviceSize{0});
        app.device_dispatch.cmdBindIndexBuffer(command_buffer, texture_indices_buffer, 0, .uint16);
        app.device_dispatch.cmdBindDescriptorSets(
            command_buffer,
            .graphics,
            app.pipeline_layout,
            0,
            1,
            &[1]vk.DescriptorSet{app.descriptor_sets[i]},
            0,
            undefined,
        );

        app.device_dispatch.cmdDrawIndexed(command_buffer, indices_count, 1, 0, 0, 0);

        app.device_dispatch.cmdEndRenderPass(command_buffer);
        try app.device_dispatch.endCommandBuffer(command_buffer);
    }
}

fn renderFrame(allocator: std.mem.Allocator, app: *GraphicsContext) !void {
    _ = try app.device_dispatch.waitForFences(
        app.logical_device,
        1,
        @ptrCast([*]const vk.Fence, &app.inflight_fences[current_frame]),
        vk.TRUE,
        std.math.maxInt(u64),
    );

    const acquire_image_result = try app.device_dispatch.acquireNextImageKHR(
        app.logical_device,
        app.swapchain,
        std.math.maxInt(u64),
        app.images_available[current_frame],
        .null_handle,
    );

    if (framebuffer_resized) {
        try recreateSwapchain(allocator, app);
        return;
    }

    // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/vkAcquireNextImageKHR.html
    switch (acquire_image_result.result) {
        .success => {},
        .error_out_of_date_khr, .suboptimal_khr => {
            const size = app.window.getFramebufferSize() catch glfw.Window.Size{ .width = screen_dimensions.width, .height = screen_dimensions.height };
            screen_dimensions.width = @intCast(u16, size.width);
            screen_dimensions.height = @intCast(u16, size.height);
            std.log.info("Updated screen to {d}, {d}", .{ screen_dimensions.width, screen_dimensions.height });
            try recreateSwapchain(allocator, app);
            return;
        },
        .error_out_of_host_memory => {
            return error.VulkanHostOutOfMemory;
        },
        .error_out_of_device_memory => {
            return error.VulkanDeviceOutOfMemory;
        },
        .error_device_lost => {
            return error.VulkanDeviceLost;
        },
        .error_surface_lost_khr => {
            return error.VulkanSurfaceLost;
        },
        .error_full_screen_exclusive_mode_lost_ext => {
            return error.VulkanFullScreenExclusiveModeLost;
        },
        .timeout => {
            return error.VulkanAcquireFramebufferImageTimeout;
        },
        .not_ready => {
            return error.VulkanAcquireFramebufferImageNotReady;
        },
        else => {
            return error.VulkanAcquireNextImageUnknown;
        },
    }

    const swapchain_image_index = acquire_image_result.image_index;

    const wait_semaphores = [1]vk.Semaphore{app.images_available[current_frame]};
    const wait_stages = [1]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
    const signal_semaphores = [1]vk.Semaphore{app.renders_finished[current_frame]};

    const command_submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &wait_semaphores,
        .p_wait_dst_stage_mask = @ptrCast([*]align(4) const vk.PipelineStageFlags, &wait_stages),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]vk.CommandBuffer, &app.command_buffers[swapchain_image_index]),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = &signal_semaphores,
    };

    try app.device_dispatch.resetFences(app.logical_device, 1, @ptrCast([*]const vk.Fence, &app.inflight_fences[current_frame]));
    try app.device_dispatch.queueSubmit(
        app.graphics_present_queue,
        1,
        @ptrCast([*]const vk.SubmitInfo, &command_submit_info),
        app.inflight_fences[current_frame],
    );

    const swapchains = [1]vk.SwapchainKHR{app.swapchain};
    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &signal_semaphores,
        .swapchain_count = 1,
        .p_swapchains = &swapchains,
        .p_image_indices = @ptrCast([*]const u32, &swapchain_image_index),
        .p_results = null,
    };

    const present_result = try app.device_dispatch.queuePresentKHR(app.graphics_present_queue, &present_info);

    // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/vkQueuePresentKHR.html
    switch (present_result) {
        .success => {},
        .error_out_of_date_khr, .suboptimal_khr => {
            const size = app.window.getFramebufferSize() catch glfw.Window.Size{ .width = screen_dimensions.width, .height = screen_dimensions.height };
            screen_dimensions.width = @intCast(u16, size.width);
            screen_dimensions.height = @intCast(u16, size.height);
            std.log.info("Updated screen to {d}, {d}", .{ screen_dimensions.width, screen_dimensions.height });
            try recreateSwapchain(allocator, app);
            return;
        },
        .error_out_of_host_memory => {
            return error.VulkanHostOutOfMemory;
        },
        .error_out_of_device_memory => {
            return error.VulkanDeviceOutOfMemory;
        },
        .error_device_lost => {
            return error.VulkanDeviceLost;
        },
        .error_surface_lost_khr => {
            return error.VulkanSurfaceLost;
        },
        .error_full_screen_exclusive_mode_lost_ext => {
            return error.VulkanFullScreenExclusiveModeLost;
        },
        .timeout => {
            return error.VulkanAcquireFramebufferImageTimeout;
        },
        .not_ready => {
            return error.VulkanAcquireFramebufferImageNotReady;
        },
        else => {
            return error.VulkanQueuePresentUnknown;
        },
    }

    previous_frame = current_frame;
    current_frame = (current_frame + 1) % max_frames_in_flight;
}

fn createSwapchainImageViews(app: GraphicsContext) !void {
    for (app.swapchain_image_views) |*image_view, image_view_i| {
        const image_view_create_info = vk.ImageViewCreateInfo{
            .image = app.swapchain_images[image_view_i],
            .view_type = .@"2d",
            .format = app.surface_format.format,
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
        image_view.* = try app.device_dispatch.createImageView(app.logical_device, &image_view_create_info, null);
    }
}

fn createRenderPass(app: GraphicsContext) !vk.RenderPass {
    return try app.device_dispatch.createRenderPass(app.logical_device, &vk.RenderPassCreateInfo{
        .attachment_count = 1,
        .p_attachments = &[1]vk.AttachmentDescription{
            .{
                .format = app.surface_format.format,
                .samples = .{ .@"1_bit" = true },
                .load_op = .clear,
                .store_op = .store,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .@"undefined",
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
        },
        .dependency_count = 1,
        .p_dependencies = &[1]vk.SubpassDependency{
            .{
                .src_subpass = vk.SUBPASS_EXTERNAL,
                .dst_subpass = 0,
                .src_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_stage_mask = .{ .color_attachment_output_bit = true },
                .src_access_mask = .{},
                .dst_access_mask = .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
                .dependency_flags = .{},
            },
        },
        .flags = .{},
    }, null);
}

fn createDescriptorPool(app: GraphicsContext) !vk.DescriptorPool {
    const image_count: u32 = @intCast(u32, app.swapchain_image_views.len);
    const descriptor_pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .@"type" = .sampler,
            .descriptor_count = image_count,
        },
        .{
            .@"type" = .sampled_image,
            .descriptor_count = image_count,
        },
    };
    const create_pool_info = vk.DescriptorPoolCreateInfo{
        .pool_size_count = descriptor_pool_sizes.len,
        .p_pool_sizes = &descriptor_pool_sizes,
        .max_sets = image_count,
        .flags = .{},
    };
    return try app.device_dispatch.createDescriptorPool(app.logical_device, &create_pool_info, null);
}

fn createDescriptorSetLayouts(allocator: std.mem.Allocator, app: GraphicsContext) ![]vk.DescriptorSetLayout {
    var descriptor_set_layouts = try allocator.alloc(vk.DescriptorSetLayout, app.swapchain_image_views.len);
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
        descriptor_set_layouts[0] = try app.device_dispatch.createDescriptorSetLayout(app.logical_device, &descriptor_set_layout_create_info, null);

        // We can copy the same descriptor set layout for each swapchain image
        var x: u32 = 1;
        while (x < app.swapchain_image_views.len) : (x += 1) {
            descriptor_set_layouts[x] = descriptor_set_layouts[0];
        }
    }
    return descriptor_set_layouts;
}

fn createDescriptorSets(allocator: std.mem.Allocator, app: GraphicsContext, descriptor_set_layouts: []vk.DescriptorSetLayout) ![]vk.DescriptorSet {
    const swapchain_image_count: u32 = @intCast(u32, app.swapchain_image_views.len);

    // 1. Allocate DescriptorSets from DescriptorPool
    var descriptor_sets = try allocator.alloc(vk.DescriptorSet, swapchain_image_count);
    {
        const descriptor_set_allocator_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = app.descriptor_pool,
            .descriptor_set_count = swapchain_image_count,
            .p_set_layouts = descriptor_set_layouts.ptr,
        };
        try app.device_dispatch.allocateDescriptorSets(app.logical_device, &descriptor_set_allocator_info, @ptrCast([*]vk.DescriptorSet, descriptor_sets.ptr));
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
    const sampler = try app.device_dispatch.createSampler(app.logical_device, &sampler_create_info, null);

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
        app.device_dispatch.updateDescriptorSets(app.logical_device, 1, &write_descriptor_set, 0, undefined);
    }
    return descriptor_sets;
}

fn createPipelineLayout(app: GraphicsContext, descriptor_set_layouts: []vk.DescriptorSetLayout) !vk.PipelineLayout {
    const pipeline_layout_create_info = vk.PipelineLayoutCreateInfo{
        .set_layout_count = 1,
        .p_set_layouts = descriptor_set_layouts.ptr,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
        .flags = .{},
    };
    return try app.device_dispatch.createPipelineLayout(app.logical_device, &pipeline_layout_create_info, null);
}

fn createGraphicsPipeline(app: GraphicsContext, pipeline_layout: vk.PipelineLayout, render_pass: vk.RenderPass) !vk.Pipeline {
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
        .module = app.vertex_shader_module,
        .p_name = "main",
        .p_specialization_info = null,
        .flags = .{},
    };

    const fragment_shader_stage_info = vk.PipelineShaderStageCreateInfo{
        .stage = .{ .fragment_bit = true },
        .module = app.fragment_shader_module,
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
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_clamp = 0.0,
        .depth_bias_slope_factor = 0.0,
        .flags = .{},
    };

    const multisampling = vk.PipelineMultisampleStateCreateInfo{
        .sample_shading_enable = vk.FALSE,
        .rasterization_samples = .{ .@"1_bit" = true },
        .min_sample_shading = 0.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
        .flags = .{},
    };

    const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .blend_enable = if (enable_blending) vk.TRUE else vk.FALSE,
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

    var graphics_pipeline: vk.Pipeline = undefined;
    _ = try app.device_dispatch.createGraphicsPipelines(app.logical_device, .null_handle, 1, &pipeline_create_infos, null, @ptrCast([*]vk.Pipeline, &graphics_pipeline));

    return graphics_pipeline;
}

fn cleanupSwapchain(allocator: std.mem.Allocator, app: *GraphicsContext) void {
    app.device_dispatch.freeCommandBuffers(
        app.logical_device,
        app.command_pool,
        @intCast(u32, app.command_buffers.len),
        app.command_buffers.ptr,
    );
    allocator.free(app.command_buffers);

    for (app.swapchain_image_views) |image_view| {
        app.device_dispatch.destroyImageView(app.logical_device, image_view, null);
    }
    app.device_dispatch.destroySwapchainKHR(app.logical_device, app.swapchain, null);
}

fn createFramebuffers(allocator: std.mem.Allocator, app: GraphicsContext) ![]vk.Framebuffer {
    std.debug.assert(app.swapchain_image_views.len > 0);
    var framebuffer_create_info = vk.FramebufferCreateInfo{
        .render_pass = app.render_pass,
        .attachment_count = 1,
        .p_attachments = undefined,
        .width = screen_dimensions.width,
        .height = screen_dimensions.height,
        .layers = 1,
        .flags = .{},
    };

    var framebuffers = try allocator.alloc(vk.Framebuffer, app.swapchain_image_views.len);
    var i: u32 = 0;
    while (i < app.swapchain_image_views.len) : (i += 1) {
        // We reuse framebuffer_create_info for each framebuffer we create,
        // we only need to update the swapchain_image_view that is attached
        framebuffer_create_info.p_attachments = @ptrCast([*]vk.ImageView, &app.swapchain_image_views[i]);
        framebuffers[i] = try app.device_dispatch.createFramebuffer(app.logical_device, &framebuffer_create_info, null);
    }
    return framebuffers;
}

fn createFragmentShaderModule(app: GraphicsContext, comptime shader_path: []const u8) !vk.ShaderModule {
    const shader_fragment_spv align(4) = @embedFile(shader_path);
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = shader_fragment_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shader_fragment_spv)),
        .flags = .{},
    };
    return try app.device_dispatch.createShaderModule(app.logical_device, &create_info, null);
}

fn createVertexShaderModule(app: GraphicsContext, comptime shader_path: []const u8) !vk.ShaderModule {
    const shader_vertex_spv align(4) = @embedFile(shader_path);
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = shader_vertex_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shader_vertex_spv)),
        .flags = .{},
    };
    return try app.device_dispatch.createShaderModule(app.logical_device, &create_info, null);
}

fn selectSurfaceFormat(
    allocator: std.mem.Allocator,
    app: GraphicsContext,
    color_space: vk.ColorSpaceKHR,
    surface_format: vk.Format,
) !?vk.SurfaceFormatKHR {
    var format_count: u32 = undefined;
    if (.success != (try app.instance_dispatch.getPhysicalDeviceSurfaceFormatsKHR(app.physical_device, app.surface, &format_count, null))) {
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

    if (.success != (try app.instance_dispatch.getPhysicalDeviceSurfaceFormatsKHR(app.physical_device, app.surface, &format_count, formats.ptr))) {
        return error.FailedToGetSurfaceFormats;
    }

    for (formats) |format| {
        if (format.format == surface_format and format.color_space == color_space) {
            return format;
        }
    }
    return null;
}

/// Used to allocate QuadFaceWriters that share backing memory
fn QuadFaceWriterPool(comptime VertexType: type) type {
    return struct {
        const QuadFace = graphics.QuadFace;

        memory_ptr: [*]QuadFace(VertexType),
        memory_quad_range: u32,

        pub fn initialize(start: [*]align(@alignOf(VertexType)) u8, memory_quad_range: u32) @This() {
            return .{
                .memory_ptr = @ptrCast([*]QuadFace(VertexType), start),
                .memory_quad_range = memory_quad_range,
            };
        }

        pub fn create(self: *@This(), quad_index: u16, quad_size: u16) QuadFaceWriter(VertexType) {
            std.debug.assert((quad_index + quad_size) <= self.memory_quad_range);
            return QuadFaceWriter(VertexType).initialize(self.memory_ptr, quad_index, quad_size);
        }
    };
}

fn QuadFaceWriter(comptime VertexType: type) type {
    return struct {
        const QuadFace = graphics.QuadFace;

        memory_ptr: [*]QuadFace(VertexType),

        quad_index: u32,
        capacity: u32,
        used: u32 = 0,

        pub fn initialize(base: [*]QuadFace(VertexType), quad_index: u32, quad_size: u32) @This() {
            return .{
                .memory_ptr = @ptrCast([*]QuadFace(VertexType), &base[quad_index]),
                .quad_index = quad_index,
                .capacity = quad_size,
                .used = 0,
            };
        }

        pub fn indexFromBase(self: @This()) u32 {
            return self.quad_index + self.used;
        }

        pub fn remaining(self: *@This()) u32 {
            std.debug.assert(self.capacity >= self.used);
            return @intCast(u32, self.capacity - self.used);
        }

        pub fn reset(self: *@This()) void {
            self.used = 0;
        }

        pub fn create(self: *@This()) !*QuadFace(VertexType) {
            if (self.used == self.capacity) return error.OutOfMemory;
            defer self.used += 1;
            return &self.memory_ptr[self.used];
        }

        pub fn allocate(self: *@This(), amount: u32) ![]QuadFace(VertexType) {
            if ((self.used + amount) > self.capacity) return error.OutOfMemory;
            defer self.used += amount;
            return self.memory_ptr[self.used .. self.used + amount];
        }
    };
}
