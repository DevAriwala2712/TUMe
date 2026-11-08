const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const admission = @import("admission.zig");
const runner = @import("runner.zig");
const filter = @import("linux_backend_filter.zig");
const collect = @import("../health/collect.zig");

const cgroup_root = "/sys/fs/cgroup";
const cgroup2_super_magic = 0x63677270;
const max_depth = 32;
const directory_flags: posix.O = .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };
const read_flags: posix.O = .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true };

pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    config: runner.Config,
    argv: [16:null]?[*:0]const u8 = @splat(null),
    dirs: [max_depth + 1]posix.fd_t = undefined,
    depth: usize = 0,
    kill_fd: posix.fd_t = -1,
    procs_fd: posix.fd_t = -1,
    landlock_fd: posix.fd_t = -1,
    cap: u64 = 0,
    child: posix.pid_t = 0,
    placed: bool = false,
    wait_status: ?u32 = null,
    out: posix.fd_t = -1,
    err: posix.fd_t = -1,

    pub fn init(allocator: std.mem.Allocator, config: runner.Config, argv: []const []const u8) !Session {
        if (!filter.supported) return error.UnsupportedBackendFilter;
        if (posix.getuid() == 0 or posix.geteuid() == 0) return error.PrivilegedBroker;
        var self: Session = .{ .arena = std.heap.ArenaAllocator.init(allocator), .config = config };
        errdefer self.deinit();
        const root = try posix.open(cgroup_root, directory_flags, 0);
        self.push(root);
        if (!isCgroup2(root)) return error.NotCgroup2;
        try requireTrueRoot(root);
        // Lock the real hierarchy root so separate invocations and leaves share
        // a single job slot. The fd stays open until cleanup has been checked.
        try posix.flock(root, posix.LOCK.EX | posix.LOCK.NB);
        const mount = try mountId(root);

        var components = std.mem.splitScalar(u8, config.job_cgroup[cgroup_root.len + 1 ..], '/');
        while (components.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..") or self.depth == self.dirs.len)
                return error.InvalidCgroupPath;
            const fd = try posix.openat(self.leaf(), component, directory_flags, 0);
            self.push(fd);
            if (try mountId(fd) != mount) return error.NestedMount;
        }
        if (self.depth < 2) return error.InvalidCgroupPath;
        if (try populated(self.leaf())) return error.WouldBlock;
        var buf: [64]u8 = undefined;
        const kind = try readAt(self.leaf(), "cgroup.type", &buf);
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, kind, "\n"), "domain")) return error.InvalidCgroupType;
        const control_flags: posix.O = .{ .ACCMODE = .WRONLY, .CLOEXEC = true, .NOFOLLOW = true };
        self.kill_fd = try posix.openat(self.leaf(), "cgroup.kill", control_flags, 0);
        self.procs_fd = try posix.openat(self.leaf(), "cgroup.procs", control_flags, 0);
        self.landlock_fd = try createLandlock();
        for (argv, 0..) |arg, i| {
            self.argv[i] = (try self.arena.allocator().dupeZ(u8, arg)).ptr;
        }
        return self;
    }

    pub fn deinit(self: *Session) void {
        close(&self.out);
        close(&self.err);
        close(&self.kill_fd);
        close(&self.procs_fd);
        close(&self.landlock_fd);
        for (self.dirs[0..self.depth]) |fd| posix.close(fd);
        self.arena.deinit();
    }

    fn push(self: *Session, fd: posix.fd_t) void {
        self.dirs[self.depth] = fd;
        self.depth += 1;
    }

    fn leaf(self: *const Session) posix.fd_t {
        return self.dirs[self.depth - 1];
    }

    pub fn now(_: *Session) ?u64 {
        return collect.bootMillis() catch null;
    }

    pub fn inspect(self: *Session, phase: admission.Phase) ?runner.Status {
        const job_memory = memory(self.leaf()) catch return .measurements_unavailable;
        const cap = switch (job_memory.max) {
            .unlimited => return .isolation_unavailable,
            .bytes => |bytes| bytes,
        };
        if (!validLimits(self.leaf())) return .isolation_unavailable;
        switch (phase) {
            .start => {
                if (cap == 0 or admission.headroom(job_memory) < self.config.measured_peak_bytes) return .insufficient_headroom;
                self.cap = cap;
            },
            .running => if (cap != self.cap) return .isolation_unavailable,
        }

        var host_buf: [collect.kernel_read_limit]u8 = undefined;
        const host_available = switch (collect.readKernel("/proc/meminfo", &host_buf)) {
            .value => |bytes| switch (collect.memory(bytes)) {
                .value => |measurement| measurement.available_bytes,
                .reason => return .measurements_unavailable,
            },
            .reason => return .measurements_unavailable,
        };
        const memory_psi = hostPressure("/proc/pressure/memory") orelse return .measurements_unavailable;
        const cpu_psi = hostPressure("/proc/pressure/cpu") orelse return .measurements_unavailable;

        var ancestors: [max_depth - 1]admission.Memory = undefined;
        const dirs = self.dirs[1 .. self.depth - 1];
        for (dirs, 0..) |fd, i| ancestors[i] = memory(fd) catch return .measurements_unavailable;
        const measurements: admission.Measurements = .{
            .host_available = host_available,
            .memory_psi = memory_psi,
            .cpu_psi = cpu_psi,
            .ancestors = ancestors[0..dirs.len],
        };
        return switch (admission.check(measurements, .{ .cap = self.cap, .reserve = self.config.reserve_bytes, .current = job_memory.current }, phase)) {
            .admit => null,
            .insufficient_headroom => .insufficient_headroom,
            .pressure => .pressure,
        };
    }

    pub fn start(self: *Session) ?runner.Status {
        const occupied = populated(self.leaf()) catch return .isolation_unavailable;
        if (occupied) return .busy;
        const parent = linux.getpid();
        const out = capturePipe() catch return .backend_failed;
        defer posix.close(out[1]);
        self.out = out[0];
        const err = capturePipe() catch return .backend_failed;
        defer posix.close(err[1]);
        self.err = err[0];
        const stdin = posix.open("/dev/null", read_flags, 0) catch return .backend_failed;
        defer posix.close(stdin);
        const child_stdin = aboveStdio(stdin) catch return .backend_failed;
        defer if (child_stdin != stdin) posix.close(child_stdin);

        var gate: [2]posix.fd_t = undefined;
        const socket_type = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
        if (linux.E.init(linux.socketpair(posix.AF.UNIX, socket_type, 0, &gate)) != .SUCCESS)
            return .isolation_unavailable;
        defer close(&gate[0]);
        defer close(&gate[1]);
        const pid = posix.fork() catch return .isolation_unavailable;
        if (pid == 0) {
            close(&gate[0]);
            self.execChild(parent, gate[1], child_stdin, out[1], err[1]);
        }
        close(&gate[1]);
        self.child = pid;

        // Only trusted setup runs before the gate. The child cannot exec until
        // its PID is attached. Gated attach also avoids a kernel clone3 bug
        // that kills later CLONE_INTO_CGROUP jobs after cgroup.kill.
        var pid_buf: [24]u8 = undefined;
        const pid_text = std.fmt.bufPrint(&pid_buf, "{d}\n", .{pid}) catch unreachable;
        self.placed = linux.write(self.procs_fd, pid_text.ptr, pid_text.len) == pid_text.len;
        if (!self.placed or linux.sendto(gate[0], "1", 1, linux.MSG.NOSIGNAL, null, 0) != 1) {
            close(&gate[0]); // EOF makes a child awaiting permission exit.
            return if (self.cleanup()) .isolation_unavailable else .cleanup_failed;
        }
        return null;
    }

    fn execChild(self: *const Session, parent: posix.pid_t, gate: posix.fd_t, stdin: posix.fd_t, out: posix.fd_t, stderr: posix.fd_t) noreturn {
        if (linux.E.init(linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), posix.SIG.KILL, 0, 0, 0)) != .SUCCESS or linux.getppid() != parent)
            posix.exit(125);
        var permission: [1]u8 = undefined;
        if (linux.read(gate, &permission, 1) != 1 or permission[0] != '1') posix.exit(125);
        posix.close(gate);
        if (linux.E.init(linux.syscall0(.setsid)) != .SUCCESS) posix.exit(125);
        if (linux.E.init(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS)
            posix.exit(125);
        if (linux.E.init(linux.syscall2(.landlock_restrict_self, @intCast(self.landlock_fd), 0)) != .SUCCESS)
            posix.exit(125);

        posix.dup2(stdin, posix.STDIN_FILENO) catch posix.exit(125);
        posix.dup2(out, posix.STDOUT_FILENO) catch posix.exit(125);
        posix.dup2(stderr, posix.STDERR_FILENO) catch posix.exit(125);
        if (linux.E.init(linux.syscall3(.close_range, 3, std.math.maxInt(u32), 0)) != .SUCCESS)
            posix.exit(125);
        if (linux.E.init(linux.chdir("/")) != .SUCCESS or !filter.install()) posix.exit(125);
        const env = [_:null]?[*:0]const u8{"LANG=C"};
        _ = linux.execve(self.argv[0].?, &self.argv, &env);
        posix.exit(126);
    }

    pub fn step(self: *Session, capture: *runner.Capture, delay: u16) ?runner.Status {
        var fds = [_]posix.pollfd{
            .{ .fd = self.out, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.err, .events = posix.POLL.IN, .revents = 0 },
        };
        switch (linux.E.init(linux.poll(&fds, fds.len, delay))) {
            .INTR => return null,
            .SUCCESS => {},
            else => return .backend_failed,
        }
        for (fds, [_]*posix.fd_t{ &self.out, &self.err }, 0..) |ready, fd, index| {
            if (ready.revents == 0) continue;
            var buf: [2048]u8 = undefined;
            const n = linux.read(fd.*, &buf, buf.len);
            switch (linux.E.init(n)) {
                .INTR, .AGAIN => continue,
                .SUCCESS => {},
                else => return .backend_failed,
            }
            if (n == 0) {
                close(fd);
            } else {
                capture.add(buf[0..n], index == 0) catch return .output_limit;
            }
        }
        if (!self.reap()) return null;
        if (self.wait_status.? != 0) return .backend_failed;
        if (populated(self.leaf()) catch return .isolation_unavailable) return .backend_failed;
        return if (self.out < 0 and self.err < 0) .completed else null;
    }

    fn reap(self: *Session) bool {
        if (self.wait_status != null) return true;
        var status: u32 = 0;
        const rc = linux.waitpid(self.child, &status, linux.W.NOHANG);
        switch (linux.E.init(rc)) {
            .SUCCESS => if (rc != 0) {
                self.wait_status = status;
            },
            .CHILD => self.wait_status = 1,
            else => {},
        }
        return self.wait_status != null;
    }

    pub fn cleanup(self: *Session) bool {
        close(&self.out);
        close(&self.err);
        const occupied = if (self.placed) populated(self.leaf()) catch true else false;
        if (occupied) {
            // The kernel serializes this recursive kill with fork and migration.
            if (linux.write(self.kill_fd, "1", 1) != 1) return false;
        } else if (!self.reap()) {
            // An unattached child has never run backend instructions. A
            // not-yet-reaped direct child keeps this PID reserved.
            posix.kill(self.child, posix.SIG.KILL) catch {};
        }

        const deadline = (self.now() orelse return false) +| 2000;
        while (true) {
            if (self.reap() and (!self.placed or !(populated(self.leaf()) catch return false))) return true;
            if ((self.now() orelse return false) >= deadline) return false;
            var no_fds: [0]posix.pollfd = .{};
            _ = linux.poll(&no_fds, 0, 10);
        }
    }
};

