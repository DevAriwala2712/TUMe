const std = @import("std");
const types = @import("../health/types.zig");
const config = @import("../health/config.zig");
const findings = @import("../health/findings.zig");
const report = @import("../health/report.zig");

pub const max_events = 128;
pub const max_bytes = 128 * 1024;
pub const age_limit_ms = 24 * 60 * 60 * 1000;
const drift_limit_ms = 5 * 60 * 1000;

pub const Gap = enum { restart, reboot, target_changed, missed_tick, status_publish_failed, history_write_failed };
pub const Kind = enum { opened, observed_open, resolved, coverage_lost, coverage_resumed, gap, context_changed };
pub const Source = enum { tume_sample, watcher, operator_config };

pub const Observation = struct {
    observation_id: []const u8,
    key: []const u8,
    value: ?report.Value,
    reason: ?types.Reason,
};

pub const FindingEvent = struct {
    incident_id: []const u8,
    rule_id: findings.RuleId,
    subject: []const u8,
    first_seen_boot_ms: u64,
    related_episode: ?[]const u8 = null,
    observations: []const Observation,
};

pub const Context = struct {
    boot_id: []const u8,
    target_id: []const u8,
    agent_release: []const u8,
    workload_release: ?[]const u8,
};

pub const ContextField = enum { boot_id, target_id, agent_release, workload_release };
pub const ContextChange = struct {
    previous: ?Context,
    current: Context,
    changed: []const ContextField,
};
pub const Event = struct {
    event_id: []const u8,
    append_order: u64,
    kind: Kind,
    source: Source,
    boot_id: []const u8,
    target_id: []const u8,
    segment_start_boot_ms: u64,
    sampled_at_boot_ms: u64,
    sampled_at_unix_ms: i64,
    journal_monotonic_us: ?u64,
    finding: ?FindingEvent = null,
    gap_reason: ?Gap = null,
    context: ?ContextChange = null,
};

pub const History = struct {
    schema_version: u16 = 1,
    truncated: bool = false,
    generation: u64 = 0,
    context: ?Context = null,
    last_boot_ms: u64 = 0,
    last_unix_ms: i64 = 0,
    segment_start_boot_ms: u64 = 0,
    active: []const ?u64 = &.{},
    events: []const Event = &.{},
};

pub const Input = struct {
    target: types.Target,
    agent_release: []const u8,
    workload_release: ?[]const u8,
    sample: types.Sample,
    before: findings.State,
    after: findings.State,
    prior_evaluable: [7]bool,
    gap: ?Gap = null,
    monotonic_us: ?u64 = null,
};

pub fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn equalOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| return if (b) |right| equal(left, right) else false;
    return b == null;
}

const Hash = struct {
    digest: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),

    fn number(self: *Hash, value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        self.digest.update(&bytes);
    }

    fn part(self: *Hash, value: []const u8) void {
        self.number(value.len);
        self.digest.update(value);
    }

    fn finish(self: *Hash) [32]u8 {
        return std.fmt.bytesToHex(self.digest.finalResult()[0..16], .lower);
    }
};

pub fn targetDigest(target: types.Target) [32]u8 {
    var hash: Hash = .{};
    hash.part("tume-target-v1");
    hash.part(target.mount);
    hash.number(if (target.thermal_zone) |zone| zone else 256);
    hash.number(target.services.len);
    for (target.services) |unit| hash.part(unit);
    return hash.finish();
}

fn incidentId(boot_id: []const u8, target_id: []const u8, segment: u64, key: findings.Key, first: u64) [32]u8 {
    var hash: Hash = .{};
    hash.part("tume-incident-v1");
    hash.part(boot_id);
    hash.part(target_id);
    hash.number(segment);
    hash.part(@tagName(key.rule_id));
    hash.part(key.subject);
    hash.number(first);
    return hash.finish();
}

fn eventId(event: Event) [32]u8 {
    var hash: Hash = .{};
    hash.part("tume-event-v1");
    if (event.finding) |f| {
        hash.part(f.incident_id);
    } else {
        hash.part(event.boot_id);
        hash.part(event.target_id);
        hash.number(event.segment_start_boot_ms);
    }
    hash.number(event.sampled_at_boot_ms);
    hash.part(@tagName(event.kind));
    return hash.finish();
}

