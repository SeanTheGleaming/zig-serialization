//! Library for serialization and deserialization
//! To add custom support for your own types, add the following:
//! 1. A serialization function matching this signature
//!    - `pub fn serialize(self: @This(), serializer: anytype) !void`
//! 2. A deserialization function matching one of the following signatures:
//!    - `pub fn deserialize(deserializer: anytype) !@This()`
//!    - `pub fn allocatingDeserialize(deserializer: anytype, allocator: std.mem.Allocator) !@This()`
//! As an alternative to the above two, you can use pre made serialization mode
//!    -  All of the pre made modes are in `SerializationMode`
//!    -  To use a pre made serialization mode, add a declaration like this to your type:
//!       - `pub const serialize_mode: SerializationMode = ...`

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

// Warning: if you change any of the below,
// you also must change all the test cases to match it
const custom_serialize_fn_name = "serialize";
const custom_deserialize_fn_name = "deserialize";
const custom_allocating_deserialize_fn_name = "allocatingDeserialize";
const custom_mode_decl_name = "serialization_mode";

/// These are pre made modes to add to your custom types to quickly define how to serialize data without boilerplate.
/// To use, just add a "serialization_mde"
pub const SerializationMode = enum {
    /// Either automatically handle serialization or use custom serialization methods.
    none,

    /// Ignore the declarations of custom serialization methods and automatically handle serialization.
    ignore_custom,

    /// By default, packed unions cannot be serialized without custom methods.
    /// You can use this mode to override that and automatically `@bitCast` your union to/from an integer.
    packed_union,

    /// Use this when you do not want to include something in serialization.
    /// When serializing, it will skip over this data.
    /// When deserializing, it will return an undefined value.
    /// Useful for cases like padding fields.
    noop,

    /// Causes a compile error upon attempting to serialize/deserialize
    unserializable,

    /// Get the serialization mode of a type
    inline fn get(comptime T: type) SerializationMode {
        switch (@typeInfo(T)) {
            .Struct, .Union, .Enum => {
                if (@hasDecl(T, custom_mode_decl_name)) {
                    return switch (@TypeOf(@field(T, custom_mode_decl_name))) {
                        SerializationMode,
                        @TypeOf(.EnumLiteral),
                        => @field(T, custom_mode_decl_name),
                        else => .none,
                    };
                } else {
                    return .none;
                }
            },
            else => return .none,
        }
    }
};

test SerializationMode {
    const IEEE = packed union {
        // use the .packed_union serialization mode
        const serialization_mode = .packed_union;

        fields: packed struct {
            mantissa: u23,
            exponent: u8,
            sign: bool,
        },
        float: f32,
        int: u32,

        fn expectEqual(self: @This(), other: @This()) !void {
            try std.testing.expectEqual(self.int, other.int);
            if (!std.math.isNan(self.float))
                try std.testing.expectEqual(self.float, other.float);
        }
    };

    const ieee_values = [_]IEEE{
        .{ .int = 7 },
        .{ .int = 0 },
        .{ .int = 0x5f3759df },
        .{ .int = math.maxInt(u32) },

        .{ .float = 0.0 },
        .{ .float = 123.456 },
        .{ .float = math.inf(f32) },
        .{ .float = math.floatMin(f32) },
        .{ .float = math.floatMax(f32) },

        .{ .fields = .{
            .sign = false,
            .exponent = 0xFF,
            .mantissa = 0,
        } },
    };

    for (ieee_values) |ieee| {
        try testSerializable(IEEE, ieee, testing.allocator, IEEE.expectEqual);
    }
}

/// Whether a type uses custom serialization functions
inline fn usesCustomSerialize(comptime T: type) bool {
    return switch (SerializationMode.get(T)) {
        .none => (meta.hasFn(T, custom_allocating_deserialize_fn_name) or meta.hasFn(T, custom_deserialize_fn_name)) and meta.hasFn(T, custom_serialize_fn_name),
        .noop => true,
        .ignore_custom, .packed_union => false,
        .unserializable => false,
    };
}

