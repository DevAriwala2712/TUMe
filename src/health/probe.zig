const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const collect = @import("collect.zig");
const types = @import("types.zig");

pub const Request = union(enum) { disk: []const u8, service: []const u8, temperature: u8 };
pub const Reply = union(enum) { disk: u16, service: types.ActiveState, temperature: i32, reason: types.Reason };

pub const Child = struct {
    pid: posix.pid_t,
    out: posix.fd_t = -1,
    err: posix.fd_t = -1,

    fn drained(self: Child) bool {
        return self.out < 0 and self.err < 0;
    }
};

pub const DrainError = error{ OutputLimit, ProbeFailure };
pub const Capture = struct {
    stdout: [4096]u8 = undefined,
    stdout_len: usize = 0,
    total: usize = 0,

    pub fn add(self: *Capture, bytes: []const u8, stdout: bool) DrainError!void {
        if (bytes.len > self.stdout.len - self.total) return error.OutputLimit;
        self.total += bytes.len;
        if (stdout) {
            @memcpy(self.stdout[self.stdout_len..][0..bytes.len], bytes);
            self.stdout_len += bytes.len;
        }
    }
};

const Operations = struct {
    ctx: ?*anyopaque = null,
    clock: *const fn (?*anyopaque) ?u64 = nativeClock,
    start: *const fn (?*anyopaque, Request) ?Child = nativeStart,
    drain: *const fn (?*anyopaque, *Child, *Capture, u16) DrainError!void = nativeDrain,
    reap: *const fn (?*anyopaque, Child) ?u32 = nativeReap,
    kill: *const fn (?*anyopaque, Child) void = nativeKill,
    close: *const fn (?*anyopaque, *Child) void = nativeClose,
};

pub const Runner = struct {
    ops: Operations = .{},
    child: ?Child = null,
    canceled: ?*const volatile u8 = null,

    pub fn now(self: *const Runner) ?u64 {
        return self.ops.clock(self.ops.ctx);
    }

    pub fn run(self: *Runner, req: Request, deadline_boot_ms: u64) Reply {
        if (self.isCanceled()) return .{ .reason = .unavailable };
        const start = self.now() orelse return .{ .reason = .unavailable };
        if (start >= deadline_boot_ms) return .{ .reason = .timeout };
        // A previously killed child can still be stuck in kernel I/O.
        if (self.child) |old| {
            if (self.ops.reap(self.ops.ctx, old) == null) return .{ .reason = .unavailable };
            self.child = null;
        }
        const deadline = @min(deadline_boot_ms, start +| 250);
        self.child = self.ops.start(self.ops.ctx, req) orelse return .{ .reason = .unavailable };
        var capture: Capture = .{};
        const child = &self.child.?;
        while (true) {
            if (self.isCanceled()) return self.abort(.unavailable);
            const current = self.now() orelse return self.abort(.unavailable);
            if (current >= deadline) return self.abort(.timeout);
            if (child.drained()) {
                if (self.ops.reap(self.ops.ctx, child.*)) |status| {
                    self.child = null;
                    return decode(req, status, capture.stdout[0..capture.stdout_len]);
                }
            }
            self.ops.drain(self.ops.ctx, child, &capture, @intCast(@min(20, deadline - current))) catch |err| {
                return self.abort(if (err == error.OutputLimit) .truncated else .unavailable);
            };
        }
    }

    fn isCanceled(self: *const Runner) bool {
        return if (self.canceled) |flag| flag.* != 0 else false;
    }

    fn abort(self: *Runner, reason: types.Reason) Reply {
        if (self.child) |*child| {
            // Signal the group before reaping its leader so the PID stays reserved.
            self.ops.kill(self.ops.ctx, child.*);
            self.ops.close(self.ops.ctx, child);
            if (self.ops.reap(self.ops.ctx, child.*) != null) self.child = null;
        }
        return .{ .reason = reason };
    }

    pub fn stop(self: *Runner) void {
        if (self.child) |child| {
            if (!child.drained()) {
                _ = self.abort(.unavailable);
            } else if (self.ops.reap(self.ops.ctx, child) != null) {
                self.child = null;
            }
        }
    }
};

