const std = @import("std");
const glfw = @import("glfw");
const freetype = @import("freetype");

const AnsiParser = @import("AnsiParser.zig");
const Gui = @import("Gui.zig");
const Terminal = @import("Terminal.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    try glfw.init();
    defer glfw.terminate();

    var tty = try Terminal.init(allocator, &.{"/usr/bin/bash"});
    defer tty.deinit(allocator);

    var gui = try Gui.init(allocator, "ttyz", 1920, 1200, .{ .size = 20, .path = "RobotoMonoNerdFont-Medium.ttf" });
    defer gui.deinit();

    var screen = try std.ArrayList(u8).initCapacity(allocator, std.heap.pageSize());

    _ = glfw.setCharCallback(gui.window, &char_callback);
    glfw.setWindowUserPointer(gui.window, &tty.fd);

    var parser = try AnsiParser.init(allocator);
    defer parser.deinit();

    while (!glfw.windowShouldClose(gui.window)) {
        if (glfw.getKey(gui.window, glfw.KeyEscape) == glfw.Press) {
            glfw.setWindowShouldClose(gui.window, true);
        }
        if (glfw.getKey(gui.window, glfw.KeyBackspace) == glfw.Press) {
            _ = try std.posix.write(tty.fd, "\x08");
        }
        if (glfw.getKey(gui.window, glfw.KeyEnter) == glfw.Press) {
            _ = try std.posix.write(tty.fd, "\n");
        }
        if (std.posix.read(tty.fd, tty.screen_buffer)) |size| {
            try parser.feed(tty.screen_buffer[0..size]);
            for (try parser.drain()) |token| {
                if (token.type != .special) try screen.append(allocator, token.payload.character);
            }
        } else |err| switch (err) {
            error.WouldBlock => {},
            error.InputOutput => {
                std.debug.print("shell exited\n", .{});
                return;
            },
            else => |leftover_err| return leftover_err,
        }

        try gui.update(screen.items);
        glfw.swapBuffers(gui.window);

        glfw.waitEventsTimeout(0.2);   // 5 fps is enough for everyone
        // glfw.waitEvents();
    }
}

fn char_callback(window: *glfw.Window, codepoint: c_uint) callconv(.c) void {
    var encoded: [4]u8 = undefined;
    const size = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch unreachable;
    const fd: *c_int = @ptrCast(@alignCast(glfw.getWindowUserPointer(window).?));
    _ = std.posix.write(fd.*, encoded[0..size]) catch unreachable;
}
