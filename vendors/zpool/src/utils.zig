const std = @import("std");

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

pub fn asTypeId(comptime typeInfo: std.lang.Type) std.lang.TypeId {
    return @as(std.lang.TypeId, typeInfo);
}

pub fn typeIdOf(comptime T: type) std.lang.TypeId {
    return asTypeId(@typeInfo(T));
}

pub fn isStruct(comptime T: type) bool {
    return typeIdOf(T) == std.lang.TypeId.@"struct";
}

pub const Field = struct {
    name: [:0]const u8,
    type: type,
    attrs: std.lang.Type.Struct.FieldAttributes,
};

pub fn fields(comptime T: type) [@typeInfo(T).@"struct".field_names.len]Field {
    const info = @typeInfo(T).@"struct";
    var result: [info.field_names.len]Field = undefined;
    for (info.field_names, info.field_types, info.field_attrs, &result) |name, field_type, attrs, *field| {
        field.* = .{ .name = name, .type = field_type, .attrs = attrs };
    }
    return result;
}

pub fn fieldInfo(comptime T: type, comptime field: std.meta.FieldEnum(T)) Field {
    return fields(T)[@backingInt(field)];
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/// UInt(bits) returns an unsigned integer type of the requested bit width.
pub fn UInt(comptime bits: u8) type {
    return @Int(.unsigned, bits);
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/// Returns an unsigned integer type with ***at least*** `min_bits`,
/// that is also large enough to be addressable by a normal pointer.
/// The returned type will always be one of the following:
/// * `u8`
/// * `u16`
/// * `u32`
/// * `u64`
/// * `u128`
/// * `u256`
pub fn AddressableUInt(comptime min_bits: u8) type {
    return switch (min_bits) {
        0...8 => u8,
        9...16 => u16,
        17...32 => u32,
        33...64 => u64,
        65...128 => u128,
        129...255 => u256,
    };
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/// Given: `Struct = struct { foo: u32, bar: u64 }`
/// Returns: `StructOfSlices = struct { foo: []u32, bar: []u64 }`
pub fn StructOfSlices(comptime Struct: type) type {
    // same number of fields in the new struct
    const struct_info = @typeInfo(Struct).@"struct";
    var field_names: [struct_info.field_names.len][]const u8 = undefined;
    var field_types: [struct_info.field_names.len]type = undefined;

    inline for (
        struct_info.field_names,
        struct_info.field_types,
        struct_info.field_attrs,
        &field_names,
        &field_types,
    ) |field_name, field_type, field_attrs, *name, *Type| {
        // u32 -> []u32
        const element_type = field_type;

        const FieldType = @Pointer(
            .slice,
            .{
                .@"align" = field_attrs.@"align",
            },
            element_type,
            null,
        );

        name.* = field_name;
        Type.* = FieldType;
    }

    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &@splat(.{}),
    );
}

test "StructOfSlices" {
    const expectEqual = std.testing.expectEqual;

    const Struct = struct { a: u16, b: u16, c: u16 };
    try expectEqual(@sizeOf(u16) * 3, @sizeOf(Struct));

    const SOS = StructOfSlices(Struct);
    try expectEqual(@sizeOf([]u16) * 3, @sizeOf(SOS));
}
