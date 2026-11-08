const std = @import("std");
const builtin = @import("builtin");
const health = @import("../health/cli.zig");
const collect = @import("../health/collect.zig");
const findings = @import("../health/findings.zig");
const state = @import("../health/state.zig");
const types = @import("../health/types.zig");
const report = @import("../health/report.zig");
const checks = @import("checks.zig");
const store = @import("store.zig");
const timeline = @import("timeline.zig");
const journal_metadata = @import("journal.zig");

pub const HistoryStatus = enum { available, empty, invalid, incompatible, unavailable };
const Current = enum { present, absent, unknown };
const EpisodeStatus = enum { last_observed_open, resolved };
const Summary = struct {
    incident_id: []const u8,
    rule_id: findings.RuleId,
    subject: []const u8,
    status: EpisodeStatus,
    partial: bool,
    current: Current,
    boot_id: []const u8,
    last_observed_at_boot_ms: u64,
    last_observed_at_unix_ms: i64,
};

const Detail = struct {
    incident: Summary,
    current: Current,
    next_checks: []const checks.Check,
    events: []const timeline.Event,
    related_episode: ?[]const u8,
    related_episode_unavailable: bool,
    reobserved_as: ?[]const u8,
    journal: ?journal_metadata.Result,
};

const Wire = struct {
    schema_version: u16 = 1,
    kind: enum { list, detail },
    history_status: HistoryStatus,
    latest_status_freshness: state.Freshness,
    latest_status_sampled_at_boot_ms: ?u64 = null,
    latest_status_sampled_at_unix_ms: ?i64 = null,
    truncated: bool,
    incidents: ?[]const Summary = null,
    detail: ?Detail = null,
};
pub const Response = struct { code: u8, body: []const u8 };

const Options = struct { config_path: []const u8, id: ?[]const u8, journal: bool };

fn arguments(args: []const []const u8) !Options {
    if (args.len < 2 or !timeline.equal(args[0], "--config")) return error.InvalidUsage;
    var options: Options = .{ .config_path = args[1], .id = null, .journal = false };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (timeline.equal(args[i], "--id") and options.id == null and i + 1 < args.len and timeline.validId(args[i + 1])) {
            i += 1;
            options.id = args[i];
        } else if (timeline.equal(args[i], "--journal") and !options.journal) {
            options.journal = true;
        } else {
            return error.InvalidUsage;
        }
    }
    if (options.journal and options.id == null) return error.InvalidUsage;
    return options;
}

fn matches(event: timeline.Event, id: []const u8) bool {
    const item = event.finding orelse return false;
    return timeline.equal(item.incident_id, id);
}

fn opening(event: timeline.Event) bool {
    return event.kind == .opened or event.kind == .observed_open;
}

fn latestFor(events: []const timeline.Event, id: []const u8) ?timeline.Event {
    var index = events.len;
    while (index > 0) {
        index -= 1;
        if (matches(events[index], id)) return events[index];
    }
    return null;
}

fn openingFor(events: []const timeline.Event, id: []const u8) ?timeline.Event {
    for (events) |event| if (opening(event) and matches(event, id)) return event;
    return null;
}

fn scopeObservation(loaded: state.Loaded, target: types.Target, event: timeline.Event) struct { current: Current, known: bool } {
    if (loaded.freshness != .fresh or !timeline.equal(event.target_id, &timeline.targetDigest(target)))
        return .{ .current = .unknown, .known = false };
    const wire = loaded.report orelse return .{ .current = .unknown, .known = false };
    const item = event.finding.?;
    for (wire.findings) |finding| {
        if (finding.rule_id == item.rule_id and timeline.equal(finding.subject, item.subject))
            return .{ .current = .present, .known = finding.input_evaluable };
    }
    for (wire.observations) |observation| {
        if (timeline.equal(observation.key, item.observations[0].key)) {
            const value = observation.value orelse return .{ .current = .absent, .known = false };
            const known = if (value.active_state) |active| switch (active) {
                .active, .inactive, .failed => true,
                else => false,
            } else true;
            return .{ .current = .absent, .known = known };
        }
    }
    return .{ .current = .absent, .known = false };
}

