const std = @import("std");
const glfw = @import("glfw");

pub fn main() !void {
    try glfw.init(.{});
    defer glfw.terminate();

    const window = try glfw.Window.create(640, 480, "GLFW-Vulkan barebones", null, null, .{});
    defer window.destroy();

    while (!window.shouldClose()) {
        try glfw.pollEvents();
        std.time.sleep(std.time.ns_per_ms * 100);
    }
}