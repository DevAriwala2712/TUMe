#!/bin/sh
# Native, model-free test for an explicitly authorized disposable Linux host.
set -eu

if [ "$(id -u)" -ne 0 ] || [ "$(uname -s)" != Linux ]; then
    printf '%s\n' 'Run this fixture as root in a disposable Linux host.' >&2
    exit 1
fi
zig=${1:-zig}
cd "$(dirname "$0")/../.."
root=/sys/fs/cgroup
scratch=$(mktemp -d)
source=$(mktemp "$PWD/src/tume-admission-smoke-XXXXXX.zig")
scope="$root/tume-admission-smoke-$$"
broker="$scope/broker"
job="$scope/job"
scope_created=0

cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ "$scope_created" -eq 1 ]; then
        for group in "$job" "$broker"; do
            if [ -e "$group/cgroup.kill" ]; then
                printf 1 > "$group/cgroup.kill" || result=1
                rmdir "$group" || result=1
            fi
        done
        rmdir "$scope" || result=1
    fi
    for file in "$source" "$scratch/smoke" "$scratch/backend"; do
        if [ -f "$file" ]; then rm -- "$file" || result=1; fi
    done
    rmdir "$scratch" || result=1
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
chmod 755 "$scratch"

cat > "$source" <<'ZIG'
const std = @import("std");
const diagnostic = @import("diagnostic/runner.zig");

fn cancel(flag: *std.atomic.Value(bool)) void {
    std.Thread.sleep(400 * std.time.ns_per_ms);
    flag.store(true, .monotonic);
}

fn confirmThread(ran: *std.atomic.Value(bool)) void {
    ran.store(true, .monotonic);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    if (args.len == 3 and std.mem.eql(u8, args[1], "write-probe")) {
        const linux = std.os.linux;
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/cgroup.procs", .{args[2]}, 0);
        const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY }, 0);
        const text = switch (linux.E.init(rc)) {
            .PERM => "write-blocked",
            .ACCES => "write-denied-by-dac",
            .SUCCESS => "write-open-allowed",
            else => "write-unexpected-error",
        };
        try std.fs.File.stdout().writeAll(text);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "socket-probe")) {
        const linux = std.os.linux;
        if (linux.E.init(linux.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0)) != .PERM) return error.SocketAllowed;
        if (linux.E.init(linux.syscall2(.clone3, 0, 0)) != .NOSYS) return error.CloneIntoCgroupAllowed;
        try std.fs.File.stdout().writeAll("socket-and-clone3-blocked");
        return;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "process-probe")) {
        const linux = std.os.linux;
        const broker_pid = try std.fmt.parseUnsigned(u32, args[2], 10);
        if (broker_pid != linux.getppid()) return error.UnexpectedBrokerPid;
        if (linux.syscall1(.getsid, 0) != @as(usize, @intCast(linux.getpid()))) return error.SharedSession;
        // Signal zero checks authorization without delivering a signal.
        if (linux.E.init(linux.syscall2(.kill, broker_pid, 0)) != .PERM) return error.SignalAllowed;
        const invalid_fd = std.math.maxInt(usize);
        for ([_]usize{ 8, 10, 15 }) |command| {
            if (linux.E.init(linux.syscall3(.fcntl, invalid_fd, command, 0)) != .PERM) return error.AsyncSignalOwnershipAllowed;
        }
        if (linux.E.init(linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), 0, 0, 0, 0)) != .PERM)
            return error.ParentDeathSignalChangeAllowed;
        var ran = std.atomic.Value(bool).init(false);
        const worker = try std.Thread.spawn(.{}, confirmThread, .{&ran});
        worker.join();
        if (!ran.load(.monotonic)) return error.ThreadDidNotRun;
        try std.fs.File.stdout().writeAll("process-guard-and-thread-ok");
        return;
    }
    if (args.len != 4) return error.MissingFixtureArguments;
    const job = args[1];
    const mode = args[2];
    var pid_buf: [24]u8 = undefined;
    const self_pid = try std.fmt.bufPrint(&pid_buf, "{d}", .{std.os.linux.getpid()});
    var flag = std.atomic.Value(bool).init(false);
    const thread = if (std.mem.eql(u8, mode, "cancel"))
        try std.Thread.spawn(.{}, cancel, .{&flag})
    else
        null;
    defer if (thread) |worker| worker.join();
    const result = try diagnostic.run(allocator, .{
        .job_cgroup = job,
        .measured_peak_bytes = if (std.mem.eql(u8, mode, "refuse")) 128 << 20 else 4 << 20,
        .reserve_bytes = 4 << 20,
        .timeout_ms = if (std.mem.eql(u8, mode, "timeout")) 400 else 3000,
        .max_output_bytes = 256,
    }, if (std.mem.eql(u8, mode, "network"))
        &.{ args[0], "socket-probe" }
    else if (std.mem.eql(u8, mode, "filesystem"))
        &.{ args[0], "write-probe", job }
    else if (std.mem.eql(u8, mode, "process"))
        &.{ args[0], "process-probe", self_pid }
    else
        &.{ args[3], mode, job }, &flag);
    defer result.deinit(allocator);
    var buffer: [128]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try writer.interface.print("{s}:{s}\n", .{ @tagName(result.status), result.output });
    try writer.interface.flush();
}
ZIG
"$zig" build-exe "$source" -O ReleaseSmall -femit-bin="$scratch/smoke"

