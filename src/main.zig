//! Library for serialization and deserialization
//! To add support for your own types, add the following:
//! 1. A serialization function matching this signature
//!    - `pub fn serialize(self: @This(), serializer: anytype) !void`
//! 2. A deserialization function matching one of the following signatures:
//!    - `pub fn deserialize(deserializer: anytype) !@This()`
//!    - `pub fn allocatingDeserialize(deserializer: anytype, allocator: std.mem.Allocator) !@This()`

const std = @import("std");
const bitio = @import("bitio.zig");
const io = std.io;
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const testing = std.testing;

/// Generally used instead of `usize` when serializing data in order to ensure identical behavior cross-platform
pub const Size = u32;

/// Packing with which to serialize data
pub const Packing = enum { bit, byte };

const custom_serialize_fn_name = "serialize";
const custom_deserialize_fn_name = "deserialize";
const custom_allocating_deserialize_fn_name = "allocatingDeserialize";

/// Contains functions returning structs with common serialization code.
/// These can be mixed in when declaring a type to reduce boilerplate in common scenarios.
/// By using the below line of code in your type,, proper serialization/deserialization functions will be mixed in, ensuring your type will be valid to serialize
/// `pub usingnamespace serialization.serialize_fns.SomeImplementation(@This());`
pub const serialize_fns = struct {
    /// Packed unions can be serialized trivially via the underlying integer layout.
    /// To allow for this, this can be used to serialize packed unions by the underling ints
    pub fn PackedUnion(comptime Self: type) type {
        return struct {
            pub fn serialize(self: Self, _serializer: anytype) !void {
                const info = @typeInfo(Self);
                if (info != .Union and info.Union.layout != .@"packed") {
                    @compileError("Serialization implementation 'PackedUnion' used on " ++ @tagName(info) ++ " type `" ++ @typeName(Self) ++ "`, which isn't a packed union");
                }
                return _serializer.serialize(meta.Int(.unsigned, @bitSizeOf(Self)), @bitCast(self));
            }
            pub fn deserialize(_deserializer: anytype) !Self {
                const info = @typeInfo(Self);
                if (info != .Union and info.Union.layout != .@"packed") {
                    @compileError("Serialization implementation 'PackedUnion' used on " ++ @tagName(info) ++ " type `" ++ @typeName(Self) ++ "`, which isn't a packed union");
                }
                return @bitCast(try _deserializer.deserialize(meta.Int(.unsigned, @bitSizeOf(Self))));
            }
        };
    }

    test PackedUnion {
        const IEEE = packed union {
            pub usingnamespace serialize_fns.PackedUnion(@This());

            fields: packed struct {
                mantissa: u23,
                exponent: u8,
                sign: bool,
            },
            float: f32,
            int: u32,

            fn expectEqual(lhs: @This(), rhs: @This()) !void {
                try testing.expectEqual(lhs.int, rhs.int);
                if (!math.isNan(lhs.float) and !math.isNan(rhs.float)) {
                    try testing.expectEqual(lhs.float, rhs.float);
                }
            }
        };

        const ieee_values = [_]IEEE{
            IEEE{ .int = 7 },
            IEEE{ .int = 0 },
            IEEE{ .int = 0x5f3759df },
            IEEE{ .int = math.maxInt(u32) },

            IEEE{ .float = 0.0 },
            IEEE{ .float = 123.456 },
            IEEE{ .float = math.inf(f32) },
            IEEE{ .float = math.nan(f32) },
            IEEE{ .float = math.floatMin(f32) },
            IEEE{ .float = math.floatMax(f32) },

            IEEE{ .fields = .{
                .sign = false,
                .exponent = 0xFF,
                .mantissa = 0,
            } },
        };

        for (ieee_values) |ieee| {
            try testSerializable(IEEE, ieee, testing.allocator, IEEE.expectEqual);
        }
    }

    /// Use this when you do not want to include something in serialization.
    /// When serializing, it will skip over this data.
    /// When deserializing, it will return an undefined value.
    /// Useful for cases like padding fields.
    pub fn NoOpSerialize(comptime Self: type) type {
        return struct {
            pub fn serialize(self: Self, _serializer: anytype) !void {
                _ = self;
                _ = _serializer;
                return;
            }
            pub fn deserialize(_deserializer: anytype) !Self {
                _ = _deserializer;
                return undefined;
            }
        };
    }

    /// Use this when something should not be serialized.
    /// Causes a compilation error when serialization/deserialization is attempted in the program
    pub fn Unserializable(comptime Self: type) type {
        return struct {
            pub const __serialization_impl_unserializable = Unserializable;
            pub fn serialize(self: Self, _serializer: anytype) !void {
                _ = self;
                _ = _serializer;
                @compileError("Error: Can not serialize type `" ++ @typeName(Self) ++ "`, which specifies that it is not serializable");
            }
            pub fn deserialize(_deserializer: anytype) !Self {
                _ = _deserializer;
                @compileError("Error: Can not deserialize type `" ++ @typeName(Self) ++ "`, which specifies that it is not serializable");
            }
        };
    }
};

