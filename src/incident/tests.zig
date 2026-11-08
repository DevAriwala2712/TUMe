const std = @import("std");
const health_types = @import("../health/types.zig");
const findings = @import("../health/findings.zig");
const config = @import("../health/config.zig");
const timeline = @import("timeline.zig");

const boot = "11111111-2222-3333-4444-555555555555";
const target: health_types.Target = .{ .mount = "/", .services = &.{"gateway.service"}, .thermal_zone = null };
const fixture_service = [_]health_types.Service{
    .{ .unit = "gateway.service", .state = .{ .value = .failed } },
    .{ .unit = "gateway.service", .state = .{ .value = .activating } },
    .{ .unit = "gateway.service", .state = .{ .value = .active } },
};

fn sample(time: u64, mode: enum { breach, missing, healthy }) health_types.Sample {
    return .{
        .stamp = .{ .boot_id = boot.*, .unix_ms = 1_760_000_000_000 + @as(i64, @intCast(time)), .boot_ms = time },
        .collection_ms = 4,
        .memory = switch (mode) {
            .breach => .{ .value = .{ .total_bytes = 1 << 30, .available_bytes = 64 << 20 } },
            .healthy => .{ .value = .{ .total_bytes = 1 << 30, .available_bytes = 256 << 20 } },
            .missing => .{ .reason = .unavailable },
        },
        .memory_psi_bp = switch (mode) {
            .breach => .{ .value = 1200 },
            .healthy => .{ .value = 100 },
            .missing => .{ .reason = .unavailable },
        },
        .disk_used_bp = switch (mode) {
            .breach => .{ .value = 9300 },
            .healthy => .{ .value = 8000 },
            .missing => .{ .reason = .denied },
        },
        .cpu_psi_bp = .{ .value = 100 },
        .services = fixture_service[@intFromEnum(mode)..][0..1],
        .temperature_mc = null,
    };
}

test "incident config is explicit and rejects noncanonical release labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const legacy = try config.parse(a, "{\"mount\":\"/\"}");
    try std.testing.expect(!legacy.history.enabled);
    const configured = try config.parse(a, "{\"mount\":\"/\",\"history\":{\"enabled\":true,\"journal_metadata\":true,\"workload_release\":\"1.2.65535\"}}");
    try std.testing.expect(configured.history.journal_metadata);
    try std.testing.expectEqualStrings("1.2.65535", configured.history.workload_release.?);
    const invalid = [_][]const u8{
        "{\"mount\":\"/\",\"history\":{\"journal_metadata\":true}}",
        "{\"mount\":\"/\",\"history\":{\"workload_release\":\"1.2.3\"}}",
        "{\"mount\":\"/\",\"history\":{\"enabled\":true,\"workload_release\":\"1.2.03\"}}",
        "{\"mount\":\"/\",\"history\":{\"enabled\":true,\"workload_release\":\"1.2.65536\"}}",
        "{\"mount\":\"/\",\"history\":{\"enabled\":true,\"enabled\":false}}",
        "{\"mount\":\"/\",\"history\":{\"enabled\":true,\"other\":1}}",
    };
    for (invalid) |json| try std.testing.expectError(error.InvalidConfig, config.parse(a, json));
}

fn replay(a: std.mem.Allocator, history: timeline.History, before: *findings.State, current: health_types.Sample, previous: ?health_types.Sample, gap: ?timeline.Gap) !timeline.History {
    const prior = before.*;
    _ = try findings.advance(a, before, target, current);
    return timeline.appendSample(a, history, .{
        .target = target,
        .agent_release = "1.0.0",
        .workload_release = null,
        .sample = current,
        .before = prior,
        .after = before.*,
        .prior_evaluable = if (previous) |p| timeline.evaluable(p) else @splat(false),
        .gap = gap,
    });
}

