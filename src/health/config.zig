const std = @import("std");
const types = @import("types.zig");
const strict_json = @import("strict_json.zig");

const Wire = struct {
    mount: []const u8,
    services: [][]const u8 = &.{},
    thermal_zone: std.json.Value = .null,
    state_dir: ?[]const u8 = null,
    history: types.HistoryConfig = .{},
};

pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 256 or path[0] != '/') return false;
    if (path.len == 1) return true;
    for (path) |c| if (c < 32 or c == 127) return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub fn validUnit(unit: []const u8) bool {
    if (unit.len <= ".service".len or unit.len > 128 or unit[0] == '-' or
        !std.mem.endsWith(u8, unit, ".service")) return false;
    for (unit) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_.@-", c) == null) return false;
    }
    return true;
}

pub fn validRelease(release: []const u8) bool {
    var parts = std.mem.splitScalar(u8, release, '.');
    for (0..3) |_| {
        const part = parts.next() orelse return false;
        if (part.len == 0 or part.len > 5 or (part.len > 1 and part[0] == '0')) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
        _ = std.fmt.parseInt(u16, part, 10) catch return false;
    }
    return parts.next() == null;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Config strings are owned by the caller's arena.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !types.Config {
    if (bytes.len > 4096) return error.InvalidConfig;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidConfig,
    };
    if (!strict_json.matches(Wire, parsed)) return error.InvalidConfig;
    const wire = std.json.parseFromValueLeaky(Wire, allocator, parsed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidConfig,
    };
    if (!validPath(wire.mount) or wire.services.len > 4) return error.InvalidConfig;
    if (wire.state_dir) |path| {
        if (!validPath(path)) return error.InvalidConfig;
    }
    for (wire.services) |unit| if (!validUnit(unit)) return error.InvalidConfig;
    std.mem.sort([]const u8, wire.services, {}, lessThan);
    for (wire.services, 0..) |unit, i| {
        if (i != 0 and std.mem.eql(u8, unit, wire.services[i - 1])) return error.InvalidConfig;
    }
    const zone: ?u8 = switch (wire.thermal_zone) {
        .null => null,
        .integer => |n| if (n >= 0 and n <= 255) @intCast(n) else return error.InvalidConfig,
        else => return error.InvalidConfig,
    };
    if (!wire.history.enabled and (wire.history.journal_metadata or wire.history.workload_release != null))
        return error.InvalidConfig;
    if (wire.history.workload_release) |release| {
        if (!validRelease(release)) return error.InvalidConfig;
    }
    if (wire.history.enabled and !std.unicode.utf8ValidateSlice(wire.mount)) return error.InvalidConfig;
    return .{
        .target = .{ .mount = wire.mount, .services = wire.services, .thermal_zone = zone },
        .state_dir = wire.state_dir,
        .history = wire.history,
    };
}

pub fn sameTarget(a: types.Target, b: types.Target) bool {
    if (!std.mem.eql(u8, a.mount, b.mount) or a.thermal_zone != b.thermal_zone or
        a.services.len != b.services.len) return false;
    for (a.services, b.services) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}