fn isCgroup2(fd: posix.fd_t) bool {
    // fstatfs writes its native structure. f_type is its first signed long.
    var data: [256]u8 align(@alignOf(c_long)) = undefined;
    const rc = linux.syscall2(.fstatfs, @intCast(fd), @intFromPtr(&data));
    return linux.E.init(rc) == .SUCCESS and @as(*const c_long, @ptrCast(&data)).* == cgroup2_super_magic;
}

fn requireTrueRoot(fd: posix.fd_t) !void {
    // A nonroot v2 cgroup whose children can expose memory limits must
    // itself have a memory controller. The real root has no memory.current.
    const opened = posix.openat(fd, "memory.current", read_flags, 0) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    posix.close(opened);
    return error.IncompleteHierarchy;
}

fn mountId(fd: posix.fd_t) !u64 {
    const statx_mnt_id = 0x1000;
    var metadata: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, statx_mnt_id, &metadata);
    if (linux.E.init(rc) != .SUCCESS or metadata.mask & statx_mnt_id == 0) return error.MountIdUnavailable;
    // Zig 0.15.2 leaves Linux's stx_mnt_id ABI field in the trailing padding.
    return metadata.__pad2[0];
}

fn readAt(dir: posix.fd_t, name: []const u8, buf: []u8) ![]const u8 {
    const fd = try posix.openat(dir, name, read_flags, 0);
    const file: std.fs.File = .{ .handle = fd };
    defer file.close();
    const n = try file.readAll(buf);
    if (n == buf.len) return error.TruncatedMeasurement;
    return buf[0..n];
}

