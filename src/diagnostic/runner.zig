const std = @import("std");
const builtin = @import("builtin");
const admission = @import("admission.zig");

test "missing measurements and inadequate headroom never start the backend" {
    for ([_]Status{ .measurements_unavailable, .insufficient_headroom, .pressure, .busy }) |reason| {
        var fixture: Fixture = .{ .refusal = reason };
        var capture: Capture = .{ .bytes = &.{} };
        try std.testing.expectEqual(reason, runSession(&fixture, 60, &capture, null));
        try std.testing.expect(!fixture.started);
        try std.testing.expect(!fixture.cleaned);
    }
}

test "sudden pressure, missing data, timeout, and cancellation clean all jobs" {
    for ([_]Status{ .pressure, .insufficient_headroom, .measurements_unavailable, .timed_out, .canceled }) |reason| {
        var flag = std.atomic.Value(bool).init(false);
        var fixture: Fixture = .{
            .active_refusal = switch (reason) {
                .pressure, .insufficient_headroom, .measurements_unavailable => reason,
                else => null,
            },
            .cancel_after_step = if (reason == .canceled) &flag else null,
        };
        var capture: Capture = .{ .bytes = &.{} };
        try std.testing.expectEqual(reason, runSession(&fixture, 150, &capture, &flag));
        try std.testing.expect(fixture.started and fixture.cleaned);
    }
}

test "capture bounds stdout and stderr together and keeps only stdout" {
    var bytes: [5]u8 = undefined;
    var capture: Capture = .{ .bytes = &bytes };
    var fixture: Fixture = .{ .stdout = "abc", .stderr = "12", .exit = .completed };
    try std.testing.expectEqual(Status.completed, runSession(&fixture, 100, &capture, null));
    try std.testing.expectEqualStrings("abc", capture.stdout());
    try std.testing.expect(fixture.cleaned);

    capture = .{ .bytes = &bytes };
    fixture = .{ .stdout = "abc", .stderr = "123", .exit = .completed };
    try std.testing.expectEqual(Status.output_limit, runSession(&fixture, 100, &capture, null));
    try std.testing.expect(fixture.cleaned);
}

test "unconfirmed recursive cleanup overrides an otherwise successful backend" {
    var fixture: Fixture = .{ .exit = .completed, .cleanup_ok = false };
    var capture: Capture = .{ .bytes = &.{} };
    try std.testing.expectEqual(Status.cleanup_failed, runSession(&fixture, 100, &capture, null));
    try std.testing.expect(fixture.cleaned);
}

test "admission requires a bounded job configuration and a local absolute executable" {
    var config: Config = .{ .job_cgroup = "/sys/fs/cgroup/tume/diagnose", .measured_peak_bytes = 50, .reserve_bytes = 100, .timeout_ms = 100, .max_output_bytes = 1024 };
    try std.testing.expect(config.valid());
    try std.testing.expect(validArgv(&.{"/usr/bin/tume-fake-backend"}));
    try std.testing.expect(!validArgv(&.{"tume-fake-backend"}));
    try std.testing.expect(!validArgv(&.{ "/usr/bin/tume-fake-backend", "x\x00y" }));
    config.timeout_ms = 0;
    try std.testing.expect(!config.valid());
    config.timeout_ms = 100;
    config.max_output_bytes = 65537;
    try std.testing.expect(!config.valid());
}

pub const Status = enum {
    completed,
    unsupported,
    busy,
    invalid_config,
    measurements_unavailable,
    insufficient_headroom,
    pressure,
    timed_out,
    canceled,
    output_limit,
    backend_failed,
    isolation_unavailable,
    cleanup_failed,
};

pub const Config = struct {
    job_cgroup: []const u8,
    measured_peak_bytes: u64,
    reserve_bytes: u64,
    timeout_ms: u32,
    max_output_bytes: usize,

    pub fn valid(self: Config) bool {
        return self.job_cgroup.len <= std.fs.max_path_bytes and
            std.mem.startsWith(u8, self.job_cgroup, "/sys/fs/cgroup/") and
            std.mem.indexOfScalar(u8, self.job_cgroup, 0) == null and
            self.measured_peak_bytes > 0 and self.reserve_bytes > 0 and
            self.timeout_ms > 0 and self.timeout_ms <= 300_000 and
            self.max_output_bytes > 0 and self.max_output_bytes <= 65_536;
    }
};

pub const Result = struct {
    status: Status,
    output: []const u8 = &.{},
    storage: []u8 = &.{},

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
    }
};