fn observationId(event_id: []const u8, key: []const u8) [32]u8 {
    var hash: Hash = .{};
    hash.part("tume-observation-v1");
    hash.part(event_id);
    hash.part(key);
    return hash.finish();
}

pub fn validId(id: []const u8) bool {
    if (id.len != 32) return false;
    for (id) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}

pub fn evaluable(sample: types.Sample) [7]bool {
    var result: [7]bool = @splat(false);
    result[0] = sample.disk_used_bp == .value;
    result[1] = sample.memory == .value;
    result[2] = sample.memory_psi_bp == .value;
    for (sample.services, result[3..][0..sample.services.len]) |service, *available| {
        available.* = service.state == .value and switch (service.state.value) {
            .active, .inactive, .failed => true,
            else => false,
        };
    }
    return result;
}

fn evidence(a: std.mem.Allocator, input: Input, key: findings.Key, i: usize) !report.Observation {
    const sample = input.sample;
    const label = try findings.evidenceKey(a, key);
    return switch (i) {
        0 => report.observation(label, sample.disk_used_bp),
        1 => report.observation(label, sample.memory),
        2 => report.observation(label, sample.memory_psi_bp),
        else => report.observation(label, sample.services[i - 3].state),
    };
}

fn priorOpen(events: []const Event, context: Context, key: findings.Key) ?[]const u8 {
    var i = events.len;
    while (i > 0) {
        i -= 1;
        const event = events[i];
        const item = event.finding orelse continue;
        if (equal(event.target_id, context.target_id) and item.rule_id == key.rule_id and equal(item.subject, key.subject)) {
            return if (event.kind == .resolved) null else item.incident_id;
        }
    }
    return null;
}

fn push(a: std.mem.Allocator, events: *std.ArrayList(Event), base: Event, kind: Kind) !void {
    var entry = base;
    entry.kind = kind;
    entry.append_order = if (events.items.len == 0) base.append_order else events.items[events.items.len - 1].append_order + 1;
    entry.event_id = try a.dupe(u8, &eventId(entry));
    try events.append(a, entry);
}

