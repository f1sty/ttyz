const std = @import("std");
const glfw = @import("glfw");
const freetype = @import("freetype");

const c = @cImport({
    @cInclude("GL/gl.h");
});

const Gui = @This();

width: c_int = 1920,
height: c_int = 1200,
x: c_int = 0, // left
y: c_int = 0, // top
title: []const u8 = "ttyz",
padding: Padding,
window: *glfw.Window = undefined,
atlas: Atlas,

const Font = struct {
    size: u32 = 20,
    path: []const u8,
};

const Padding = struct { x: u16 = 10, y: u16 = 30 };

const Atlas = struct {
    texture_id: c_uint,
    width: c_long,
    height: c_long,
    glyphs: std.ArrayList(Glyph),
    library: freetype.Library,
    face: freetype.Face,

    const Glyph = struct { width: c_uint, height: c_uint, bearing_x: c_int, bearing_y: c_int, advance: c_long, u0: f32, v0: f32 = 0.0, u1: f32, v1: f32 };

    fn init(allocator: std.mem.Allocator, font: Font) !@This() {
        const library = try freetype.Library.init(allocator);
        const face = try library.face(font.path, font.size);
        const characters = 57528;
        const height = face.ft_face.*.height >> 7; // FIXME: >> 6 is twice bigger than expected. what the actual fuck?
        const width = face.ft_face.*.max_advance_width;
        var texture_id: c_uint = undefined;

        c.glGenTextures(1, &texture_id); // generates one c_uint (texture name)
        c.glBindTexture(c.GL_TEXTURE_2D, texture_id);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1); // freetype bitmaps aren't aligned properly

        // using OpenGL 2.1 static, hence GL_ALPHA
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_ALPHA, @intCast(width), @intCast(height), 0, c.GL_ALPHA, c.GL_UNSIGNED_BYTE, null);

        // setup to preperly display text
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

        // filling texture atlas
        var offset: c_int = 0;
        var glyphs: std.ArrayList(Glyph) = try .initCapacity(allocator, characters);

        const texture_width_f: f32 = @floatFromInt(width);
        const texture_height_f: f32 = @floatFromInt(height);

        for (0..characters) |char| {
            const glyph = try face.getGlyphSlot(@intCast(char));
            const xoffset_f: f32 = @floatFromInt(offset);
            const width_f: f32 = @floatFromInt(glyph.bitmap.width);
            const height_f: f32 = @floatFromInt(glyph.bitmap.rows);

            try glyphs.append(allocator, .{ .width = glyph.bitmap.width, .height = glyph.bitmap.rows, .bearing_x = glyph.bitmap_left, .bearing_y = glyph.bitmap_top, .advance = glyph.advance.x >> 6, .u0 = xoffset_f / texture_width_f, .u1 = (xoffset_f + width_f) / texture_width_f, .v1 = height_f / texture_height_f });
            c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, offset, 0, @intCast(glyph.bitmap.width), @intCast(glyph.bitmap.rows), c.GL_ALPHA, c.GL_UNSIGNED_BYTE, glyph.bitmap.buffer);
            offset += @intCast(glyph.bitmap.width);
        }

        return .{
            .texture_id = texture_id,
            .width = width,
            .height = height,
            .glyphs = glyphs,
            .library = library,
            .face = face,
        };
    }

    fn deinit(atlas: *@This()) void {
        defer atlas.library.deinit();
        defer atlas.face.deinit();
    }
};

pub fn init(allocator: std.mem.Allocator, title: []const u8, width: u16, height: u16, font: Font) !@This() {
    const window = try glfw.createWindow(width, height, @ptrCast(title), null, null);
    glfw.makeContextCurrent(window);

    c.glViewport(0, 0, width, height);
    c.glMatrixMode(c.GL_PROJECTION);
    c.glLoadIdentity();
    c.glOrtho(0, @floatFromInt(width), @floatFromInt(height), 0, -1, 1);
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glLoadIdentity();
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    const atlas: Atlas = try .init(allocator, font);
    c.glBindTexture(c.GL_TEXTURE_2D, atlas.texture_id);

    return .{ .window = window, .width = width, .height = height, .atlas = atlas, .padding = .{} };
}

pub fn deinit(gui: *@This()) void {
    gui.atlas.deinit();
    glfw.destroyWindow(gui.window);
}

pub fn update(gui: *@This(), screen: []u8) !void {
    c.glClearColor(0.1, 0.1, 0.1, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    c.glEnable(c.GL_TEXTURE_2D);
    c.glColor4f(1, 1, 1, 1);

    var x: c_int = gui.padding.x;
    var y: c_int = gui.padding.y;
    var utf8 = (try std.unicode.Utf8View.init(screen)).iterator();

    while (utf8.nextCodepoint()) |char| {
        if (char == '\n') {
            x = gui.padding.x;
            y += @intCast(gui.atlas.height);
            continue;
        }

        const pen_x: c_int = x + gui.atlas.glyphs.items[char].bearing_x;
        const pen_y: c_int = y - gui.atlas.glyphs.items[char].bearing_y;
        const width: c_int = @intCast(gui.atlas.glyphs.items[char].width);
        const height: c_int = @intCast(gui.atlas.glyphs.items[char].height);

        c.glBegin(c.GL_QUADS);
        c.glTexCoord2f(gui.atlas.glyphs.items[char].u0, gui.atlas.glyphs.items[char].v0);
        c.glVertex2i(pen_x, pen_y);
        c.glTexCoord2f(gui.atlas.glyphs.items[char].u1, gui.atlas.glyphs.items[char].v0);
        c.glVertex2i(pen_x + width, pen_y);
        c.glTexCoord2f(gui.atlas.glyphs.items[char].u1, gui.atlas.glyphs.items[char].v1);
        c.glVertex2i(pen_x + width, pen_y + height);
        c.glTexCoord2f(gui.atlas.glyphs.items[char].u0, gui.atlas.glyphs.items[char].v1);
        c.glVertex2i(pen_x, pen_y + height);
        c.glEnd();

        x += @intCast(gui.atlas.glyphs.items[char].advance);
    }

    c.glDisable(c.GL_TEXTURE_2D);
}