/// Whether custom serialization functions are used anywhere in the structure of a type
inline fn containsCustomSerialize(comptime T: type) bool {
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

/// Whether a type uses serialization compatible with being @bitCasted from a packed struct field
inline fn usesNonIntSerialize(comptime T: type) bool {
    return switch (SerializationMode.get(T)) {
        .none => (meta.hasFn(T, custom_allocating_deserialize_fn_name) or meta.hasFn(T, custom_deserialize_fn_name)) and meta.hasFn(T, custom_serialize_fn_name),
        .noop => true,
        .ignore_custom, .packed_union => false,
        .unserializable => false,
    };
}

/// Whether a type can be
inline fn containsNonIntSerialize(comptime T: type) bool {
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
inline fn serializeErrorFields(comptime T: type, comptime name: []const u8, comptime prev: []const []const u8) ?SerializationErrorInfo {
    switch (SerializationMode.get(T)) {
        .unserializable => return .{
            .problem = T,
            .fields = prev ++ &[1][]const u8{name},
            .info = "Custom type specifies that it is unserializable",
        },
        .packed_union => switch (@typeInfo(T)) {
            .Union => |info| {
                if (info.layout != .@"packed") {
                    return .{
                        .problem = T,
                        .fields = prev ++ &[1][]const u8{name},
                        .info = "Serialization mode `.packed_union` used on an unpacked union",
                    };
                } else {
                    return null;
                }
            },
            else => return .{
                .problem = T,
                .fields = prev ++ &[1][]const u8{name},
                .info = "Serialization mode `.packed_union` used on non packed-union",
            },
        },
        .none, .ignore_custom, .noop => {},
    }

    switch (@typeInfo(T)) {
        .Struct => |info| {
            if (usesCustomSerialize(T)) return null;
            inline for (info.fields) |field| {
                if (serializeErrorFields(field.type, field.name, prev ++ &[1][]const u8{name})) |err| {
                    return err;
                }
            }
            return null;
        },

        .Union => |info| {
            if (usesCustomSerialize(T)) return null;
            if (info.tag_type) |_| {
                if (info.fields.len == 0) return .{
                    .problem = T,
                    .fields = prev ++ &[1][]const u8{name},
                    .info = "Zero field unions cannot be serialized",
                };

                inline for (info.fields) |field| {
                    if (serializeErrorFields(field.type, field.name, prev ++ &[1][]const u8{name})) |err| {
                        return err;
                    }
                }

                return null;
            } else if (info.layout == .@"packed") return .{
                .problem = T,
                .fields = prev ++ &[1][]const u8{name},
                .info = "Packed unions cannot be serialized without serialization mode `.packed_union` or custom serialization/deserialization methods",
            } else return .{
                .problem = T,
                .fields = prev ++ &[1][]const u8{name},
                .info = "Untagged unions cannot be serialized without custom serialize/deserialize methods",
            };
        },
        .Enum => |info| {
            if (usesCustomSerialize(T)) return null;

            if (info.is_exhaustive and info.fields.len == 0) return .{
                .problem = T,
                .fields = prev ++ &[1][]const u8{name},
                .info = "Zero field enums cannot be serialized",
            };

            return null;
        },

        .Optional => |info| return serializeErrorFields(info.child, "?", prev ++ &[1][]const u8{name}),
        inline .Array, .Vector => |info| return if (info.len == 0) null else serializeErrorFields(info.child, name ++ "[...]", prev),

        .Int, .Float, .Bool, .Void, .Undefined, .Null => return null,

        else => return .{ .problem = T, .fields = prev ++ &[1][]const u8{name}, .info = switch (@typeInfo(T)) {
            .Pointer => "Pointers cannot be serialized. Consider using custom serialize/deserialize methods",
            .ErrorUnion => "Error unions cannot be serialized, did you mean to use a 'try' statement?",
            .ErrorSet => "Error sets cannot be serialized",
            .Fn => "Functions cannot be serialized",
            .Type => "Types cannot be serialized",
            .Frame, .AnyFrame => "Frames cannot be serialized",
            .EnumLiteral => "Enum literals cannot be serialized",
            else => null,
        } },
    }
}

/// The error message for trying to serialize/deserialize a type, if that type is not serializable/deserializable
pub inline fn serializeTypeErrorMessage(comptime T: type) ?[]const u8 {
    const opfields = serializeErrorFields(T, @typeName(T), &.{});
    if (opfields) |errfields| {
        const nav = comptime blk: {
            var field_nav_str: []const u8 = "";
            for (errfields.fields) |errmsg| {
                field_nav_str = field_nav_str ++ "." ++ errmsg;
            }
            break :blk field_nav_str[1..];
        };

        return std.fmt.comptimePrint(
            \\Error with serialization of type {}
            \\Cannot meaningfully serialize {s} type of {s}
            \\{s}
        , .{ errfields.problem, @tagName(@typeInfo(errfields.problem)), nav, errfields.info orelse "Unimplemented and/or Unplanned" });
    } else {
        return null;
    }
}

/// Whether type `T` is able to be serialized/deserialized
pub inline fn canSerialize(comptime T: type) bool {
    return serializeTypeErrorMessage(T) == null;
}

/// Whether an allocator is required for deserializtion of type `T`
pub inline fn deserializeNeedsAllocator(comptime T: type) bool {
    return if (!canSerialize(T)) false else switch (@typeInfo(T)) {
        .Struct => blk: {
            const fields = meta.fields(T);
            inline for (fields) |field| {
                if (deserializeNeedsAllocator(field.type)) break :blk true;
            }
            break :blk false;
        },
        .Union => |Union| blk: {
            if (Union.tag_type) |Tag| {
                if (deserializeNeedsAllocator(Tag)) break :blk true;
            }
            const fields = meta.fields(T);
            inline for (fields) |field| {
                if (deserializeNeedsAllocator(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => usesCustomSerialize(T) and meta.hasFn(T, custom_allocating_deserialize_fn_name),
    };
}

inline fn integerLayout(comptime T: type) bool {
    return bitio.noData(T) or switch (@typeInfo(T)) {
        .Int, .Float, .Void, .Null, .Undefined => true,
        .Vector => |info| integerLayout(info.child),
        .Struct => |info| info.layout == .@"packed",
        .Union => |info| info.layout == .@"packed",
        else => false,
    };
}

inline fn byteLayout(comptime T: type, comptime endian: std.builtin.Endian, comptime packing: Packing) bool {
    const native_endian = @import("builtin").cpu.arch.endian();
    const is_native = endian == native_endian;
    const is_integral = integerLayout(T);
    const matches_packing = switch (packing) {
        .bit => @typeInfo(T) == .Vector and @divFloor(@bitSizeOf(T), 8) == @sizeOf(T),
        .byte => @divFloor(@bitSizeOf(T), 8) == @sizeOf(T),
    };
    if (is_native and matches_packing and is_integral) return true;
    return switch (@typeInfo(T)) {
        .Array => |info| blk: {
            const child_integral = integerLayout(info.child);
            const child_byte = byteLayout(info.child, endian, packing);
            if (@bitSizeOf(info.child) == 8 and (child_byte or child_integral)) break :blk true;
            const child_byte_aligned = @mod(@bitSizeOf(info.child), 8) == 0;
            break :blk child_byte_aligned and (is_native != child_integral);
        },
        else => false,
    };
}

/// Whether it is correct to serialize/deserialize type `T` by `@bitCast`ing to/from integers
inline fn intSerializable(comptime T: type) bool {
    return comptime integerLayout(T) and !containsNonIntSerialize(T);
}

/// Whether it is correct to serialize/deserialize type `T` by `@bitCast`ing to/from bytes
inline fn byteSerializable(comptime T: type, comptime endian: std.builtin.Endian, comptime packing: Packing) bool {
    return comptime byteLayout(T, endian, packing) and !containsNonIntSerialize(T);
}

/// Reads values from a reader
pub fn Deserializer(comptime endianness: std.builtin.Endian, comptime packing_mode: Packing, comptime ReaderType: type) type {
    return struct {
        pub const endian: std.builtin.Endian = endianness;
        pub const packing: Packing = packing_mode;

        pub const UnderlyingReader = ReaderType;
        pub const ActiveReader = if (packing == .bit) io.BitReader(endian, UnderlyingReader) else UnderlyingReader;
        pub const ReadError = ActiveReader.Error;

        /// Signifies that the type is a valid deserializer
        pub const ValidDeserializer = Deserializer;

        reader: ActiveReader,

        const Self = @This();

        pub fn init(reader: UnderlyingReader) Self {
            return Self{
                .reader = switch (packing) {
                    .bit => io.bitReader(endian, reader),
                    .byte => reader,
                },
            };
        }

        pub fn alignToByte(self: *Self) void {
            if (packing == .byte) return;
            self.reader.alignToByte();
        }

        /// T should have a well defined memory layout and bit width
        fn deserializeInt(self: *Self, comptime Int: type) !Int {
            return switch (comptime packing) {
                .bit => bitio.bitReadInt(&self.reader, Int),
                .byte => bitio.byteReadInt(&self.reader, endian, Int),
            };
        }

        fn deserializeEnum(self: *Self, comptime Enum: type) !Enum {
            return switch (comptime packing) {
                .bit => bitio.bitReadEnum(&self.reader, Enum),
                .byte => bitio.byteReadEnum(&self.reader, endian, Enum),
            };
        }

        const DeserializeType = enum { pointer, value };

        inline fn fasterDeserializeType(comptime T: type) DeserializeType {
            if (usesNonIntSerialize(T)) return .value;
            if (byteSerializable(T, endian, packing)) return .pointer;
            return switch (@typeInfo(T)) {
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
            defer self.alignToByte();
            if (serializeTypeErrorMessage(T)) |err| {
                @compileError(err);
            }
            if (usesCustomSerialize(T)) {
                //custom deserializer: fn(deserializer: anytype) !T
                if (meta.hasFn(T, custom_deserialize_fn_name)) {
                    return @field(T, custom_deserialize_fn_name)(self);
                }
                //custom allocating deserializer: fn(deserializer: anytype, allocator: std.mem.Allocator) !T
                else if (meta.hasFn(T, custom_allocating_deserialize_fn_name)) {
                    return @field(T, custom_allocating_deserialize_fn_name)(self, allocator);
                } else {
                    comptime unreachable;
                }
            }

            switch (SerializationMode.get(T)) {
                .none, .ignore_custom => {},
                .unserializable => comptime unreachable,
                .packed_union => return @bitCast(try self.deserializeInt(@Type(.{
                    .Int = .{
                        .signedness = .unsigned,
                        .bits = @bitSizeOf(T),
                    },
                }))),
                .noop => return @as(T, undefined),
            }

            if (byteSerializable(T, endian, packing)) raw_read: {
                const reader = switch (packing) {
                    .bit => blk: {
                        if (self.reader.bit_count != 0) break :raw_read;
                        break :blk self.reader.reader();
                    },
                    .byte => self.reader,
                };
                const result = blk: {
                    var buf: T = undefined;
                    reader.readNoEof(std.mem.asBytes(&buf)) catch |err| switch (err) {
                        error.EndOfStream => return error.Corrupt,
                        else => return err,
                    };
                    break :blk buf;
                };
                return result;
            }

            if (intSerializable(T)) {
                return self.deserializeInt(T);
            } else return switch (@typeInfo(T)) {
                .Undefined => @as(@TypeOf(undefined), undefined),
                .Void => void{},
                .Null => null,

                .Float, .Int => comptime unreachable, // already handled with deserializeInt
                .Bool => (try self.deserializeInt(u1)) != 0,

                .Enum => self.deserializeEnum(T),

                .Optional => |info| blk: {
                    const whether: bool = try self.deserializeInt(u1) == 1;
                    if (whether) {
                        break :blk try self.allocatingDeserialize(info.child, allocator);
                    } else {
                        break :blk null;
                    }
                },

                .Union => |info| blk: {
                    const Tag: type = info.tag_type.?;
                    const tag: Tag = try self.deserialize(Tag);
                    if (comptime @typeInfo(Tag).Enum.is_exhaustive) {
                        switch (tag) {
                            inline else => |field| {
                                const Payload: type = @TypeOf(@field(@as(T, undefined), @tagName(field)));
                                switch (comptime fasterDeserializeType(Payload)) {
                                    .pointer => {
                                        var with_tag = @unionInit(T, @tagName(field), undefined);
                                        try self.allocatingDeserializeInto(&@field(with_tag, @tagName(field)), allocator);
                                        break :blk with_tag;
                                    },
                                    .value => {
                                        break :blk @unionInit(
                                            T,
                                            @tagName(field),
                                            try self.allocatingDeserialize(
                                                Payload,
                                                allocator,
                                            ),
                                        );
                                    },
                                }
                            },
                        }
                    } else {
                        inline for (info.fields) |field| {
                            const field_tag = @field(Tag, field.name);
                            const Payload = @TypeOf(@field(@as(T, undefined), field.name));
                            if (field_tag == tag) {
                                switch (comptime fasterDeserializeType(Payload)) {
                                    .pointer => {
                                        var with_tag = @unionInit(T, field.name, undefined);
                                        try self.allocatingDeserializeInto(&@field(with_tag, field.name), allocator);
                                        break :blk with_tag;
                                    },
                                    .value => {
                                        break :blk @unionInit(
                                            T,
                                            field.name,
                                            try self.allocatingDeserialize(
                                                Payload,
                                                allocator,
                                            ),
                                        );
                                    },
                                }
                            }
                        }
                        // unnamed tag value
                        return error.Corrupt;
                    }
                },

                else => default: {
                    var value: T = undefined;
                    try self.allocatingDeserializeInto(&value, allocator);
                    break :default value;
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
            defer self.alignToByte();
            const Ptr = @TypeOf(ptr);
            const ptr_info = @typeInfo(@TypeOf(ptr));

            const T: type = switch (ptr_info) {
                .Pointer => |p| blk: {
                    switch (p.size) {
                        .One, .C => {},
                        else => @compileError("A multi item pointer has been passed into deserializeInto"),
                    }
                    if (p.is_const)
                        @compileError("A const pointer has been passed into deserializeInto");
                    break :blk p.child;
                },
                else => |non_pointer| {
                    const msg = "`" ++ @tagName(non_pointer) ++ " type `" ++ @typeName(Ptr) ++ "` has been passed into deserializeInto";
                    @compileError(msg);
                },
            };

            if (serializeTypeErrorMessage(T)) |err| {
                @compileError(err);
            } else if (usesCustomSerialize(T)) {
                //custom deserializer: fn(deserializer: anytype) !void
                if (meta.hasFn(T, custom_deserialize_fn_name)) {
                    ptr.* = try self.deserialize(T);
                    return;
                }
                //custom allocating deserializer: fn(self: *Self, deserializer: anytype, allocator: std.mem.Allocator) !void
                else if (meta.hasFn(T, custom_allocating_deserialize_fn_name)) {
                    ptr.* = try self.allocatingDeserialize(T, allocator);
                    return;
                } else {
                    comptime unreachable;
                }
            }

            switch (SerializationMode.get(T)) {
                .none, .ignore_custom => {},
                .unserializable => comptime unreachable,
                .packed_union => {
                    ptr.* = @bitCast(try self.deserializeInt(@Type(.{
                        .Int = .{
                            .signedness = .unsigned,
                            .bits = @bitSizeOf(T),
                        },
                    })));
                    return;
                },
                .noop => return,
            }

            if (byteSerializable(T, endian, packing)) raw_read: {
                const reader = switch (packing) {
                    .bit => blk: {
                        if (self.reader.bit_count != 0) break :raw_read;
                        break :blk self.reader.reader();
                    },
                    .byte => self.reader,
                };
                return reader.readNoEof(std.mem.asBytes(ptr)) catch |err| {
                    if (err == error.EndOfStream) {
                        return error.Corrupt;
                    } else {
                        return err;
                    }
                };
            }

            switch (@typeInfo(T)) {
                .Float, .Int => ptr.* = try self.deserializeInt(T), // handled with the intSerializable(T) check
                .Void, .Undefined, .Null, .Enum, .Bool, .Optional => ptr.* = try self.deserialize(T),
                .Struct => |info| inline for (info.fields) |field_info| {
                    switch (fasterDeserializeType(@TypeOf(@field(ptr, field_info.name)))) {
                        .pointer => try self.allocatingDeserializeInto(&@field(ptr, field_info.name), allocator),
                        .value => @field(ptr, field_info.name) = try self.allocatingDeserialize(@TypeOf(@field(ptr, field_info.name)), allocator),
                    }
                },
                .Union => |info| {
                    const Tag: type = info.tag_type.?;
                    const tag: Tag = try self.deserialize(Tag);
                    if (@typeInfo(Tag).Enum.is_exhaustive) {
                        switch (tag) {
                            inline else => |field| {
                                switch (fasterDeserializeType(@TypeOf(@field(ptr, @tagName(field))))) {
                                    .pointer => {
                                        ptr.* = @unionInit(T, @tagName(field), undefined);
                                        self.allocatingDeserializeInto(&@field(ptr, @tagName(field)), allocator);
                                    },
                                    .value => {
                                        ptr.* = @unionInit(T, @tagName(tag), try self.allocatingDeserialize(@TypeOf(@field(ptr, @tagName(field))), allocator));
                                    },
                                }
                            },
                        }
                    } else {
                        inline for (info.fields) |field| field_iter: {
                            const field_tag = @field(Tag, field.name);
                            if (field_tag == tag) {
                                switch (fasterDeserializeType(@TypeOf(@field(ptr, field.name)))) {
                                    .pointer => {
                                        ptr.* = @unionInit(T, field.name, undefined);
                                        self.allocatingDeserializeInto(&@field(ptr, field.name), allocator);
                                    },
                                    .value => {
                                        ptr.* = @unionInit(T, @tagName(tag), try self.allocatingDeserialize(@TypeOf(@field(ptr, field.name)), allocator));
                                    },
                                }
                                break :field_iter;
                            }
                        }
                        return error.Corrupt;
                    }
                },
                .Array => |info| {
                    if (intSerializable(info.child) and @bitSizeOf(info.child) == 8) {
                        const reader = switch (packing) {
                            .bit => self.reader.reader(),
                            .byte => self.reader,
                        };
                        return reader.readNoEof(std.mem.asBytes(ptr)) catch |err| {
                            if (err == error.EndOfStream) {
                                return error.Corrupt;
                            } else {
                                return err;
                            }
                        };
                    } else for (ptr) |*item| {
                        try self.allocatingDeserializeInto(item, allocator);
                    }
                },
                .Vector => |info| {
                    for (0..info.len) |i| {
                        if (fasterDeserializeType(info.child) == .pointer and @typeInfo(@TypeOf(&ptr[i])).Pointer.alignment >= @alignOf(info.child)) {
                            try self.allocatingDeserializeInto(&ptr[i], allocator);
                        } else {
                            ptr[i] = try self.allocatingDeserialize(info.child, allocator);
                        }
                    }
                },
                else => |other| {
                    @compileError("Cannot deserialize " ++ @tagName(other) ++ " types.\nError in obtaining proper error message for serialization of this invalid type. Sorry :(");
                },
            }
        }

        /// Returns a deserialized value of type `T`.
        /// Guaranteed to never allocate memory.
        /// If deserialization of the requested type requires allocation,
        /// then a compiler error will be generated
        pub fn deserialize(self: *Self, comptime T: type) !T {
            return if (deserializeNeedsAllocator(T))
                @compileError("Deserialization of type " ++ @typeName(T) ++ " requires an allocator")
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
                @compileError("Deserialization of type " ++ @typeName(C) ++ " requires an allocator")
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
pub fn Serializer(comptime endianness: std.builtin.Endian, comptime packing_mode: Packing, comptime WriterType: type) type {
    return struct {
        pub const endian: std.builtin.Endian = endianness;
        pub const packing: Packing = packing_mode;

        pub const UnderlyingWriter = WriterType;
        pub const ActiveWriter = if (packing == .bit) io.BitWriter(endian, UnderlyingWriter) else UnderlyingWriter;
        pub const WriteError = ActiveWriter.Error;

        /// Signifies that the type is a valid serializer
        pub const ValidSerializer = Serializer;

        writer: ActiveWriter,

        const Self = @This();

        pub const Error = error{} || UnderlyingWriter.Error;

        pub fn init(writer: UnderlyingWriter) Self {
            return Self{
                .writer = switch (packing) {
                    .bit => io.bitWriter(endian, writer),
                    .byte => writer,
                },
            };
        }

        /// Flushes any unwritten bits to the writer
        pub fn flush(self: *Self) !void {
            if (packing == .bit) return self.writer.flushBits();
        }

        fn serializeInt(self: *Self, comptime Int: type, value: Int) !void {
            if (!integerLayout(Int))
                @compileError("Cannot use serializeInt on type " ++ @typeName(Int) ++ ", whose layout is not portable");

            return switch (comptime packing) {
                .bit => bitio.bitWriteInt(&self.writer, Int, value),
                .byte => bitio.byteWriteInt(&self.writer, endian, Int, value),
            };
        }

        fn serializeEnum(self: *Self, comptime Enum: type, tag: Enum) !void {
            if (@typeInfo(Enum) != .Enum)
                @compileError("Cannot use serializeEnum on type " ++ @typeName(Enum) ++ ", which is not an enum");

            return switch (comptime packing) {
                .bit => bitio.bitWriteEnum(&self.writer, Enum, tag),
                .byte => bitio.byteWriteEnum(&self.writer, endian, Enum, tag),
            };
        }

        /// Serializes the passed value into the writer
        pub fn serialize(self: *Self, comptime T: type, value: T) !void {
            defer self.flush() catch unreachable;
            if (serializeTypeErrorMessage(T)) |err| {
                @compileError(err);
            } else if (usesCustomSerialize(T)) {
                return @field(T, custom_serialize_fn_name)(value, self);
            }
            switch (SerializationMode.get(T)) {
                .none, .ignore_custom => {},
                .unserializable => comptime unreachable,
                .packed_union => return self.serializeInt(@Type(.{
                    .Int = .{
                        .signedness = .unsigned,
                        .bits = @bitSizeOf(T),
                    },
                }), @bitCast(value)),
                .noop => return,
            }
            if (byteSerializable(T, endian, packing)) raw_write: {
                const writer = switch (packing) {
                    .bit => blk: {
                        if (self.writer.bit_count != 0) break :raw_write;
                        break :blk self.writer.writer();
                    },
                    .byte => self.writer,
                };
                return writer.writeAll(std.mem.asBytes(&value));
            }
            if (intSerializable(T)) {
                return self.serializeInt(T, value);
            } else switch (@typeInfo(T)) {
                .Void, .Undefined, .Null => return void{},
                .Bool => try self.serializeInt(u1, @intFromBool(value)),
                .Float, .Int => comptime unreachable, // handled by intSerializable
                .Struct => |info| {
                    if (intSerializable(T)) {
                        try self.serializeInt(T, value);
                    } else inline for (info.fields) |field_info| {
                        const name: []const u8 = field_info.name;
                        const FieldType: type = field_info.type;
                        try self.serialize(FieldType, @field(value, name));
                    }
                },
                .Union => |info| union_blk: {
                    const TagType = info.tag_type.?;
                    if (!@typeInfo(TagType).Enum.is_exhaustive) {
                        try self.serialize(TagType, value);
                        inline for (info.fields) |field| {
                            const field_enum: TagType = @field(TagType, field.name);
                            if (field_enum == value) {
                                try self.serialize(field.type, @field(value, field.name));
                                break :union_blk;
                            }
                        }
                        unreachable;
                    } else switch (value) {
                        inline else => |field| {
                            const FieldType: type = @TypeOf(field);
                            const tag: TagType = value;
                            try self.serialize(TagType, tag);
                            return self.serialize(FieldType, field);
                        },
                    }
                },
                .Optional => |op| {
                    const is_some: bool = value != null;
                    try self.serializeInt(u1, @intFromBool(is_some));
                    if (is_some) try self.serialize(op.child, value.?);
                },
                .Enum => try self.serializeEnum(T, value),
                .Array => |info| {
                    for (value) |item| {
                        try self.serialize(info.child, item);
                    }
                },
                .Vector => |info| {
                    for (0..info.len) |i| {
                        try self.serialize(info.child, value[i]);
                    }
                },
                else => {
                    @compileError("Cannot serialize " ++ @tagName(@typeInfo(T)) ++ " types.\nError in obtaining proper error message for serialization of this invalid type. Sorry :(");
                },
            }
        }
    };
}

/// Whether type `T` is a serializer interface
pub inline fn isSerializer(comptime T: type) bool {
    if (@typeInfo(T) == .Pointer) {
        if (@typeInfo(T).Pointer.size != .One) {
            return false;
        } else {
            return isSerializer(@typeInfo(T).Pointer.child);
        }
    } else {
        return @hasDecl(T, "ValidSerializer") and T.ValidSerializer == Serializer;
    }
}

/// Whether type `T` is a deserializer interface
pub inline fn isDeserializer(comptime T: type) bool {
    if (@typeInfo(T) == .Pointer) {
        if (@typeInfo(T).Pointer.size != .One) {
            return false;
        } else {
            return isDeserializer(@typeInfo(T).Pointer.child);
        }
    } else {
        return @hasDecl(T, "ValidDeserializer") and T.ValidDeserializer == Deserializer;
    }
}

/// At comptime, assert that type `T` is a `Serializer` type
pub inline fn assertSerializerType(comptime T: type) void {
    if (comptime !isSerializer(T))
        @compileError("Type " ++ @typeName(T) ++ " is not a serializer");
}
/// At comptime, assert that type `T` is a `Deserializer` type
pub inline fn assertDeserializerType(comptime T: type) void {
    if (comptime !isDeserializer(T))
        @compileError("Type " ++ @typeName(T) ++ " is not a deserializer");
}
/// At comptime, assert that the given value is a `Serializer`
pub inline fn assertSerializer(serializer_value: anytype) void {
    const T = @TypeOf(serializer_value);
    comptime assertSerializerType(T);
}
/// At comptime, assert that the given value is a `Deserializer`
pub inline fn assertDeserializer(deserializer_value: anytype) void {
    const T = @TypeOf(deserializer_value);
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
fn testSerializableDeserializableExtra(
    comptime endian: std.builtin.Endian,
    comptime packing: Packing,
    comptime T: type,
    x: T,
    allocator: mem.Allocator,
    expectEqlFn: anytype,
) !void {
    // we use this as a buffer to write our serialized data to
    var serialized_data = std.ArrayList(u8).init(testing.allocator);
    defer serialized_data.deinit();

    const writer = serialized_data.writer();
    var _serializer = serializer(endian, packing, writer);

    _serializer.serialize(T, x) catch |err| {
        if (err == error.OutOfMemory) return error.SkipZigTest;
        return err;
    };
    _serializer.flush() catch |err| {
        if (err == error.OutOfMemory) return error.SkipZigTest;
        return err;
    };

    // since we dont know the type, we dont know hoe to properly deallocate any memory we may have allocated
    // in fact, we dont even know if we allocate memory at all.
    // so we use an arena which should cover any memory leaks
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_alloc = arena.allocator();

    var stream = io.StreamSource{ .buffer = io.fixedBufferStream(serialized_data.items) };
    const reader = stream.reader();

    var _deserializer = deserializer(endian, packing, reader);

    const y: T = _deserializer.allocatingDeserialize(T, arena_alloc) catch |err| {
        if (err == error.OutOfMemory) return error.SkipZigTest;
        return err;
    };

    try expectEqlFn(x, y);
}

/// For use in test blocks.
/// Test whether a value can be serialized and deserialized back into the original value.
/// `expectEqlFn` should be a function type of signature `fn (a: T, b: T) !void` which returns an error if `a != b`.
/// In general, it is advised to just pass in `std.testing.expectEqual` here.
fn testSerializable(comptime T: type, x: T, allocator: mem.Allocator, testEqualFn: anytype) !void {
    try testSerializableDeserializableExtra(.little, .bit, T, x, allocator, testEqualFn);
    try testSerializableDeserializableExtra(.little, .byte, T, x, allocator, testEqualFn);
    try testSerializableDeserializableExtra(.big, .bit, T, x, allocator, testEqualFn);
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
    try testIntSerializerDeserializer(.little, .bit);
    try testIntSerializerDeserializer(.little, .byte);
    try testIntSerializerDeserializer(.big, .bit);
    try testIntSerializerDeserializer(.big, .byte);
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
    try testIntSerializerDeserializerInfNaN(.little, .bit);
    try testIntSerializerDeserializerInfNaN(.little, .byte);
    try testIntSerializerDeserializerInfNaN(.big, .bit);
    try testIntSerializerDeserializerInfNaN(.big, .byte);
}

test "Serializer/Deserializer generic" {
    const ColorType = enum(u4) {
        RGB8 = 1,
        RA16 = 2,
        R32 = 3,
    };

    const TagNonExhaustive = enum(u32) {
        A,
        B,
        C,
        _,
    };

    const NonExhaustiveUnion = union(TagNonExhaustive) {
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

    const PackedByte = packed struct(u8) {
        f_lo: u4,
        f_hi: u4,
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
        f_non_exhaustive_union: NonExhaustiveUnion,
        f_u24: u24,
        f_i19: i19,
        f_void: void,
        f_f32: f32,
        f_f128: ?f128,
        f_packed_0: PackedStruct,
        f_i7arr: [10]i7,
        f_u16vec: @Vector(4, u16),
        f_bytearr: [16]PackedByte,
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
        .f_non_exhaustive_union = NonExhaustiveUnion{ .B = 148 },
        .f_u24 = 24,
        .f_i19 = 19,
        .f_void = void{},
        .f_f32 = 32.32,
        .f_f128 = 128.128,
        .f_packed_0 = PackedStruct{ .f_i3 = -1, .f_u2 = 2 },
        .f_i7arr = [10]i7{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 },
        .f_u16vec = @Vector(4, u16){ 10, 11, 12, 13 },
        .f_bytearr = @bitCast([16]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p' }),
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
    try testBadData(.little, .bit);
    try testBadData(.little, .byte);
    try testBadData(.big, .bit);
    try testBadData(.big, .byte);
}

test {
    testing.refAllDeclsRecursive(@This());
}