fn summarize(events: []const timeline.Event, loaded: state.Loaded, target: types.Target, latest: timeline.Event) Summary {
    const item = latest.finding.?;
    return .{
        .incident_id = item.incident_id,
        .rule_id = item.rule_id,
        .subject = item.subject,
        .status = if (latest.kind == .resolved) .resolved else .last_observed_open,
        .partial = openingFor(events, item.incident_id) == null,
        .current = scopeObservation(loaded, target, latest).current,
        .boot_id = latest.boot_id,
        .last_observed_at_boot_ms = latest.sampled_at_boot_ms,
        .last_observed_at_unix_ms = latest.sampled_at_unix_ms,
    };
}

pub fn response(a: std.mem.Allocator, history: timeline.History, loaded: state.Loaded, target: types.Target, id: ?[]const u8, journal: ?journal_metadata.Result) !Response {
    var wire: Wire = .{
        .kind = if (id == null) .list else .detail,
        .history_status = .empty,
        .latest_status_freshness = loaded.freshness,
        .latest_status_sampled_at_boot_ms = if (loaded.report) |current| current.sampled_at_boot_ms else null,
        .latest_status_sampled_at_unix_ms = if (loaded.report) |current| current.sampled_at_unix_ms else null,
        .truncated = history.truncated,
    };
    var summaries: [20]Summary = undefined;
    var events: [16]timeline.Event = undefined;
    var suggestions: [3]checks.Check = undefined;
    var code: u8 = 0;
    if (id) |selected| {
        if (latestFor(history.events, selected)) |last| {
            wire.history_status = .available;
            const incident = summarize(history.events, loaded, target, last);
            const item = last.finding.?;
            const first = openingFor(history.events, selected);
            const related = if (first) |event| event.finding.?.related_episode else null;
            const related_retained = if (related) |candidate| latestFor(history.events, candidate) != null else false;
            var reobserved_as: ?[]const u8 = null;
            var closing_gap: ?u64 = null;
            var initial_context: ?u64 = null;
            for (history.events) |event| {
                if (event.append_order < (if (first) |opened| opened.append_order else last.append_order) and
                    event.kind == .context_changed and timeline.equal(event.boot_id, last.boot_id) and timeline.equal(event.target_id, last.target_id))
                    initial_context = event.append_order;
                if (event.append_order <= last.append_order) continue;
                if (event.kind == .gap and closing_gap == null and incident.status != .resolved)
                    closing_gap = event.append_order;
                if (event.finding) |candidate| {
                    if (candidate.related_episode != null and timeline.equal(candidate.related_episode.?, selected) and reobserved_as == null)
                        reobserved_as = candidate.incident_id;
                }
            }
            var start = events.len;
            var index = history.events.len;
            while (index > 0) {
                index -= 1;
                const event = history.events[index];
                const in_segment = timeline.equal(event.boot_id, last.boot_id) and
                    timeline.equal(event.target_id, last.target_id) and event.segment_start_boot_ms == last.segment_start_boot_ms;
                const context_during = event.kind == .context_changed and in_segment and
                    event.append_order <= (closing_gap orelse if (incident.status == .resolved) last.append_order else std.math.maxInt(u64));
                if (matches(event, selected) or closing_gap == event.append_order or initial_context == event.append_order or context_during) {
                    if (start == 0) {
                        wire.truncated = true;
                        break;
                    }
                    start -= 1;
                    events[start] = event;
                }
            }
            // Recent context markers may outnumber finding events. Always keep the
            // latest finding observation so checks point to included evidence.
            var latest_included = false;
            for (events[start..]) |event| {
                if (event.append_order == last.append_order) latest_included = true;
            }
            if (!latest_included) {
                start -|= 1;
                events[start] = last;
                wire.truncated = true;
            }
            for (events[start..]) |*event| {
                if (event.finding) |*finding| {
                    if (finding.related_episode) |candidate| {
                        if (latestFor(history.events, candidate) == null) finding.related_episode = null;
                    }
                }
            }
            const scope = scopeObservation(loaded, target, last);
            const offset: usize = @intFromBool(!scope.known);
            if (!scope.known) suggestions[0] = checks.missing_coverage;
            suggestions[offset..][0..2].* = checks.forRule(item.rule_id);
            for (suggestions[0 .. offset + 2]) |*check| {
                check.evidence_id = item.observations[0].observation_id;
                check.historical = !scope.known;
            }
            wire.detail = .{
                .incident = incident,
                .current = scope.current,
                .next_checks = suggestions[0 .. offset + 2],
                .events = events[start..],
                .related_episode = if (related_retained) related else null,
                .related_episode_unavailable = related != null and !related_retained,
                .reobserved_as = reobserved_as,
                .journal = journal,
            };
        } else {
            code = 3;
            for (history.events) |event| {
                if (event.finding != null) {
                    wire.history_status = .available;
                    break;
                }
            }
        }
    } else {
        var index = history.events.len;
        var count: usize = 0;
        while (index > 0) {
            index -= 1;
            const event = history.events[index];
            const item = event.finding orelse continue;
            if (latestFor(history.events[index + 1 ..], item.incident_id) != null) continue;
            if (count == summaries.len) {
                wire.truncated = true;
                break;
            }
            summaries[count] = summarize(history.events, loaded, target, event);
            count += 1;
        }
        wire.incidents = summaries[0..count];
        if (count != 0) wire.history_status = .available;
    }
    return .{ .code = code, .body = try report.encodeJson(a, wire, report.status_limit) };
}

