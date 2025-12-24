const std = @import("std");
const glfw = @import("glfw");
const freetype = @import("freetype");
const ansi_codes = @import("ansi_codes.zig");

const c = @cImport({
    @cInclude("pty.h");
    @cInclude("GL/gl.h");
});

const window_width = 1920;
const window_height = 1200;
const font_size = 20;
const padding_x = 10;
const padding_y = padding_x * 3;
const columns = 80;
const lines = 25;

const GlyphSlot = struct { width: c_uint, height: c_uint, bearing_x: c_int, bearing_y: c_int, advance: c_long, u0: f32, v0: f32 = 0.0, u1: f32, v1: f32 };
const Screen = struct {
    buffer: std.ArrayList(u8) = undefined,
    width: u16,
    height: u16,
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    reader: std.Io.Reader,

    fn init(allocator: std.mem.Allocator, width: u16, height: u16) !@This() {
        var buffer = try std.ArrayList(u8).initCapacity(allocator, width * height);
        @memset(buffer.items, 0);
        return .{ .buffer = buffer, .width = width, .height = height, .reader = std.Io.Reader.fixed(buffer.items) };
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    try glfw.init();
    defer glfw.terminate();

    var fd: c_int = undefined;
    const pid = c.forkpty(&fd, null, null, null);

    if (pid == 0) {
        std.process.execv(allocator, &.{"/usr/bin/sh"}) catch unreachable;
        return;
    }

    const window = try glfw.createWindow(window_width, window_height, "ttyz", null, null);
    defer glfw.destroyWindow(window);

    glfw.makeContextCurrent(window);

    const library = try freetype.Library.init(allocator);
    defer library.deinit();

    const face = try library.face("RobotoMonoNerdFont-Medium.ttf", font_size);
    defer face.deinit();

    var texture_width: c_uint = 0;
    var texture_height: c_uint = 0;

    const top_bound = 58000;
    const bottom_bound = 0;

    for (bottom_bound..top_bound) |char| {
        const glyph = try face.getGlyphSlot(@intCast(char));
        texture_width += glyph.bitmap.width;
        if (glyph.bitmap.rows > texture_height) texture_height = glyph.bitmap.rows;
    }

    var characters_texture: c_uint = undefined;
    c.glGenTextures(1, &characters_texture); // generates one c_uint (texture name)
    c.glBindTexture(c.GL_TEXTURE_2D, characters_texture);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1); // freetype bitmaps aren't aligned properly

    // using OpenGL 2.1 static, hence GL_ALPHA
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_ALPHA, @intCast(texture_width), @intCast(texture_height), 0, c.GL_ALPHA, c.GL_UNSIGNED_BYTE, null);

    // setup to preperly display text
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

    // filling texture atlas
    var xoffset: c_int = 0;
    var texture_atlas: std.ArrayList(GlyphSlot) = try .initCapacity(allocator, top_bound - bottom_bound);
    defer texture_atlas.deinit(allocator);

    const texture_width_f: f32 = @floatFromInt(texture_width);
    const texture_height_f: f32 = @floatFromInt(texture_height);

    for (bottom_bound..top_bound) |char| {
        const glyph = try face.getGlyphSlot(@intCast(char));
        const xoffset_f: f32 = @floatFromInt(xoffset);
        const width_f: f32 = @floatFromInt(glyph.bitmap.width);
        const height_f: f32 = @floatFromInt(glyph.bitmap.rows);

        try texture_atlas.append(allocator, .{ .width = glyph.bitmap.width, .height = glyph.bitmap.rows, .bearing_x = glyph.bitmap_left, .bearing_y = glyph.bitmap_top, .advance = glyph.advance.x >> 6, .u0 = xoffset_f / texture_width_f, .u1 = (xoffset_f + width_f) / texture_width_f, .v1 = height_f / texture_height_f });
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, xoffset, 0, @intCast(glyph.bitmap.width), @intCast(glyph.bitmap.rows), c.GL_ALPHA, c.GL_UNSIGNED_BYTE, glyph.bitmap.buffer);
        xoffset += @intCast(glyph.bitmap.width);
    }

    // setup to display font properly
    c.glViewport(0, 0, window_width, window_height);
    c.glMatrixMode(c.GL_PROJECTION);
    c.glLoadIdentity();
    c.glOrtho(0, window_width, 0, window_height, -1, 1);
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glLoadIdentity();
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    var buffer: [columns * lines]u8 = undefined;
    @memset(&buffer, 0); // fill with 0s to interface with c-strings

    const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | std.posix.SOCK.NONBLOCK);

    // var reader: std.Io.Reader = .fixed(&buffer);
    // const parsed = try ansi_codes.parse(allocator, &reader);

    c.glBindTexture(c.GL_TEXTURE_2D, characters_texture);

    var screen = try std.ArrayList(u8).initCapacity(allocator, std.heap.pageSize());

    _ = glfw.setCharCallback(window, &char_callback);
    glfw.setWindowUserPointer(window, &fd);

    while (!glfw.windowShouldClose(window)) {
        c.glClearColor(0.1, 0.1, 0.1, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        var x: c_int = padding_x;
        var y: c_int = window_height - padding_y;

        c.glEnable(c.GL_TEXTURE_2D);
        c.glColor4f(1, 1, 1, 1);

        if (std.posix.read(fd, &buffer)) |size| {
            try screen.appendSlice(allocator, buffer[0..size]);
        } else |err| switch (err) {
            error.WouldBlock => {},
            error.InputOutput => {
                std.debug.print("shell exited\n", .{});
                return;
            },
            else => |leftover_err| return leftover_err,
        }

        var utf8 = (try std.unicode.Utf8View.init(screen.items)).iterator();
        while (utf8.nextCodepoint()) |char| {
            if (char == '\n') {
                x = padding_x;
                y -= @intCast(texture_height);
                continue;
            }

            // const idx = char - bottom_bound;
            const pen_x: c_int = x + texture_atlas.items[char].bearing_x;
            const pen_y: c_int = y + texture_atlas.items[char].bearing_y;
            const width: c_int = @intCast(texture_atlas.items[char].width);
            const height: c_int = @intCast(texture_atlas.items[char].height);

            c.glBegin(c.GL_QUADS);
            c.glTexCoord2f(texture_atlas.items[char].u0, texture_atlas.items[char].v0);
            c.glVertex2i(pen_x, pen_y);
            c.glTexCoord2f(texture_atlas.items[char].u1, texture_atlas.items[char].v0);
            c.glVertex2i(pen_x + width, pen_y);
            c.glTexCoord2f(texture_atlas.items[char].u1, texture_atlas.items[char].v1);
            c.glVertex2i(pen_x + width, pen_y - height);
            c.glTexCoord2f(texture_atlas.items[char].u0, texture_atlas.items[char].v1);
            c.glVertex2i(pen_x, pen_y - height);
            c.glEnd();

            x += @intCast(texture_atlas.items[char].advance);
        }

        c.glDisable(c.GL_TEXTURE_2D);

        glfw.swapBuffers(window);

        if (glfw.getKey(window, glfw.KeyEscape) == glfw.Press) {
            glfw.setWindowShouldClose(window, true);
        }
        if (glfw.getKey(window, glfw.KeyBackspace) == glfw.Press) {
            _ = try std.posix.write(fd, "\x08");
        }
        if (glfw.getKey(window, glfw.KeyEnter) == glfw.Press) {
            _ = try std.posix.write(fd, "\n");
        }

        glfw.waitEvents();
    }
}

fn char_callback(window: *glfw.Window, codepoint: c_uint) callconv(.c) void {
    var encoded: [4]u8 = undefined;
    const size = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch unreachable;
    const fd: *c_int = @ptrCast(@alignCast(glfw.getWindowUserPointer(window).?));
    _ = std.posix.write(fd.*, encoded[0..size]) catch unreachable;
}
