const std = @import("std");
const strict_json = @import("../health/strict_json.zig");

pub const Policy = struct {
    schema_version: u16,
    backend: []const u8,
    job_cgroup: []const u8,
    measured_peak_bytes: u64,
    reserve_bytes: u64,
    timeout_ms: u32,
    max_output_bytes: usize,
    max_tokens: u16,
};

fn absolutePath(path: []const u8) bool {
    return path.len > 1 and path.len <= 1024 and path[0] == '/' and std.mem.indexOfScalar(u8, path, 0) == null;
}

pub fn parse(a: std.mem.Allocator, contents: []const u8) !std.json.Parsed(Policy) {
    if (contents.len > 4096) return error.InvalidPolicy;
    const tree = std.json.parseFromSlice(std.json.Value, a, contents, .{}) catch return error.InvalidPolicy;
    defer tree.deinit();
    if (!strict_json.matches(Policy, tree.value)) return error.InvalidPolicy;
    var parsed = std.json.parseFromValue(Policy, a, tree.value, .{ .allocate = .alloc_always }) catch return error.InvalidPolicy;
    errdefer parsed.deinit();
    const p = parsed.value;
    if (p.schema_version != 1 or !absolutePath(p.backend) or !absolutePath(p.job_cgroup) or
        p.measured_peak_bytes == 0 or p.reserve_bytes == 0 or p.timeout_ms == 0 or p.timeout_ms > 120000 or
        p.max_output_bytes == 0 or p.max_output_bytes > 4096 or p.max_tokens == 0 or p.max_tokens > 512)
    {
        return error.InvalidPolicy;
    }
    return parsed;
}

pub fn read(a: std.mem.Allocator, path: []const u8) !std.json.Parsed(Policy) {
    const fd = try std.posix.open(path, .{ .CLOEXEC = true, .NONBLOCK = true, .NOFOLLOW = true }, 0);
    const file: std.fs.File = .{ .handle = fd };
    defer file.close();
    if ((try file.stat()).kind != .file) return error.InvalidPolicy;
    var bytes: [4097]u8 = undefined;
    const len = try file.readAll(&bytes);
    return parse(a, bytes[0..len]);
}

const testing = std.testing;

test "diagnostic policy requires a fixed absolute backend and typed positive budgets" {
    const valid =
        \\{"schema_version":1,"backend":"/opt/tume/explain","job_cgroup":"/sys/fs/cgroup/tume/job",
        \\"measured_peak_bytes":67108864,"reserve_bytes":134217728,"timeout_ms":10000,
        \\"max_output_bytes":4096,"max_tokens":128}
    ;
    const a = testing.allocator;
    var parsed = try parse(a, valid);
    defer parsed.deinit();
    try testing.expectEqual(@as(u16, 128), parsed.value.max_tokens);
    const relative = try std.mem.replaceOwned(u8, a, valid, "/opt/tume/explain", "./explain");
    defer a.free(relative);
    try testing.expectError(error.InvalidPolicy, parse(a, relative));
    const string_budget = try std.mem.replaceOwned(u8, a, valid, "10000", "\"10000\"");
    defer a.free(string_budget);
    try testing.expectError(error.InvalidPolicy, parse(a, string_budget));
    const zero = try std.mem.replaceOwned(u8, a, valid, "67108864", "0");
    defer a.free(zero);
    try testing.expectError(error.InvalidPolicy, parse(a, zero));
}