fn memory(fd: posix.fd_t) !admission.Memory {
    var buf: [64]u8 = undefined;
    const current = admission.unsigned(try readAt(fd, "memory.current", &buf)) orelse return error.InvalidMeasurement;
    const high = admission.limit(try readAt(fd, "memory.high", &buf)) orelse return error.InvalidMeasurement;
    const max = admission.limit(try readAt(fd, "memory.max", &buf)) orelse return error.InvalidMeasurement;
    return .{ .current = current, .high = high, .max = max };
}

fn validLimits(fd: posix.fd_t) bool {
    var buf: [64]u8 = undefined;
    const swap = admission.unsigned(readAt(fd, "memory.swap.max", &buf) catch return false) orelse return false;
    const pids = admission.unsigned(readAt(fd, "pids.max", &buf) catch return false) orelse return false;
    const cpu_max = readAt(fd, "cpu.max", &buf) catch return false;
    var fields = std.mem.tokenizeAny(u8, cpu_max, " \t\r\n");
    const quota = admission.unsigned(fields.next() orelse return false) orelse return false;
    const period = admission.unsigned(fields.next() orelse return false) orelse return false;
    return swap == 0 and pids > 0 and pids <= 64 and quota > 0 and quota <= period and fields.next() == null;
}

fn hostPressure(path: []const u8) ?u16 {
    var buf: [512]u8 = undefined;
    const data = switch (collect.readKernel(path, &buf)) {
        .value => |bytes| bytes,
        .reason => return null,
    };
    // Require exactly one line for the measurement we use.
    return admission.pressure(data);
}