pub const Capture = struct {
    bytes: []u8,
    stdout_len: usize = 0,
    total: usize = 0,

    pub fn add(self: *Capture, bytes: []const u8, is_stdout: bool) error{OutputLimit}!void {
        if (bytes.len > self.bytes.len - self.total) return error.OutputLimit;
        self.total += bytes.len;
        if (is_stdout) {
            @memcpy(self.bytes[self.stdout_len..][0..bytes.len], bytes);
            self.stdout_len += bytes.len;
        }
    }

    fn stdout(self: Capture) []const u8 {
        return self.bytes[0..self.stdout_len];
    }
};

fn validArgv(argv: []const []const u8) bool {
    if (argv.len == 0 or argv.len > 16 or !std.fs.path.isAbsolute(argv[0])) return false;
    var remaining: usize = 65_536;
    for (argv) |arg| {
        if (arg.len >= remaining or std.mem.indexOfScalar(u8, arg, 0) != null) return false;
        remaining -= arg.len + 1;
    }
    return true;
}

pub fn run(allocator: std.mem.Allocator, config: Config, argv: []const []const u8, canceled: ?*const std.atomic.Value(bool)) !Result {
    if (!config.valid() or !validArgv(argv)) return .{ .status = .invalid_config };
    if (builtin.os.tag != .linux) return .{ .status = .unsupported };
    if (isCanceled(canceled)) return .{ .status = .canceled };

    const native = @import("linux_runner.zig");
    var session = native.Session.init(allocator, config, argv) catch |err| return .{ .status = switch (err) {
        error.WouldBlock => .busy,
        error.OutOfMemory => return error.OutOfMemory,
        else => .isolation_unavailable,
    } };
    defer session.deinit();
    const bytes = try allocator.alloc(u8, config.max_output_bytes);
    var capture: Capture = .{ .bytes = bytes };
    const status = runSession(&session, config.timeout_ms, &capture, canceled);
    if (status == .completed) return .{ .status = status, .output = capture.stdout(), .storage = bytes };
    allocator.free(bytes);
    return .{ .status = status };
}

fn isCanceled(flag: ?*const std.atomic.Value(bool)) bool {
    return if (flag) |value| value.load(.monotonic) else false;
}

fn runSession(session: anytype, timeout_ms: u32, capture: *Capture, canceled: ?*const std.atomic.Value(bool)) Status {
    if (isCanceled(canceled)) return .canceled;
    const start_ms = session.now() orelse return .measurements_unavailable;
    const deadline = start_ms +| timeout_ms;
    if (session.inspect(.start)) |status| return status;
    if (isCanceled(canceled)) return .canceled;
    if ((session.now() orelse return .measurements_unavailable) >= deadline) return .timed_out;
    if (session.start()) |status| return status;

    var inspect_at = start_ms;
    var terminal: ?Status = null;
    const status: Status = while (true) {
        if (isCanceled(canceled)) break .canceled;
        const now = session.now() orelse break .measurements_unavailable;
        if (now >= deadline) break .timed_out;
        if (now >= inspect_at) {
            if (session.inspect(.running)) |refusal| break refusal;
            inspect_at = now +| 100;
        }
        if (terminal) |done| break done;
        terminal = session.step(capture, @intCast(@min(20, deadline - now)));
    };
    return if (session.cleanup()) status else .cleanup_failed;
}

const Fixture = struct {
    refusal: ?Status = null,
    active_refusal: ?Status = null,
    started: bool = false,
    cleaned: bool = false,
    cleanup_ok: bool = true,
    millis: u64 = 0,
    cancel_after_step: ?*std.atomic.Value(bool) = null,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    exit: ?Status = null,

    fn now(self: *Fixture) ?u64 {
        return self.millis;
    }

    fn inspect(self: *Fixture, phase: admission.Phase) ?Status {
        return switch (phase) {
            .start => self.refusal,
            .running => if (self.millis >= 100) self.active_refusal else null,
        };
    }

    fn start(self: *Fixture) ?Status {
        self.started = true;
        return null;
    }

    fn step(self: *Fixture, capture: *Capture, delay: u16) ?Status {
        self.millis += delay;
        if (self.cancel_after_step) |flag| flag.store(true, .monotonic);
        capture.add(self.stdout, true) catch return .output_limit;
        capture.add(self.stderr, false) catch return .output_limit;
        return self.exit;
    }

    fn cleanup(self: *Fixture) bool {
        self.cleaned = true;
        return self.cleanup_ok;
    }
};
