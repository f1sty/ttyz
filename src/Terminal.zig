const std = @import("std");
const Terminal = @This();

const c = @cImport({
    @cInclude("pty.h");
});

columns: u16 = 80,
rows: u16 = 25,
cursor_position: [2]u16 = .{ 0, 0 },
fd: c_int = undefined,
screen_buffer: []u8 = undefined,

pub fn init(allocator: std.mem.Allocator, shell_cmd: []const []const u8) !@This() {
    var fd: c_int = undefined;
    const pid = c.forkpty(&fd, null, null, null);

    if (pid == 0) {
        const tio = try std.posix.tcgetattr(0);
        _ = try std.posix.tcsetattr(0, std.posix.TCSA.NOW, tio); // disable newline buffering
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

pub fn deinit(terminal: *@This(), allocator: std.mem.Allocator) void {
    allocator.free(terminal.screen_buffer);
    std.posix.close(terminal.fd);
}