fn populated(fd: posix.fd_t) !bool {
    var buf: [512]u8 = undefined;
    var lines = std.mem.splitScalar(u8, try readAt(fd, "cgroup.events", &buf), '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "populated 0")) return false;
        if (std.mem.eql(u8, line, "populated 1")) return true;
    }
    return error.InvalidMeasurement;
}

fn createLandlock() !posix.fd_t {
    const abi = linux.syscall3(.landlock_create_ruleset, 0, 0, 1);
    if (linux.E.init(abi) != .SUCCESS or abi < 3) return error.LandlockUnavailable;
    // Deny file writes, truncate, remove, create, and cross-directory links.
    // No paths receive a write exception, including the delegated hierarchy.
    const denied_fs: u64 = (1 << 1) | (((1 << 15) - 1) & ~@as(u64, (1 << 4) - 1));
    const rc = linux.syscall3(.landlock_create_ruleset, @intFromPtr(&denied_fs), @sizeOf(u64), 0);
    if (linux.E.init(rc) != .SUCCESS) return error.LandlockUnavailable;
    return @intCast(rc);
}

fn capturePipe() ![2]posix.fd_t {
    var fds = try posix.pipe2(.{ .CLOEXEC = true });
    errdefer for (fds) |fd| posix.close(fd);
    for (&fds) |*fd| {
        const moved = try aboveStdio(fd.*);
        if (moved != fd.*) posix.close(fd.*);
        fd.* = moved;
    }
    const flags = try posix.fcntl(fds[0], posix.F.GETFL, 0);
    _ = try posix.fcntl(fds[0], posix.F.SETFL, flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    return fds;
}

fn aboveStdio(fd: posix.fd_t) !posix.fd_t {
    if (fd > posix.STDERR_FILENO) return fd;
    // Linux F_DUPFD_CLOEXEC is absent from Zig 0.15.2's F namespace.
    return @intCast(try posix.fcntl(fd, 1030, 3));
}

fn close(fd: *posix.fd_t) void {
    if (fd.* >= 0) posix.close(fd.*);
    fd.* = -1;
}
