const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const collect = @import("../health/collect.zig");
const probe = @import("../health/probe.zig");
const procedure = @import("procedure.zig");
const ledger = @import("ledger.zig");
const engine = @import("engine.zig");
const native = @import("native.zig");
const protocol = @import("protocol.zig");

const state_path = "/var/lib/tume-recovery";
const allocator = std.heap.page_allocator;

pub fn main() void {
    if (builtin.os.tag != .linux) {
        std.debug.print("tume-recovery-executor requires Linux\n", .{});
        std.process.exit(2);
    }
    std.process.exit(run() catch |err| {
        std.debug.print("recovery executor: {s}\n", .{@errorName(err)});
        returnCode(err);
    });
}

pub fn automaticMain() void {
    if (builtin.os.tag != .linux) {
        std.debug.print("tume-recovery-automatic requires Linux\n", .{});
        std.process.exit(2);
    }
    std.process.exit(runAutomatic() catch |err| {
        std.debug.print("automatic recovery: {s}\n", .{@errorName(err)});
        switch (err) {
            error.AutomaticPolicyDisabled, error.MaintenanceWindowClosed, error.AutomaticRateLimited, error.ApprovalAlreadyPending, error.PreconditionsFailed => std.process.exit(0),
            else => returnCode(err),
        }
    });
}

fn runAutomatic() !u8 {
    if (posix.getuid() != 0 or posix.geteuid() != 0 or try actor() != 0) return error.TrustedRootRequired;
    var args = std.process.args();
    _ = args.skip();
    if (args.next() != null) return error.InvalidUsage;
    try validateStandardDescriptors();
    const identity = try readIdentity(0);
    var dir = try openState();
    defer dir.close();
    if (readAutomaticPolicy(&dir) == null) return error.AutomaticPolicyDisabled;

    var store = try ledger.Store.lock(dir, allocator);
    defer store.close();
    var id: procedure.Id = undefined;
    std.crypto.random.bytes(&id);
    const result = try engine.automatic(&store, native.operations(), .{
        .context = &dir,
        .read = readAutomaticPolicy,
    }, identity, id);
    var output: [64]u8 = undefined;
    try std.fs.File.stdout().writeAll(try std.fmt.bufPrint(&output, "Automatic attempt {s}\n", .{std.fmt.bytesToHex(id, .lower)}));
    return report(result, .automatic);
}

fn readAutomaticPolicy(context: *anyopaque) ?engine.Window {
    const dir: *std.fs.Dir = @ptrCast(@alignCast(context));
    if (!(enabled(dir.*) catch return null)) return null;
    const fd = posix.openat(dir.fd, "automatic-policy", .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0) catch return null;
    const file: std.fs.File = .{ .handle = fd };
    defer file.close();
    ledger.privateFile(fd) catch return null;
    var bytes: [160]u8 = undefined;
    const n = file.readAll(&bytes) catch return null;
    if (n == bytes.len) return null;
    const window = protocol.parseWindow(bytes[0..n]) orelse return null;
    if (posix.fstatat(dir.fd, "automatic-stop", posix.AT.SYMLINK_NOFOLLOW)) |_| {
        return null;
    } else |err| {
        if (err != error.FileNotFound) return null;
    }
    return window;
}

fn validateStandardDescriptors() !void {
    for (0..3) |fd| _ = posix.fcntl(@intCast(fd), posix.F.GETFD, 0) catch return error.InvalidStandardDescriptors;
}

fn openState() !std.fs.Dir {
    var dir: std.fs.Dir = .{ .fd = try trustedDirectory(state_path) };
    errdefer dir.close();
    if (!try probe.isExt4(dir.fd)) return error.UnsupportedAuditFilesystem;
    return dir;
}

fn returnCode(err: anyerror) noreturn {
    std.process.exit(switch (err) {
        error.InvalidUsage, error.UnregisteredTarget, error.InvalidApprovalId => 2,
        error.AmbiguousAuditWrite, error.UncertainAuditDurability, error.ReconciliationRequired => 4,
        else => 3,
    });
}

const Command = union(enum) {
    approve: procedure.Target,
    execute: procedure.Id,
    reconcile: procedure.Id,
    audit,
};

