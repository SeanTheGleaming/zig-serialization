# Zig Serialization
Zig Serialization provides an easy to use interface to portably serialize and deserialize binary data to and from std readers and writers.

This library is based on the now-removed `io.serialization` API from the zig standard library. You can find the original code [here](https://github.com/ziglang/std-lib-orphanage/blob/master/std/serialization.zig) in the [ziglang/std-lib-orphanage](https://github.com/ziglang/std-lib-orphanage) repository.
## How to use in your project
### Adding dependency to your build script
To add this library as a dependency, run the following in your build folder:
```sh
zig fetch git+https://github.com/SeanTheGleaming/zig-serialization --save=serialization
```
### In your build script
```zig
pub fn build(b: *std.Build) void {
  const serialization_dep = b.dependency("serialization", .{});
  const serialization_module = serialization_dep.module("serialization");
  
  // Adding to a compile step (executable, library, or unit test)
  const exe: *std.Build.Step.Compile = ...;
	exe.root_module.addImport("serialization", serialization_module);
  
  // Adding to a module
  const module: *std.Build.Module = ...;
  module.addImport("serialization", serialization_module);
}
```
### Usage
To import the library in your Zig source code, use `@import("serialization")`

To see documentation, you can clone this repo and generate documenation with `zig build doc`
