const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const Reading = types.Reading;

pub const kernel_read_limit = 8192;

fn memBytes(field: []const u8) ?u64 {
    var parts = std.mem.tokenizeAny(u8, field, " \t");
    const digits = parts.next() orelse return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseUnsigned(u64, digits, 10) catch return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "kB") or parts.next() != null) return null;
    return std.math.mul(u64, n, 1024) catch null;
}

pub fn memory(bytes: []const u8) Reading(types.Memory) {
    var total: ?u64 = null;
    var available: ?u64 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            if (total != null) return .{ .reason = .invalid };
            total = memBytes(line["MemTotal:".len..]) orelse return .{ .reason = .invalid };
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            if (available != null) return .{ .reason = .invalid };
            available = memBytes(line["MemAvailable:".len..]) orelse return .{ .reason = .invalid };
        }
    }
    const total_bytes = total orelse return .{ .reason = .invalid };
    const available_bytes = available orelse return .{ .reason = .invalid };
    if (total_bytes == 0 or available_bytes > total_bytes) return .{ .reason = .invalid };
    return .{ .value = .{ .total_bytes = total_bytes, .available_bytes = available_bytes } };
}

fn basisPoints(decimal: []const u8) ?u16 {
    var parts = std.mem.splitScalar(u8, decimal, '.');
    const whole = parts.first();
    if (whole.len == 0) return null;
    for (whole) |c| if (!std.ascii.isDigit(c)) return null;
    const percent = std.fmt.parseUnsigned(u16, whole, 10) catch return null;
    if (percent > 100) return null;
    var bp = percent * 100;
    if (parts.next()) |fraction| {
        if (fraction.len == 0 or parts.next() != null) return null;
        for (fraction, 0..) |digit, i| {
            if (!std.ascii.isDigit(digit) or (percent == 100 and digit != '0')) return null;
            switch (i) {
                0 => bp += @as(u16, digit - '0') * 10,
                1 => bp += digit - '0',
                2 => if (digit >= '5') {
                    bp += 1;
                },
                else => {},
            }
        }
    }
    return bp;
}

pub fn psi(bytes: []const u8) Reading(u16) {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        if (!std.mem.eql(u8, fields.next() orelse continue, "some")) continue;
        while (fields.next()) |field| {
            if (!std.mem.startsWith(u8, field, "avg10=")) continue;
            return if (basisPoints(field["avg10=".len..])) |bp| .{ .value = bp } else .{ .reason = .invalid };
        }
    }
    return .{ .reason = .invalid };
}

pub fn fileReason(err: anyerror) types.Reason {
    return switch (err) {
        error.FileNotFound => .unsupported,
        error.AccessDenied, error.PermissionDenied => .denied,
        else => .unavailable,
    };
}

pub fn readKernel(path: []const u8, buffer: []u8) Reading([]const u8) {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| return .{ .reason = fileReason(err) };
    defer file.close();
    const n = file.readAll(buffer) catch |err| return .{ .reason = fileReason(err) };
    if (n == buffer.len) return .{ .reason = .truncated };
    return .{ .value = buffer[0..n] };
}

pub fn bootMillis() !u64 {
    if (builtin.os.tag != .linux) return error.ClockUnavailable;
    const now = std.posix.clock_gettime(.BOOTTIME) catch return error.ClockUnavailable;
    return @intCast(now.sec * 1000 + @divTrunc(now.nsec, std.time.ns_per_ms));
}

pub fn stamp() !types.Stamp {
    if (builtin.os.tag != .linux) return error.ClockUnavailable;
    var buffer: [38]u8 = undefined;
    const boot_id = switch (readKernel("/proc/sys/kernel/random/boot_id", &buffer)) {
        .value => |data| std.mem.trimEnd(u8, data, "\n"),
        .reason => return error.ClockUnavailable,
    };
    if (boot_id.len != 36) return error.ClockUnavailable;
    for (boot_id, 0..) |byte, i| {
        const valid = switch (i) {
            8, 13, 18, 23 => byte == '-',
            else => std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'),
        };
        if (!valid) return error.ClockUnavailable;
    }
    const real = std.posix.clock_gettime(.REALTIME) catch return error.ClockUnavailable;
    return .{
        .boot_id = boot_id[0..36].*,
        .unix_ms = real.sec * 1000 + @divTrunc(real.nsec, std.time.ns_per_ms),
        .boot_ms = try bootMillis(),
    };
}
