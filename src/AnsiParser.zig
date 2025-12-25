const std = @import("std");
const AnsiParser = @This();
const State = enum { start, c0, c1, csi, dcs, osc };
const Token = struct {
    type: Type = .unsupported,
    payload: ?Payload = null,

    const Type = enum { printable, unsupported, ich };
    const Payload = union {
        character: u8,
        single: usize,
        multiple: std.ArrayList(usize),
        text: std.ArrayList(u8),
    };
};
const ParserError = error{ Unimplemented, EndOfStream, ReadFailed, OutOfMemory, StreamTooLong, InvalidCharacter, Overflow };

state: State,
reader: std.Io.Reader = undefined,
internal_buffer: std.ArrayList(Token) = undefined,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !AnsiParser {
    return .{ .state = .start, .allocator = allocator };
}

pub fn parse(parser: *AnsiParser, buffer: []u8) ParserError!std.ArrayList(Token) {
    const reader = std.Io.Reader.fixed(buffer);
    const internal_buffer = try std.ArrayList(Token).initCapacity(parser.allocator, buffer.len);
    parser.reader = reader;
    parser.internal_buffer = internal_buffer;
    parser.consume_char() catch |err| switch (err) {
        error.EndOfStream => return parser.internal_buffer,
        else => |leftover_err| return leftover_err,
    };
    return error.Unimplemented;
}

fn consume_char(parser: *AnsiParser) ParserError!void {
    switch (parser.state) {
        .start => {
            switch (try parser.reader.takeByte()) {
                '\x1b' => {
                    parser.state = .c1;
                    try parser.consume_char();
                },
                else => |byte| {
                    try parser.internal_buffer.append(parser.allocator, .{ .type = .printable, .payload = .{ .character = byte } });
                    parser.state = .start;
                    try parser.consume_char();
                },
            }
        },
        .c1 => {
            switch (try parser.reader.takeByte()) {
                '[' => {
                    parser.state = .csi;
                    try parser.consume_char();
                },
                ']' => {
                    parser.state = .osc;
                    try parser.consume_char();
                },
                'P' => {
                    parser.state = .dcs;
                    try parser.consume_char();
                },
                '=' => {
                    parser.state = .start;
                    try parser.consume_char();
                },
                '>' => {
                    parser.state = .start;
                    try parser.consume_char();
                },
                else => {
                    return error.Unimplemented;
                },
            }
        },
        .csi => {
            switch (try parser.reader.peekByte()) {
                '0'...'9' => {
                    try parser.consume_single();
                    parser.state = .start;
                },
                '?' => {
                    parser.reader.toss(1);
                    try parser.consume_multiple();
                },
                '#' => {
                    parser.reader.toss(1);
                    try parser.consume_char();
                    parser.state = .start;
                },
                '>' => {
                    try parser.internal_buffer.append(parser.allocator, .{});
                    parser.reader.toss(1);
                    try parser.consume_char();
                    parser.state = .start;
                },
                else => {
                    return error.Unimplemented;
                },
            }
        },
        else => return error.Unimplemented,
    }
}

fn consume_single(parser: *AnsiParser) ParserError!void {
    switch (parser.state) {
        .csi => {
            if (try parser.reader.takeDelimiter('@')) |string| {
                const number = try std.fmt.parseInt(usize, string, 10);
                try parser.internal_buffer.append(parser.allocator, .{ .type = .ich, .payload = .{ .single = number } });
                parser.state = .start; // FIXME: handle CSI Ps SP @
                try parser.consume_char();
            }
        },
        else => return error.Unimplemented,
    }
}

fn consume_multiple(parser: *AnsiParser) ParserError!void {
    var number = try std.ArrayList(u8).initCapacity(parser.allocator, 4);
    var multiple = try std.ArrayList(usize).initCapacity(parser.allocator, 4);
    try switch (parser.state) {
        .csi => {
            while (true) {
                const byte = try parser.reader.takeByte();
                if (std.ascii.isDigit(byte)) {
                    try number.append(parser.allocator, byte);
                }
                if (byte == ';') {
                    const number_parsed = try std.fmt.parseInt(usize, number.items, 10);
                    try multiple.append(parser.allocator, number_parsed);
                }
                if (byte == 'h' or byte == 'l') {
                    const number_parsed = try std.fmt.parseInt(usize, number.items, 10);
                    try multiple.append(parser.allocator, number_parsed);
                    try parser.internal_buffer.append(parser.allocator, .{ .payload = .{ .multiple = multiple } });
                    parser.state = .start; // FIXME: handle CSI Ps SP @
                    try parser.consume_char();
                    break;
                }
            }
        },
        else => error.Unimplemented,
    };
}
