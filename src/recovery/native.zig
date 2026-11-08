const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const collect = @import("../health/collect.zig");
const procedure = @import("procedure.zig");
const protocol = @import("protocol.zig");
const engine = @import("engine.zig");

const systemctl = "/usr/bin/systemctl";
const restart_timeout = 8_000;
const inspect_timeout = 2_000;
const probe_timeout = 1_000;
var context: u8 = 0;

pub fn operations() engine.Ops {
    return .{ .context = &context, .now = clock, .inspect = inspect, .restart = restart, .probe = functional };
}

fn clock(_: *anyopaque) ?u64 {
    return collect.bootMillis() catch null;
}

fn inspect(_: *anyopaque) ?engine.Service {
    const argv = [_:null]?[*:0]const u8{
        systemctl,                                                                                                "--system", "--no-pager",   "--no-ask-password", "--all", "show",
        "--property=Id,FragmentPath,LoadState,ActiveState,MainPID,Job,InvocationID,DropInPaths,NeedDaemonReload", "--",       procedure.unit,
    };
    var output: [2048]u8 = undefined;
    const result = command(&argv, &output, inspect_timeout, null) orelse return null;
    if (result != 0) return null;
    return protocol.parseService(std.mem.sliceTo(&output, 0));
}

fn restart(_: *anyopaque, lock_fd: posix.fd_t, permit: engine.Permit) engine.Dispatch {
    const now = collect.bootMillis() catch return .uncertain;
    const pid = posix.fork() catch return .uncertain;
    if (pid == 0) {
        // The supervisor inherits the locked open-file description and stays
        // alive until systemctl has exited, including if the caller dies.
        _ = posix.fcntl(lock_fd, posix.F.GETFD, 0) catch posix.exit(1);
        if (linux.setsid() < 0) posix.exit(1);
        const argv = [_:null]?[*:0]const u8{
            systemctl, "--system", "--no-pager", "--no-ask-password", "--job-mode=fail", @tagName(permit.effect()).ptr, "--", procedure.unit,
        };
        const result = command(&argv, null, restart_timeout, permit) orelse posix.exit(1);
        posix.exit(result);
    }
    const deadline = now + restart_timeout + 1_000;
    while ((collect.bootMillis() catch return .uncertain) < deadline) {
        if (reap(pid)) |code| return if (code == 0) .exit_zero else .uncertain;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    // Leave the supervisor holding the lock if a child cannot yet be reaped.
    return .uncertain;
}

fn command(argv: [*:null]const ?[*:0]const u8, output: ?[]u8, timeout: u64, permit: ?engine.Permit) ?u8 {
    const deadline = (collect.bootMillis() catch return null) + timeout;
    const null_fd = posix.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch return null;
    defer posix.close(null_fd);
    const pipe = if (output != null) posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true }) catch return null else null;
    defer if (pipe) |fds| posix.close(fds[0]);
    const pid = posix.fork() catch {
        if (pipe) |fds| posix.close(fds[1]);
        return null;
    };
    if (pid == 0) {
        if (permit) |authority| {
            if (!authority.allows(operations())) posix.exit(1);
        }
        posix.dup2(null_fd, posix.STDIN_FILENO) catch posix.exit(1);
        posix.dup2(if (pipe) |fds| fds[1] else null_fd, posix.STDOUT_FILENO) catch posix.exit(1);
        posix.dup2(null_fd, posix.STDERR_FILENO) catch posix.exit(1);
        if (linux.E.init(linux.syscall3(.close_range, 3, std.math.maxInt(u32), 0)) != .SUCCESS) posix.exit(1);
        const env = [_:null]?[*:0]const u8{"LC_ALL=C"};
        posix.exit(switch (posix.execveZ(systemctl, argv, &env)) {
            error.AccessDenied, error.PermissionDenied => 126,
            else => 127,
        });
    }
    if (pipe) |fds| posix.close(fds[1]);

    var code: ?u8 = null;
    defer if (code == null) {
        posix.kill(pid, posix.SIG.KILL) catch {};
        if (permit != null) {
            _ = posix.waitpid(pid, 0);
        } else {
            _ = reap(pid);
        }
    };
    var received: usize = 0;
    var eof = pipe == null;
    while ((collect.bootMillis() catch return null) < deadline) {
        if (!eof) {
            const buf = output.?;
            if (received == buf.len - 1) return null;
            if (posix.read(pipe.?[0], buf[received .. buf.len - 1])) |count| {
                if (count == 0) {
                    buf[received] = 0;
                    if (std.mem.indexOfScalar(u8, buf[0..received], 0) != null) return null;
                    eof = true;
                }
                received += count;
            } else |err| switch (err) {
                error.WouldBlock => {},
                else => return null,
            }
        }
        if (code == null) code = reap(pid);
        if (eof and code != null) return code;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return null;
}

fn reap(pid: posix.pid_t) ?u8 {
    var status: u32 = 0;
    const result = linux.waitpid(pid, &status, linux.W.NOHANG);
    return switch (linux.E.init(result)) {
        .SUCCESS => if (result == 0) null else if (posix.W.IFEXITED(status)) posix.W.EXITSTATUS(status) else 1,
        .CHILD => 1,
        else => null,
    };
}

fn functional(_: *anyopaque, pid: u32) bool {
    const address = std.net.Address.initUnix(protocol.socket_path) catch return false;
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.SEQPACKET | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0) catch return false;
    defer posix.close(fd);
    posix.connect(fd, &address.any, address.getOsSockLen()) catch return false;

    const Credentials = extern struct { pid: i32, uid: u32, gid: u32 };
    var peer: Credentials = undefined;
    posix.getsockopt(fd, posix.SOL.SOCKET, posix.SO.PEERCRED, std.mem.asBytes(&peer)) catch return false;
    if (peer.pid <= 0 or @as(u32, @intCast(peer.pid)) != pid or peer.uid == 0) return false;

    if ((posix.send(fd, protocol.request, linux.MSG.NOSIGNAL) catch return false) != protocol.request.len) return false;
    if (!waitReadable(fd, probe_timeout)) return false;
    var reply: [protocol.response.len + 1]u8 = undefined;
    const len = posix.recv(fd, &reply, 0) catch return false;
    return std.mem.eql(u8, reply[0..len], protocol.response);
}

fn waitReadable(fd: posix.fd_t, timeout: u64) bool {
    const deadline = (collect.bootMillis() catch return false) + timeout;
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    while (true) {
        const now = collect.bootMillis() catch return false;
        if (now >= deadline) return false;
        switch (linux.E.init(linux.poll(&fds, fds.len, @intCast(deadline - now)))) {
            .SUCCESS => return fds[0].revents & posix.POLL.IN != 0,
            .INTR => continue,
            else => return false,
        }
    }
}