/// Whether a type uses custom serialization functions
fn usesCustomSerialize(comptime T: type) bool {
    return (meta.hasFn(T, custom_allocating_deserialize_fn_name) or meta.hasFn(T, custom_deserialize_fn_name)) and meta.hasFn(T, custom_serialize_fn_name);
}

/// Whether custom serialization functions are used anywhere in the structure of a type
fn containsCustomSerialize(comptime T: type) bool {
    return comptime usesCustomSerialize(T) or switch (@typeInfo(T)) {
        .Struct => |Struct| blk: {
            for (Struct.fields) |field| {
                if (containsCustomSerialize(field.type)) break :blk true;
            }
            break :blk false;
        },
        .Union => |Union| blk: {
            if (Union.tag_type) |Tag| {
                if (containsCustomSerialize(Tag)) break :blk true;
            }
            for (Union.fields) |field| {
                if (containsCustomSerialize(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

// code for cleaner error messages
// reduces guess work by saying exactly which field of a struct/union cannot be serialized
// TODO: clean up this code a lot

const SerializationErrorInfo = struct {
    problem: type,
    fields: []const []const u8,
    info: ?[]const u8 = null,
};

/// Actual implementation of generating error messages for unserializable types
fn serializeErrorFields(comptime T: type, comptime name: []const u8, comptime prev: []const []const u8) ?SerializationErrorInfo {
    return comptime switch (@typeInfo(T)) {
        .Struct => |Struct| blk: {
            if (usesCustomSerialize(T)) {
                if (@hasDecl(T, "__serialization_impl_unserializable")) {
                    if (T.__serialization_impl_unserializable == serialize_fns.Unserializable) {
                        break :blk .{ .problem = T, .fields = prev ++ &[1][]const u8{name}, .info = "Custom type specifies that it is unserializable" };
                    }
                }

                break :blk null;
            }
            for (Struct.fields) |field| {
                if (serializeErrorFields(field.type, field.name, prev ++ &[1][]const u8{name})) |err| {
                    break :blk err;
                }
            }
            break :blk null;
        },

        .Union => |Union| blk: {
            if (usesCustomSerialize(T)) {
                if (@hasDecl(T, "__serialization_impl_unserializable")) {
                    if (T.__serialization_impl_unserializable == serialize_fns.Unserializable) {
                        break :blk .{ .problem = T, .fields = prev ++ &[1][]const u8{name}, .info = "Custom type specifies that it is unserializable" };
                    }
                }

                break :blk null;
            }
            if (Union.tag_type) |Tag| {
                if (!@typeInfo(Tag).Enum.is_exhaustive) {
                    break :blk .{ .problem = T, .fields = prev ++ &[1][]const u8{name}, .info = "TODO: support serialization of unions tagged by non-exhaustive enums" };
                }
                for (Union.fields) |field| {
                    if (serializeErrorFields(field.type, field.name, prev ++ &[1][]const u8{name})) |err| {
                        break :blk err;
                    }
                }
                break :blk null;
            } else {
                break :blk .{ .problem = T, .fields = prev ++ &[1][]const u8{name}, .info = "Untagged unions cannot be serialized without custom serialize/deserialize methods" };
            }
        },
        .Enum => blk: {
            if (usesCustomSerialize(T)) {
                if (@hasDecl(T, "__serialization_impl_unserializable")) {
                    if (T.__serialization_impl_unserializable == serialize_fns.Unserializable) {
                        break :blk .{ .problem = T, .fields = prev ++ &[1][]const u8{name}, .info = "Custom type specifies that it is unserializable" };
                    }
                }
            }

            break :blk null;
        },

        .Optional => |Optional| serializeErrorFields(Optional.child, "?", prev ++ &[1][]const u8{name}),
        .Array => |Array| serializeErrorFields(Array.child, name ++ "[...]", prev),
        .Vector => |Vector| serializeErrorFields(Vector.child, name ++ "[...]", prev),

        .Int, .Float, .Bool, .Void, .Undefined, .Null => null,

        else => .{ .problem = T, .fields = prev ++ &[1][]const u8{name}, .info = switch (@typeInfo(T)) {
            .Pointer => "Pointers cannot be serialized. Consider using custom serialize/deserialize methods",
            .ErrorUnion => "Error unions cannot be serialized, did you mean to use a 'try' statement?",
            .ErrorSet => "Error sets cannot be serialized",
            .Fn => "Functions cannot be serialized",
            .Type => "Types cannot be serialized",
            .Frame, .AnyFrame => "Frames cannot be serialized",
            .EnumLiteral => "Enum literals cannot be serialized",
            else => null,
        } },
    };
}

/// The error message for trying to serialize/deserialize a type, if that type is not serializable/deserializable
pub fn serializeTypeErrorMessage(comptime T: type) ?[]const u8 {
    const opfields = serializeErrorFields(T, @typeName(T), &.{});
    if (opfields) |errfields| {
        var field_nav_str: []const u8 = "";

        for (errfields.fields) |errmsg| {
            field_nav_str = field_nav_str ++ "." ++ errmsg;
        }
        field_nav_str = field_nav_str[1..];

        return std.fmt.comptimePrint(
            \\Error with serialization of type {}
            \\Cannot meaningfully serialize {s} type of {s}
            \\{s}
        , .{ errfields.problem, @tagName(@typeInfo(errfields.problem)), field_nav_str, errfields.info orelse "Unimplemented and/or Unplanned" });
    } else {
        return null;
    }
}

/// Whether type `T` is able to be serialized/deserialized
pub fn canSerialize(comptime T: type) bool {
    return serializeTypeErrorMessage(T) == null;
}

/// Whether an allocator is required for deserializtion of type `T`
pub fn deserializeNeedsAllocator(comptime T: type) bool {
    return comptime if (!canSerialize(T)) false else switch (@typeInfo(T)) {
        .Struct => blk: {
            const fields = meta.fields(T);
            for (fields) |field| {
                if (deserializeNeedsAllocator(field.type)) break :blk true;
            }
            break :blk false;
        },
        .Union => |Union| blk: {
            if (Union.tag_type) |Tag| {
                if (deserializeNeedsAllocator(Tag)) break :blk true;
            }
            const fields = meta.fields(T);
            for (fields) |field| {
                if (deserializeNeedsAllocator(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => usesCustomSerialize(T) and meta.hasFn(T, custom_allocating_deserialize_fn_name),
    };
}

fn signedness(comptime T: type) std.builtin.Signedness {
    return switch (@typeInfo(T)) {
        .Int => |int| int.signedness,
        .Float => .signed,
        else => .unsigned,
    };
}

fn portableLayout(comptime T: anytype) bool {
    const info = @typeInfo(T);
    return comptime switch (info) {
        .Int, .Float, .Void, .Null, .Undefined => true,
        .Struct => |Struct| Struct.layout == .@"packed" or @sizeOf(T) == 0,
        .Union => |Union| Union.layout == .@"packed" or @sizeOf(T) == 0,
        else => false,
    };
}

/// Whether the type uses any custom serialization function
fn intSerializable(comptime T: type) bool {
    return portableLayout(T) and !containsCustomSerialize(T);
}

/// Reads values from a reader
pub fn Deserializer(comptime _endian: std.builtin.Endian, comptime _packing: Packing, comptime ReaderType: type) type {
    return struct {
        pub const endian: std.builtin.Endian = _endian;
        pub const packing: Packing = _packing;

        pub const UnderlyingReader: type = ReaderType;
        pub const ActiveReader: type = if (packing == .bit) io.BitReader(endian, UnderlyingReader) else UnderlyingReader;

        /// Signifies that the type is a valid deserializer
        pub const ValidDeserializer = Deserializer;

        in_stream: ActiveReader,

        const Self = @This();

        pub const ReadError: type = ActiveReader.Error;

        pub fn init(in_stream: UnderlyingReader) Self {
            return Self{
                .in_stream = switch (packing) {
                    .bit => io.bitReader(endian, in_stream),
                    .byte => in_stream,
                },
            };
        }

        pub fn alignToByte(self: *Self) void {
            if (packing == .byte) return;
            self.in_stream.alignToByte();
        }

        /// T should have a well defined memory layout and bit width
        fn deserializeInt(self: *Self, comptime Int: type) !Int {
            return switch (comptime packing) {
                .bit => bitio.bitReadInt(&self.in_stream, Int),
                .byte => bitio.byteReadInt(&self.in_stream, endian, Int),
            };
        }

        fn deserializeEnum(self: *Self, comptime Enum: type) !Enum {
            return switch (comptime packing) {
                .bit => bitio.bitReadEnum(&self.in_stream, Enum),
                .byte => bitio.byteReadEnum(&self.in_stream, endian, Enum),
            };
        }

        const DeserializeType = enum { pointer, value };

        inline fn fasterDeserializeType(comptime T: type) DeserializeType {
            return comptime if (usesCustomSerialize(T)) .value else switch (@typeInfo(T)) {
                .Null, .Void, .Undefined => .value,
                .Bool => .value,
                .Enum => |en| fasterDeserializeType(en.tag_type),
                .Optional => .value,
                else => if (@sizeOf(T) <= @sizeOf(usize)) .value else .pointer,
            };
        }

        /// Deserializes and returns data of the specified type from the stream
        /// Custom deserialization functions may allocate memory using the passed.
        ///
        /// Any allocated memory is owned by the caller, and
        /// it is assumed that normal usage of the data will deallocate
        /// the memory (eg, using value.deinit() on data structures).
        ///
        /// The 'ptr' argument is generic so that it can take in pointers to packed struct fields, etc
        pub fn allocatingDeserialize(self: *Self, comptime T: type, allocator: mem.Allocator) !T {
            if (comptime serializeTypeErrorMessage(T)) |err| {
                @compileError(err);
            } else if (comptime usesCustomSerialize(T)) {
                //custom deserializer: fn(deserializer: anytype) !T
                if (comptime meta.hasFn(T, custom_deserialize_fn_name)) {
                    return @field(T, custom_deserialize_fn_name)(self);
                }
                //custom allocating deserializer: fn(deserializer: anytype, allocator: std.mem.Allocator) !T
                else if (comptime meta.hasFn(T, custom_allocating_deserialize_fn_name)) {
                    return @field(T, custom_allocating_deserialize_fn_name)(self, allocator);
                } else {
                    unreachable;
                }
            } else return switch (comptime @typeInfo(T)) {
                .Undefined => @as(@TypeOf(undefined), undefined),
                .Void => void{},
                .Null => null,

                .Float, .Int => self.deserializeInt(T),
                .Bool => (try self.deserializeInt(u1)) != 0,

                .Enum => self.deserializeEnum(T),

                .Optional => |op| blk: {
                    const whether: bool = try self.deserializeInt(u1) == 1;
                    if (whether) {
                        break :blk try self.allocatingDeserialize(op.child, allocator);
                    } else {
                        break :blk null;
                    }
                },

                .Union => |un| blk: {
                    const TagType = un.tag_type.?;
                    break :blk switch (try self.deserialize(TagType)) {
                        inline else => |tag| @unionInit(T, @tagName(tag), try self.allocatingDeserialize(meta.TagPayload(T, tag), allocator)),
                    };
                },

                else => default: {
                    if (comptime intSerializable(T)) {
                        break :default self.deserializeInt(T);
                    } else {
                        var value: T = undefined;
                        try self.allocatingDeserializeInto(&value, allocator);
                        break :default value;
                    }
                },
            };
        }

        /// Deserializes and returns data of the specified type from the stream.
        ///
        /// Custom deserialization functions may allocate memory using the passed.
        ///
        /// Any allocated memory is owned by the caller, and
        /// it is assumed that normal usage of the data will deallocate
        /// the memory (eg, using value.deinit() on data structures)
        ///
        /// The 'ptr' argument is generic so that it can take in pointers to packed struct fields, etc
        pub fn allocatingDeserializeInto(self: *Self, ptr: anytype, allocator: mem.Allocator) !void {
            const original = ptr.*;
            errdefer ptr.* = original;

            const T: type = @TypeOf(original);

            const child_type_id: std.builtin.Type = @typeInfo(T);

            if (comptime serializeTypeErrorMessage(T)) |err| {
                @compileError(err);
            } else if (comptime usesCustomSerialize(T)) {
                //custom deserializer: fn(deserializer: anytype) !void
                if (comptime meta.hasFn(T, custom_deserialize_fn_name)) {
                    ptr.* = try self.deserialize(T);
                    return;
                }
                //custom allocating deserializer: fn(self: *Self, deserializer: anytype, allocator: std.mem.Allocator) !void
                else if (comptime meta.hasFn(T, custom_allocating_deserialize_fn_name)) {
                    ptr.* = try self.allocatingDeserialize(T, allocator);
                    return;
                } else {
                    unreachable;
                }
            } else switch (comptime child_type_id) {
                .Void, .Undefined, .Null, .Enum, .Bool, .Optional, .Float, .Int => ptr.* = try self.deserialize(T),
                .Struct => |info| inline for (info.fields) |field_info| {
                    switch (comptime fasterDeserializeType(@TypeOf(@field(ptr, field_info.name)))) {
                        .pointer => try self.allocatingDeserializeInto(&@field(ptr, field_info.name), allocator),
                        .value => @field(ptr, field_info.name) = try self.allocatingDeserialize(@TypeOf(@field(ptr, field_info.name)), allocator),
                    }
                },
                .Union => |info| switch (try self.allocatingDeserialize(info.tag_type.?, allocator)) {
                    inline else => |tag| {
                        switch (comptime fasterDeserializeType(meta.TagPayload(T, tag))) {
                            .pointer => {
                                ptr.* = @unionInit(T, @tagName(tag), undefined);
                                return self.allocatingDeserializeInto(&@field(ptr, @tagName(tag)), allocator);
                            },
                            .value => {
                                ptr.* = @unionInit(T, @tagName(tag), try self.allocatingDeserialize(meta.TagPayload(T, tag), allocator));
                            },
                        }
                    },
                },
                .Array => {
                    for (ptr) |*item| {
                        try self.allocatingDeserializeInto(item, allocator);
                    }
                },
                .Vector => |vec| {
                    for (0..vec.len) |i| {
                        if (comptime fasterDeserializeType(vec.child) == .pointer and @TypeOf(&ptr[i]) == *vec.child) {
                            try self.allocatingDeserializeInto(&ptr[i], allocator);
                        } else {
                            ptr[i] = try self.allocatingDeserialize(vec.child, allocator);
                        }
                    }
                },
                else => {
                    @compileError("Cannot deserialize " ++ @tagName(child_type_id) ++ " types.\nError in obtaining proper error message for serialization of this invalid type. Sorry :(");
                },
            }
        }

        /// Returns a deserialized value of type `T`.
        /// Guaranteed to never allocate memory.
        /// If deserialization of the requested type requires allocation,
        /// then a compiler error will be generated
        pub fn deserialize(self: *Self, comptime T: type) !T {
            return if (comptime deserializeNeedsAllocator(T))
                @compileError("Error: deserialization of type " ++ @typeName(T) ++ " requires an allocator")
            else
                self.allocatingDeserialize(T, undefined);
        }

        /// Deserializes data into the type pointed to by `ptr`.
        /// Guaranteed to never allocate memory.
        /// If deserialization of the requested type requires allocation,
        /// then a compiler error will be generated
        pub fn deserializeInto(self: *Self, ptr: anytype) !void {
            const T: type = @TypeOf(ptr);

            const C: type = @typeInfo(T).Pointer.child;

            return if (comptime deserializeNeedsAllocator(C))
                @compileError("Error: deserialization of type " ++ @typeName(C) ++ " requires an allocator")
            else
                self.allocatingDeserializeInto(ptr, undefined);
        }
    };
}

/// Create a `Derializer` from a `reader`, `packing`, and `endian`
pub fn deserializer(
    comptime endian: std.builtin.Endian,
    comptime packing: Packing,
    reader: anytype,
) Deserializer(endian, packing, @TypeOf(reader)) {
    return Deserializer(endian, packing, @TypeOf(reader)).init(reader);
}

/// Writes values to a writer
pub fn Serializer(comptime _endian: std.builtin.Endian, comptime _packing: Packing, comptime WriterType: type) type {
    return struct {
        pub const endian: std.builtin.Endian = _endian;
        pub const packing: Packing = _packing;

        pub const UnderlyingWriter: type = WriterType;
        pub const ActiveWriter: type = if (packing == .bit) io.BitWriter(endian, UnderlyingWriter) else UnderlyingWriter;

        /// Signifies that the type is a valid serializer
        pub const ValidSerializer = Serializer;

        writer: ActiveWriter,

        const Self = @This();
        pub const Error: type = UnderlyingWriter.Error;

        pub fn init(writer: UnderlyingWriter) Self {
            return Self{
                .writer = switch (packing) {
                    .bit => io.bitWriter(endian, writer),
                    .byte => writer,
                },
            };
        }

        /// Flushes any unwritten bits to the stream
        pub fn flush(self: *Self) Error!void {
            if (packing == .bit) return self.writer.flushBits();
        }

        fn serializeInt(self: *Self, comptime Int: type, value: Int) Error!void {
            if (comptime !portableLayout(Int))
                @compileError("Error: cannot use serializeInt on type " ++ @typeName(Int) ++ ", whose layout is not portable");

            return switch (comptime packing) {
                .bit => bitio.bitWriteInt(&self.writer, Int, value),
                .byte => bitio.byteWriteInt(&self.writer, endian, Int, value),
            };
        }

        fn serializeEnum(self: *Self, comptime Enum: type, tag: Enum) Error!void {
            if (comptime @typeInfo(Enum) != .Enum)
                @compileError("Error: cannot use serializeEnum on type " ++ @typeName(Enum) ++ ", which is not an enum");

            return switch (comptime packing) {
                .bit => bitio.bitWriteEnum(&self.writer, Enum, tag),
                .byte => bitio.byteWriteEnum(&self.writer, endian, Enum, tag),
            };
        }

        /// Serializes the passed value into the stream
        pub fn serialize(self: *Self, comptime T: type, value: T) Error!void {
            if (comptime serializeTypeErrorMessage(T)) |err| {
                @compileError(err);
            } else if (comptime usesCustomSerialize(T)) {
                return @field(T, custom_serialize_fn_name)(value, self);
            } else switch (@typeInfo(T)) {
                .Void, .Undefined, .Null => return void{},
                .Bool => return try self.serializeInt(u1, @intFromBool(value)),
                .Float, .Int => return try self.serializeInt(T, value),
                .Struct => |info| {
                    if (comptime intSerializable(T)) {
                        try self.serializeInt(T, value);
                    } else inline for (info.fields) |field_info| {
                        const name: [:0]const u8 = field_info.name;
                        const FieldType: type = field_info.type;
                        try self.serialize(FieldType, @field(value, name));
                    }
                },
                .Union => |info| {
                    if (info.tag_type) |TagType| {
                        if (!@typeInfo(TagType).Enum.is_exhaustive)
                            @compileError("TODO: support serialization/deserialization of unions tagged by non-exhaustive enums");

                        switch (value) {
                            inline else => |field| {
                                const FieldType: type = @TypeOf(field);
                                const tag: TagType = value;
                                try self.serialize(TagType, tag);
                                return self.serialize(FieldType, field);
                            },
                        }
                    } else {
                        // handled by compiler error for untagged unions
                        comptime unreachable;
                    }
                },
                .Optional => |op| {
                    const is_some: bool = value != null;
                    try self.serializeInt(u1, @intFromBool(is_some));
                    if (is_some) try self.serialize(op.child, value.?);
                },
                .Enum => try self.serializeEnum(T, value),
                .Array => |arr| {
                    for (value) |item|
                        try self.serialize(arr.child, item);
                },
                .Vector => |vec| {
                    for (0..vec.len) |i|
                        try self.serialize(vec.child, value[i]);
                },
                else => {
                    @compileError("Cannot serialize " ++ @tagName(@typeInfo(T)) ++ " types.\nError in obtaining proper error message for serialization of this invalid type. Sorry :(");
                },
            }
        }
    };
}

/// Whether type `T` is a serializer interface
pub fn isSerializer(comptime T: type) bool {
    if (@typeInfo(T) == .Pointer) {
        if (@typeInfo(T).Pointer.size != .One) {
            return false;
        } else {
            return isSerializer(@typeInfo(T).Pointer.child);
        }
    } else {
        return comptime @hasDecl(T, "ValidSerializer") and T.ValidSerializer == Serializer;
    }
}

/// Whether type `T` is a deserializer interface
pub fn isDeserializer(comptime T: type) bool {
    if (@typeInfo(T) == .Pointer) {
        if (@typeInfo(T).Pointer.size != .One) {
            return false;
        } else {
            return comptime isDeserializer(@typeInfo(T).Pointer.child);
        }
    } else {
        return comptime @hasDecl(T, "ValidDeserializer") and T.ValidDeserializer == Deserializer;
    }
}

/// At comptime, assert that type `T` is a `Serializer` type
pub inline fn assertSerializerType(comptime T: type) void {
    if (comptime !isSerializer(T))
        @compileError("Error: type " ++ @typeName(T) ++ " is not a serializer");
}
/// At comptime, assert that type `T` is a `Deserializer` type
pub inline fn assertDeserializerType(comptime T: type) void {
    if (comptime !isDeserializer(T))
        @compileError("Error: type " ++ @typeName(T) ++ " is not a deserializer");
}
/// At comptime, assert that the given value is a `Serializer`
pub fn assertSerializer(_serializer: anytype) void {
    const T = @TypeOf(_serializer);
    comptime assertSerializerType(T);
}
/// At comptime, assert that the given value is a `Deserializer`
pub fn assertDeserializer(_deserializer: anytype) void {
    const T = @TypeOf(_deserializer);
    comptime assertDeserializerType(T);
}

/// Create a `Serializer` from a `writer`, `packing`, and `endian`
pub fn serializer(
    comptime endian: std.builtin.Endian,
    comptime packing: Packing,
    writer: anytype,
) Serializer(endian, packing, @TypeOf(writer)) {
    return Serializer(endian, packing, @TypeOf(writer)).init(writer);
}

/// Test whether a value can be serialized and deserialized back into the original value, with options for endian and packing.
/// `expectEqlFn` should be a function type of signature `fn (a: T, b: T) !void` which returns an error if `a != b`.
/// In general, it is advised to just pass in `std.testing.expectEqual` here.
fn testSerializableDeserializableExtra(comptime endian: std.builtin.Endian, comptime packing: Packing, comptime T: type, x: T, allocator: mem.Allocator, expectEqlFn: anytype) !void {
    // we use this as a buffer to write our serialized data to
    var serialized_data = std.ArrayList(u8).init(testing.allocator);
    defer serialized_data.deinit();

    const writer = serialized_data.writer();
    var _serializer = serializer(endian, packing, writer);

    try _serializer.serialize(T, x);
    try _serializer.flush();

    // since we dont know the type, we dont know hoe to properly deallocate any memory we may have allocated
    // in fact, we dont even know if we allocate memory at all.
    // so we use an arena which should cover any memory leaks
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_alloc = arena.allocator();

    var stream = io.StreamSource{ .buffer = io.fixedBufferStream(serialized_data.items) };
    const reader = stream.reader();

    var _deserializer = deserializer(endian, packing, reader);

    const y: T = try _deserializer.allocatingDeserialize(T, arena_alloc);

    try expectEqlFn(x, y);
}

/// For use in test blocks.
/// Test whether a value can be serialized and deserialized back into the original value.
/// `expectEqlFn` should be a function type of signature `fn (a: T, b: T) !void` which returns an error if `a != b`.
/// In general, it is advised to just pass in `std.testing.expectEqual` here.
pub fn testSerializable(comptime T: type, x: T, allocator: mem.Allocator, testEqualFn: anytype) !void {
    try testSerializableDeserializableExtra(.little, .bit, T, x, allocator, testEqualFn);
    try testSerializableDeserializableExtra(.little, .bit, T, x, allocator, testEqualFn);
    try testSerializableDeserializableExtra(.big, .byte, T, x, allocator, testEqualFn);
    try testSerializableDeserializableExtra(.big, .byte, T, x, allocator, testEqualFn);
}

/// Test basic functionality of serializing integers
fn testIntSerializerDeserializer(comptime endian: std.builtin.Endian, comptime packing: Packing) !void {
    const max_test_bitsize: comptime_int = 128;

    @setEvalBranchQuota(max_test_bitsize * 10);

    const total_bytes: comptime_int = comptime blk: {
        var bytes: comptime_int = 0;
        var i: comptime_int = 0;
        while (i <= max_test_bitsize) : (i += 1) bytes += (i / 8) + @as(comptime_int, @intFromBool(i % 8 > 0));
        break :blk bytes * 2;
    };

    var data_mem: [total_bytes]u8 = undefined;
    var out = io.fixedBufferStream(&data_mem);
    var _serializer = serializer(endian, packing, out.writer());

    var in = io.fixedBufferStream(&data_mem);
    var _deserializer = deserializer(endian, packing, in.reader());

    comptime var i: comptime_int = 0;
    inline while (i <= max_test_bitsize) : (i += 1) {
        const U: type = meta.Int(.unsigned, i);
        const S: type = meta.Int(.signed, i);
        try _serializer.serializeInt(U, i);
        if (i != 0) try _serializer.serializeInt(S, -1) else try _serializer.serialize(S, 0);
    }
    try _serializer.flush();

    i = 0;
    inline while (i <= max_test_bitsize) : (i += 1) {
        const U: type = meta.Int(.unsigned, i);
        const S: type = meta.Int(.signed, i);
        const x: U = try _deserializer.deserializeInt(U);
        const y: S = try _deserializer.deserializeInt(S);
        try testing.expectEqual(x, @as(U, i));
        if (i != 0) {
            try testing.expectEqual(y, @as(S, -1));
        } else {
            try testing.expectEqual(y, 0);
        }
    }

    //0 + 1 + 2 + ... n = (n * (n + 1)) / 2
    //and we have each for unsigned and signed, so * 2
    const total_bits: comptime_int = (max_test_bitsize * (max_test_bitsize + 1));
    const extra_packed_byte: comptime_int = @intFromBool(total_bits % 8 > 0);
    const total_packed_bytes: comptime_int = (total_bits / 8) + extra_packed_byte;

    try testing.expectEqual(in.pos, if (packing == .bit) total_packed_bytes else total_bytes);

    //Verify that empty error set works with serializer.
    //deserializer is covered by FixedBufferStream
    var null_serializer = serializer(endian, packing, io.null_writer);
    try null_serializer.serialize(@TypeOf(data_mem), data_mem);
    try null_serializer.flush();
}

test "Serializer/Deserializer Int" {
    try testIntSerializerDeserializer(.big, .byte);
    try testIntSerializerDeserializer(.little, .byte);
    try testIntSerializerDeserializer(.big, .bit);
    try testIntSerializerDeserializer(.little, .bit);
}

/// Test basic functionality of serializing floats
fn testIntSerializerDeserializerInfNaN(
    comptime endian: std.builtin.Endian,
    comptime packing: Packing,
) !void {
    var data = std.ArrayList(u8).init(testing.allocator);
    defer data.deinit();

    var _serializer = serializer(endian, packing, data.writer());

    try _serializer.serialize(f16, math.nan(f16));
    try _serializer.serialize(f16, math.inf(f16));
    try _serializer.serialize(f32, math.nan(f32));
    try _serializer.serialize(f32, math.inf(f32));
    try _serializer.serialize(f64, math.nan(f64));
    try _serializer.serialize(f64, math.inf(f64));
    try _serializer.serialize(f128, math.nan(f128));
    try _serializer.serialize(f128, math.inf(f128));
    try _serializer.serialize(f80, math.nan(f80));
    try _serializer.serialize(f80, math.inf(f80));

    try _serializer.flush();

    var buffer = io.fixedBufferStream(data.items);

    var _deserializer = deserializer(endian, packing, buffer.reader());

    const nan_check_f16: f16 = try _deserializer.deserialize(f16);
    const inf_check_f16: f16 = try _deserializer.deserialize(f16);
    const nan_check_f32: f32 = try _deserializer.deserialize(f32);
    const inf_check_f32: f32 = try _deserializer.deserialize(f32);
    const nan_check_f64: f64 = try _deserializer.deserialize(f64);
    const inf_check_f64: f64 = try _deserializer.deserialize(f64);
    const nan_check_f128: f128 = try _deserializer.deserialize(f128);
    const inf_check_f128: f128 = try _deserializer.deserialize(f128);
    const nan_check_f80: f80 = try _deserializer.deserialize(f80);
    const inf_check_f80: f80 = try _deserializer.deserialize(f80);

    try testing.expect(math.isNan(nan_check_f16));
    try testing.expect(math.isInf(inf_check_f16));
    try testing.expect(math.isNan(nan_check_f32));
    try testing.expect(math.isInf(inf_check_f32));
    try testing.expect(math.isNan(nan_check_f64));
    try testing.expect(math.isInf(inf_check_f64));
    try testing.expect(math.isNan(nan_check_f128));
    try testing.expect(math.isInf(inf_check_f128));
    try testing.expect(math.isNan(nan_check_f80));
    try testing.expect(math.isInf(inf_check_f80));
}

test "Serializer/Deserializer Int: Inf/NaN" {
    try testIntSerializerDeserializerInfNaN(.big, .byte);
    try testIntSerializerDeserializerInfNaN(.little, .byte);
    try testIntSerializerDeserializerInfNaN(.big, .bit);
    try testIntSerializerDeserializerInfNaN(.little, .bit);
}

test "Serializer/Deserializer generic" {
    const ColorType = enum(u4) {
        RGB8 = 1,
        RA16 = 2,
        R32 = 3,
    };

    const TagAlign = union(enum(u32)) {
        A: u8,
        B: u8,
        C: u8,
    };

    const Color = union(ColorType) {
        RGB8: struct {
            r: u8,
            g: u8,
            b: u8,
            a: u8,
        },
        RA16: struct {
            r: u16,
            a: u16,
        },
        R32: u32,
    };

    const PackedStruct = packed struct {
        f_i3: i3,
        f_u2: u2,
    };

    //to test custom serialization
    const Custom = struct {
        const Self = @This();

        f_f16: f16,
        f_unused_u32: u32,

        fn deserialize(_deserializer: anytype) !Self {
            assertDeserializer(_deserializer);
            return Self{ .f_f16 = try _deserializer.deserialize(f16), .f_unused_u32 = 47 };
        }

        fn serialize(self: Self, _serializer: anytype) !void {
            assertSerializer(_serializer);
            try _serializer.serialize(@TypeOf(self.f_f16), self.f_f16);
        }
    };

    const MyStruct = struct {
        f_i3: i3,
        f_u8: u8,
        f_tag_align: TagAlign,
        f_u24: u24,
        f_i19: i19,
        f_void: void,
        f_f32: f32,
        f_f128: ?f128,
        f_packed_0: PackedStruct,
        f_i7arr: [10]i7,
        f_u16vec: @Vector(4, u16),
        f_of64n: ?f64,
        f_of64v: ?f64,
        f_opt_color_null: ?ColorType,
        f_opt_color_value: ?ColorType,
        f_packed_1: PackedStruct,
        f_custom: Custom,
        f_opt_custom_null: ?Custom,
        f_opt_custom_value: ?Custom,
        f_color: Color,
    };

    const my_inst = MyStruct{
        .f_i3 = -1,
        .f_u8 = 8,
        .f_tag_align = TagAlign{ .B = 148 },
        .f_u24 = 24,
        .f_i19 = 19,
        .f_void = void{},
        .f_f32 = 32.32,
        .f_f128 = 128.128,
        .f_packed_0 = PackedStruct{ .f_i3 = -1, .f_u2 = 2 },
        .f_i7arr = [10]i7{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 },
        .f_u16vec = @Vector(4, u16){ 10, 11, 12, 13 },
        .f_of64n = null,
        .f_of64v = 64.64,
        .f_opt_color_null = null,
        .f_opt_color_value = ColorType.R32,
        .f_packed_1 = PackedStruct{ .f_i3 = 1, .f_u2 = 1 },
        .f_custom = Custom{ .f_f16 = 38.63, .f_unused_u32 = 47 },
        .f_opt_custom_null = null,
        .f_opt_custom_value = Custom{ .f_f16 = 12.34, .f_unused_u32 = 47 },
        .f_color = Color{ .R32 = 123822 },
    };

    try testSerializable(MyStruct, my_inst, testing.allocator, testing.expectEqualDeep);
}

/// Expect failure for serializing invalid enums
fn testBadData(comptime endian: std.builtin.Endian, comptime packing: Packing) !void {
    const E = enum(u14) {
        One = 1,
        Two = 2,
    };

    const A = struct {
        e: E,
    };

    const C = union(E) {
        One: u14,
        Two: f16,
    };

    var data_mem: [4]u8 = undefined;
    var out = io.fixedBufferStream(&data_mem);
    var _serializer = serializer(endian, packing, out.writer());

    var in = io.fixedBufferStream(&data_mem);
    var _deserializer = deserializer(endian, packing, in.reader());

    try _serializer.serialize(u14, 3);
    try _serializer.flush();
    try testing.expectError(error.Corrupt, _deserializer.deserialize(A));
    out.pos = 0;
    try _serializer.serialize(u14, 3);
    try _serializer.serialize(u14, 88);
    try _serializer.flush();
    try testing.expectError(error.Corrupt, _deserializer.deserialize(C));
}

test "Deserializer bad data" {
    try testBadData(.big, .byte);
    try testBadData(.little, .byte);
    try testBadData(.big, .bit);
    try testBadData(.little, .bit);
}

test {
    testing.refAllDeclsRecursive(@This());
}