test "incident replay explicitly opens, loses coverage, regains it and resolves every rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var confirmed: findings.State = .{};
    var history: timeline.History = .{};
    const inputs = [_]health_types.Sample{
        sample(15000, .breach),  sample(30000, .breach),  sample(45000, .missing),
        sample(60000, .healthy), sample(75000, .healthy),
    };
    for (inputs, 0..) |input, i| history = try replay(a, history, &confirmed, input, if (i == 0) null else inputs[i - 1], null);
    try std.testing.expectEqual(@as(usize, 17), history.events.len);
    try std.testing.expectEqual(.context_changed, history.events[0].kind);
    for (0..4) |i| {
        const opened = history.events[1 + i];
        try std.testing.expectEqual(.opened, opened.kind);
        try std.testing.expectEqual(.coverage_lost, history.events[5 + i].kind);
        try std.testing.expectEqual(.coverage_resumed, history.events[9 + i].kind);
        const resolved = history.events[13 + i];
        try std.testing.expectEqual(.resolved, resolved.kind);
        try std.testing.expectEqualStrings(opened.finding.?.incident_id, resolved.finding.?.incident_id);
        try std.testing.expectEqual(@as(usize, 1), resolved.finding.?.observations.len);
    }
    try std.testing.expectEqual(.activating, history.events[8].finding.?.observations[0].value.?.active_state.?);
}

test "incident replay links a fresh episode across restart without resolving the old one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var confirmed: findings.State = .{};
    const first = sample(15000, .breach);
    const second = sample(30000, .breach);
    const old = try replay(a, try replay(a, .{}, &confirmed, first, null, null), &confirmed, second, first, null);
    var retried = confirmed;
    const after = try replay(a, old, &confirmed, sample(45000, .breach), null, .restart);
    const repeat = try replay(a, old, &retried, sample(45000, .breach), null, .restart);
    try std.testing.expectEqual(.gap, after.events[5].kind);
    const newer = after.events[6];
    try std.testing.expectEqual(.observed_open, newer.kind);
    try std.testing.expectEqualStrings(old.events[1].finding.?.incident_id, newer.finding.?.related_episode.?);
    try std.testing.expect(!std.mem.eql(u8, old.events[1].finding.?.incident_id, newer.finding.?.incident_id));
    try std.testing.expectEqualStrings(newer.event_id, repeat.events[6].event_id);
    try std.testing.expectEqualStrings(newer.finding.?.observations[0].observation_id, repeat.events[6].finding.?.observations[0].observation_id);
}

const history_store = @import("store.zig");
const state = @import("../health/state.zig");

test "incident history retains old complete bytes on file-sync failure and new complete bytes on directory-sync failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const first = sample(15000, .breach);
    const second = sample(30000, .breach);
    var confirmed: findings.State = .{};
    const prior = try replay(a, .{}, &confirmed, first, null, null);
    const current = try replay(a, prior, &confirmed, second, first, null);
    const dir = temp.dir.fd;

    try history_store.persist(a, dir, prior, .{ .sync = skipSync });
    try std.testing.expectError(error.TestIoFailure, history_store.persist(a, dir, current, .{ .sync = failFileSync }));
    const still_old = try history_store.read(a, dir, second.stamp);
    try std.testing.expectEqual(@as(usize, 1), still_old.events.len);

    try std.testing.expectError(error.UncertainDurability, history_store.persist(a, dir, current, .{ .sync = failDirectorySync }));
    const complete_new = try history_store.read(a, dir, second.stamp);
    try std.testing.expectEqual(@as(usize, 5), complete_new.events.len);
    try std.testing.expectEqual(.opened, complete_new.events[4].kind);
    try std.testing.expectError(error.FileNotFound, temp.dir.openFile(".history.tmp", .{}));
}

fn skipSync(_: std.posix.fd_t, _: state.SyncPhase) !void {}
fn failFileSync(_: std.posix.fd_t, phase: state.SyncPhase) !void {
    if (phase == .file) return error.TestIoFailure;
}
fn failDirectorySync(_: std.posix.fd_t, phase: state.SyncPhase) !void {
    if (phase == .directory) return error.TestIoFailure;
}

