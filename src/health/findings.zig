const std = @import("std");
const types = @import("types.zig");

pub const RuleId = enum { disk_capacity_high, memory_headroom_low, memory_stalled, service_unavailable };
pub const Key = struct { rule_id: RuleId, subject: []const u8 };
pub const Finding = struct {
    rule_id: RuleId,
    subject: []const u8,
    evidence_key: []const u8,
    opened_at_unix_ms: i64,
    input_evaluable: bool,
};

pub const Entry = struct {
    breach: u2 = 0,
    recovery: u2 = 0,
    opened_at_unix_ms: ?i64 = null,
};

pub const State = struct { entries: [7]Entry = @splat(.{}) };

const Verdict = enum { breach, recovery, deadband, unknown };

pub fn resetStreaks(state: *State) void {
    for (&state.entries) |*entry| {
        entry.breach = 0;
        entry.recovery = 0;
    }
}

pub fn keyAt(target: types.Target, i: usize) Key {
    return switch (i) {
        0 => .{ .rule_id = .disk_capacity_high, .subject = target.mount },
        1 => .{ .rule_id = .memory_headroom_low, .subject = "host" },
        2 => .{ .rule_id = .memory_stalled, .subject = "host" },
        else => .{ .rule_id = .service_unavailable, .subject = target.services[i - 3] },
    };
}

pub fn evidenceKey(a: std.mem.Allocator, key: Key) ![]const u8 {
    return switch (key.rule_id) {
        .disk_capacity_high => "disk.mount",
        .memory_headroom_low => "host.memory",
        .memory_stalled => "host.memory_psi",
        .service_unavailable => std.fmt.allocPrint(a, "service:{s}", .{key.subject}),
    };
}

fn verdictAt(sample: types.Sample, i: usize) Verdict {
    return switch (i) {
        0 => switch (sample.disk_used_bp) {
            .reason => .unknown,
            .value => |used| if (used >= 9000) .breach else if (used <= 8500) .recovery else .deadband,
        },
        1 => switch (sample.memory) {
            .reason => .unknown,
            .value => |memory| if (memory.available_bytes < 128 << 20) .breach else if (memory.available_bytes >= 160 << 20) .recovery else .deadband,
        },
        2 => switch (sample.memory_psi_bp) {
            .reason => .unknown,
            .value => |pressure| if (pressure >= 1000) .breach else if (pressure < 500) .recovery else .deadband,
        },
        else => switch (sample.services[i - 3].state) {
            .reason => .unknown,
            .value => |value| switch (value) {
                .failed, .inactive => .breach,
                .active => .recovery,
                .activating, .deactivating, .reloading => .unknown,
            },
        },
    };
}

fn evaluate(entry: *Entry, verdict: Verdict, time: i64) void {
    entry.breach = if (verdict == .breach) @min(entry.breach +| 1, 2) else 0;
    entry.recovery = if (verdict == .recovery) @min(entry.recovery +| 1, 2) else 0;
    if (entry.breach == 2 and entry.opened_at_unix_ms == null) entry.opened_at_unix_ms = time;
    if (entry.recovery == 2) entry.opened_at_unix_ms = null;
}

fn build(a: std.mem.Allocator, state: ?*State, target: types.Target, sample: types.Sample) ![]Finding {
    var result: std.ArrayList(Finding) = .empty;
    var next: State = if (state) |prior| prior.* else .{};
    for (0..3 + target.services.len) |i| {
        const key = keyAt(target, i);
        const verdict = verdictAt(sample, i);
        const time = sample.stamp.unix_ms;
        const opened = if (state != null) opened: {
            evaluate(&next.entries[i], verdict, time);
            break :opened next.entries[i].opened_at_unix_ms;
        } else if (verdict == .breach) time else null;
        if (opened) |opened_at| try result.append(a, .{
            .rule_id = key.rule_id,
            .subject = key.subject,
            .evidence_key = try evidenceKey(a, key),
            .opened_at_unix_ms = opened_at,
            .input_evaluable = verdict != .unknown,
        });
    }
    const list = try result.toOwnedSlice(a);
    if (state) |out| out.* = next;
    return list;
}

pub fn instant(a: std.mem.Allocator, target: types.Target, sample: types.Sample) ![]Finding {
    return build(a, null, target, sample);
}

pub fn advance(a: std.mem.Allocator, state: *State, target: types.Target, sample: types.Sample) ![]Finding {
    return build(a, state, target, sample);
}
