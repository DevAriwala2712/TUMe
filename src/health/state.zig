const std = @import("std");
const posix = std.posix;
const config = @import("config.zig");
const collect = @import("collect.zig");
const findings = @import("findings.zig");
const probe = @import("probe.zig");
const report = @import("report.zig");
const types = @import("types.zig");
const strict_json = @import("strict_json.zig");

pub const Freshness = enum { fresh, absent, stale, invalid, incompatible, unavailable };

pub fn freshness(saved: types.Stamp, current: types.Stamp, same_target: bool) Freshness {
    if (!same_target) return .incompatible;
    if (!std.mem.eql(u8, &saved.boot_id, &current.boot_id)) return .stale;
    if (saved.boot_ms > current.boot_ms) return .invalid;
    return if (current.boot_ms - saved.boot_ms >= 45000) .stale else .fresh;
}

pub const Loaded = struct {
    freshness: Freshness,
    report: ?report.Wire = null,
    confirmed: ?findings.State = null,
};

const latest = "latest.json";
const temporary = ".latest.tmp";
pub const private_read: posix.O = .{ .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true };

pub const SyncPhase = enum { file, directory };
pub fn syncFd(fd: posix.fd_t, _: SyncPhase) !void {
    try posix.fsync(fd);
}

pub const Store = struct {
    dir: posix.fd_t,
    writer_lock: ?posix.fd_t = null,
    sync: *const fn (posix.fd_t, SyncPhase) anyerror!void = syncFd,

    pub fn open(path: []const u8) !Store {
        var store = try fromDirectory(try probe.openDirectory(path));
        errdefer store.close();
        if (!try probe.isExt4(store.dir)) return error.UnsupportedStateFilesystem;
        return store;
    }

    /// Takes ownership of the directory descriptor, including on failure.
    pub fn fromDirectory(dir: posix.fd_t) !Store {
        errdefer posix.close(dir);
        const stat = try posix.fstat(dir);
        if (!posix.S.ISDIR(stat.mode) or stat.uid != posix.geteuid() or
            stat.mode & 0o7777 != 0o700) return error.UnsafeStateDirectory;
        return .{ .dir = dir };
    }

    pub fn validateFile(fd: posix.fd_t, allow_unlinked: bool) !void {
        const stat = try posix.fstat(fd);
        if (!posix.S.ISREG(stat.mode) or stat.uid != posix.geteuid() or
            stat.mode & 0o7777 != 0o600 or stat.nlink > 1 or
            (stat.nlink == 0 and !allow_unlinked)) return error.UnsafeStateFile;
    }

    pub fn lock(self: *Store) !void {
        if (self.writer_lock != null) return error.WatcherLocked;
        var flags = private_read;
        flags.ACCMODE = .RDWR;
        flags.CREAT = true;
        const fd = try posix.openat(self.dir, "writer.lock", flags, 0o600);
        errdefer posix.close(fd);
        try validateFile(fd, false);
        posix.flock(fd, posix.LOCK.EX | posix.LOCK.NB) catch |err| switch (err) {
            error.WouldBlock => return error.WatcherLocked,
            else => return err,
        };
        self.writer_lock = fd;
    }

    pub fn openPrivate(self: *Store, name: []const u8, allow_unlinked: bool) !std.fs.File {
        const fd = try posix.openat(self.dir, name, private_read, 0);
        errdefer posix.close(fd);
        try validateFile(fd, allow_unlinked);
        return .{ .handle = fd };
    }

    pub fn load(self: *Store, a: std.mem.Allocator, target: types.Target, now: ?types.Stamp) Loaded {
        const file = self.openPrivate(latest, true) catch |err| return .{
            .freshness = if (err == error.FileNotFound) .absent else .unavailable,
        };
        defer file.close();
        var bytes: [report.wire_limit + 1]u8 = undefined;
        const n = file.readAll(&bytes) catch return .{ .freshness = .unavailable };
        if (n > report.wire_limit) return .{ .freshness = .invalid };
        // A concurrent rename can publish a sample during the read. Take the
        // reader's time after opening and reading that complete version.
        const checked_at = now orelse collect.stamp() catch return .{ .freshness = .unavailable };
        return decode(a, bytes[0..n], target, checked_at);
    }

    pub fn checkedExisting(self: *Store, name: []const u8) !bool {
        const file = self.openPrivate(name, false) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        file.close();
        return true;
    }

    pub fn publish(self: *Store, a: std.mem.Allocator, value: report.Report, confirmed: findings.State) !void {
        if (self.writer_lock == null) return error.WatcherNotLocked;
        var wire = try report.toWire(a, value);
        var streaks: [7]report.Streak = undefined;
        const len = 3 + value.target.services.len;
        for (streaks[0..len], confirmed.entries[0..len], 0..) |*streak, entry, i| {
            const key = findings.keyAt(value.target, i);
            streak.* = .{ .rule_id = key.rule_id, .subject = key.subject, .breach = entry.breach, .recovery = entry.recovery };
        }
        wire.streaks = streaks[0..len];
        const bytes = try report.encodeJson(a, wire, report.wire_limit);

        _ = try self.checkedExisting(latest);
        if (try self.checkedExisting(temporary)) try posix.unlinkat(self.dir, temporary, 0);
        var flags = private_read;
        flags.ACCMODE = .WRONLY;
        flags.CREAT = true;
        flags.EXCL = true;
        const fd = try posix.openat(self.dir, temporary, flags, 0o600);
        const file: std.fs.File = .{ .handle = fd };
        defer file.close();
        var renamed = false;
        defer if (!renamed) posix.unlinkat(self.dir, temporary, 0) catch {};
        try posix.fchmod(fd, 0o600);
        try file.writeAll(bytes);
        try self.sync(fd, .file);
        try posix.renameat(self.dir, temporary, self.dir, latest);
        renamed = true;
        self.sync(self.dir, .directory) catch return error.UncertainDurability;
    }

    pub fn close(self: *Store) void {
        if (self.writer_lock) |fd| posix.close(fd);
        posix.close(self.dir);
        self.* = undefined;
    }
};

