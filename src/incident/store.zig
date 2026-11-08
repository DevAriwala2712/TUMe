const std = @import("std");
const posix = std.posix;
const timeline = @import("timeline.zig");
const types = @import("../health/types.zig");
const report = @import("../health/report.zig");
const state = @import("../health/state.zig");
const strict_json = @import("../health/strict_json.zig");

const latest = "history.json";
const temporary = ".history.tmp";

pub fn decode(a: std.mem.Allocator, bytes: []const u8, now: ?types.Stamp) !timeline.History {
    if (bytes.len > timeline.max_bytes) return error.InvalidHistory;
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidHistory,
    };
    if (root != .object) return error.InvalidHistory;
    const version = root.object.get("schema_version") orelse return error.InvalidHistory;
    if (version != .integer or version.integer < 0) return error.InvalidHistory;
    if (version.integer != 1) return error.IncompatibleHistory;
    if (!strict_json.matches(timeline.History, root)) return error.InvalidHistory;
    const history = std.json.parseFromValueLeaky(timeline.History, a, root, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidHistory,
    };
    if (!timeline.validate(history, now)) return error.InvalidHistory;
    return history;
}

pub fn read(a: std.mem.Allocator, dir: posix.fd_t, now: ?types.Stamp) !timeline.History {
    var store: state.Store = .{ .dir = dir };
    const file = store.openPrivate(latest, true) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close();
    const bytes = try a.alloc(u8, timeline.max_bytes + 1);
    const length = try file.readAll(bytes);
    return decode(a, bytes[0..length], now);
}

pub fn lock(dir: posix.fd_t) !posix.fd_t {
    var flags = state.private_read;
    flags.ACCMODE = .RDWR;
    flags.CREAT = true;
    const fd = try posix.openat(dir, "history.lock", flags, 0o600);
    errdefer posix.close(fd);
    try state.Store.validateFile(fd, false);
    try posix.flock(fd, posix.LOCK.EX | posix.LOCK.NB);
    return fd;
}

pub const PersistOptions = struct {
    sync: *const fn (posix.fd_t, state.SyncPhase) anyerror!void = state.syncFd,
    before_rename: ?*const fn (u64) anyerror!void = null,
    deadline: u64 = 0,
};

/// The caller holds the separate history lock from read through rename.
pub fn persist(a: std.mem.Allocator, dir: posix.fd_t, initial: timeline.History, options: PersistOptions) !void {
    var history = initial;
    const bytes = while (true) {
        break report.encodeJson(a, history, timeline.max_bytes) catch |err| switch (err) {
            error.ReportTooLarge => {
                if (history.events.len == 0) return err;
                history.events = history.events[1..];
                history.truncated = true;
                continue;
            },
            else => return err,
        };
    };
    var store: state.Store = .{ .dir = dir };
    _ = try store.checkedExisting(latest);
    if (try store.checkedExisting(temporary)) try posix.unlinkat(dir, temporary, 0);
    var flags = state.private_read;
    flags.ACCMODE = .WRONLY;
    flags.CREAT = true;
    flags.EXCL = true;
    const fd = try posix.openat(dir, temporary, flags, 0o600);
    const file: std.fs.File = .{ .handle = fd };
    defer file.close();
    var renamed = false;
    defer if (!renamed) posix.unlinkat(dir, temporary, 0) catch {};
    try posix.fchmod(fd, 0o600);
    try file.writeAll(bytes);
    try options.sync(fd, .file);
    if (options.before_rename) |check| try check(options.deadline);
    try posix.renameat(dir, temporary, dir, latest);
    renamed = true;
    options.sync(dir, .directory) catch return error.UncertainDurability;
}
