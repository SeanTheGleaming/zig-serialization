# Zig Serialization

Zig Serialization provides an easy to use interface to portably serialize and deserialize binary data to and from std readers and writers.

This library is based on the now-removed `io.serialization` API from the zig standard library. You can find the original code [here](https://github.com/ziglang/std-lib-orphanage/blob/master/std/serialization.zig) in the [ziglang/std-lib-orphanage](https://github.com/ziglang/std-lib-orphanage) repository.

# Limitations:

- all pointer types beside slices are currently unsupported

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

### Example

```zig
fn example() !void {
    const MyDataType2 = struct {
        arr: []const i32,
        hello_world: []const u8,
    };
    const MyDataType = struct {
        arr: []const f64,
        tomato: []const u8,
        nested: []const MyDataType2,
    };
    const nested = MyDataType2{
        .arr = &.{ 3, 2, 1 },
        .hello_world = "hello world",
    };

    const mydata = MyDataType{
        .arr = &.{ 1, 2, 3 },
        .tomato = "tomato",
        .nested = &.{ nested, nested },
    };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var list = std.ArrayList(u8).init(alloc);

    var ser = serializer(.little, .bit, list.writer());

    try ser.serialize(MyDataType, mydata);
    const dat = list.items;

    var fixed_stream = std.io.fixedBufferStream(dat);

    var de = deserializer(.little, .bit, fixed_stream.reader());
    const rede = try de.deserialize(MyDataType, alloc);
    std.log.warn("print : {any}", .{rede});
}
```