fn decode(a: std.mem.Allocator, bytes: []const u8, target: types.Target, now: types.Stamp) Loaded {
    const invalid: Loaded = .{ .freshness = .invalid };
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_always }) catch return invalid;
    if (root != .object) return invalid;
    const version = root.object.get("schema_version") orelse return invalid;
    if (version != .integer or version.integer < 0) return invalid;
    if (version.integer != report.version) return .{ .freshness = .incompatible };
    if (!strict_json.matches(report.Wire, root)) return invalid;
    var wire = std.json.parseFromValueLeaky(report.Wire, a, root, .{}) catch return invalid;
    if (wire.mode != .watch or !types.validBootId(wire.boot_id)) return invalid;
    if (!config.sameTarget(wire.target, target)) return .{ .freshness = .incompatible };
    if (!validObservations(a, wire)) return invalid;
    const confirmed = restore(a, wire) orelse return invalid;
    const saved: types.Stamp = .{
        .boot_id = wire.boot_id[0..36].*,
        .unix_ms = wire.sampled_at_unix_ms,
        .boot_ms = wire.sampled_at_boot_ms,
    };
    const status = freshness(saved, now, true);
    if (status != .fresh) return .{ .freshness = status };
    wire.streaks = null;
    return .{ .freshness = .fresh, .report = wire, .confirmed = confirmed };
}

fn validObservations(a: std.mem.Allocator, wire: report.Wire) bool {
    const configured_sensor = wire.target.thermal_zone != null;
    const first_service: usize = if (configured_sensor) 5 else 4;
    if (wire.observations.len != first_service + wire.target.services.len) return false;
    for (wire.observations, 0..) |observation, i| {
        const expected = switch (i) {
            0 => "disk.mount",
            1 => "host.cpu_psi",
            2 => "host.memory",
            3 => "host.memory_psi",
            else => if (i < first_service) "sensor.temperature" else findings.evidenceKey(a, .{
                .rule_id = .service_unavailable,
                .subject = wire.target.services[i - first_service],
            }) catch return false,
        };
        if (!std.mem.eql(u8, observation.key, expected)) return false;
        const value = observation.value orelse {
            if (observation.reason == null) return false;
            continue;
        };
        if (observation.reason != null) return false;
        const fields = @as(u8, @intFromBool(value.total_bytes != null)) +
            @intFromBool(value.available_bytes != null) + @intFromBool(value.basis_points != null) +
            @intFromBool(value.millidegrees_c != null) + @intFromBool(value.active_state != null);
        const valid = switch (i) {
            0, 1, 3 => fields == 1 and (value.basis_points orelse return false) <= 10000,
            2 => validMemory: {
                const total = value.total_bytes orelse return false;
                const available = value.available_bytes orelse return false;
                break :validMemory fields == 2 and total > 0 and available <= total;
            },
            else => if (i < first_service) validThermal: {
                const temperature = value.millidegrees_c orelse return false;
                break :validThermal fields == 1 and temperature >= -40000 and temperature <= 150000;
            } else fields == 1 and value.active_state != null,
        };
        if (!valid) return false;
    }
    return true;
}

fn restore(a: std.mem.Allocator, wire: report.Wire) ?findings.State {
    const streaks = wire.streaks orelse return null;
    if (streaks.len != 3 + wire.target.services.len or wire.findings.len > streaks.len) return null;
    var confirmed: findings.State = .{};
    var open_index: usize = 0;
    for (streaks, 0..) |streak, i| {
        const key = findings.keyAt(wire.target, i);
        if (streak.rule_id != key.rule_id or !std.mem.eql(u8, streak.subject, key.subject)) return null;
        if (streak.breach > 2 or streak.recovery > 2 or (streak.breach != 0 and streak.recovery != 0)) return null;
        var opened: ?i64 = null;
        if (open_index < wire.findings.len) {
            const finding = wire.findings[open_index];
            if (finding.rule_id == key.rule_id and std.mem.eql(u8, finding.subject, key.subject)) {
                const expected = findings.evidenceKey(a, key) catch return null;
                if (!std.mem.eql(u8, finding.evidence_key, expected)) return null;
                opened = finding.opened_at_unix_ms;
                open_index += 1;
            }
        }
        if ((streak.breach == 2 and opened == null) or (streak.recovery == 2 and opened != null)) return null;
        confirmed.entries[i] = .{ .breach = streak.breach, .recovery = streak.recovery, .opened_at_unix_ms = opened };
    }
    return if (open_index == wire.findings.len) confirmed else null;
}

test "tume health task 4 reader can finish a report replaced by the watcher" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile("latest.json", .{ .mode = 0o600, .read = true });
    defer file.close();
    try file.writeAll("complete report");
    try temp.dir.deleteFile("latest.json");
    try Store.validateFile(file.handle, true);
    try file.seekTo(0);
    var bytes: [32]u8 = undefined;
    const n = try file.readAll(&bytes);
    try std.testing.expectEqualStrings("complete report", bytes[0..n]);
}
