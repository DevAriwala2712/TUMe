const std = @import("std");
const posix = std.posix;
const procedure = @import("procedure.zig");

pub const max_events = 64;
const max_bytes = 64 * 1024;
const audit_name = "audit.json";
const temp_name = ".audit.tmp";
const version = 1;
const read_flags: posix.O = .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true };

pub const Event = struct {
    kind: enum { approval, intent, automatic_intent, dispatch, finished, reconciled },
    id: procedure.Id,
    identity: procedure.Identity,
    at: u64,
    target: procedure.Target = .demo,
    revision: u16 = procedure.revision,
    expires: ?u64 = null,
    dispatch: ?procedure.Dispatch = null,
    evidence: ?procedure.Evidence = null,
    rollback_eligible: bool = false,
};
const Wire = struct { schema_version: u8, events: []const Event };

pub const Store = struct {
    dir: std.fs.Dir,
    lock_fd: posix.fd_t,
    allocator: std.mem.Allocator,
    records: [max_events]Event = undefined,
    count: usize = 0,
    usable: bool = true,

    /// Borrows the directory. All callers hold the same lock through the last event.
    pub fn lock(dir: std.fs.Dir, allocator: std.mem.Allocator) !Store {
        const info = try posix.fstat(dir.fd);
        if (!posix.S.ISDIR(info.mode) or info.uid != posix.geteuid() or
            info.mode & 0o7777 != 0o700) return error.UnsafeAuditDirectory;
        const fd = try posix.openat(dir.fd, ".executor.lock", .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
            .NONBLOCK = true,
        }, 0o600);
        errdefer posix.close(fd);
        try privateFile(fd);
        posix.flock(fd, posix.LOCK.EX | posix.LOCK.NB) catch |err| switch (err) {
            error.WouldBlock => return error.TargetBusy,
            else => return err,
        };
        var result: Store = .{ .dir = dir, .lock_fd = fd, .allocator = allocator };
        try result.load();
        return result;
    }

    fn load(self: *Store) !void {
        const fd = posix.openat(self.dir.fd, audit_name, read_flags, 0) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer posix.close(fd);
        try privateFile(fd);
        const file: std.fs.File = .{ .handle = fd };
        const bytes = try self.allocator.alloc(u8, max_bytes + 1);
        defer self.allocator.free(bytes);
        const len = try file.readAll(bytes);
        if (len > max_bytes) return error.InvalidAudit;
        const saved = std.json.parseFromSlice(Wire, self.allocator, bytes[0..len], .{}) catch return error.InvalidAudit;
        defer saved.deinit();
        if (saved.value.schema_version != version or saved.value.events.len > max_events) return error.InvalidAudit;
        for (saved.value.events) |event| {
            try self.validate(event);
            self.records[self.count] = event;
            self.count += 1;
        }
    }

    fn validate(self: *const Store, event: Event) !void {
        if (procedure.allZero(event.id) or procedure.allZero(event.identity.device) or
            procedure.allZero(event.identity.boot) or event.revision == 0 or event.rollback_eligible) return error.InvalidAudit;
        const previous = self.last(event.id);
        if (event.kind == .approval) {
            if (previous != null or event.expires == null or event.expires.? <= event.at or
                event.dispatch != null or event.evidence != null or self.pending() != null) return error.InvalidAudit;
            return;
        }
        if (event.kind == .automatic_intent) {
            if (previous != null or event.identity.actor != 0 or self.pending() != null or
                event.expires != null or event.dispatch != null or event.evidence != null) return error.InvalidAudit;
            return;
        }
        const prior = previous orelse return error.InvalidAudit;
        if (!procedure.equal(event.identity.device, prior.identity.device) or event.revision != prior.revision or
            event.target != prior.target or event.expires != null) return error.InvalidAudit;
        if (event.kind != .reconciled and
            (!procedure.sameIdentity(event.identity, prior.identity) or event.at < prior.at)) return error.InvalidAudit;
        const valid = switch (event.kind) {
            .approval, .automatic_intent => unreachable,
            .intent => prior.kind == .approval and event.at < prior.expires.? and self.pending() == null and
                event.dispatch == null and event.evidence == null,
            .dispatch => isIntent(prior) and event.dispatch != null and event.evidence == null,
            .finished => prior.kind == .dispatch and prior.dispatch.? == .exit_zero and
                event.dispatch == null and event.evidence != null,
            .reconciled => (isIntent(prior) or prior.kind == .dispatch) and
                event.dispatch == null and event.evidence != null,
        };
        if (!valid) return error.InvalidAudit;
    }

    pub fn events(self: *const Store) []const Event {
        return self.records[0..self.count];
    }

    pub fn last(self: *const Store, id: procedure.Id) ?Event {
        var i = self.events().len;
        while (i > 0) {
            i -= 1;
            const event = self.events()[i];
            if (procedure.equal(event.id, id)) return event;
        }
        return null;
    }

    pub fn pending(self: *const Store) ?Event {
        const list = self.events();
        if (list.len == 0) return null;
        const event = list[list.len - 1];
        return if (isIntent(event) or event.kind == .dispatch) event else null;
    }

    pub fn reserve(self: *const Store, count: usize) !void {
        if (!self.usable) return error.AuditUnavailable;
        if (count > max_events - self.events().len) return error.AuditFull;
    }

    pub fn encode(self: *const Store) ![]u8 {
        return std.json.Stringify.valueAlloc(self.allocator, Wire{
            .schema_version = version,
            .events = self.events(),
        }, .{});
    }

    pub fn append(self: *Store, event: Event) !void {
        try self.reserve(1);
        try self.validate(event);
        self.records[self.count] = event;
        self.count += 1;
        errdefer {
            self.count -= 1;
            self.usable = false;
        }
        const bytes = try self.encode();
        defer self.allocator.free(bytes);
        if (bytes.len > max_bytes) return error.AuditFull;
        self.dir.deleteFile(temp_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const fd = try posix.openat(self.dir.fd, temp_name, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
            .NONBLOCK = true,
        }, 0o600);
        defer posix.close(fd);
        var renamed = false;
        defer if (!renamed) self.dir.deleteFile(temp_name) catch {};
        try posix.fchmod(fd, 0o600);
        const file: std.fs.File = .{ .handle = fd };
        try file.writeAll(bytes);
        try file.sync();
        try self.dir.rename(temp_name, audit_name);
        renamed = true;
        posix.fsync(self.dir.fd) catch return error.UncertainAuditDurability;
    }

    pub fn close(self: *Store) void {
        posix.close(self.lock_fd);
        self.* = undefined;
    }
};

pub fn privateFile(fd: posix.fd_t) !void {
    const info = try posix.fstat(fd);
    if (!posix.S.ISREG(info.mode) or info.uid != posix.geteuid() or
        info.mode & 0o7777 != 0o600 or info.nlink != 1) return error.UnsafeAuditFile;
}

fn isIntent(event: Event) bool {
    return event.kind == .intent or event.kind == .automatic_intent;
}