pub fn serviceReply(exit_code: u8, stdout: []const u8) Reply {
    var loaded: ?[]const u8 = null;
    var active: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "LoadState=")) {
            if (loaded != null) return .{ .reason = .invalid };
            loaded = line["LoadState=".len..];
        } else if (std.mem.startsWith(u8, line, "ActiveState=")) {
            if (active != null) return .{ .reason = .invalid };
            active = line["ActiveState=".len..];
        } else if (line.len != 0) {
            return .{ .reason = if (exit_code == 0) .invalid else .unavailable };
        }
    }
    const load = loaded orelse return .{ .reason = .unavailable };
    const state = active orelse return .{ .reason = .unavailable };
    if (std.mem.eql(u8, load, "not-found") and std.mem.eql(u8, state, "inactive")) {
        return .{ .reason = .unsupported };
    }
    if (exit_code != 0 or !std.mem.eql(u8, load, "loaded")) return .{ .reason = .unavailable };
    return if (std.meta.stringToEnum(types.ActiveState, state)) |value| .{ .service = value } else .{ .reason = .unavailable };
}

pub fn diskReply(blocks: u64, bfree: u64, bavail: u64, ext4: bool) Reply {
    if (!ext4) return .{ .reason = .unsupported };
    if (bavail > bfree or bfree > blocks) return .{ .reason = .invalid };
    const used: u128 = blocks - bfree;
    const capacity = used + bavail;
    if (capacity == 0) return .{ .reason = .invalid };
    return .{ .disk = @intCast(used * 10_000 / capacity) };
}

pub fn thermalReply(bytes: []const u8) Reply {
    const text = std.mem.trimEnd(u8, bytes, "\n");
    const digits = if (text.len != 0 and text[0] == '-') text[1..] else text;
    for (digits) |c| if (!std.ascii.isDigit(c)) return .{ .reason = .invalid };
    const milli = std.fmt.parseInt(i32, text, 10) catch return .{ .reason = .invalid };
    if (milli < -40_000 or milli > 150_000) return .{ .reason = .invalid };
    return .{ .temperature = milli };
}

pub fn openDirectory(path: []const u8) !posix.fd_t {
    const flags: posix.O = .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };
    var fd = try posix.open("/", flags, 0);
    errdefer posix.close(fd);
    if (std.mem.eql(u8, path, "/")) return fd;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        const next = try posix.openat(fd, part, flags, 0);
        posix.close(fd);
        fd = next;
    }
    return fd;
}

pub fn isExt4(fd: posix.fd_t) !bool {
    var path_buffer: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/self/fdinfo/{d}", .{fd});
    var fd_buffer: [1025]u8 = undefined;
    const fdinfo = try mountMetadata(path, &fd_buffer);
    var lines = std.mem.splitScalar(u8, fdinfo, '\n');
    const id = while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "mnt_id:")) break std.mem.trim(u8, line["mnt_id:".len..], " \t");
    } else return error.MountUnavailable;
    if (id.len == 0) return error.MountUnavailable;
    var table_buffer: [65537]u8 = undefined;
    const table = try mountMetadata("/proc/self/mountinfo", &table_buffer);
    lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (!std.mem.eql(u8, line[0..space], id)) continue;
        const separator = std.mem.indexOf(u8, line, " - ") orelse return error.MountUnavailable;
        return std.mem.startsWith(u8, line[separator + 3 ..], "ext4 ");
    }
    return error.MountUnavailable;
}

fn mountMetadata(path: []const u8, buffer: []u8) ![]const u8 {
    return switch (collect.readKernel(path, buffer)) {
        .value => |data| data,
        .reason => |reason| switch (reason) {
            .truncated => error.MountTruncated,
            .denied => error.AccessDenied,
            else => error.MountUnavailable,
        },
    };
}

fn disk(path: []const u8) Reply {
    const fd = openDirectory(path) catch |err| return .{ .reason = collect.fileReason(err) };
    defer posix.close(fd);
    const ext4 = isExt4(fd) catch |err| return .{
        .reason = if (err == error.MountTruncated) .truncated else collect.fileReason(err),
    };
    if (!ext4) return .{ .reason = .unsupported };

    // Linux asm-generic statfs ABI on the supported 64-bit targets.
    const StatFs = extern struct {
        fs_type: c_long,
        block_size: c_long,
        blocks: u64,
        free: u64,
        available: u64,
        files: u64,
        free_files: u64,
        fs_id: [2]i32,
        name_len: c_long,
        fragment_size: c_long,
        flags: c_long,
        spare: [4]c_long,
    };
    if (@sizeOf(c_long) != 8) return .{ .reason = .unsupported };
    var stat: StatFs = undefined;
    switch (linux.E.init(linux.syscall2(.fstatfs, @intCast(fd), @intFromPtr(&stat)))) {
        .SUCCESS => return diskReply(stat.blocks, stat.free, stat.available, true),
        .ACCES, .PERM => return .{ .reason = .denied },
        else => return .{ .reason = .unavailable },
    }
}

