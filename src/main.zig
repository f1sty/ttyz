const std = @import("std");
const glfw = @import("glfw");
const freetype = @import("freetype");
const AnsiParser = @import("AnsiParser.zig");

const c = @cImport({
    @cInclude("pty.h");
    @cInclude("GL/gl.h");
});

const Gui = struct {
    width: c_int = 1920,
    height: c_int = 1200,
    font: Font,
    padding: Padding,
    window: *glfw.Window = undefined,

    const Font = struct {
        size: u32 = 20,
        path: []u8,
    };
    const Padding = struct { x: u16 = 10, y: u16 = 30 };

    fn init(title: []const u8, width: u16, height: u16, font_path: []const u8) !@This() {
        const window = try glfw.createWindow(width, height, @ptrCast(title), null, null);
        glfw.makeContextCurrent(window);

        return .{ .window = window, .width = width, .height = height, .font = .{ .path = @constCast(font_path) }, .padding = .{} };
    }

    fn deinit(gui: *@This()) void {
        glfw.destroyWindow(gui.window);
    }
};

const Terminal = struct {
    columns: u16 = 80,
    rows: u16 = 25,
    cursor_position: [2]u16 = .{ 0, 0 },
    fd: c_int = undefined,
    screen_buffer: []u8 = undefined,

    fn init(allocator: std.mem.Allocator, shell_cmd: []const []const u8) !@This() {
        var fd: c_int = undefined;
        const pid = c.forkpty(&fd, null, null, null);

        if (pid == 0) {
            const tio = try std.posix.tcgetattr(0);
            _ = try std.posix.tcsetattr(0, std.posix.TCSA.NOW, tio);   // disable newline buffering
            std.process.execv(allocator, shell_cmd) catch unreachable;
        }

        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | std.posix.SOCK.NONBLOCK);
        var default: @This() = .{};

        default.fd = fd;
        default.screen_buffer = try allocator.alloc(u8, default.columns * default.rows);
        @memset(default.screen_buffer, 0);

        return default;
    }

    fn deinit(terminal: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(terminal.screen_buffer);
        std.posix.close(terminal.fd);
    }
};

const Atlas = struct {
    texture: c_uint,
    texture_height: c_uint,
    glyphs: std.ArrayList(GlyphSlot),

    const GlyphSlot = struct { width: c_uint, height: c_uint, bearing_x: c_int, bearing_y: c_int, advance: c_long, u0: f32, v0: f32 = 0.0, u1: f32, v1: f32 };

    fn init(allocator: std.mem.Allocator, face: freetype.Face) !@This() {
        var texture_width: c_uint = 0;
        var texture_height: c_uint = 0;
        const characters = 57528;

        for (0..characters) |char| {
            const glyph = try face.getGlyphSlot(@intCast(char));
            texture_width += glyph.bitmap.width;
            if (glyph.bitmap.rows > texture_height) texture_height = glyph.bitmap.rows;
        }

        var texture: c_uint = undefined;

        c.glGenTextures(1, &texture); // generates one c_uint (texture name)
        c.glBindTexture(c.GL_TEXTURE_2D, texture);
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
        var glyphs: std.ArrayList(GlyphSlot) = try .initCapacity(allocator, characters);

        const texture_width_f: f32 = @floatFromInt(texture_width);
        const texture_height_f: f32 = @floatFromInt(texture_height);

        for (0..characters) |char| {
            const glyph = try face.getGlyphSlot(@intCast(char));
            const xoffset_f: f32 = @floatFromInt(xoffset);
            const width_f: f32 = @floatFromInt(glyph.bitmap.width);
            const height_f: f32 = @floatFromInt(glyph.bitmap.rows);

            try glyphs.append(allocator, .{ .width = glyph.bitmap.width, .height = glyph.bitmap.rows, .bearing_x = glyph.bitmap_left, .bearing_y = glyph.bitmap_top, .advance = glyph.advance.x >> 6, .u0 = xoffset_f / texture_width_f, .u1 = (xoffset_f + width_f) / texture_width_f, .v1 = height_f / texture_height_f });
            c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, xoffset, 0, @intCast(glyph.bitmap.width), @intCast(glyph.bitmap.rows), c.GL_ALPHA, c.GL_UNSIGNED_BYTE, glyph.bitmap.buffer);
            xoffset += @intCast(glyph.bitmap.width);
        }

        return .{
            .texture = texture,
            .glyphs = glyphs,
            .texture_height = texture_height,
        };
    }

    fn deinit(atlas: *@This(), allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = atlas;
        // allocator.free(atlas.glyphs);
    }
};

