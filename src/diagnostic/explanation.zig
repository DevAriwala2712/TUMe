const std = @import("std");
const findings = @import("../health/findings.zig");
const report = @import("../health/report.zig");
const state = @import("../health/state.zig");
const strict_json = @import("../health/strict_json.zig");

pub const Cause = enum { disk_near_capacity, memory_headroom_low, memory_stalls, unit_failed, unit_inactive };

const Evidence = struct {
    id: []const u8,
    sampled_at_unix_ms: i64,
    value: report.Value,
};

pub const Request = struct {
    schema_version: u16 = 1,
    rule: findings.RuleId,
    evidence: Evidence,
};

pub fn openFinding(loaded: state.Loaded, key: []const u8) ?findings.Finding {
    if (loaded.freshness != .fresh) return null;
    const wire = loaded.report orelse return null;
    for (wire.findings) |finding| {
        if (std.mem.eql(u8, finding.evidence_key, key)) return finding;
    }
    return null;
}

pub fn prepare(allocator: std.mem.Allocator, loaded: state.Loaded, key: []const u8) !?Request {
    const finding = openFinding(loaded, key) orelse return null;
    if (!finding.input_evaluable) return null;
    const wire = loaded.report.?;
    for (wire.observations) |observation| {
        if (!std.mem.eql(u8, observation.key, key)) continue;
        const value = observation.value orelse return null;
        if (observation.reason != null or supported(finding.rule_id, value) == null) return null;
        const identity = try std.fmt.allocPrint(allocator, "{s}:{d}:{s}", .{ wire.boot_id, wire.sampled_at_boot_ms, key });
        defer allocator.free(identity);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(identity, &hash, .{});
        const hex = std.fmt.bytesToHex(hash, .lower);
        return .{
            .rule = finding.rule_id,
            .evidence = .{
                .id = try allocator.dupe(u8, &hex),
                .sampled_at_unix_ms = wire.sampled_at_unix_ms,
                .value = value,
            },
        };
    }
    return null;
}

fn supported(rule: findings.RuleId, value: report.Value) ?Cause {
    return switch (rule) {
        .disk_capacity_high => if (findings.diskVerdict(value.basis_points orelse return null) == .breach) .disk_near_capacity else null,
        .memory_headroom_low => if (findings.memoryVerdict(value.available_bytes orelse return null) == .breach) .memory_headroom_low else null,
        .memory_stalled => if (findings.stallVerdict(value.basis_points orelse return null) == .breach) .memory_stalls else null,
        .service_unavailable => switch (value.active_state orelse return null) {
            .failed => .unit_failed,
            .inactive => .unit_inactive,
            else => null,
        },
    };
}

const Proposal = struct { schema_version: u16, cause: Cause, citation: []const u8 };

pub fn validate(allocator: std.mem.Allocator, request: Request, response: []const u8) ?Cause {
    if (response.len > 4096) return null;
    const tree = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return null;
    defer tree.deinit();
    if (!strict_json.matches(Proposal, tree.value)) return null;
    const parsed = std.json.parseFromValue(Proposal, allocator, tree.value, .{}) catch return null;
    defer parsed.deinit();
    const proposal = parsed.value;
    if (proposal.schema_version != 1 or !std.mem.eql(u8, proposal.citation, request.evidence.id)) return null;
    if (supported(request.rule, request.evidence.value) != proposal.cause) return null;
    return proposal.cause;
}

const testing = std.testing;
const a = testing.allocator;

test "explanation requires a citation and a supported cause" {
    const request: Request = .{
        .rule = .service_unavailable,
        .evidence = .{ .id = "event-id", .sampled_at_unix_ms = 10, .value = .{ .active_state = .failed } },
    };
    const valid = validate(a, request, "{\"schema_version\":1,\"cause\":\"unit_failed\",\"citation\":\"event-id\"}");
    try testing.expectEqual(@as(?Cause, .unit_failed), valid);
    try testing.expectEqual(@as(?Cause, null), validate(a, request, "{\"schema_version\":1,\"cause\":\"unit_inactive\",\"citation\":\"event-id\"}"));
    try testing.expectEqual(@as(?Cause, null), validate(a, request, "{\"schema_version\":1,\"cause\":\"unit_failed\",\"citation\":\"invented\"}"));
    try testing.expectEqual(@as(?Cause, null), validate(a, request, "{\"schema_version\":\"1\",\"cause\":\"unit_failed\",\"citation\":\"event-id\"}"));
    try testing.expectEqual(@as(?Cause, null), validate(a, request, "{\"schema_version\":1,\"cause\":\"unit_failed\",\"citation\":\"event-id\",\"command\":\"restart\"}"));
}

test "explanation refuses stale, missing and currently healthy evidence" {
    try testing.expectEqual(@as(?Request, null), try prepare(a, .{ .freshness = .stale }, "host.memory"));
    try testing.expectEqual(@as(?Cause, null), supported(.disk_capacity_high, .{ .basis_points = 8500 }));
    try testing.expectEqual(@as(?Cause, null), supported(.memory_headroom_low, .{}));
    try testing.expectEqual(@as(?Cause, null), supported(.memory_headroom_low, .{ .available_bytes = 128 << 20 }));
    try testing.expectEqual(@as(?Cause, null), supported(.memory_stalled, .{ .basis_points = 999 }));
    try testing.expectEqual(Cause.disk_near_capacity, supported(.disk_capacity_high, .{ .basis_points = 9100 }).?);
    try testing.expectEqual(Cause.memory_headroom_low, supported(.memory_headroom_low, .{ .available_bytes = 16 << 20 }).?);
    try testing.expectEqual(Cause.memory_stalls, supported(.memory_stalled, .{ .basis_points = 1001 }).?);
}

test "explanation prepares a stable reference to the exact watcher sample" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    const key = "service:gateway.service";
    var observations = [_]report.Observation{.{ .key = key, .value = .{ .active_state = .inactive }, .reason = null }};
    var open = [_]findings.Finding{.{
        .rule_id = .service_unavailable,
        .subject = "gateway.service",
        .evidence_key = key,
        .opened_at_unix_ms = 1234,
        .input_evaluable = true,
    }};
    var loaded: state.Loaded = .{
        .freshness = .fresh,
        .report = .{
            .mode = .watch,
            .boot_id = "00000000-0000-0000-0000-000000000001",
            .sampled_at_unix_ms = 1234,
            .sampled_at_boot_ms = 34,
            .collection_ms = 1,
            .target = .{ .mount = "/", .services = &.{"gateway.service"}, .thermal_zone = null },
            .observations = &observations,
            .findings = &open,
        },
    };
    const first = (try prepare(allocator, loaded, key)).?;
    const repeat = (try prepare(allocator, loaded, key)).?;
    try testing.expectEqualStrings(first.evidence.id, repeat.evidence.id);
    try testing.expectEqual(Cause.unit_inactive, supported(first.rule, first.evidence.value).?);
    loaded.report.?.sampled_at_boot_ms += 15;
    const later = (try prepare(allocator, loaded, key)).?;
    try testing.expect(!std.mem.eql(u8, first.evidence.id, later.evidence.id));
    open[0].input_evaluable = false;
    try testing.expectEqual(@as(?Request, null), try prepare(allocator, loaded, key));
    open[0].input_evaluable = true;
    observations[0].value = .{ .active_state = .active };
    try testing.expectEqual(@as(?Request, null), try prepare(allocator, loaded, key));
}