pub fn appendSample(a: std.mem.Allocator, prior: History, input: Input) !History {
    const stamp = input.sample.stamp;
    if (prior.generation > std.math.maxInt(u64) - max_events) return error.InvalidHistory;
    if (prior.context) |old| {
        if (equal(old.boot_id, &stamp.boot_id) and stamp.boot_ms <= prior.last_boot_ms) return error.StaleHistorySample;
    }
    const retained = prune(prior, stamp);
    const current: Context = .{
        .boot_id = try a.dupe(u8, &stamp.boot_id),
        .target_id = try a.dupe(u8, &targetDigest(input.target)),
        .agent_release = input.agent_release,
        .workload_release = input.workload_release,
    };
    var reason = input.gap;
    if (prior.context) |old| {
        if (!equal(old.boot_id, current.boot_id)) {
            reason = .reboot;
        } else if (!equal(old.target_id, current.target_id)) {
            reason = .target_changed;
        }
    }
    const boundary = reason != null or prior.context == null;
    const segment = if (boundary) stamp.boot_ms else prior.segment_start_boot_ms;
    const count = 3 + input.target.services.len;
    const active = try a.alloc(?u64, count);
    if (boundary) {
        @memset(active, null);
    } else {
        if (prior.active.len != count) return error.InvalidHistory;
        @memcpy(active, prior.active);
    }
    var events: std.ArrayList(Event) = .empty;
    try events.appendSlice(a, retained.events);
    var base: Event = .{
        .event_id = "",
        .append_order = prior.generation + 1,
        .kind = undefined,
        .source = .watcher,
        .boot_id = current.boot_id,
        .target_id = current.target_id,
        .segment_start_boot_ms = segment,
        .sampled_at_boot_ms = stamp.boot_ms,
        .sampled_at_unix_ms = stamp.unix_ms,
        .journal_monotonic_us = input.monotonic_us,
    };
    if (reason) |gap| {
        if (prior.context != null or gap != .restart) {
            base.gap_reason = gap;
            try push(a, &events, base, .gap);
            base.gap_reason = null;
        }
    }
    var fields: [4]ContextField = undefined;
    const changed = changedFields(&fields, prior.context, current);
    if (changed.len != 0) {
        base.context = .{ .previous = prior.context, .current = current, .changed = try a.dupe(ContextField, changed) };
        base.source = changeSource(changed);
        try push(a, &events, base, .context_changed);
        base.context = null;
    }

    const coverage = evaluable(input.sample);
    base.source = .tume_sample;
    for (0..count) |i| {
        const was_open = input.before.entries[i].opened_at_unix_ms != null;
        const is_open = input.after.entries[i].opened_at_unix_ms != null;
        const kind: Kind = if (is_open and boundary and was_open)
            .observed_open
        else if (is_open and !was_open)
            .opened
        else if (is_open and active[i] == null)
            .observed_open
        else if (!is_open and active[i] != null and input.after.entries[i].recovery == 2)
            .resolved
        else if (is_open and coverage[i] != input.prior_evaluable[i])
            if (coverage[i]) .coverage_resumed else .coverage_lost
        else
            continue;
        const first = active[i] orelse stamp.boot_ms;
        active[i] = if (kind == .resolved) null else first;
        const key = findings.keyAt(input.target, i);
        const id = incidentId(current.boot_id, current.target_id, segment, key, first);
        base.finding = .{
            .incident_id = try a.dupe(u8, &id),
            .rule_id = key.rule_id,
            .subject = key.subject,
            .first_seen_boot_ms = first,
            .related_episode = if (kind == .observed_open) priorOpen(retained.events, current, key) else null,
            .observations = &.{},
        };
        try push(a, &events, base, kind);
        const newest = &events.items[events.items.len - 1];
        const observation = try evidence(a, input, key, i);
        const observations = try a.alloc(Observation, 1);
        observations[0] = .{
            .observation_id = try a.dupe(u8, &observationId(newest.event_id, observation.key)),
            .key = observation.key,
            .value = observation.value,
            .reason = observation.reason,
        };
        newest.finding.?.observations = observations;
    }
    if (events.items.len == retained.events.len and retained.events.len == prior.events.len) return prior;
    const generation = if (events.items.len == 0) prior.generation else events.items[events.items.len - 1].append_order;
    const discarded = events.items.len -| max_events;
    return .{
        .context = current,
        .generation = generation,
        .last_boot_ms = stamp.boot_ms,
        .last_unix_ms = stamp.unix_ms,
        .segment_start_boot_ms = segment,
        .active = active,
        .events = events.items[discarded..],
        .truncated = retained.truncated or discarded != 0,
    };
}

fn changedFields(buffer: *[4]ContextField, old: ?Context, current: Context) []const ContextField {
    var count: usize = 0;
    inline for (.{ ContextField.boot_id, ContextField.target_id, ContextField.agent_release, ContextField.workload_release }) |field| {
        const name = @tagName(field);
        const previous: ?[]const u8 = if (old) |context| @field(context, name) else null;
        if (!equalOptional(previous, @field(current, name))) {
            buffer[count] = field;
            count += 1;
        }
    }
    return buffer[0..count];
}

fn changeSource(changed: []const ContextField) Source {
    for (changed) |field| {
        if (field == .target_id or field == .workload_release) return .operator_config;
    }
    return .watcher;
}

