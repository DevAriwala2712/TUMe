const std = @import("std");
const builtin = @import("builtin");
const collect = @import("collect.zig");
const findings = @import("findings.zig");
const probe = @import("probe.zig");
const state = @import("state.zig");
const types = @import("types.zig");

const interval_ms = 15000;
const warning_interval_ms = 300000;

pub fn cadence(previous_boot_ms: ?u64, current_boot_ms: u64) enum { skip, sample, sample_reset } {
    const previous = previous_boot_ms orelse return .sample;
    const elapsed = current_boot_ms -| previous;
    if (elapsed < interval_ms) return .skip;
    return if (elapsed >= 2 * interval_ms) .sample_reset else .sample;
}

pub const Cursor = struct {
    previous: ?u64 = null,
    confirmed: findings.State = .{},

    pub fn fromLoaded(loaded: state.Loaded) Cursor {
        if (loaded.report) |wire| {
            return .{ .previous = wire.sampled_at_boot_ms, .confirmed = loaded.confirmed.? };
        }
        return .{};
    }

    pub fn publish(self: *Cursor, a: std.mem.Allocator, store: *state.Store, target: types.Target, sample: types.Sample) !bool {
        switch (cadence(self.previous, sample.stamp.boot_ms)) {
            .skip => return false,
            .sample => {},
            .sample_reset => findings.resetStreaks(&self.confirmed),
        }
        const confirmed = try findings.advance(a, &self.confirmed, target, sample);
        self.previous = sample.stamp.boot_ms;
        try store.publish(a, .{
            .target = target,
            .sample = sample,
            .mode = .watch,
            .findings = confirmed,
        }, self.confirmed);
        return true;
    }
};

var stopped: u8 = 0;

fn handleSignal(_: i32) callconv(.c) void {
    const flag: *volatile u8 = &stopped;
    flag.* = 1;
}

fn waitUntil(boot_ms: u64) !void {
    const linux = std.os.linux;
    const deadline: linux.timespec = .{
        .sec = @intCast(boot_ms / 1000),
        .nsec = @intCast((boot_ms % 1000) * std.time.ns_per_ms),
    };
    switch (linux.E.init(linux.clock_nanosleep(.BOOTTIME, .{ .ABSTIME = true }, &deadline, null))) {
        .SUCCESS, .INTR => {},
        else => return error.ClockUnavailable,
    }
}

pub fn run(allocator: std.mem.Allocator, config: types.Config, once: bool) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    const posix = std.posix;
    const flag: *volatile u8 = &stopped;
    flag.* = 0;
    const action: posix.Sigaction = .{ .handler = .{ .handler = handleSignal }, .mask = posix.sigemptyset(), .flags = 0 };
    var old_term: posix.Sigaction = undefined;
    var old_int: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.TERM, &action, &old_term);
    posix.sigaction(posix.SIG.INT, &action, &old_int);
    defer posix.sigaction(posix.SIG.TERM, &old_term, null);
    defer posix.sigaction(posix.SIG.INT, &old_int, null);

    var store = try state.Store.open(config.state_dir orelse return error.InvalidConfig);
    defer store.close();
    try store.lock();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var cursor = Cursor.fromLoaded(store.load(arena.allocator(), config.target, try collect.stamp()));
    var runner: probe.Runner = .{ .canceled = flag };
    defer runner.stop();
    var last_warning: ?u64 = null;
    while (flag.* == 0) {
        const now = try collect.bootMillis();
        if (cadence(cursor.previous, now) == .skip) {
            if (once) return;
            // Bound the gap if a stop signal arrives just before entering sleep.
            try waitUntil(@min(cursor.previous.? +| interval_ms, now +| 250));
            continue;
        }
        _ = arena.reset(.free_all);
        const a = arena.allocator();
        const sampled = try collect.stamp();
        const sample = try collect.take(a, config.target, sampled, &runner);
        if (flag.* != 0) return;
        _ = cursor.publish(a, &store, config.target, sample) catch |err| {
            if (once or cursor.previous != sampled.boot_ms) return err;
            if (last_warning == null or sampled.boot_ms -| last_warning.? >= warning_interval_ms) {
                std.debug.print("health publish: {s}\n", .{@errorName(err)});
                last_warning = sampled.boot_ms;
            }
        };
        if (once) return;
    }
}