fn setupOpenGL(gui: *Gui) void {
    c.glViewport(0, 0, gui.width, gui.height);
    c.glMatrixMode(c.GL_PROJECTION);
    c.glLoadIdentity();
    c.glOrtho(0, @floatFromInt(gui.width), 0, @floatFromInt(gui.height), -1, 1);
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glLoadIdentity();
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    try glfw.init();
    defer glfw.terminate();

    var gui = try Gui.init("ttyz", 1920, 1200, "RobotoMonoNerdFont-Medium.ttf");
    defer gui.deinit();

    var tty = try Terminal.init(allocator, &.{"/usr/bin/bash"});
    defer tty.deinit(allocator);

    const library = try freetype.Library.init(allocator);
    defer library.deinit();

    const face = try library.face(gui.font.path, gui.font.size);
    defer face.deinit();

    var atlas = try Atlas.init(allocator, face);
    defer atlas.deinit(allocator);

    setupOpenGL(&gui);

    c.glBindTexture(c.GL_TEXTURE_2D, atlas.texture);

    var screen = try std.ArrayList(u8).initCapacity(allocator, std.heap.pageSize());

    _ = glfw.setCharCallback(gui.window, &char_callback);
    glfw.setWindowUserPointer(gui.window, &tty.fd);

    var parser = try AnsiParser.init(allocator);
    defer parser.deinit();

    while (!glfw.windowShouldClose(gui.window)) {
        c.glClearColor(0.1, 0.1, 0.1, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        var x: c_int = gui.padding.x;
        var y: c_int = gui.height - gui.padding.y;

        c.glEnable(c.GL_TEXTURE_2D);
        c.glColor4f(1, 1, 1, 1);

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

        var utf8 = (try std.unicode.Utf8View.init(screen.items)).iterator();
        while (utf8.nextCodepoint()) |char| {
            if (char == '\n') {
                x = gui.padding.x;
                y -= @intCast(atlas.texture_height);
                continue;
            }

            // const idx = char - bottom_bound;
            const pen_x: c_int = x + atlas.glyphs.items[char].bearing_x;
            const pen_y: c_int = y + atlas.glyphs.items[char].bearing_y;
            const width: c_int = @intCast(atlas.glyphs.items[char].width);
            const height: c_int = @intCast(atlas.glyphs.items[char].height);

            c.glBegin(c.GL_QUADS);
            c.glTexCoord2f(atlas.glyphs.items[char].u0, atlas.glyphs.items[char].v0);
            c.glVertex2i(pen_x, pen_y);
            c.glTexCoord2f(atlas.glyphs.items[char].u1, atlas.glyphs.items[char].v0);
            c.glVertex2i(pen_x + width, pen_y);
            c.glTexCoord2f(atlas.glyphs.items[char].u1, atlas.glyphs.items[char].v1);
            c.glVertex2i(pen_x + width, pen_y - height);
            c.glTexCoord2f(atlas.glyphs.items[char].u0, atlas.glyphs.items[char].v1);
            c.glVertex2i(pen_x, pen_y - height);
            c.glEnd();

            x += @intCast(atlas.glyphs.items[char].advance);
        }

        c.glDisable(c.GL_TEXTURE_2D);

        glfw.swapBuffers(gui.window);

        if (glfw.getKey(gui.window, glfw.KeyEscape) == glfw.Press) {
            glfw.setWindowShouldClose(gui.window, true);
        }
        if (glfw.getKey(gui.window, glfw.KeyBackspace) == glfw.Press) {
            _ = try std.posix.write(tty.fd, "\x08");
        }
        if (glfw.getKey(gui.window, glfw.KeyEnter) == glfw.Press) {
            _ = try std.posix.write(tty.fd, "\n");
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
