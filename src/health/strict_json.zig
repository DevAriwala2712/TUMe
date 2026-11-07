const std = @import("std");

/// Check wire types before Zig's typed decoder can coerce JSON values.
pub fn matches(comptime T: type, value: std.json.Value) bool {
    if (T == std.json.Value) return true;
    switch (@typeInfo(T)) {
        .optional => |optional| return value == .null or matches(optional.child, value),
        .bool => return value == .bool,
        .int => return switch (value) {
            .integer => std.math.cast(T, value.integer) != null,
            .number_string => if (std.fmt.parseInt(T, value.number_string, 10)) |_| true else |_| false,
            else => false,
        },
        .@"enum" => return value == .string and std.meta.stringToEnum(T, value.string) != null,
        .pointer => |pointer| {
            if (pointer.size != .slice) @compileError("expected a JSON wire slice");
            if (pointer.child == u8) return value == .string;
            if (value != .array) return false;
            for (value.array.items) |item| {
                if (!matches(pointer.child, item)) return false;
            }
            return true;
        },
        .@"struct" => |structure| {
            if (value != .object) return false;
            inline for (structure.fields) |field| {
                if (value.object.get(field.name)) |item| {
                    if (!matches(field.type, item)) return false;
                } else if (field.default_value_ptr == null) return false;
            }
            return true;
        },
        else => @compileError("unsupported health JSON wire type"),
    }
}
