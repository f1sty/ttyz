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

const GlyphSlot = struct { id: c_uint, code: u8, width: u32, height: u32, bearing_x: i32, bearing_y: i32, advance: c_long };
const GlyphSlotsInfo = struct {
    items: std.ArrayList(GlyphSlot) = undefined,
    max_height: u32 = 0,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    try glfw.init();
    defer glfw.terminate();

    const library = try freetype.Library.init(allocator);
    defer library.deinit();

    const face = try library.face("RobotoMonoNerdFont-Medium.ttf", font_size);
    defer face.deinit();

    var fd: c_int = undefined;
    var name: [1024]u8 = undefined;

    const pid = c.forkpty(&fd, @ptrCast(&name), null, null);

    if (pid == 0) {
        std.process.execv(allocator, &.{"/usr/bin/sh"}) catch unreachable;
        return;
    }

    const window = try glfw.createWindow(window_width, window_height, @ptrCast(&name), null, null);
    defer glfw.destroyWindow(window);

    glfw.makeContextCurrent(window);

    // setup to display font properly
    c.glViewport(0, 0, window_width, window_height);
    c.glMatrixMode(c.GL_PROJECTION);
    c.glLoadIdentity();
    c.glOrtho(0, window_width, 0, window_height, -1, 1);
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glLoadIdentity();
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);

    var buffer: [80 * 25]u8 = undefined;
    const size = try std.posix.read(fd, &buffer);
    _ = size;

    var reader: std.Io.Reader = .fixed(&buffer);
    const parsed = try ansi_codes.parse(allocator, &reader);

    const glyphs = try strToGlyphInfo(allocator, parsed, face);

    while (!glfw.windowShouldClose(window)) {
        c.glClearColor(0.1, 0.1, 0.1, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        var x: c_int = padding_x;
        var y: c_int = window_height - padding_y;

        c.glEnable(c.GL_TEXTURE_2D);
        c.glColor3f(1, 0.5, 1);

        for (glyphs.items.items) |char| {
            if (char.code == '\n') {
                x = padding_x;
                y -= @intCast(glyphs.max_height);
                continue;
            }
            const pen_x: c_int = x + char.bearing_x;
            const pen_y: c_int = y + char.bearing_y;
            const w: c_int = @intCast(char.width);
            const h: c_int = @intCast(char.height);

            c.glBindTexture(c.GL_TEXTURE_2D, char.id);

            c.glBegin(c.GL_QUADS);
            c.glTexCoord2f(0, 0);
            c.glVertex2i(pen_x, pen_y);
            c.glTexCoord2f(1, 0);
            c.glVertex2i(pen_x + w, pen_y);
            c.glTexCoord2f(1, 1);
            c.glVertex2i(pen_x + w, pen_y - h);
            c.glTexCoord2f(0, 1);
            c.glVertex2i(pen_x, pen_y - h);
            c.glEnd();

            x += @intCast(char.advance);
        }

        c.glDisable(c.GL_TEXTURE_2D);

        glfw.swapBuffers(window);

        if (glfw.getKey(window, glfw.KeyEscape) == glfw.Press) {
            glfw.setWindowShouldClose(window, true);
        }

        glfw.pollEvents();
    }
}

fn strToGlyphInfo(allocator: std.mem.Allocator, tokens: std.ArrayList(ansi_codes.Token), face: freetype.Face) !GlyphSlotsInfo {
    var glyphs: GlyphSlotsInfo = .{ .items = try .initCapacity(allocator, tokens.items.len) };
    for (tokens.items) |token| {
        if (token.t == .character) {
            const g = try face.getGlyphSlot(token.payload.?.code);
            var texture: c_uint = undefined;

            c.glGenTextures(1, &texture);
            c.glBindTexture(c.GL_TEXTURE_2D, texture);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_R8, @intCast(g.bitmap.width), @intCast(g.bitmap.rows), 0, c.GL_RED, c.GL_UNSIGNED_BYTE, g.bitmap.buffer);

            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

            const character: GlyphSlot = .{ .id = texture, .code = token.payload.?.code, .width = g.bitmap.width, .height = g.bitmap.rows, .bearing_x = g.bitmap_left, .bearing_y = g.bitmap_top, .advance = g.advance.x >> 6 };
            try glyphs.items.append(allocator, character);
            if (character.height > glyphs.max_height) glyphs.max_height = character.height;
        }
    }

    return glyphs;
}