fn arguments(args: []const []const u8) !Command {
    if (args.len == 1 and std.mem.eql(u8, args[0], "audit")) return .audit;
    if (args.len != 2) return error.InvalidUsage;
    if (std.mem.eql(u8, args[0], "approve")) return .{ .approve = try procedure.parseTarget(args[1]) };
    if (std.mem.eql(u8, args[0], "execute")) return .{ .execute = try procedure.parseId(args[1]) };
    if (std.mem.eql(u8, args[0], "reconcile")) return .{ .reconcile = try procedure.parseId(args[1]) };
    return error.InvalidUsage;
}

fn run() !u8 {
    if (posix.getuid() != 0 or posix.geteuid() != 0) return error.TrustedLocalOperatorRequired;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const cmd = arguments(args[1..]) catch |err| {
        std.debug.print("Usage: tume-recovery-executor {{approve UNIT|execute ID|reconcile ID|audit}}\n", .{});
        return err;
    };
    try validateStandardDescriptors();
    const identity = try readIdentity(try actor());
    var dir = try openState();
    defer dir.close();
    const ops = native.operations();
    switch (cmd) {
        .approve => |target| {
            if (!try enabled(dir)) return error.ProcedureDisabled;
            var id: procedure.Id = undefined;
            std.crypto.random.bytes(&id);
            const encoded = std.fmt.bytesToHex(id, .lower);
            var challenge_buf: [64]u8 = undefined;
            const challenge = try std.fmt.bufPrint(&challenge_buf, "approve {s}", .{encoded});
            try confirm(procedure.preview, challenge);
            var store = try ledger.Store.lock(dir, allocator);
            defer store.close();
            try engine.approve(&store, ops, try enabled(dir), identity, target, id);
            const approval = store.last(id).?;
            var output: [192]u8 = undefined;
            try std.fs.File.stdout().writeAll(try std.fmt.bufPrint(&output, "Approval {s}\nExpires at boot time {d} ms\n", .{ encoded, approval.expires.? }));
            return 0;
        },
        .execute => |id| {
            var store = try ledger.Store.lock(dir, allocator);
            defer store.close();
            return report(try engine.execute(&store, ops, try enabled(dir), identity, id), .manual);
        },
        .reconcile => |id| {
            var challenge_buf: [64]u8 = undefined;
            const challenge = try std.fmt.bufPrint(&challenge_buf, "reconcile {s}", .{std.fmt.bytesToHex(id, .lower)});
            try confirm("Confirm that you checked the local systemd job and journal for the ambiguous restart. " ++
                "Reconciliation checks current health and does not dispatch a restart.\n", challenge);
            var store = try ledger.Store.lock(dir, allocator);
            defer store.close();
            return report(try engine.reconcile(&store, ops, identity, id), .reconciliation);
        },
        .audit => {
            var store = try ledger.Store.lock(dir, allocator);
            defer store.close();
            const bytes = try store.encode();
            defer allocator.free(bytes);
            try std.fs.File.stdout().writeAll(bytes);
            try std.fs.File.stdout().writeAll("\n");
            return 0;
        },
    }
}

fn actor() !u32 {
    // A direct root operator has root authority. The supplied sudo policy
    // resets the environment and forbids command-line environment overrides.
    var path_buf: [64]u8 = undefined;
    const parent_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/exe", .{linux.getppid()});
    const supplied_uid = std.posix.getenv("SUDO_UID");
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent = std.fs.readLinkAbsolute(parent_path, &exe_buf) catch {
        if (supplied_uid != null) return error.TrustedLocalOperatorRequired;
        return 0;
    };
    if (!std.mem.eql(u8, parent, "/usr/bin/sudo")) {
        if (supplied_uid != null) return error.TrustedLocalOperatorRequired;
        return 0;
    }
    const uid = supplied_uid orelse return error.TrustedLocalOperatorRequired;
    if (uid.len == 0) return error.TrustedLocalOperatorRequired;
    for (uid) |c| if (!std.ascii.isDigit(c)) return error.TrustedLocalOperatorRequired;
    return std.fmt.parseUnsigned(u32, uid, 10) catch return error.TrustedLocalOperatorRequired;
}

fn trustedDirectory(path: []const u8) !posix.fd_t {
    const flags: posix.O = .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };
    var fd = try posix.open("/", flags, 0);
    errdefer posix.close(fd);
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (true) {
        const info = try posix.fstat(fd);
        if (info.uid != 0 or info.mode & 0o022 != 0) return error.UnsafeTrustedDirectory;
        const name = parts.next() orelse break;
        const next = try posix.openat(fd, name, flags, 0);
        posix.close(fd);
        fd = next;
    }
    return fd;
}

