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
const builtin = @import("builtin");
const Type = std.builtin.Type;

const mem = std.mem;
const math = std.math;
const testing = std.testing;

const Allocator = std.mem.Allocator;
const Endian = std.builtin.Endian;
const expect = std.testing.expect;
const assert = std.debug.assert;

const native_endian = builtin.cpu.arch.endian();

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

/// Identical to the `@hasDecl` builtin, but if `T` is not a namespace,
/// then instead of causing a compile error, return false.
inline fn safeHasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct",
        .@"union",
        .@"enum",
        .@"opaque",
        => @hasDecl(T, name),
        else => false,
    };
}

/// The enum tag of union `T`, except always exhaustive and with noreturn fields removed.
/// Very useful for deserialization of tagged unions.
fn UnionTag(comptime T: type) type {
    const BaseTag = @typeInfo(T).@"union".tag_type.?;
    const old_fields = @typeInfo(T).@"union".fields;
    const enum_info = @typeInfo(BaseTag).@"enum";
    var fields_buf: [enum_info.fields.len]std.builtin.Type.EnumField = undefined;
    var i: usize = 0;
    for (old_fields, enum_info.fields) |union_field, enum_field| {
        if (union_field.type != noreturn) {
            fields_buf[i] = enum_field;
            i += 1;
        }
    }
    const fields = fields_buf[0..i];
    return @Type(.{ .@"enum" = .{
        .decls = &.{},
        .fields = fields,
        .is_exhaustive = true,
        .tag_type = enum_info.tag_type,
    } });
}

/// Whether `Pointer` contains bytes which can be directly read to/written from.
/// Sounds simple, but has several niche edge cases.
fn pointerHasIoBytes(comptime Pointer: type) bool {
    const type_info = @typeInfo(Pointer);
    const ptr_info = type_info.pointer;
    if (Pointer != @Type(type_info)) {
        // Handles pointers to packed struct fields,
        // which painfully cannot be differentiated with typeInfo
        return false;
    }
    return ptr_info.address_space == .generic and !ptr_info.is_allowzero and !ptr_info.is_volatile;
}

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
    fn get(comptime T: type) SerializationMode {
        if (safeHasDecl(T, custom_mode_decl_name)) {
            const override = @field(T, custom_mode_decl_name);
            switch (@TypeOf(override)) {
                SerializationMode => return override,
                @Type(.enum_literal) => {
                    const tag = @tagName(override);
                    if (@hasField(SerializationMode, tag)) {
                        return @field(SerializationMode, tag);
                    }
                },
                else => {},
            }
        }
        return .none;
    }
};

