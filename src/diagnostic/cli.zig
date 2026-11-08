const std = @import("std");
const builtin = @import("builtin");
const health = @import("../health/cli.zig");
const report = @import("../health/report.zig");
const checks = @import("../incident/checks.zig");
const explanation = @import("explanation.zig");
const policy = @import("policy.zig");
const runner = @import("runner.zig");

var canceled = std.atomic.Value(bool).init(false);

fn handleSignal(_: i32) callconv(.c) void {
    canceled.store(true, .monotonic);
}

fn diagnosticJob(a: std.mem.Allocator, settings: policy.Policy, request: explanation.Request) !runner.Result {
    const request_json = try report.encodeJson(a, request, 2048);
    const max_tokens = try std.fmt.allocPrint(a, "{d}", .{settings.max_tokens});
    const argv = [_][]const u8{ settings.backend, "--max-tokens", max_tokens, "--request-json", request_json };

    const posix = std.posix;
    const action: posix.Sigaction = .{ .handler = .{ .handler = handleSignal }, .mask = posix.sigemptyset(), .flags = 0 };
    var old_term: posix.Sigaction = undefined;
    var old_int: posix.Sigaction = undefined;
    canceled.store(false, .monotonic);
    posix.sigaction(posix.SIG.TERM, &action, &old_term);
    posix.sigaction(posix.SIG.INT, &action, &old_int);
    defer posix.sigaction(posix.SIG.TERM, &old_term, null);
    defer posix.sigaction(posix.SIG.INT, &old_int, null);

    return runner.run(a, .{
        .job_cgroup = settings.job_cgroup,
        .measured_peak_bytes = settings.measured_peak_bytes,
        .reserve_bytes = settings.reserve_bytes,
        .timeout_ms = settings.timeout_ms,
        .max_output_bytes = settings.max_output_bytes,
    }, &argv, &canceled);
}

const Result = struct {
    schema_version: u16 = 1,
    outcome: enum { explained, inconclusive } = .inconclusive,
    reason: ?[]const u8 = null,
    request: ?explanation.Request = null,
    possible_cause: ?explanation.Cause = null,
    uncertainty: ?[]const u8 = null,
    next_check: ?checks.Check = null,
};

fn evaluate(a: std.mem.Allocator, args: []const []const u8) !Result {
    const health_config = try health.readConfig(a, args[1]);
    if (health_config.state_dir == null) return error.InvalidHealthConfig;
    var settings = try policy.read(a, args[3]);
    defer settings.deinit();
    const key = args[5];
    const loaded = health.loadStatus(a, health_config);
    if (loaded.freshness != .fresh) return .{ .reason = @tagName(loaded.freshness) };
    const finding = explanation.openFinding(loaded, key) orelse return .{ .reason = "finding_not_open" };
    const request = (try explanation.prepare(a, loaded, key)) orelse {
        return .{ .reason = "insufficient_evidence", .next_check = checks.missing_coverage };
    };

    var next = checks.forRule(finding.rule_id)[0];
    next.evidence_id = request.evidence.id;
    const job = diagnosticJob(a, settings.value, request) catch {
        return .{ .reason = "diagnostic_error", .request = request, .next_check = next };
    };
    defer job.deinit(a);
    if (job.status != .completed) return .{ .reason = @tagName(job.status), .request = request, .next_check = next };
    const cause = explanation.validate(a, request, job.output) orelse {
        return .{ .reason = "unsupported_proposal", .request = request, .next_check = next };
    };
    return .{
        .outcome = .explained,
        .request = request,
        .possible_cause = cause,
        .uncertainty = "The cited sample supports the immediate condition. Its underlying cause requires further evidence.",
        .next_check = next,
    };
}

fn usageMatches(args: []const []const u8) bool {
    return args.len == 6 and std.mem.eql(u8, args[0], "--config") and
        std.mem.eql(u8, args[2], "--policy") and std.mem.eql(u8, args[4], "--finding") and
        args[5].len > 0 and args[5].len <= 256;
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    if (builtin.os.tag != .linux) {
        std.debug.print("health explain requires Linux\n", .{});
        return 2;
    }
    if (!usageMatches(args)) {
        std.debug.print("Usage: nanoclaw-next health explain --config PATH --policy PATH --finding EVIDENCE_KEY\n", .{});
        return 2;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = evaluate(a, args) catch |err| {
        std.debug.print("health explain: {s}\n", .{@errorName(err)});
        return 2;
    };
    const encoded = report.encodeJson(a, result, 4096) catch return 3;
    std.fs.File.stdout().writeAll(encoded) catch return 3;
    return if (result.outcome == .explained) 0 else 3;
}