test "incident history rejects unsafe files, unknown versions and reordered events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = sample(15000, .breach);
    const second = sample(30000, .breach);
    var confirmed: findings.State = .{};
    const prior = try replay(a, .{}, &confirmed, first, null, null);
    var current = try replay(a, prior, &confirmed, second, first, null);
    const events = try a.dupe(timeline.Event, current.events);
    std.mem.swap(timeline.Event, &events[1], &events[2]);
    current.events = events;
    const report = @import("../health/report.zig");
    try std.testing.expectError(error.InvalidHistory, history_store.decode(a, try report.encodeJson(a, current, timeline.max_bytes), second.stamp));
    try std.testing.expectError(error.IncompatibleHistory, history_store.decode(a, "{\"schema_version\":2}", second.stamp));

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile("history.json", .{ .mode = 0o644 });
    file.close();
    try std.testing.expectError(error.UnsafeStateFile, history_store.read(a, temp.dir.fd, second.stamp));
}

const incident_cli = @import("cli.zig");
const checks = @import("checks.zig");

test "incident detail leads with missing coverage when status is stale and cites a retained observation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var confirmed: findings.State = .{};
    const first = sample(15000, .breach);
    const second = sample(30000, .breach);
    const prior = try replay(a, .{}, &confirmed, first, null, null);
    const opened = try replay(a, prior, &confirmed, second, first, null);
    const item = opened.events[4].finding.?;
    const response = try incident_cli.response(a, opened, .{ .freshness = .stale }, target, item.incident_id, null);
    try std.testing.expectEqual(@as(u8, 0), response.code);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
    const detail = value.object.get("detail").?.object;
    try std.testing.expectEqualStrings("unknown", detail.get("current").?.string);
    const next = detail.get("next_checks").?.array.items;
    try std.testing.expectEqualStrings("verify_observation_coverage", next[0].object.get("code").?.string);
    try std.testing.expectEqualStrings("verify_unit_state", next[1].object.get("code").?.string);
    try std.testing.expectEqualStrings(item.observations[0].observation_id, next[1].object.get("evidence_id").?.string);
    try std.testing.expect(next[1].object.get("historical").?.bool);
}

test "incident checks identify each rule by its operator action" {
    try std.testing.expectEqualStrings("inspect_memory_consumers", checks.nextCheck(.memory_headroom_low));
    try std.testing.expectEqualStrings("review_pressure_window", checks.nextCheck(.memory_stalled));
    try std.testing.expectEqualStrings("inspect_mount_usage", checks.nextCheck(.disk_capacity_high));
    try std.testing.expectEqualStrings("verify_unit_state", checks.nextCheck(.service_unavailable));
}

const journal = @import("journal.zig");