pub fn prune(history: History, now: types.Stamp) History {
    var result = history;
    const current_boot_start = @as(i128, now.unix_ms) - now.boot_ms;
    var prior_boots_usable = now.unix_ms > 0;
    if (history.context) |context| {
        if (equal(context.boot_id, &now.boot_id)) {
            const last_boot_start = @as(i128, history.last_unix_ms) - history.last_boot_ms;
            prior_boots_usable = prior_boots_usable and @abs(current_boot_start - last_boot_start) <= drift_limit_ms;
        }
    }
    var older_end: usize = 0;
    var drop: usize = 0;
    var prior_wall: ?i64 = null;
    for (history.events, 0..) |event, i| {
        if (equal(event.boot_id, &now.boot_id)) {
            if (now.boot_ms -| event.sampled_at_boot_ms >= age_limit_ms) drop = i + 1;
        } else {
            older_end = i + 1;
            const wall = event.sampled_at_unix_ms;
            if (wall <= 0 or wall > current_boot_start or (prior_wall != null and wall < prior_wall.?)) prior_boots_usable = false;
            if (@as(i128, now.unix_ms) - wall >= age_limit_ms) drop = i + 1;
            prior_wall = wall;
        }
    }
    if (!prior_boots_usable) drop = @max(drop, older_end);
    result.events = history.events[drop..];
    result.truncated = result.truncated or drop != 0;
    return result;
}

fn validContext(context: Context) bool {
    return types.validBootId(context.boot_id) and validId(context.target_id) and
        config.validRelease(context.agent_release) and
        (context.workload_release == null or config.validRelease(context.workload_release.?));
}

fn validObservation(event: Event, finding: FindingEvent, observation: Observation) bool {
    const expected: []const u8 = switch (finding.rule_id) {
        .disk_capacity_high => "disk.mount",
        .memory_headroom_low => "host.memory",
        .memory_stalled => "host.memory_psi",
        .service_unavailable => service: {
            var buffer: ["service:".len + 128]u8 = undefined;
            const key = std.fmt.bufPrint(&buffer, "service:{s}", .{finding.subject}) catch return false;
            if (!equal(key, observation.key)) return false;
            break :service observation.key;
        },
    };
    if (!equal(expected, observation.key) or !equal(observation.observation_id, &observationId(event.event_id, observation.key))) return false;
    const value = observation.value orelse return observation.reason != null and
        (event.kind == .coverage_lost or event.kind == .observed_open);
    if (observation.reason != null or value.millidegrees_c != null) return false;
    return switch (finding.rule_id) {
        .disk_capacity_high, .memory_stalled => value.total_bytes == null and value.available_bytes == null and
            value.active_state == null and (value.basis_points orelse 10001) <= 10000 and event.kind != .coverage_lost,
        .memory_headroom_low => memory: {
            const total = value.total_bytes orelse return false;
            const available = value.available_bytes orelse return false;
            break :memory value.active_state == null and value.basis_points == null and total > 0 and available <= total and event.kind != .coverage_lost;
        },
        .service_unavailable => service: {
            const active = value.active_state orelse return false;
            const transitional = active == .activating or active == .deactivating or active == .reloading;
            if (transitional and event.kind != .coverage_lost and event.kind != .observed_open) return false;
            if (!transitional and event.kind == .coverage_lost) return false;
            break :service value.total_bytes == null and value.available_bytes == null and value.basis_points == null;
        },
    };
}

