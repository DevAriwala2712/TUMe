const std = @import("std");
const config = @import("../health/config.zig");
const types = @import("../health/types.zig");
const probe = @import("../health/probe.zig");
const timeline = @import("timeline.zig");

const before_us = 5 * 60 * std.time.us_per_s;
const after_us = 60 * std.time.us_per_s;
const output_limit = 16 * 1024;
const candidate_limit = 33;

pub const Coverage = enum { limited, empty_or_inaccessible, out_of_scope, unavailable, timeout, invalid, truncated };
pub const Row = struct {
    citation_id: []const u8,
    source: enum { system_journal } = .system_journal,
    boot_id: []const u8,
    unit: []const u8,
    journal_monotonic_us: u64,
    sampled_at_unix_us: u64,
    kind: enum { manager_event, unit_log_event },
};
pub const Result = struct { coverage: Coverage, rows: []const Row = &.{} };

pub const Scope = struct {
    boot_id: []const u8,
    unit: []const u8,
    monotonic_us: u64,
    unix_us: u64,
};

fn compactBoot(boot: []const u8) [32]u8 {
    var compact: [32]u8 = undefined;
    var index: usize = 0;
    for (boot) |c| {
        if (c == '-') continue;
        compact[index] = c;
        index += 1;
    }
    return compact;
}

fn field(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn micros(object: std.json.ObjectMap, key: []const u8) !u64 {
    const text = field(object, key) orelse return error.InvalidRow;
    if (text.len == 0 or text.len > 20) return error.InvalidRow;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidRow;
    return std.fmt.parseInt(u64, text, 10) catch return error.InvalidRow;
}

fn citation(boot_id: []const u8, unit: []const u8, cursor: []const u8) [32]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var cursor_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(cursor, &cursor_digest, .{});
    var hasher = Sha256.init(.{});
    hasher.update("tume-journal-citation-v1\x00");
    hasher.update(boot_id);
    hasher.update(unit);
    hasher.update("\x00");
    hasher.update(&cursor_digest);
    return std.fmt.bytesToHex(hasher.finalResult()[0..16], .lower);
}

fn row(a: std.mem.Allocator, scope: Scope, line: []const u8) !?Row {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const value = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidRow,
    };
    if (value != .object) return error.InvalidRow;
    const object = value.object;
    const boot = field(object, "_BOOT_ID") orelse return error.InvalidRow;
    if (!timeline.equal(boot, &compactBoot(scope.boot_id))) return null;
    const unit_log = timeline.equal(field(object, "_SYSTEMD_UNIT") orelse "", scope.unit);
    const manager_log = timeline.equal(field(object, "_PID") orelse "", "1") and timeline.equal(field(object, "UNIT") orelse "", scope.unit);
    if (!unit_log and !manager_log) return null;
    const monotonic = try micros(object, "__MONOTONIC_TIMESTAMP");
    const wall = try micros(object, "__REALTIME_TIMESTAMP");
    if (monotonic < scope.monotonic_us -| before_us or monotonic > scope.monotonic_us +| after_us or
        wall < scope.unix_us -| before_us or wall > scope.unix_us +| after_us) return null;
    // Suspending and wall-clock changes can make the wall-clock search hint
    // miss rows. Reject incompatible timestamps and keep coverage limited.
    const monotonic_delta = @as(i128, monotonic) - scope.monotonic_us;
    const wall_delta = @as(i128, wall) - scope.unix_us;
    if (@abs(monotonic_delta - wall_delta) > 5 * std.time.us_per_s) return null;
    const cursor = field(object, "__CURSOR") orelse return error.InvalidRow;
    if (cursor.len == 0 or cursor.len > 512) return error.InvalidRow;
    for (cursor) |c| if (c < 33 or c > 126) return error.InvalidRow;
    return .{
        .citation_id = try a.dupe(u8, &citation(scope.boot_id, scope.unit, cursor)),
        .boot_id = scope.boot_id,
        .unit = scope.unit,
        .journal_monotonic_us = monotonic,
        .sampled_at_unix_us = wall,
        .kind = if (manager_log) .manager_event else .unit_log_event,
    };
}

