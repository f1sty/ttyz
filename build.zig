const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.graph.host;
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{ .name = "sandbox", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .root_source_file = b.path("src/main.zig") }) });

    const freetype = b.dependency("zig_freetype2", .{ .target = target, .optimize = optimize });
    const zglfw = b.dependency("zglfw", .{ .target = target, .optimize = optimize });

    const ansi_codes = b.createModule(.{ .target = target, .optimize = optimize, .root_source_file = b.path("src/ansi_codes.zig") });

    exe.root_module.addImport("ascii_codes", ansi_codes);
    exe.root_module.addImport("glfw", zglfw.module("glfw"));
    exe.root_module.addImport("freetype", freetype.module("freetype"));
    exe.root_module.linkSystemLibrary("glfw3", .{});
    exe.root_module.linkSystemLibrary("gl", .{});

    b.installArtifact(exe);
}