fn errorResponse(a: std.mem.Allocator, loaded: state.Loaded, id: ?[]const u8, err: anyerror) !Response {
    return .{ .code = 3, .body = try report.encodeJson(a, Wire{
        .kind = if (id == null) .list else .detail,
        .history_status = switch (err) {
            error.InvalidHistory => .invalid,
            error.IncompatibleHistory => .incompatible,
            else => .unavailable,
        },
        .latest_status_freshness = loaded.freshness,
        .latest_status_sampled_at_boot_ms = if (loaded.report) |current| current.sampled_at_boot_ms else null,
        .latest_status_sampled_at_unix_ms = if (loaded.report) |current| current.sampled_at_unix_ms else null,
        .truncated = false,
    }, report.status_limit) };
}

fn readResponse(a: std.mem.Allocator, config: types.Config, options: Options) !Response {
    var dir = state.Store.open(config.state_dir.?) catch |err| return errorResponse(a, .{
        .freshness = if (err == error.FileNotFound) .absent else .unavailable,
    }, options.id, err);
    defer dir.close();
    const loaded = dir.load(a, config.target, null);
    const saved = store.read(a, dir.dir, null) catch |err| return errorResponse(a, loaded, options.id, err);
    // Take the reader's time after opening a complete version. A writer may
    // publish a new version concurrently with the T1 status read.
    const now = collect.stamp() catch |err| return errorResponse(a, loaded, options.id, err);
    if (saved.context != null and !timeline.validate(saved, now)) return errorResponse(a, loaded, options.id, error.InvalidHistory);
    const history = timeline.prune(saved, now);
    const journal = if (options.journal) try journalFor(a, history, config.target, options.id.?) else null;
    return response(a, history, loaded, config.target, options.id, journal);
}

fn journalFor(a: std.mem.Allocator, history: timeline.History, target: types.Target, id: []const u8) !?journal_metadata.Result {
    const last = latestFor(history.events, id) orelse return null;
    const item = last.finding.?;
    if (item.rule_id != .service_unavailable) return .{ .coverage = .out_of_scope };
    for (target.services) |unit| {
        if (timeline.equal(unit, item.subject)) break;
    } else return .{ .coverage = .out_of_scope };
    const first = openingFor(history.events, id) orelse return .{ .coverage = .unavailable };
    const monotonic = first.journal_monotonic_us orelse return .{ .coverage = .unavailable };
    if (first.sampled_at_unix_ms <= 0) return .{ .coverage = .unavailable };
    const unix_us = std.math.mul(u64, @intCast(first.sampled_at_unix_ms), std.time.us_per_ms) catch return .{ .coverage = .unavailable };
    return try journal_metadata.query(a, .{
        .boot_id = first.boot_id,
        .unit = item.subject,
        .monotonic_us = monotonic,
        .unix_us = unix_us,
    });
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    if (builtin.os.tag != .linux) {
        std.debug.print("health incidents requires Linux\n", .{});
        return 2;
    }
    const options = arguments(args) catch {
        std.debug.print("Usage: nanoclaw-next health incidents --config PATH [--id ID [--journal]]\n", .{});
        return 2;
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = health.readConfig(a, options.config_path) catch |err| {
        std.debug.print("health config: {s}\n", .{@errorName(err)});
        return 2;
    };
    if (config.state_dir == null or !config.history.enabled or (options.journal and !config.history.journal_metadata)) {
        std.debug.print("health incidents requires an enabled history and state_dir. --journal requires enabled journal metadata.\n", .{});
        return 2;
    }
    const output = readResponse(a, config, options) catch return 3;
    std.fs.File.stdout().writeAll(output.body) catch return 3;
    return output.code;
}
