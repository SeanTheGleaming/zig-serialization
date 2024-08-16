const std = @import("std");
const module_package = @import("module_package");
pub usingnamespace @import("src/main.zig");
pub fn build(b: *std.Build) void {
    module_package.buildScript(b, "serialization", b.path("src"));
}