test SerializationMode {
    const IEEE = packed union {
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

fn hasSerializationFns(comptime T: type) bool {
    const serialize_fn = safeHasDecl(T, custom_serialize_fn_name);
    const deserialize_fn = safeHasDecl(T, custom_deserialize_fn_name);
    const alloc_deserialize_fn = safeHasDecl(T, custom_allocating_deserialize_fn_name);
    return serialize_fn and (deserialize_fn or alloc_deserialize_fn);
}

/// Whether a type uses custom serialization functions
fn usesCustomSerialize(comptime T: type) bool {
    return switch (SerializationMode.get(T)) {
        .none => hasSerializationFns(T),
        .noop => true,
        .ignore_custom, .packed_union => false,
        .unserializable => false,
    };
}

/// Whether custom serialization functions are used anywhere in the structure of a type
fn containsCustomSerialize(comptime T: type) bool {
    return comptime usesCustomSerialize(T) or switch (@typeInfo(T)) {
        .@"struct" => |s| for (s.fields) |field| {
            if (!field.is_comptime and containsCustomSerialize(field.type)) break true;
        } else false,
        .@"union" => |u| blk: {
            if (u.tag_type) |Tag| {
                if (containsCustomSerialize(Tag)) break :blk true;
            }
            for (u.fields) |field| {
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
        .none => hasSerializationFns(T),
        .noop => true,
        .ignore_custom, .packed_union => false,
        .unserializable => false,
    };
}

/// Whether a type can be
inline fn containsNonIntSerialize(comptime T: type) bool {
    return comptime usesCustomSerialize(T) or switch (@typeInfo(T)) {
        .@"struct" => |s| for (s.fields) |field| {
            if (!field.is_comptime and containsCustomSerialize(field.type)) break true;
        } else false,
        .@"union" => |u| blk: {
            if (u.tag_type) |Tag| {
                if (containsCustomSerialize(Tag)) break :blk true;
            }
            for (u.fields) |field| {
                if (containsCustomSerialize(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn uniqueEnum(comptime E: type) bool {
    switch (@typeInfo(E)) {
        .@"enum" => |e| switch (@typeInfo(e.tag_type)) {
            .int => |i| {
                if (e.is_exhaustive) {
                    const expected_fields = 1 << @as(comptime_int, i.bits);
                    return e.fields.len == expected_fields;
                } else {
                    return true;
                }
            },
            else => {},
        },
        else => {},
    }
    return false;
}

fn intSerializable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool => true,
        inline .@"struct", .@"union" => |s| s.layout == .@"packed",
        else => false,
    };
}

/// Whether the bytes of `T` in memory are already ordered in the same way they would be serialized.
/// May return false negatives, but never false positives.
/// Used to sometimes simplify the process of serializing/deserializing values.
/// mode `fallible` is for writing, and assumes the bytes form a valid `T`.
/// mode `unique` is for reading, and only returns true if all values of
fn orderedBytes(comptime T: type, comptime endian: Endian, comptime mode: enum { unique, fallible }) bool {
    switch (@typeInfo(T)) {
        .@"enum" => |e| return orderedBytes(e.tag_type, endian, mode) and switch (mode) {
            .unique => uniqueEnum(T),
            .fallible => true,
        },
        .@"struct" => |s| {
            if (s.backing_integer) |Int| {
                return orderedBytes(Int, endian, mode);
            } else switch (s.layout) {
                .@"packed" => {
                    const Int = @Type(.{
                        .int = .{
                            .bits = @bitSizeOf(T),
                            .signedness = .unsigned,
                        },
                    });
                    return orderedBytes(Int, endian, mode);
                },
                .auto, .@"extern" => {
                    // This often works for extern structs,
                    // and it is possible that auto struct layout happens to work here
                    comptime var offset = 0;
                    return inline for (s.fields) |field| {
                        if (!field.is_comptime) {
                            if (comptime offset == @offsetOf(T, field.name) and orderedBytes(field.type, endian, mode)) {
                                offset += @sizeOf(field.type);
                            } else {
                                break false;
                            }
                        }
                    } else offset == @sizeOf(T);
                },
            }
        },
        .array => |a| return a.len == 0 or orderedBytes(a.child, endian, mode),
        else => return intSerializable(T) and switch (@bitSizeOf(T)) {
            0, 8 => true,
            else => |bits| @sizeOf(T) * 8 == bits and endian == native_endian,
        },
    }
}

/// Reads values from a reader
pub fn Deserializer(comptime endianness: Endian, comptime packing_mode: Packing, comptime ReaderType: type) type {
    return struct {
        pub const endian: Endian = endianness;
        pub const packing: Packing = packing_mode;

        pub const UnderlyingReader: type = ReaderType;
        pub const ActiveReader: type = switch (packing) {
            .bit => std.io.BitReader(endian, UnderlyingReader),
            .byte => UnderlyingReader,
        };

        pub const ReadError = error{} || ActiveReader.Error; // empty error set merge so tooling knows its an error set
        pub const ReadEofError = error{EndOfStream} || ReadError;

        /// Signifies that the type is a valid deserializer
        const ValidDeserializer = Deserializer;

        reader: ActiveReader,

        const Self = @This();

        pub fn init(reader: UnderlyingReader) Self {
            return Self{
                .reader = switch (packing) {
                    .bit => std.io.bitReader(endian, reader),
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
            return switch (packing) {
                .bit => bitio.bitReadInt(&self.reader, Int),
                .byte => bitio.byteReadInt(&self.reader, endian, Int),
            };
        }

        fn deserializeEnum(self: *Self, comptime Enum: type) !Enum {
            return switch (packing) {
                .bit => bitio.bitReadEnum(&self.reader, Enum),
                .byte => bitio.byteReadEnum(&self.reader, endian, Enum),
            };
        }
        fn deserializeUnion(self: *Self, info: Type.Union, T: type, alloc: Allocator) !T {
            const Tag: type = info.tag_type.?;
            const tag: Tag = try self.deserialize(Tag, undefined);
            if (@typeInfo(Tag).@"enum".is_exhaustive) {
                switch (tag) {
                    inline else => |field| {
                        const Payload: type = @FieldType(T, @tagName(field));
                        if (Payload == noreturn) return error.Corrupt;
                        return @unionInit(
                            T,
                            @tagName(field),
                            try self.deserialize(
                                Payload,
                                alloc,
                            ),
                        );
                    },
                }
            } else {
                inline for (info.fields) |field| {
                    const field_tag = @field(Tag, field.name);
                    const Payload = field.type;
                    if (Payload == noreturn) continue;
                    if (field_tag == tag) {
                        return @unionInit(
                            T,
                            field.name,
                            try self.deserialize(
                                Payload,
                                alloc,
                            ),
                        );
                    }
                }
                // unnamed tag value
                return error.Corrupt;
            }
        }

        const DeserializeType = enum { pointer, value };

        inline fn fasterDeserializeType(comptime T: type) DeserializeType {
            if (usesNonIntSerialize(T)) return .value;
            if (packing_mode == .byte and orderedBytes(T, endian, .unique)) return .pointer;
            return switch (@typeInfo(T)) {
                .null, .void, .undefined => .value,
                .bool => .value,
                .@"enum" => |en| fasterDeserializeType(en.tag_type),
                .optional => .value,
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
        pub fn deserialize(self: *Self, comptime T: type, alloc: Allocator) !T {
            // SerializeError.maybeRaise(T);

            if (comptime usesCustomSerialize(T)) {
                if (@hasDecl(T, custom_deserialize_fn_name)) {
                    //custom deserializer: fn(deserializer: anytype) !T
                    return @field(T, custom_deserialize_fn_name)(self);
                } else if (@hasDecl(T, custom_allocating_deserialize_fn_name)) {
                    //custom allocating deserializer: fn(deserializer: anytype, allocator: Allocator) !T
                    return @field(T, custom_allocating_deserialize_fn_name)(self, alloc);
                } else {
                    comptime unreachable;
                }
            }

            switch (comptime SerializationMode.get(T)) {
                .none, .ignore_custom => {},
                .unserializable => comptime unreachable,
                .packed_union => return @bitCast(try self.deserializeInt(@Type(.{
                    .int = .{
                        .signedness = .unsigned,
                        .bits = @bitSizeOf(T),
                    },
                }))),
                .noop => return @as(T, undefined),
            }

            if (comptime intSerializable(T)) {
                const U = @Type(.{ .int = .{
                    .signedness = .unsigned,
                    .bits = @bitSizeOf(T),
                } });
                return @bitCast(try self.deserializeInt(U));
            }

            return switch (@typeInfo(T)) {
                .undefined => undefined,
                .void => {},
                .null => null,

                .float, .int => comptime unreachable, // already handled with deserializeInt

                .bool => (try self.deserializeInt(u1)) != 0,

                .@"struct" => |info| blk: {
                    var strct: T = undefined;
                    inline for (info.fields) |field| {
                        const strcf = &@field(strct, field.name);
                        if (comptime !field.is_comptime) {
                            const fieldval = try self.deserialize(field.type, alloc);
                            strcf.* = fieldval;
                        }
                    }
                    break :blk strct;
                },

                .@"enum" => self.deserializeEnum(T),

                .optional => |info| blk: {
                    if (try self.deserializeInt(bool)) {
                        break :blk try self.deserialize(info.child, alloc);
                    } else {
                        break :blk null;
                    }
                },

                .@"union" => |info| try self.deserializeUnion(info, T, alloc),

                .vector => |info| {
                    return self.deserialize([info.len]info.child, alloc);
                },
                .array => |info| blk: {
                    var val: T = undefined;
                    for (&val) |*item| {
                        item.* = try self.deserialize(info.child, alloc);
                    }
                    break :blk val;
                },
                .pointer => |ptr| blck: {
                    if (comptime ptr.size == .slice) {
                        var slice: []ptr.child = undefined;
                        // NOTE: triggers if serialized len of > 2^32 on a system where usize = u64 and read where usize = u32!
                        const len = math.cast(usize, try self.deserializeInt(u64)) orelse return error.ValueDoesNotFit;
                        slice.len = len;
                        if (len == 0) break :blck slice;
                        slice = try alloc.alloc(ptr.child, len);
                        for (slice) |*arr_entry| {
                            arr_entry.* = try self.deserialize(ptr.child, alloc);
                        }
                        break :blck slice;
                    } else {
                        var value: T = undefined;
                        try self.allocatingDeserializeInto(&value, alloc);
                        break :blck value;
                    }
                },
                else => {
                    std.log.warn("failed serialization because of type {}", .{T});
                    return error.UnsupportedType;
                },
            };
        }
    };
}

/// Create a `Derializer` from a `reader`, `packing`, and `endian`
pub fn deserializer(
    comptime endian: Endian,
    comptime packing: Packing,
    reader: anytype,
) Deserializer(endian, packing, @TypeOf(reader)) {
    return .init(reader);
}

/// Writes values to a writer
pub fn Serializer(comptime endianness: Endian, comptime packing_mode: Packing, comptime WriterType: type) type {
    return struct {
        pub const endian: Endian = endianness;
        pub const packing: Packing = packing_mode;

        pub const UnderlyingWriter: type = WriterType;
        pub const ActiveWriter: type = switch (packing) {
            .bit => std.io.BitWriter(endian, UnderlyingWriter),
            .byte => UnderlyingWriter,
        };

        /// Signifies that the type is a valid serializer
        const ValidSerializer = Serializer;

        writer: ActiveWriter,

        const Self = @This();

        pub const Error = error{} || UnderlyingWriter.Error; // empty error set merge so tooling knows its an error set

        pub fn init(writer: UnderlyingWriter) Self {
            return Self{
                .writer = switch (packing) {
                    .bit => std.io.bitWriter(endian, writer),
                    .byte => writer,
                },
            };
        }

        /// Flushes any unwritten bits to the writer
        pub fn flush(self: *Self) !void {
            if (packing == .bit) return self.writer.flushBits();
        }

        fn serializeInt(self: *Self, comptime Int: type, value: Int) !void {
            return switch (packing) {
                .bit => bitio.bitWriteInt(&self.writer, Int, value),
                .byte => bitio.byteWriteInt(&self.writer, endian, Int, value),
            };
        }

        fn serializeEnum(self: *Self, comptime Enum: type, tag: Enum) !void {
            return switch (packing) {
                .bit => bitio.bitWriteEnum(&self.writer, Enum, tag),
                .byte => bitio.byteWriteEnum(&self.writer, endian, Enum, tag),
            };
        }
        fn serializeUnion(self: *Self, info: Type.Union, T: type, value: T) !void {
            const TagType = info.tag_type.?;
            if (!@typeInfo(TagType).@"enum".is_exhaustive) {
                try self.serialize(TagType, value);
                inline for (info.fields) |field| {
                    const field_enum: TagType = @field(TagType, field.name);
                    if (field_enum == value) {
                        try self.serialize(field.type, @field(value, field.name));
                        return;
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
        }

        /// Serializes the passed value into the writer
        pub fn serialize(self: *Self, comptime T: type, value: T) !void {
            if (comptime usesCustomSerialize(T)) {
                return @field(T, custom_serialize_fn_name)(value, self);
            }

            switch (comptime SerializationMode.get(T)) {
                .none, .ignore_custom => {},
                .unserializable => comptime unreachable,
                .packed_union => return self.serializeInt(@Type(.{
                    .int = .{
                        .signedness = .unsigned,
                        .bits = @bitSizeOf(T),
                    },
                }), @bitCast(value)),
                .noop => return,
            }

            if (comptime packing_mode == .byte and orderedBytes(T, endian, .fallible)) {
                // When possible, attempt to greatly simplify the serialization process
                // by just printing the value as it is im memory
                return switch (@sizeOf(T)) {
                    0 => {},
                    else => self.writer.writeAll(std.mem.asBytes(&value)),
                };
            }

            if (comptime intSerializable(T)) {
                const U = @Type(.{ .int = .{
                    .signedness = .unsigned,
                    .bits = @bitSizeOf(T),
                } });
                return try self.serializeInt(U, @bitCast(value));
            } else switch (@typeInfo(T)) {
                .void, .undefined, .null => return {},
                .bool => try self.serializeInt(u1, @intFromBool(value)),
                .float, .int => comptime unreachable, // handled by intSerializable

                .@"struct" => |info| {
                    inline for (info.fields) |field| {
                        if (!field.is_comptime) {
                            try self.serialize(field.type, @field(value, field.name));
                        }
                    }
                },
                .@"union" => |info| try self.serializeUnion(info, T, value),
                .optional => |op| {
                    const is_some: bool = value != null;
                    try self.serializeInt(u1, @intFromBool(is_some));
                    if (is_some) try self.serialize(op.child, value.?);
                },
                .@"enum" => try self.serializeEnum(T, value),
                .array => |info| {
                    for (value) |item| {
                        try self.serialize(info.child, item);
                    }
                },
                .vector => |info| {
                    return self.serialize([info.len]info.child, value);
                },
                .pointer => |ptr| {
                    if (comptime ptr.size == .slice) {
                        // NOTE: triggers if serialized len of > 2^32 on a system where usize = u64 and read where usize = u32!
                        const slice_len = math.cast(u64, value.len) orelse return error.ValueDoesNotFit;
                        try self.serializeInt(u64, slice_len);
                        for (value) |arr_entry| {
                            try self.serialize(ptr.child, arr_entry);
                        }
                    } else {
                        serialize_compile_error(T);
                    }
                },
                else => serialize_compile_error(T),
            }
        }
    };
}

fn serialize_compile_error(T: type) void {
    @compileError("Cannot serialize " ++ @tagName(@typeInfo(T)) ++ " types.\n" ++
        \\Error in obtaining proper error message for serialization of this invalid type. Sorry :(
    );
}

/// Whether type `T` is a serializer interface
pub inline fn isSerializer(comptime T: type) bool {
    if (@typeInfo(T) == .pointer) {
        if (@typeInfo(T).pointer.size != .one) {
            return false;
        } else {
            return isSerializer(@typeInfo(T).pointer.child);
        }
    } else {
        return safeHasDecl(T, "ValidSerializer") and T.ValidSerializer == Serializer;
    }
}

/// Whether type `T` is a deserializer interface
pub inline fn isDeserializer(comptime T: type) bool {
    if (@typeInfo(T) == .pointer) {
        if (@typeInfo(T).pointer.size != .one) {
            return false;
        } else {
            return isDeserializer(@typeInfo(T).pointer.child);
        }
    } else {
        return safeHasDecl(T, "ValidDeserializer") and T.ValidDeserializer == Deserializer;
    }
}

/// At comptime, assert that type `T` is a `Serializer` type
pub inline fn assertSerializerType(comptime T: type) void {
    if (!isSerializer(T))
        @compileError("Type " ++ @typeName(T) ++ " is not a serializer");
}
/// At comptime, assert that type `T` is a `Deserializer` type
pub inline fn assertDeserializerType(comptime T: type) void {
    if (!isDeserializer(T))
        @compileError("Type " ++ @typeName(T) ++ " is not a deserializer");
}
/// At comptime, assert that the given value is a `Serializer`
pub inline fn assertSerializer(serializer_value: anytype) void {
    const T = @TypeOf(serializer_value);
    assertSerializerType(T);
}
/// At comptime, assert that the given value is a `Deserializer`
pub inline fn assertDeserializer(deserializer_value: anytype) void {
    const T = @TypeOf(deserializer_value);
    assertDeserializerType(T);
}

/// Create a `Serializer` from a `writer`, `packing`, and `endian`
pub fn serializer(
    comptime endian: Endian,
    comptime packing: Packing,
    writer: anytype,
) Serializer(endian, packing, @TypeOf(writer)) {
    return .init(writer);
}

/// Test whether a value can be serialized and deserialized back into the original value, with options for endian and packing.
/// `expectEqlFn` should be a function type of signature `fn (a: T, b: T) !void` which returns an error if `a != b`.
/// In general, it is advised to just pass in `std.testing.expectEqual` here.
fn testSerializableDeserializableExtra(
    comptime endian: Endian,
    comptime packing: Packing,
    comptime T: type,
    x: T,
    allocator: Allocator,
    expectEqlFn: anytype,
) !void {
    // we use this as a buffer to write our serialized data to
    var serialized_data: std.ArrayList(u8) = .init(testing.allocator);
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
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const arena_alloc = arena.allocator();

    var stream: std.io.StreamSource = .{ .buffer = std.io.fixedBufferStream(serialized_data.items) };
    const reader = stream.reader();

    var _deserializer = deserializer(endian, packing, reader);

    const y: T = _deserializer.deserialize(T, arena_alloc) catch |err| {
        if (err == error.OutOfMemory) return error.SkipZigTest;
        return err;
    };

    try expectEqlFn(x, y);
}

/// For use in test blocks.
/// Test whether a value can be serialized and deserialized back into the original value.
/// `expectEqlFn` should be a function type of signature `fn (a: T, b: T) !void` which returns an error if `a != b`.
/// In general, it is advised to just pass in `std.testing.expectEqual` here.
fn testSerializable(comptime T: type, x: T, allocator: Allocator, testEqualFn: anytype) !void {
    try testSerializableDeserializableExtra(.little, .bit, T, x, allocator, testEqualFn);
    try testSerializableDeserializableExtra(.little, .byte, T, x, allocator, testEqualFn);
    try testSerializableDeserializableExtra(.big, .bit, T, x, allocator, testEqualFn);
    try testSerializableDeserializableExtra(.big, .byte, T, x, allocator, testEqualFn);
}

/// Test basic functionality of serializing integers
fn testIntSerializerDeserializer(comptime endian: Endian, comptime packing: Packing) !void {
    const max_test_bitsize: comptime_int = 128;
    @setEvalBranchQuota(max_test_bitsize * 10);

    const total_bytes: comptime_int = comptime blk: {
        var bytes: comptime_int = 0;
        var i: comptime_int = 0;
        while (i <= max_test_bitsize) : (i += 1) {
            bytes += (i / 8) + @as(comptime_int, @intFromBool(i % 8 > 0));
        }
        break :blk bytes * 2;
    };

    var data_mem: [total_bytes]u8 = undefined;
    var out = std.io.fixedBufferStream(&data_mem);
    var _serializer = serializer(endian, packing, out.writer());

    var in = std.io.fixedBufferStream(&data_mem);
    var _deserializer = deserializer(endian, packing, in.reader());

    comptime var i: comptime_int = 0;
    inline while (i <= max_test_bitsize) : (i += 1) {
        const U: type = @Type(.{ .int = .{
            .signedness = .unsigned,
            .bits = i,
        } });
        const S: type = @Type(.{ .int = .{
            .signedness = .signed,
            .bits = i,
        } });
        try _serializer.serializeInt(U, i);
        if (i != 0) try _serializer.serializeInt(S, -1) else try _serializer.serialize(S, 0);
    }
    try _serializer.flush();

    i = 0;
    inline while (i <= max_test_bitsize) : (i += 1) {
        const U: type = @Type(.{ .int = .{
            .signedness = .unsigned,
            .bits = i,
        } });
        const S: type = @Type(.{ .int = .{
            .signedness = .signed,
            .bits = i,
        } });
        const x: U = try _deserializer.deserialize(U, undefined);
        const y: S = try _deserializer.deserialize(S, undefined);
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
    var null_serializer = serializer(endian, packing, std.io.null_writer);
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
    comptime endian: Endian,
    comptime packing: Packing,
) !void {
    var data: std.ArrayList(u8) = .init(testing.allocator);
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

    var buffer = std.io.fixedBufferStream(data.items);

    var _deserializer = deserializer(endian, packing, buffer.reader());

    const nan_check_f16: f16 = try _deserializer.deserialize(f16, undefined);
    const inf_check_f16: f16 = try _deserializer.deserialize(f16, undefined);
    const nan_check_f32: f32 = try _deserializer.deserialize(f32, undefined);
    const inf_check_f32: f32 = try _deserializer.deserialize(f32, undefined);
    const nan_check_f64: f64 = try _deserializer.deserialize(f64, undefined);
    const inf_check_f64: f64 = try _deserializer.deserialize(f64, undefined);
    const nan_check_f128: f128 = try _deserializer.deserialize(f128, undefined);
    const inf_check_f128: f128 = try _deserializer.deserialize(f128, undefined);
    const nan_check_f80: f80 = try _deserializer.deserialize(f80, undefined);
    const inf_check_f80: f80 = try _deserializer.deserialize(f80, undefined);

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
        lo: u4,
        hi: u4,
    };

    //to test custom serialization
    const Custom = struct {
        float: f16,
        unused_u32: u32,

        fn deserialize(_deserializer: anytype) !@This() {
            assertDeserializer(_deserializer);
            return .{ .float = try _deserializer.deserialize(f16, undefined), .unused_u32 = 47 };
        }

        fn serialize(self: @This(), _serializer: anytype) !void {
            assertSerializer(_serializer);
            try _serializer.serialize(@TypeOf(self.float), self.float);
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

    const my_inst: MyStruct = .{
        .f_i3 = -1,
        .f_u8 = 8,
        .f_non_exhaustive_union = .{ .B = 148 },
        .f_u24 = 24,
        .f_i19 = 19,
        .f_void = {},
        .f_f32 = 32.32,
        .f_f128 = 128.128,
        .f_packed_0 = .{ .f_i3 = -1, .f_u2 = 2 },
        .f_i7arr = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 },
        .f_u16vec = .{ 10, 11, 12, 13 },
        .f_bytearr = @bitCast([_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p' }),
        .f_of64n = null,
        .f_of64v = 64.64,
        .f_opt_color_null = null,
        .f_opt_color_value = .R32,
        .f_packed_1 = .{ .f_i3 = 1, .f_u2 = 1 },
        .f_custom = .{ .float = 38.63, .unused_u32 = 47 },
        .f_opt_custom_null = null,
        .f_opt_custom_value = .{ .float = 12.34, .unused_u32 = 47 },
        .f_color = .{ .R32 = 123822 },
    };

    try testSerializable(MyStruct, my_inst, testing.allocator, testing.expectEqualDeep);
}

/// Expect failure for serializing invalid enums
fn testBadData(comptime endian: Endian, comptime packing: Packing) !void {
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
    var out = std.io.fixedBufferStream(&data_mem);
    var _serializer = serializer(endian, packing, out.writer());

    var in = std.io.fixedBufferStream(&data_mem);
    var _deserializer = deserializer(endian, packing, in.reader());

    try _serializer.serialize(u14, 3);
    try _serializer.flush();
    try testing.expectError(error.Corrupt, _deserializer.deserialize(A, undefined));
    out.pos = 0;
    try _serializer.serialize(u14, 3);
    try _serializer.serialize(u14, 88);
    try _serializer.flush();
    try testing.expectError(error.Corrupt, _deserializer.deserialize(C, undefined));
}

test "Deserializer bad data" {
    try testBadData(.little, .bit);
    try testBadData(.little, .byte);
    try testBadData(.big, .bit);
    try testBadData(.big, .byte);
}

test "serialize nested const slices" {
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

    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try testSerializable(MyDataType, mydata, arena.allocator(), testing.expectEqualDeep);
}

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
test "run example" {
    try example();
}

// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
