const std = @import("std");

const esc = '\x1b';
const bel = '\x07';
const bs = '\x08';
const cr = '\x0d';
const enq = '\x05';
const ff = '\x0c';
const lf = '\n';
const so = '\x0e';
const si = '\x0f';
const vt = '\x0b';
const tab = '\t';

pub const Token = struct {
    t: TokenType,
    payload: ?Payload = null,

    const TokenType = enum(u16) { decset, deckpam, character, index, next_line, tab_set, reverse_index, ss2, ss3, dcs, spa, epa, sos, decid, csi, st, osc, pm, apc, bel, bs, cr, enq, ff, lf, si, so, tab, vt, s7c1t, s8c1t, ansi_lvl1, ansi_lvl2, ansi_lvl3 };
    const Payload = union {
        code: u8,
        value: u16,
        string: []u8,
    };
};

pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !std.ArrayList(Token) {
    var tokens: std.ArrayList(Token) = try .initCapacity(allocator, 256);
    while (reader.bufferedLen() != 0) {
        const c = try reader.takeByte();
        switch (c) {
            esc => {
                switch (try reader.takeByte()) {
                    'D' => try tokens.append(allocator, .{ .t = .index }),
                    'E' => try tokens.append(allocator, .{ .t = .next_line }),
                    'H' => try tokens.append(allocator, .{ .t = .tab_set }),
                    'M' => try tokens.append(allocator, .{ .t = .reverse_index }),
                    'N' => try tokens.append(allocator, .{ .t = .ss2 }),
                    'O' => try tokens.append(allocator, .{ .t = .ss3 }),
                    'P' => try tokens.append(allocator, .{ .t = .dcs }),
                    'V' => try tokens.append(allocator, .{ .t = .spa }),
                    'W' => try tokens.append(allocator, .{ .t = .epa }),
                    'X' => try tokens.append(allocator, .{ .t = .sos }),
                    'Z' => try tokens.append(allocator, .{ .t = .decid }),
                    '=' => try tokens.append(allocator, .{ .t = .deckpam }),
                    // '[' => try tokens.append(allocator, .{ .t = .csi }),
                    '[' => {
                        switch (try reader.takeByte()) {
                            '?' => {
                                var lookahead = try reader.takeByte();
                                var buffer: std.ArrayList(u8) = try .initCapacity(allocator, 4);
                                defer buffer.deinit(allocator);
                                while (std.ascii.isDigit(lookahead)) {
                                    try buffer.append(allocator, lookahead);
                                    lookahead = try reader.takeByte();
                                }
                                const value = try std.fmt.parseInt(u16, buffer.items, 10);
                                switch (lookahead) {
                                    'h' => try tokens.append(allocator, .{ .t = .decset, .payload = .{ .value = value } }),
                                    else => unreachable,
                                }
                            },
                            else => unreachable,
                        }
                    },
                    '\\' => try tokens.append(allocator, .{ .t = .st }),
                    // ']' => try tokens.append(allocator, .{ .t = .osc }),
                    ']' => {
                        if (reader.takeDelimiter('\\')) |settings| {
                            try tokens.append(allocator, .{ .t = .osc, .payload = .{ .string = settings.? } });
                            try tokens.append(allocator, .{ .t = .st });
                        } else |err| {
                            if (err == error.StreamTooLong) {
                                if (reader.takeDelimiter(bel)) |settings| {
                                    try tokens.append(allocator, .{ .t = .osc, .payload = .{ .string = settings.? } });
                                    try tokens.append(allocator, .{ .t = .bel });
                                } else |_| {}
                            }
                        }
                    },
                    '^' => try tokens.append(allocator, .{ .t = .pm }),
                    '_' => try tokens.append(allocator, .{ .t = .apc }),
                    ' ' => {
                        switch (try reader.takeByte()) {
                            'F' => try tokens.append(allocator, .{ .t = .s7c1t }),
                            'G' => try tokens.append(allocator, .{ .t = .s8c1t }),
                            'L' => try tokens.append(allocator, .{ .t = .ansi_lvl1 }),
                            'M' => try tokens.append(allocator, .{ .t = .ansi_lvl2 }),
                            'N' => try tokens.append(allocator, .{ .t = .ansi_lvl3 }),
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            bel => try tokens.append(allocator, .{ .t = .bel }),
            bs => try tokens.append(allocator, .{ .t = .bs }),
            cr => try tokens.append(allocator, .{ .t = .cr }),
            enq => try tokens.append(allocator, .{ .t = .enq }),
            ff => try tokens.append(allocator, .{ .t = .ff }),
            lf => try tokens.append(allocator, .{ .t = .lf }),
            so => try tokens.append(allocator, .{ .t = .so }),
            si => try tokens.append(allocator, .{ .t = .si }),
            vt => try tokens.append(allocator, .{ .t = .vt }),
            tab => try tokens.append(allocator, .{ .t = .tab }),
            else => {
                if (std.ascii.isPrint(c)) {
                    try tokens.append(allocator, .{ .t = .character, .payload = .{ .code = c } });
                }
            },
        }
    }
    return tokens;
}