test "journal projection keeps only scoped metadata and deduplicates cursors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const scope: journal.Scope = .{
        .boot_id = boot,
        .unit = "gateway.service",
        .monotonic_us = 500_000_000,
        .unix_us = 1_760_000_000_000_000,
    };
    const fixture =
        \\{"_BOOT_ID":"11111111222233334444555555555555","_SYSTEMD_UNIT":"gateway.service","__MONOTONIC_TIMESTAMP":"500000000","__REALTIME_TIMESTAMP":"1760000000000000","__CURSOR":"private-a","MESSAGE":"Bearer secret-test","_CMDLINE":"sh -c secret-test","ENV":"secret-test"}
        \\{"_BOOT_ID":"11111111222233334444555555555555","UNIT":"gateway.service","_PID":"1","__MONOTONIC_TIMESTAMP":"499000000","__REALTIME_TIMESTAMP":"1759999999000000","__CURSOR":"private-b"}
        \\{"_BOOT_ID":"11111111222233334444555555555555","_SYSTEMD_UNIT":"gateway.service","__MONOTONIC_TIMESTAMP":"500000000","__REALTIME_TIMESTAMP":"1760000000000000","__CURSOR":"private-a"}
        \\{"_BOOT_ID":"11111111222233334444555555555555","UNIT":"gateway.service","_PID":"33","__MONOTONIC_TIMESTAMP":"499000000","__REALTIME_TIMESTAMP":"1759999999000000","__CURSOR":"private-c"}
        \\{"_BOOT_ID":"11111111222233334444555555555555","_SYSTEMD_UNIT":"gateway.service","__MONOTONIC_TIMESTAMP":"199000000","__REALTIME_TIMESTAMP":"1759999999000000","__CURSOR":"private-d"}
        \\{"_BOOT_ID":"11111111222233334444555555555555","_SYSTEMD_UNIT":"gateway.service","__MONOTONIC_TIMESTAMP":"501000000","__REALTIME_TIMESTAMP":"1759999800000000","__CURSOR":"private-e"}
    ;
    const selected = try journal.project(a, scope, fixture);
    try std.testing.expectEqual(.limited, selected.coverage);
    try std.testing.expectEqual(@as(usize, 2), selected.rows.len);
    try std.testing.expectEqual(.manager_event, selected.rows[0].kind);
    try std.testing.expectEqual(.unit_log_event, selected.rows[1].kind);
    const serialized = try std.json.Stringify.valueAlloc(a, selected, .{});
    for ([_][]const u8{ "secret-test", "private-", "MESSAGE", "_CMDLINE" }) |unwanted| {
        try std.testing.expect(std.mem.indexOf(u8, serialized, unwanted) == null);
    }
    try std.testing.expectEqual(.invalid, (try journal.project(a, scope, "{not-json}")).coverage);
    try std.testing.expectEqual(.empty_or_inaccessible, (try journal.project(a, scope, "")).coverage);
}

test "history applies count and boot-relative age limits, including on a stopped-watcher read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var confirmed: findings.State = .{};
    var history: timeline.History = .{};
    var previous: ?health_types.Sample = null;
    for (1..161) |tick| {
        const current = if ((tick - 1) % 4 < 2) sample(tick * 15000, .breach) else sample(tick * 15000, .healthy);
        history = try replay(a, history, &confirmed, current, previous, null);
        previous = current;
    }
    try std.testing.expectEqual(@as(usize, 128), history.events.len);
    try std.testing.expect(history.truncated);
    try std.testing.expect(timeline.validate(history, previous.?.stamp));
    var later = previous.?.stamp;
    later.boot_ms += timeline.age_limit_ms;
    // Even a backwards display clock cannot retain expired same-boot evidence.
    later.unix_ms -= 5000;
    const pruned = timeline.prune(history, later);
    try std.testing.expectEqual(@as(usize, 0), pruned.events.len);
    try std.testing.expect(pruned.truncated);
}

test "history retains chronological previous boot evidence and removes it after clock drift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var confirmed: findings.State = .{};
    const first = sample(15000, .breach);
    const second = sample(30000, .breach);
    const prior = try replay(a, .{}, &confirmed, first, null, null);
    const opened = try replay(a, prior, &confirmed, second, first, null);
    var current = sample(15000, .healthy);
    current.stamp.boot_id[0] = '2';
    current.stamp.unix_ms += 60000;
    confirmed = .{};
    const after_boot = try replay(a, opened, &confirmed, current, null, .restart);
    try std.testing.expectEqual(.reboot, after_boot.events[5].gap_reason.?);
    try std.testing.expectEqual(.context_changed, after_boot.events[6].kind);
    try std.testing.expectEqualStrings(boot, after_boot.events[6].context.?.previous.?.boot_id);
    try std.testing.expectEqualSlices(timeline.ContextField, &.{.boot_id}, after_boot.events[6].context.?.changed);
    try std.testing.expect(timeline.validate(after_boot, current.stamp));
    var drift = current.stamp;
    drift.boot_ms += 15000;
    drift.unix_ms += 360000;
    const pruned = timeline.prune(after_boot, drift);
    try std.testing.expectEqual(@as(usize, 2), pruned.events.len);
    try std.testing.expect(pruned.truncated);
    try std.testing.expectEqual(.gap, pruned.events[0].kind);
}

