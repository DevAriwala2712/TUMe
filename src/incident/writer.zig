const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const collect = @import("../health/collect.zig");
const timeline = @import("timeline.zig");
const history = @import("store.zig");

test "history writer drops a timed-out child and leaves a gap" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pid = try posix.fork();
    if (pid == 0) {
        std.Thread.sleep(std.time.ns_per_s);
        posix.exit(0);
    }
    var writer: Writer = .{ .child = .{ .pid = pid, .deadline = 10 } };
    defer writer.stop();
    writer.poll(10);
    try std.testing.expectEqual(.history_write_failed, writer.gap.?);
    const deadline = (try collect.bootMillis()) + 1000;
    while (writer.child != null and (try collect.bootMillis()) < deadline) {
        writer.poll(11);
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(writer.child == null);
}

// Kept in step with the compile-time package release in build.zig.zon.
pub const agent_release = "0.0.1";

const Child = struct { pid: posix.pid_t, deadline: u64, killed: bool = false };

pub const Writer = struct {
    child: ?Child = null,
    gap: ?timeline.Gap = .restart,

    pub fn waiting(self: Writer) bool {
        return self.child != null and !self.child.?.killed;
    }

    pub fn breakContinuity(self: *Writer, reason: timeline.Gap) void {
        if (self.gap == null or self.gap == .restart) self.gap = reason;
    }

    pub fn poll(self: *Writer, now: u64) void {
        const child = &(self.child orelse return);
        // Check the completion first so a child already reaped by the deadline
        // needs no cancellation signal.
        var status: u32 = 0;
        const result = linux.waitpid(child.pid, &status, posix.W.NOHANG);
        switch (linux.E.init(result)) {
            .SUCCESS => if (result != 0) {
                if (!posix.W.IFEXITED(status) or posix.W.EXITSTATUS(status) != 0)
                    self.breakContinuity(.history_write_failed);
                self.child = null;
                return;
            },
            .CHILD => {
                self.breakContinuity(.history_write_failed);
                self.child = null;
                return;
            },
            else => {},
        }
        if (now >= child.deadline and !child.killed) {
            self.breakContinuity(.history_write_failed);
            posix.kill(child.pid, posix.SIG.KILL) catch {};
            self.child.?.killed = true;
        }
    }

    pub fn submit(self: *Writer, dir: posix.fd_t, pending: timeline.Input) void {
        const now = collect.bootMillis() catch {
            self.breakContinuity(.history_write_failed);
            return;
        };
        self.poll(now);
        if (self.child != null) {
            self.breakContinuity(.history_write_failed);
            return;
        }
        var input = pending;
        input.gap = self.gap;
        const deadline = now +| 250;
        const pid = posix.fork() catch {
            self.breakContinuity(.history_write_failed);
            return;
        };
        if (pid == 0) {
            isolate(dir) catch posix.exit(1);
            write(dir, input, deadline) catch posix.exit(1);
            posix.exit(0);
        }
        self.gap = null;
        self.child = .{ .pid = pid, .deadline = deadline };
    }

    pub fn stop(self: *Writer) void {
        self.poll(std.math.maxInt(u64));
    }
};

fn isolate(dir: posix.fd_t) !void {
    const keep: u32 = @intCast(dir);
    if (keep != 0 and linux.E.init(linux.syscall3(.close_range, 0, keep - 1, 0)) != .SUCCESS) return error.DescriptorIsolationFailed;
    if (linux.E.init(linux.syscall3(.close_range, keep + 1, std.math.maxInt(u32), 0)) != .SUCCESS) return error.DescriptorIsolationFailed;
    const default: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(posix.SIG.TERM, &default, null);
    posix.sigaction(posix.SIG.INT, &default, null);
}

fn checkDeadline(deadline: u64) !void {
    if (try collect.bootMillis() >= deadline) return error.HistoryDeadline;
}

fn write(dir: posix.fd_t, input: timeline.Input, deadline: u64) !void {
    try checkDeadline(deadline);
    const lock = try history.lock(dir);
    defer posix.close(lock);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Holding this lock from read through atomic replacement serializes the
    // generation. appendSample rejects an equal or older sample in this boot.
    const prior = try history.read(a, dir, input.sample.stamp);
    const next = try timeline.appendSample(a, prior, input);
    if (prior.generation != next.generation or prior.events.len != next.events.len)
        try history.persist(a, dir, next, .{ .before_rename = checkDeadline, .deadline = deadline });
    try checkDeadline(deadline);
}

pub fn monotonicMicros() ?u64 {
    const time = posix.clock_gettime(.MONOTONIC) catch return null;
    if (time.sec < 0 or time.nsec < 0) return null;
    return @as(u64, @intCast(time.sec)) * std.time.us_per_s + @as(u64, @intCast(time.nsec)) / std.time.ns_per_us;
}