fn byTime(_: void, left: Row, right: Row) bool {
    if (left.journal_monotonic_us != right.journal_monotonic_us) return left.journal_monotonic_us < right.journal_monotonic_us;
    return std.mem.order(u8, left.citation_id, right.citation_id) == .lt;
}

pub fn project(a: std.mem.Allocator, scope: Scope, bytes: []const u8) !Result {
    if (!types.validBootId(scope.boot_id) or !config.validUnit(scope.unit)) return .{ .coverage = .out_of_scope };
    if (scope.unix_us < before_us) return .{ .coverage = .unavailable };
    if (bytes.len > output_limit) return .{ .coverage = .truncated };
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var rows: [candidate_limit]Row = undefined;
    var count: usize = 0;
    var scanned: usize = 0;
    var invalid = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (scanned == candidate_limit) break;
        scanned += 1;
        const selected = row(a, scope, line) catch |err| switch (err) {
            error.InvalidRow => {
                invalid = true;
                continue;
            },
            else => return err,
        };
        const item = selected orelse continue;
        for (rows[0..count]) |seen| {
            if (timeline.equal(seen.citation_id, item.citation_id)) break;
        } else {
            rows[count] = item;
            count += 1;
        }
    }
    std.mem.sort(Row, rows[0..count], {}, byTime);
    const start = count -| (candidate_limit - 1);
    return .{
        .coverage = if (scanned == candidate_limit) .truncated else if (count != 0) .limited else if (invalid) .invalid else if (scanned == 0) .empty_or_inaccessible else .limited,
        .rows = try a.dupe(Row, rows[start..count]),
    };
}

pub fn query(a: std.mem.Allocator, scope: Scope) !Result {
    if (!types.validBootId(scope.boot_id) or !config.validUnit(scope.unit)) return .{ .coverage = .out_of_scope };
    if (scope.unix_us < before_us) return .{ .coverage = .unavailable };
    var boot_buf: [40]u8 = undefined;
    var since_buf: [48]u8 = undefined;
    var until_buf: [48]u8 = undefined;
    var trusted_unit_buf: [144]u8 = undefined;
    var manager_unit_buf: [134]u8 = undefined;
    const boot = try std.fmt.bufPrintZ(&boot_buf, "--boot={s}", .{&compactBoot(scope.boot_id)});
    const since = try std.fmt.bufPrintZ(&since_buf, "--since=@{d}", .{(scope.unix_us - before_us) / std.time.us_per_s});
    const until = try std.fmt.bufPrintZ(&until_buf, "--until=@{d}", .{(scope.unix_us +| after_us) / std.time.us_per_s + 1});
    const trusted = try std.fmt.bufPrintZ(&trusted_unit_buf, "_SYSTEMD_UNIT={s}", .{scope.unit});
    const manager = try std.fmt.bufPrintZ(&manager_unit_buf, "UNIT={s}", .{scope.unit});
    const path = "/usr/bin/journalctl";
    const argv = [_:null]?[*:0]const u8{
        path,                                      "--system",   "--no-pager", "--quiet", "--output=json",
        "--output-fields=_SYSTEMD_UNIT,UNIT,_PID", "--lines=33", "--reverse",  boot.ptr,  since.ptr,
        until.ptr,                                 "--",         trusted.ptr,  "+",       "_PID=1",
        manager.ptr,
    };
    const captured = probe.captureCommand(output_limit, .{ .path = path, .argv = &argv }) catch |err| return .{
        .coverage = switch (err) {
            error.OutputLimit => .truncated,
            error.CommandTimeout => .timeout,
            else => .unavailable,
        },
    };
    return project(a, scope, captured.stdout[0..captured.stdout_len]);
}
