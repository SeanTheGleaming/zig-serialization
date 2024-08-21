const std = @import("std");

// Expose the module to dependant build scripts,
// in case you for some reason want to use this
// inside a build script
pub usingnamespace @import("src/main.zig");

pub fn build(b: *std.Build) void {
    const src_dir = "src";

    const install_step = b.getInstallStep();

    const fmt_step = b.step("fmt", "Format the source code");
    const test_step = b.step("test", "Run the unit tests");
    const doc_step = b.step("doc", "Install the docs");
    doc_step.dependOn(fmt_step);
    install_step.dependOn(doc_step);

    const release_step = b.step("release", "Format source, install docs and run unit tests");
    release_step.dependOn(fmt_step);
    release_step.dependOn(doc_step);
    release_step.dependOn(test_step);

    const fmt = b.addFmt(.{ .paths = &.{src_dir} });
    fmt_step.dependOn(&fmt.step);

    const src = b.path(src_dir);
    const root = src.path(b, "main.zig");

    const exported_module = b.addModule("serialization", .{
        .root_source_file = root,
    });
    _ = exported_module;

    // target and optimization just for the tests/docs
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tests = b.addTest(.{
        .name = "Serialization",
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&tests.step);

    const doc_compile = b.addObject(.{
        .name = "Serialization",
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
    });
    const docs = doc_compile.getEmittedDocs();
    const doc_install = b.addInstallDirectory(.{
        .install_dir = .{ .custom = "doc" },
        .source_dir = docs,
        .install_subdir = "",
    });
    doc_step.dependOn(&doc_install.step);
}
