const std = @import("std");
const AnsiParser = @This();
const State = enum { start, c1, csi, dcs, osc, rxvt_graphics, dec_line, utf8_mode, char_control, st, dsr };
const Token = struct {
    type: Type,
    payload: Payload,

    const Type = enum {
        character,
        special,
        lf,
        bel,
        csi,
        bs,
        cr,
        so,
        si,
        enq,
        tab,
        vt,
        ff,
        can,
        sub,
        decbi,
        decsc,
        decrc,
        decfi,
        nel,
        esc_f,
        hts,
        ri,
        ss1,
        ss2,
        spa,
        epa,
        decid,
        ind,
        lock,
        unlock,
        ls2,
        ls3,
        deckpnm,
        deckpam,
        ls3r,
        ls2r,
        ls1r,
        decdhl,
        decswl,
        decdwl,
        decaln,
        utf8_enable_alias,
        utf8_enable,
        utf8_disable,
        s7c1t,
        s8c1t,
        ansi1,
        ansi2,
        ansi3,
    };
    const Payload = union {
        character: u8,
        single: usize,
        multiple: std.ArrayList(usize),
        text: std.ArrayList(u8),
    };
};

state: State = .start,
tokens: std.ArrayList(Token),
number_buffer: std.ArrayList(u8),
string_buffer: std.ArrayList(u8),
numbers: std.ArrayList(usize),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !AnsiParser {
    return .{
        .allocator = allocator,
        .tokens = try std.ArrayList(Token).initCapacity(allocator, 2048),
        .number_buffer = try std.ArrayList(u8).initCapacity(allocator, 4),
        .string_buffer = try std.ArrayList(u8).initCapacity(allocator, 4),
        .numbers = try std.ArrayList(usize).initCapacity(allocator, 4),
    };
}

pub fn deinit(parser: *AnsiParser) void {
    parser.tokens.deinit(parser.allocator);
}

pub fn feed(parser: *AnsiParser, buffer: []u8) !void {
    for (buffer) |byte| {
        // std.debug.print("feeding: {x} '{c}'\n", .{ byte, byte });
        switch (parser.state) {
            .start => try parser.stepStart(byte),
            .csi => try parser.stepCsi(byte),
            .c1 => try parser.stepC1(byte),
            .dcs => try parser.stepDcs(byte),
            .osc => try parser.stepOsc(byte),
            .rxvt_graphics => try parser.stepRxvtGraphics(byte),
            .dec_line => try parser.stepDecLine(byte),
            .utf8_mode => try parser.stepUtf8Mode(byte),
            .char_control => try parser.stepCharControl(byte),
            .st => try parser.stepSt(byte),
            .dsr => try parser.stepDsr(byte),
        }
    }
}

pub fn drain(parser: *AnsiParser) ![]Token {
    return try parser.tokens.toOwnedSlice(parser.allocator);
}

fn stepStart(parser: *AnsiParser, byte: u8) !void {
    switch (byte) {
        '\x1b' => parser.state = .c1,
        '\x05' => try parser.tokens.append(parser.allocator, .{ .type = .enq, .payload = .{ .character = byte } }),
        '\x07' => try parser.tokens.append(parser.allocator, .{ .type = .bel, .payload = .{ .character = byte } }),
        '\x08' => try parser.tokens.append(parser.allocator, .{ .type = .bs, .payload = .{ .character = byte } }),
        '\x09' => try parser.tokens.append(parser.allocator, .{ .type = .tab, .payload = .{ .character = byte } }),
        '\x0a' => try parser.tokens.append(parser.allocator, .{ .type = .lf, .payload = .{ .character = byte } }),
        '\x0b' => try parser.tokens.append(parser.allocator, .{ .type = .vt, .payload = .{ .character = byte } }),
        '\x0c' => try parser.tokens.append(parser.allocator, .{ .type = .ff, .payload = .{ .character = byte } }),
        '\x0d' => try parser.tokens.append(parser.allocator, .{ .type = .cr, .payload = .{ .character = byte } }),
        '\x0e' => try parser.tokens.append(parser.allocator, .{ .type = .so, .payload = .{ .character = byte } }),
        '\x0f' => try parser.tokens.append(parser.allocator, .{ .type = .si, .payload = .{ .character = byte } }),
        '\x18' => try parser.tokens.append(parser.allocator, .{ .type = .can, .payload = .{ .character = byte } }),
        '\x1a' => try parser.tokens.append(parser.allocator, .{ .type = .sub, .payload = .{ .character = byte } }),
        else => {
            try parser.tokens.append(parser.allocator, .{ .type = .character, .payload = .{ .character = byte } });
        },
    }
}

