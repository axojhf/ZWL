const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "zwl",
        .root_source_file = .{ .path = "src/zwl.zig" },
        .target = target,
        .optimize = optimize,
    });
    const zigwin32_dep = b.dependency("zigwin32", .{
        .target = target,
        .optimize = optimize,
    });
    lib.addModule("win32", zigwin32_dep.module("zigwin32"));
    _ = b.addModule("zwl", .{
        .source_file = .{ .path = "src/zwl.zig" },
    });
    // b.installArtifact(lib);
}

// pub fn link(b: *std.Build, step: *std.build.CompileStep) !void {
//     step.linkLibrary(b.dependency("zigwin32", .{
//         .target = step.target,
//         .optimize = step.optimize,
//     }).artifact("zigwin32"));
// }
