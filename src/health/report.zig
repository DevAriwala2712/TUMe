const std = @import("std");
const types = @import("types.zig");
const findings = @import("findings.zig");

pub const version = 1;
pub const wire_limit = 61440;
pub const status_limit = 65536;
pub const Mode = enum { snapshot, watch };

pub const Report = struct {
    target: types.Target,
    sample: types.Sample,
    mode: Mode,
    findings: []const findings.Finding,
};

pub const Value = struct {
    total_bytes: ?u64 = null,
    available_bytes: ?u64 = null,
    basis_points: ?u16 = null,
    millidegrees_c: ?i32 = null,
    active_state: ?types.ActiveState = null,

    pub fn jsonStringify(self: Value, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(Value).@"struct".fields) |field| {
            if (@field(self, field.name)) |item| {
                try writer.objectField(field.name);
                try writer.write(item);
            }
        }
        try writer.endObject();
    }
};

pub const Observation = struct { key: []const u8, value: ?Value, reason: ?types.Reason };

pub const Streak = struct {
    rule_id: findings.RuleId,
    subject: []const u8,
    breach: u2,
    recovery: u2,
};

pub const Wire = struct {
    schema_version: u16 = version,
    mode: Mode,
    boot_id: []const u8,
    sampled_at_unix_ms: i64,
    sampled_at_boot_ms: u64,
    collection_ms: u64,
    target: types.Target,
    observations: []const Observation,
    findings: []const findings.Finding,
    streaks: ?[]const Streak = null,

    pub fn jsonStringify(self: Wire, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(Wire).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (comptime std.mem.eql(u8, field.name, "streaks")) {
                if (value != null) {
                    try writer.objectField(field.name);
                    try writer.write(value);
                }
            } else {
                try writer.objectField(field.name);
                try writer.write(value);
            }
        }
        try writer.endObject();
    }
};

fn observation(key: []const u8, reading: anytype) Observation {
    return switch (reading) {
        .reason => |reason| .{ .key = key, .value = null, .reason = reason },
        .value => |value| .{
            .key = key,
            .value = switch (@TypeOf(value)) {
                types.Memory => .{ .total_bytes = value.total_bytes, .available_bytes = value.available_bytes },
                u16 => .{ .basis_points = value },
                i32 => .{ .millidegrees_c = value },
                types.ActiveState => .{ .active_state = value },
                else => @compileError("unsupported observation type"),
            },
            .reason = null,
        },
    };
}

pub fn toWire(a: std.mem.Allocator, value: Report) !Wire {
    const sample = value.sample;
    const sensor_count: usize = if (sample.temperature_mc != null) 1 else 0;
    const observations = try a.alloc(Observation, 4 + sample.services.len + sensor_count);
    observations[0] = observation("disk.mount", sample.disk_used_bp);
    observations[1] = observation("host.cpu_psi", sample.cpu_psi_bp);
    observations[2] = observation("host.memory", sample.memory);
    observations[3] = observation("host.memory_psi", sample.memory_psi_bp);
    if (sample.temperature_mc) |reading| observations[4] = observation("sensor.temperature", reading);
    for (sample.services, observations[4 + sensor_count ..]) |service, *entry| {
        const key = try findings.evidenceKey(a, .{ .rule_id = .service_unavailable, .subject = service.unit });
        entry.* = observation(key, service.state);
    }
    const boot_id = try a.dupe(u8, &sample.stamp.boot_id);
    return .{
        .mode = value.mode,
        .boot_id = boot_id,
        .sampled_at_unix_ms = sample.stamp.unix_ms,
        .sampled_at_boot_ms = sample.stamp.boot_ms,
        .collection_ms = sample.collection_ms,
        .target = value.target,
        .observations = observations,
        .findings = value.findings,
    };
}

pub fn encodeJson(a: std.mem.Allocator, value: anytype, limit: usize) ![]u8 {
    var buffer = std.Io.Writer.Allocating.init(a);
    defer buffer.deinit();
    try std.json.Stringify.value(value, .{}, &buffer.writer);
    try buffer.writer.writeByte('\n');
    if (buffer.written().len > limit) return error.ReportTooLarge;
    return buffer.toOwnedSlice();
}

pub fn encode(a: std.mem.Allocator, value: Report) ![]u8 {
    return encodeJson(a, try toWire(a, value), wire_limit);
}