fn temperature(zone: u8) Reply {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/sys/class/thermal/thermal_zone{d}/temp", .{zone}) catch unreachable;
    var bytes: [collect.kernel_read_limit + 1]u8 = undefined;
    return switch (collect.readKernel(path, &bytes)) {
        .value => |data| thermalReply(data),
        .reason => |reason| .{ .reason = reason },
    };
}

const helper_reason_start = 64;

fn decode(req: Request, status: u32, stdout: []const u8) Reply {
    if (!posix.W.IFEXITED(status)) return .{ .reason = .unavailable };
    const code = posix.W.EXITSTATUS(status);
    if (req == .service) return serviceReply(code, stdout);
    if (code != 0) {
        const reason = if (code >= helper_reason_start)
            std.enums.fromInt(types.Reason, code - helper_reason_start)
        else
            null;
        return .{ .reason = reason orelse .unavailable };
    }
    if (stdout.len != 4) return .{ .reason = .invalid };
    const result = std.mem.readInt(i32, stdout[0..4], .little);
    return switch (req) {
        .disk => if (result >= 0 and result <= 10_000) .{ .disk = @intCast(result) } else .{ .reason = .invalid },
        .temperature => if (result >= -40_000 and result <= 150_000) .{ .temperature = result } else .{ .reason = .invalid },
        .service => unreachable,
    };
}

fn childWork(req: Request) u8 {
    if (req == .service) {
        var unit_buf: [129]u8 = undefined;
        const unit = std.fmt.bufPrintZ(&unit_buf, "{s}", .{req.service}) catch return 1;
        const path = "/usr/bin/systemctl";
        const argv = [_:null]?[*:0]const u8{
            path, "show", "--no-pager", "--property=LoadState", "--property=ActiveState", "--", unit.ptr,
        };
        const env = [_:null]?[*:0]const u8{"LC_ALL=C"};
        return switch (posix.execveZ(path, &argv, &env)) {
            error.AccessDenied, error.PermissionDenied => 126,
            else => 127,
        };
    }
    const result = switch (req) {
        .disk => |path| disk(path),
        .temperature => |zone| temperature(zone),
        .service => unreachable,
    };
    const value: i32 = switch (result) {
        .reason => |reason| return helper_reason_start + @as(u8, @intFromEnum(reason)),
        .disk => |value| value,
        .temperature => |value| value,
        .service => unreachable,
    };
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &bytes, value, .little);
    const n = posix.write(posix.STDOUT_FILENO, &bytes) catch return 1;
    return if (n == bytes.len) 0 else 1;
}

fn nativeClock(_: ?*anyopaque) ?u64 {
    return collect.bootMillis() catch null;
}

fn nativeStart(_: ?*anyopaque, req: Request) ?Child {
    if (builtin.os.tag != .linux) return null;
    return spawn(req, childWork) catch null;
}