cat > "$scratch/backend" <<'BACKEND'
#!/bin/sh
set -eu
case "$1" in
    success) printf fixture-ok ;;
    overflow) printf '%257s' '' >&2 ;;
    timeout|cancel) /usr/bin/setsid /bin/sleep 10 & wait ;;
    descendants) /usr/bin/setsid /bin/sleep 10 & exit 0 ;;
    *) exit 90 ;;
esac
BACKEND
chmod 755 "$scratch/backend"

mkdir "$scope"
scope_created=1
# A host systemd normally enables these on the root already. Refuse if
# unavailable without modifying any existing host cgroup.
printf '%s\n' '+cpu +memory +pids' > "$scope/cgroup.subtree_control"
mkdir "$broker" "$job"
printf '67108864\n' > "$job/memory.max"
printf '0\n' > "$job/memory.swap.max"
printf '20000 100000\n' > "$job/cpu.max"
printf '8\n' > "$job/pids.max"
chown nobody "$scope/cgroup.procs" "$job/cgroup.procs" "$job/cgroup.kill"

assert_case() {
    mode=$1
    expected=$2
    result=$(sh -c '
        printf "%s\n" "$$" > "$1/cgroup.procs"
        exec setpriv --reuid nobody --regid "$(id -g nobody)" --clear-groups --no-new-privs -- "$2" "$3" "$4" "$5"
    ' sh "$broker" "$scratch/smoke" "$job" "$mode" "$scratch/backend")
    if [ "$result" != "$expected" ]; then
        printf '%s\n' "$mode returned $result, expected $expected" >&2
        exit 1
    fi
    if ! awk '$1 == "populated" && $2 == "0" { found=1 } END { exit !found }' "$job/cgroup.events"; then
        printf '%s\n' "$mode left an occupied job cgroup" >&2
        exit 1
    fi
    printf '%s\n' "$mode $result"
}

exec 9< "$root"
flock -n -x 9
assert_case success 'busy:'
flock -u 9
exec 9<&-
assert_case success 'completed:fixture-ok'
assert_case filesystem 'completed:write-blocked'
assert_case network 'completed:socket-and-clone3-blocked'
assert_case process 'completed:process-guard-and-thread-ok'
assert_case overflow 'output_limit:'
assert_case timeout 'timed_out:'
assert_case success 'completed:fixture-ok'
assert_case cancel 'canceled:'
assert_case descendants 'backend_failed:'
assert_case success 'completed:fixture-ok'
assert_case refuse 'insufficient_headroom:'