fn readIdentity(uid: u32) !procedure.Identity {
    const etc = try trustedDirectory("/etc");
    defer posix.close(etc);
    const fd = try posix.openat(etc, "machine-id", .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
    const file: std.fs.File = .{ .handle = fd };
    defer file.close();
    const info = try posix.fstat(fd);
    if (!posix.S.ISREG(info.mode) or info.uid != 0 or info.mode & 0o022 != 0) return error.DeviceIdentityUnavailable;
    var bytes: [34]u8 = undefined;
    if (try file.readAll(&bytes) != 33 or bytes[32] != '\n') return error.DeviceIdentityUnavailable;
    const device = procedure.parseId(bytes[0..32]) catch return error.DeviceIdentityUnavailable;
    const stamp = try collect.stamp();
    var boot_bytes: [32]u8 = undefined;
    var i: usize = 0;
    for (stamp.boot_id) |byte| {
        if (byte == '-') continue;
        boot_bytes[i] = byte;
        i += 1;
    }
    return .{ .actor = uid, .device = device, .boot = procedure.parseId(&boot_bytes) catch return error.DeviceIdentityUnavailable };
}

fn enabled(dir: std.fs.Dir) !bool {
    const fd = posix.openat(dir.fd, "policy", .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    const file: std.fs.File = .{ .handle = fd };
    defer file.close();
    try ledger.privateFile(fd);
    var bytes: [procedure.policy.len + 1]u8 = undefined;
    const count = try file.readAll(&bytes);
    return std.mem.eql(u8, bytes[0..count], procedure.policy);
}

fn confirm(description: []const u8, challenge: []const u8) !void {
    const fd = posix.open("/dev/tty", .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NONBLOCK = true }, 0) catch
        return error.TrustedLocalOperatorRequired;
    const tty: std.fs.File = .{ .handle = fd };
    defer tty.close();
    if (!posix.isatty(fd)) return error.TrustedLocalOperatorRequired;
    // Discard terminal input queued before the prompt.
    const tcflsh = 0x540b; // Linux TCFLSH, with TCIFLUSH = 0.
    if (linux.E.init(linux.ioctl(fd, tcflsh, 0)) != .SUCCESS) return error.TrustedLocalOperatorRequired;
    try tty.writeAll(description);
    try tty.writeAll("Type exactly: ");
    try tty.writeAll(challenge);
    try tty.writeAll("\n> ");

    const deadline = (try collect.bootMillis()) + 60_000;
    var input: [80]u8 = undefined;
    var used: usize = 0;
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    while (used < input.len) {
        const now = try collect.bootMillis();
        if (now >= deadline) return error.OperatorConfirmationExpired;
        switch (linux.E.init(linux.poll(&fds, fds.len, @intCast(deadline - now)))) {
            .SUCCESS => if (fds[0].revents & posix.POLL.IN == 0) return error.OperatorConfirmationExpired,
            .INTR => continue,
            else => return error.TrustedLocalOperatorRequired,
        }
        const count = tty.read(input[used..][0..1]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (count == 0) return error.OperatorConfirmationRejected;
        if (input[used] == '\n') {
            if (!std.mem.eql(u8, input[0..used], challenge)) return error.OperatorConfirmationRejected;
            return;
        }
        used += count;
    }
    return error.OperatorConfirmationRejected;
}

fn report(outcome: engine.Outcome, mode: enum { manual, automatic, reconciliation }) !u8 {
    const message: []const u8 = switch (outcome) {
        .verified => switch (mode) {
            .manual => "Restart verified by independent service and functional checks.\n",
            .automatic => "Service and functional health verified after the automatic start request.\n",
            .reconciliation => "Current service and functional health verified; earlier dispatch may be unknown.\n",
        },
        .unverified => "Service or functional verification failed. Escalate to the operator. Rollback is unavailable.\n",
        .ambiguous => "Recovery outcome is ambiguous. Check the systemd job and journal, then explicitly reconcile.\n",
    };
    try std.fs.File.stdout().writeAll(message);
    return switch (outcome) {
        .verified => 0,
        .unverified => 5,
        .ambiguous => 4,
    };
}
