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
reader: *std.Io.Reader = undefined,
internal_buffer: std.ArrayList(Token) = undefined,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !AnsiParser {
    return .{ .state = .start, .allocator = allocator };
}

pub fn parse(parser: *AnsiParser, buffer: []u8) ParserError!std.ArrayList(Token) {
    var reader = std.Io.Reader.fixed(buffer);
    const internal_buffer = try std.ArrayList(Token).initCapacity(parser.allocator, buffer.len);
    parser.reader = &reader;
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
                else => {
                    return error.Unimplemented;
                },
            }
        },
        .csi => {
            switch (try parser.reader.peekByte()) {
                '0'...'9' => {
                    try parser.consume_single();
                },
                '?' => {
                    parser.reader.toss(1);
                    try parser.consume_multiple();
                },
                '#' => {
                    parser.reader.toss(1);
                    try parser.consume_char();
                },
                '>' => {
                    parser.reader.toss(1);
                    try parser.consume_char();
                },
                else => return error.Unimplemented,
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
    try switch (parser.state) {
        .csi => {
            if (try parser.reader.takeDelimiter('h')) |string| {
                std.debug.print("{s}\n", .{string});
                var multiple = try std.ArrayList(usize).initCapacity(parser.allocator, 4);
                var it = std.mem.splitScalar(u8, string, ';');
                while (it.next()) |substring| {
                    const number = try std.fmt.parseInt(usize, substring, 10);
                    try multiple.append(parser.allocator, number);
                }
                try parser.internal_buffer.append(parser.allocator, .{ .payload = .{ .multiple = multiple } });
                parser.state = .start; // FIXME: handle CSI Ps SP @
                try parser.consume_char();
            }
            if (try parser.reader.takeDelimiter('l')) |string| {
                var multiple = try std.ArrayList(usize).initCapacity(parser.allocator, 4);
                var it = std.mem.splitScalar(u8, string, ';');
                while (it.next()) |substring| {
                    const number = try std.fmt.parseInt(usize, substring, 10);
                    try multiple.append(parser.allocator, number);
                }
                try parser.internal_buffer.append(parser.allocator, .{ .payload = .{ .multiple = multiple } });
                parser.state = .start;
                try parser.consume_char();
            }
        },
        else => error.Unimplemented,
    };
}