fn validEvent(event: Event) bool {
    if (!types.validBootId(event.boot_id) or !validId(event.target_id) or event.append_order == 0 or
        event.segment_start_boot_ms > event.sampled_at_boot_ms or !equal(event.event_id, &eventId(event))) return false;
    if (event.journal_monotonic_us) |monotonic| {
        if (monotonic / 1000 > event.sampled_at_boot_ms +| 1) return false;
    }
    switch (event.kind) {
        .gap => return event.source == .watcher and event.gap_reason != null and event.finding == null and event.context == null,
        .context_changed => {
            const change = event.context orelse return false;
            var fields: [4]ContextField = undefined;
            const changed = changedFields(&fields, change.previous, change.current);
            return changed.len != 0 and std.mem.eql(ContextField, change.changed, changed) and
                event.source == changeSource(changed) and event.gap_reason == null and event.finding == null and
                validContext(change.current) and equal(change.current.boot_id, event.boot_id) and equal(change.current.target_id, event.target_id) and
                (change.previous == null or validContext(change.previous.?));
        },
        else => {},
    }
    const item = event.finding orelse return false;
    if (event.source != .tume_sample or event.context != null or event.gap_reason != null) return false;
    if (item.first_seen_boot_ms < event.segment_start_boot_ms or item.first_seen_boot_ms > event.sampled_at_boot_ms) return false;
    if ((event.kind == .opened or event.kind == .observed_open) != (item.first_seen_boot_ms == event.sampled_at_boot_ms)) return false;
    if (item.related_episode) |related| {
        if (event.kind != .observed_open or !validId(related) or equal(related, item.incident_id)) return false;
    }
    const valid_subject = switch (item.rule_id) {
        .disk_capacity_high => config.validPath(item.subject) and std.unicode.utf8ValidateSlice(item.subject),
        .memory_stalled, .memory_headroom_low => equal(item.subject, "host"),
        .service_unavailable => config.validUnit(item.subject),
    };
    if (!valid_subject) return false;
    const key: findings.Key = .{ .rule_id = item.rule_id, .subject = item.subject };
    if (!equal(item.incident_id, &incidentId(event.boot_id, event.target_id, event.segment_start_boot_ms, key, item.first_seen_boot_ms))) return false;
    if (item.observations.len != 1 or !validObservation(event, item, item.observations[0])) return false;
    if (event.kind != .opened and event.kind != .resolved) return true;
    const value = item.observations[0].value.?;
    const verdict = switch (item.rule_id) {
        .disk_capacity_high => findings.diskVerdict(value.basis_points.?),
        .memory_headroom_low => findings.memoryVerdict(value.available_bytes.?),
        .memory_stalled => findings.stallVerdict(value.basis_points.?),
        .service_unavailable => findings.serviceVerdict(value.active_state.?),
    };
    return verdict == (if (event.kind == .opened) findings.Verdict.breach else .recovery);
}

pub fn validate(history: History, now: ?types.Stamp) bool {
    const context = history.context orelse return false;
    if (!validContext(context) or history.generation == 0 or history.segment_start_boot_ms > history.last_boot_ms or
        history.events.len > max_events or history.active.len < 3 or history.active.len > 7) return false;
    if (now) |current| {
        if (equal(context.boot_id, &current.boot_id) and history.last_boot_ms > current.boot_ms) return false;
    }
    for (history.active) |maybe_first| {
        if (maybe_first) |first| {
            if (first < history.segment_start_boot_ms or first > history.last_boot_ms) return false;
        }
    }
    var previous: ?Event = null;
    for (history.events, 0..) |event, i| {
        if (!validEvent(event)) return false;
        if (now) |current| {
            if (equal(event.boot_id, &current.boot_id) and event.sampled_at_boot_ms > current.boot_ms) return false;
        }
        if (previous) |last| {
            if (last.append_order == std.math.maxInt(u64) or event.append_order != last.append_order + 1) return false;
            if (equal(last.boot_id, event.boot_id)) {
                if (event.sampled_at_boot_ms < last.sampled_at_boot_ms or event.segment_start_boot_ms < last.segment_start_boot_ms) return false;
                if (event.sampled_at_boot_ms == last.sampled_at_boot_ms and
                    (event.sampled_at_unix_ms != last.sampled_at_unix_ms or event.segment_start_boot_ms != last.segment_start_boot_ms or
                        !equal(event.target_id, last.target_id) or event.journal_monotonic_us != last.journal_monotonic_us)) return false;
            } else {
                for (history.events[0..i]) |old| if (equal(old.boot_id, event.boot_id)) return false;
            }
        }
        for (history.events[0..i]) |old| {
            if (equal(old.event_id, event.event_id)) return false;
            if (old.finding != null and event.finding != null and equal(old.finding.?.incident_id, event.finding.?.incident_id)) {
                if (old.kind == .resolved or event.kind == .opened or event.kind == .observed_open) return false;
                if (old.sampled_at_boot_ms == event.sampled_at_boot_ms) return false;
            }
        }
        previous = event;
    }
    if (previous) |last| {
        if (last.append_order != history.generation) return false;
        if (equal(last.boot_id, context.boot_id) and
            (last.sampled_at_boot_ms > history.last_boot_ms or last.segment_start_boot_ms > history.segment_start_boot_ms or
                !equal(last.target_id, context.target_id))) return false;
    }
    return true;
}