test "twelve labeled rule and coverage cases show the expected first incident check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var confirmed: findings.State = .{};
    const first = sample(15000, .breach);
    const second = sample(30000, .breach);
    const third = sample(45000, .missing);
    const prior = try replay(a, .{}, &confirmed, first, null, null);
    const opened = try replay(a, prior, &confirmed, second, first, null);
    const open_findings = try findings.instant(a, target, second);
    const latest = @import("../health/report.zig");
    const open_wire = try latest.toWire(a, .{ .sample = second, .target = target, .mode = .watch, .findings = open_findings });
    const lost = try replay(a, opened, &confirmed, third, second, null);
    const missing_findings = try findings.advance(a, &confirmed, target, third);
    const missing_wire = try latest.toWire(a, .{ .sample = third, .target = target, .mode = .watch, .findings = missing_findings });

    const expected_checks = [_][]const u8{ "inspect_mount_usage", "inspect_memory_consumers", "review_pressure_window", "verify_unit_state" };
    const coverage_cases = [_]struct {
        history: timeline.History,
        latest: state.Loaded,
        historical: bool,
    }{
        .{ .history = opened, .latest = .{ .freshness = .fresh, .report = open_wire }, .historical = false },
        .{ .history = opened, .latest = .{ .freshness = .stale }, .historical = true },
        .{ .history = lost, .latest = .{ .freshness = .fresh, .report = missing_wire }, .historical = true },
    };
    for (coverage_cases) |scenario| {
        for (expected_checks, 0..) |expected, i| {
            const id = opened.events[i + 1].finding.?.incident_id;
            const result = try incident_cli.response(a, scenario.history, scenario.latest, target, id, null);
            const value = try std.json.parseFromSliceLeaky(std.json.Value, a, result.body, .{});
            const ordered = value.object.get("detail").?.object.get("next_checks").?.array.items;
            if (scenario.historical) {
                try std.testing.expectEqualStrings("verify_observation_coverage", ordered[0].object.get("code").?.string);
            }
            const suggested = ordered[@intFromBool(scenario.historical)].object;
            try std.testing.expectEqualStrings(expected, suggested.get("code").?.string);
            try std.testing.expectEqual(scenario.historical, suggested.get("historical").?.bool);
        }
    }
}

test {
    _ = @import("writer.zig");
}

test "incident history rejects typed evidence that contradicts a transition" {
    const report = @import("../health/report.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var confirmed: findings.State = .{};
    var history: timeline.History = .{};
    const inputs = [_]health_types.Sample{
        sample(15000, .breach),  sample(30000, .breach),
        sample(45000, .healthy), sample(60000, .healthy),
    };
    for (inputs, 0..) |input, i| {
        history = try replay(a, history, &confirmed, input, if (i == 0) null else inputs[i - 1], null);
    }
    const now = inputs[inputs.len - 1].stamp;
    _ = try history_store.decode(a, try report.encodeJson(a, history, timeline.max_bytes), now);
    const edits = [_]struct { kind: timeline.Kind, rule: findings.RuleId, value: report.Value }{
        .{ .kind = .opened, .rule = .disk_capacity_high, .value = .{ .basis_points = 0 } },
        .{ .kind = .resolved, .rule = .service_unavailable, .value = .{ .active_state = .failed } },
    };
    for (edits) |edit| {
        var corrupt = history;
        const events = try a.dupe(timeline.Event, history.events);
        corrupt.events = events;
        for (events) |*event| {
            if (event.kind != edit.kind or event.finding.?.rule_id != edit.rule) continue;
            const observations = try a.dupe(timeline.Observation, event.finding.?.observations);
            observations[0].value = edit.value;
            event.finding.?.observations = observations;
        }
        try std.testing.expectError(error.InvalidHistory, history_store.decode(a, try report.encodeJson(a, corrupt, timeline.max_bytes), now));
    }
}