fn stepC1(parser: *AnsiParser, byte: u8) !void {
    switch (byte) {
        '[' => parser.state = .csi,
        ']' => parser.state = .osc,
        'P' => parser.state = .dcs,
        '#' => parser.state = .dec_line,
        '%' => parser.state = .utf8_mode,
        ' ' => parser.state = .char_control,
        '\\' => parser.state = .st,
        '6' => {
            try parser.tokens.append(parser.allocator, .{ .type = .decbi, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        '7' => {
            try parser.tokens.append(parser.allocator, .{ .type = .decsc, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        '8' => {
            try parser.tokens.append(parser.allocator, .{ .type = .decrc, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        '9' => {
            try parser.tokens.append(parser.allocator, .{ .type = .decfi, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'D' => {
            try parser.tokens.append(parser.allocator, .{ .type = .ind, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'E' => {
            try parser.tokens.append(parser.allocator, .{ .type = .nel, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'F' => {
            try parser.tokens.append(parser.allocator, .{ .type = .esc_f, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'G' => parser.state = .rxvt_graphics,
        'H' => {
            try parser.tokens.append(parser.allocator, .{ .type = .hts, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'M' => {
            try parser.tokens.append(parser.allocator, .{ .type = .ri, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'N' => {
            try parser.tokens.append(parser.allocator, .{ .type = .ss1, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'O' => {
            try parser.tokens.append(parser.allocator, .{ .type = .ss2, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'V' => {
            try parser.tokens.append(parser.allocator, .{ .type = .spa, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'W' => {
            try parser.tokens.append(parser.allocator, .{ .type = .epa, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'Z' => {
            try parser.tokens.append(parser.allocator, .{ .type = .decid, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'c' => {
            try parser.tokens.append(parser.allocator, .{ .type = .ind, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'l' => {
            try parser.tokens.append(parser.allocator, .{ .type = .lock, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'm' => {
            try parser.tokens.append(parser.allocator, .{ .type = .unlock, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'n' => {
            try parser.tokens.append(parser.allocator, .{ .type = .ls2, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'o' => {
            try parser.tokens.append(parser.allocator, .{ .type = .ls3, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        '>' => {
            try parser.tokens.append(parser.allocator, .{ .type = .deckpnm, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        '=' => {
            try parser.tokens.append(parser.allocator, .{ .type = .deckpam, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        '@' => parser.state = .rxvt_graphics,
        '|' => {
            try parser.tokens.append(parser.allocator, .{ .type = .ls3r, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        '}' => {
            try parser.tokens.append(parser.allocator, .{ .type = .ls2r, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        '~' => {
            try parser.tokens.append(parser.allocator, .{ .type = .ls1r, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        else => return error.C1Unimplemented,
    }
}

fn stepCsi(parser: *AnsiParser, byte: u8) !void {
    switch (byte) {
        '0'...'9' => {
            try parser.number_buffer.append(parser.allocator, byte);
        },
        '@' => {
            const number = try std.fmt.parseInt(usize, parser.number_buffer.items, 10);
            try parser.tokens.append(parser.allocator, .{ .type = .special, .payload = .{ .single = number } });
            parser.resetBuffers();
        },
        ';' => {
            if (parser.number_buffer.items.len == 0) {
                try parser.numbers.append(parser.allocator, 1);
            } else {
                try parser.numbers.append(parser.allocator, try std.fmt.parseInt(usize, parser.number_buffer.items, 10));
            }
        },
        ' ' => {},
        '?' => {},
        'm' => {
            parser.resetBuffers();
        },
        'H' => {
            parser.resetBuffers();
        },
        'J' => {
            parser.resetBuffers();
        },
        'h' => {
            const number = std.fmt.parseInt(usize, parser.number_buffer.items, 10) catch 1;
            try parser.tokens.append(parser.allocator, .{ .type = .special, .payload = .{ .single = number } });
            parser.resetBuffers();
        },
        'l' => {
            const number = std.fmt.parseInt(usize, parser.number_buffer.items, 10) catch 1;
            try parser.tokens.append(parser.allocator, .{ .type = .special, .payload = .{ .single = number } });
            parser.resetBuffers();
        },
        'K' => {
            const number = std.fmt.parseInt(usize, parser.number_buffer.items, 10) catch 1;
            try parser.tokens.append(parser.allocator, .{ .type = .special, .payload = .{ .single = number } });
            parser.resetBuffers();
        },
        else => return error.CsiUnimplemented,
    }
}

fn stepOsc(parser: *AnsiParser, byte: u8) !void {
    switch (byte) {
        '\x1b' => parser.state = .c1,
        '?' => parser.state = .dsr,
        else => {
            try parser.string_buffer.append(parser.allocator, byte);
        },
    }
}

fn stepDcs(parser: *AnsiParser, byte: u8) !void {
    switch (byte) {
        '[' => parser.state = .csi,
        ']' => parser.state = .osc,
        'P' => parser.state = .dcs,
        else => return error.DcsUnimplemented,
    }
}

fn stepRxvtGraphics(parser: *AnsiParser, byte: u8) !void {
    switch (byte) {
        '0'...'9' => {
            try parser.tokens.append(parser.allocator, .{ .type = .special, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        else => return error.UnknownRxvtGraphicsParam,
    }
}

fn stepDecLine(parser: *AnsiParser, byte: u8) !void {
    switch (byte) {
        '3' => {
            try parser.tokens.append(parser.allocator, .{ .type = .decdhl, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        '4' => {
            try parser.tokens.append(parser.allocator, .{ .type = .decdhl, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        '5' => {
            try parser.tokens.append(parser.allocator, .{ .type = .decswl, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        '6' => {
            try parser.tokens.append(parser.allocator, .{ .type = .decdwl, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        '8' => {
            try parser.tokens.append(parser.allocator, .{ .type = .decaln, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        else => return error.DeclineUnimplemented,
    }
}

fn stepUtf8Mode(parser: *AnsiParser, byte: u8) !void {
    switch (byte) {
        '8' => {
            try parser.tokens.append(parser.allocator, .{ .type = .utf8_enable_alias, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'G' => {
            try parser.tokens.append(parser.allocator, .{ .type = .utf8_enable, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        '@' => {
            try parser.tokens.append(parser.allocator, .{ .type = .utf8_disable, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        else => return error.Utf8ModeUnimplmented,
    }
}

fn stepCharControl(parser: *AnsiParser, byte: u8) !void {
    switch (byte) {
        'F' => {
            try parser.tokens.append(parser.allocator, .{ .type = .s7c1t, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'G' => {
            try parser.tokens.append(parser.allocator, .{ .type = .s8c1t, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'L' => {
            try parser.tokens.append(parser.allocator, .{ .type = .ansi1, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'M' => {
            try parser.tokens.append(parser.allocator, .{ .type = .ansi2, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        'N' => {
            try parser.tokens.append(parser.allocator, .{ .type = .ansi3, .payload = .{ .character = byte } });
            parser.state = .start;
        },
        else => return error.CharControlUnimplemented,
    }
}

fn stepSt(parser: *AnsiParser, byte: u8) !void {
    _ = byte;
    if (parser.string_buffer.items.len != 0) {
        try parser.tokens.append(parser.allocator, .{ .type = .special, .payload = .{ .text = parser.string_buffer } });
    }
    parser.resetBuffers();
    parser.state = .start;
}

fn stepDsr(parser: *AnsiParser, byte: u8) !void {
    switch (byte) {
        '0'...'9' => try parser.number_buffer.append(parser.allocator, byte),
        'h' => {
            if (parser.number_buffer.items.len > 0) {
                try parser.tokens.append(parser.allocator, .{ .type = .special, .payload = .{ .single = try std.fmt.parseInt(usize, parser.number_buffer.items, 10) } });
                parser.resetBuffers();
            }
            parser.state = .start;
        },
        else => return error.DsrUnimplemented,
    }
}

fn resetBuffers(parser: *AnsiParser) void {
    parser.number_buffer.clearRetainingCapacity();
    parser.string_buffer.clearRetainingCapacity();
    parser.numbers.clearRetainingCapacity();
    parser.state = .start;
}
