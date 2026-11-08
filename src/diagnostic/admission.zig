const std = @import("std");

test "malformed cgroup limits and pressure are distinct from valid readings" {
    try std.testing.expectEqual(@as(?u16, 125), pressure("some avg10=1.25 avg60=0.90 avg300=0.20 total=9\n"));
    try std.testing.expectEqual(@as(?u16, null), pressure("some avg10=nan avg60=0.90 avg300=0.20 total=9\n"));
    try std.testing.expectEqual(@as(?u16, null), pressure("some avg10=101.00 avg60=0.90 avg300=0.20 total=9\n"));
    try std.testing.expectEqual(@as(?Limit, .unlimited), limit("max\n"));
    try std.testing.expectEqual(@as(?Limit, .{ .bytes = 123 }), limit("123\n"));
    try std.testing.expectEqual(@as(?Limit, null), limit("bad\n"));
}

test "running jobs retain reserve for growth to the configured cap" {
    const sample: Measurements = .{ .host_available = 399, .memory_psi = 0, .cpu_psi = 0, .ancestors = &.{} };
    const budget: Budget = .{ .cap = 500, .reserve = 100, .current = 200 };
    try std.testing.expectEqual(Verdict.insufficient_headroom, check(sample, budget, .running));
}

test "full job cap fits the host and every ancestor, including memory.high" {
    const healthy: Memory = .{ .current = 100, .high = .unlimited, .max = .{ .bytes = 1000 } };
    const tight: Memory = .{ .current = 100, .high = .{ .bytes = 650 }, .max = .{ .bytes = 900 } };
    const measurements: Measurements = .{ .host_available = 1500, .memory_psi = 0, .cpu_psi = 0, .ancestors = &.{ healthy, tight } };
    const budget: Budget = .{ .cap = 500, .reserve = 100, .current = 450 };
    try std.testing.expectEqual(Verdict.insufficient_headroom, check(measurements, budget, .start));
    try std.testing.expectEqual(Verdict.admit, check(measurements, budget, .running));
    var changed = measurements;
    changed.ancestors = &.{healthy};
    changed.host_available = 599;
    try std.testing.expectEqual(Verdict.insufficient_headroom, check(changed, budget, .start));
    changed.host_available = 600;
    try std.testing.expectEqual(Verdict.admit, check(changed, budget, .start));
    changed.host_available = 99;
    try std.testing.expectEqual(Verdict.insufficient_headroom, check(changed, budget, .running));
    changed.host_available = 800;
    changed.memory_psi = 100;
    try std.testing.expectEqual(Verdict.pressure, check(changed, budget, .running));
    changed.memory_psi = 0;
    changed.cpu_psi = 1000;
    try std.testing.expectEqual(Verdict.pressure, check(changed, budget, .running));
}

pub const Limit = union(enum) { unlimited, bytes: u64 };
pub const Memory = struct { current: u64, high: Limit, max: Limit };
pub const Measurements = struct {
    host_available: u64,
    memory_psi: u16,
    cpu_psi: u16,
    ancestors: []const Memory,
};
pub const Budget = struct { cap: u64, reserve: u64, current: u64 };
pub const Phase = enum { start, running };
pub const Verdict = enum { admit, insufficient_headroom, pressure };

pub fn check(measurements: Measurements, budget: Budget, phase: Phase) Verdict {
    // PSI is in basis points. Cancel at 1% memory or 10% CPU stall over 10s.
    if (measurements.memory_psi >= 100 or measurements.cpu_psi >= 1000) return .pressure;
    const growth = switch (phase) {
        .start => budget.cap,
        .running => budget.cap -| budget.current,
    };
    const required = std.math.add(u64, growth, budget.reserve) catch return .insufficient_headroom;
    if (measurements.host_available < required) return .insufficient_headroom;
    for (measurements.ancestors) |ancestor| {
        if (headroom(ancestor) < required) return .insufficient_headroom;
    }
    return .admit;
}

pub fn headroom(memory: Memory) u64 {
    const high = switch (memory.high) {
        .unlimited => std.math.maxInt(u64),
        .bytes => |bytes| bytes,
    };
    const max = switch (memory.max) {
        .unlimited => std.math.maxInt(u64),
        .bytes => |bytes| bytes,
    };
    return @min(high, max) -| memory.current;
}

pub fn unsigned(bytes: []const u8) ?u64 {
    const value = std.mem.trim(u8, bytes, " \t\r\n");
    if (value.len == 0) return null;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseUnsigned(u64, value, 10) catch null;
}

pub fn limit(bytes: []const u8) ?Limit {
    if (std.mem.eql(u8, std.mem.trim(u8, bytes, " \t\r\n"), "max")) return .unlimited;
    return .{ .bytes = unsigned(bytes) orelse return null };
}

pub fn pressure(bytes: []const u8) ?u16 {
    var value: ?u16 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "some ")) continue;
        if (value != null) return null;
        var tokens = std.mem.tokenizeScalar(u8, line[5..], ' ');
        const avg = tokens.next() orelse return null;
        if (!std.mem.startsWith(u8, avg, "avg10=")) return null;
        var parts = std.mem.splitScalar(u8, avg[6..], '.');
        const whole = unsigned(parts.next() orelse return null) orelse return null;
        const hundredths = parts.next() orelse return null;
        if (whole > 100 or hundredths.len != 2 or parts.next() != null) return null;
        const fraction = unsigned(hundredths) orelse return null;
        const basis_points = whole * 100 + fraction;
        if (basis_points > 10000) return null;
        value = @intCast(basis_points);
    }
    return value;
}