fn pipe() ![2]posix.fd_t {
    var fds = try posix.pipe2(.{ .CLOEXEC = true });
    errdefer for (fds) |fd| posix.close(fd);
    for (&fds) |*fd| {
        if (fd.* > posix.STDERR_FILENO) continue;
        // Linux F_DUPFD_CLOEXEC is absent from the Zig 0.15.2 F namespace.
        const duplicate = try posix.fcntl(fd.*, 1030, 3);
        posix.close(fd.*);
        fd.* = @intCast(duplicate);
    }
    const flags = try posix.fcntl(fds[0], posix.F.GETFL, 0);
    _ = try posix.fcntl(fds[0], posix.F.SETFL, flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    return fds;
}

fn spawn(req: Request, comptime work: fn (Request) u8) !Child {
    const out = try pipe();
    errdefer posix.close(out[0]);
    defer posix.close(out[1]);
    const err = try pipe();
    errdefer posix.close(err[0]);
    defer posix.close(err[1]);
    const pid = try posix.fork();
    if (pid == 0) {
        posix.setpgid(0, 0) catch posix.exit(1);
        posix.dup2(out[1], posix.STDOUT_FILENO) catch posix.exit(1);
        posix.dup2(err[1], posix.STDERR_FILENO) catch posix.exit(1);
        _ = linux.close(posix.STDIN_FILENO);
        if (linux.E.init(linux.syscall3(.close_range, 3, std.math.maxInt(u32), 0)) != .SUCCESS) posix.exit(1);
        posix.exit(work(req));
    }
    // Either side may run first. Once the child execs, its group already exists.
    posix.setpgid(pid, pid) catch {};
    return .{ .pid = pid, .out = out[0], .err = err[0] };
}

fn nativeDrain(_: ?*anyopaque, child: *Child, capture: *Capture, delay: u16) DrainError!void {
    if (builtin.os.tag != .linux) return error.ProbeFailure;
    var fds = [_]posix.pollfd{
        .{ .fd = child.out, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = child.err, .events = posix.POLL.IN, .revents = 0 },
    };
    // Use the raw poll so a signal cannot cause an unbounded retry in posix.poll.
    switch (linux.E.init(linux.poll(&fds, fds.len, delay))) {
        .INTR => return,
        .SUCCESS => {},
        else => return error.ProbeFailure,
    }
    const pipes = [_]*posix.fd_t{ &child.out, &child.err };
    for (fds, pipes, 0..) |ready, fd, i| {
        if (ready.revents == 0) continue;
        var buffer: [1024]u8 = undefined;
        const n = posix.read(fd.*, &buffer) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return error.ProbeFailure,
        };
        if (n == 0) {
            posix.close(fd.*);
            fd.* = -1;
        } else {
            try capture.add(buffer[0..n], i == 0);
        }
    }
}

fn nativeReap(_: ?*anyopaque, child: Child) ?u32 {
    if (builtin.os.tag != .linux) return null;
    var status: u32 = 0;
    const result = linux.waitpid(child.pid, &status, linux.W.NOHANG);
    return switch (linux.E.init(result)) {
        .SUCCESS => if (result == 0) null else status,
        .CHILD => 1,
        else => null,
    };
}

fn nativeKill(_: ?*anyopaque, child: Child) void {
    posix.kill(-child.pid, posix.SIG.KILL) catch {};
    posix.kill(child.pid, posix.SIG.KILL) catch {};
}

fn nativeClose(_: ?*anyopaque, child: *Child) void {
    if (child.out >= 0) posix.close(child.out);
    if (child.err >= 0) posix.close(child.err);
    child.out = -1;
    child.err = -1;
}

fn fixtureChild(req: Request) u8 {
    switch (req) {
        .disk => std.Thread.sleep(std.time.ns_per_s),
        .service => {
            const reply = "LoadState=loaded\nActiveState=active\n";
            _ = posix.write(posix.STDOUT_FILENO, reply) catch return 1;
        },
        .temperature => {
            const chunk = "x" ** 1024;
            for (0..5) |_| _ = posix.write(posix.STDERR_FILENO, chunk) catch return 1;
        },
    }
    return 0;
}

fn fixtureStart(_: ?*anyopaque, req: Request) ?Child {
    return spawn(req, fixtureChild) catch null;
}

test "tume health task 2 native helper exit, timeout and oversize output" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var runner: Runner = .{ .ops = .{ .start = fixtureStart } };
    defer runner.stop();
    try std.testing.expectEqual(.active, runner.run(.{ .service = "test.service" }, (try collect.bootMillis()) + 1500).service);
    try std.testing.expectEqual(.timeout, runner.run(.{ .disk = "/" }, (try collect.bootMillis()) + 1500).reason);
    try reapFixture(&runner);
    try std.testing.expectEqual(.truncated, runner.run(.{ .temperature = 0 }, (try collect.bootMillis()) + 1500).reason);
    try reapFixture(&runner);
}

fn reapFixture(runner: *Runner) !void {
    const deadline = (try collect.bootMillis()) + 1000;
    while (runner.child != null and (try collect.bootMillis()) < deadline) {
        runner.stop();
        if (runner.child != null) std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(runner.child == null);
}
