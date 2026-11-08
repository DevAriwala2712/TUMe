const std = @import("std");
const procedure = @import("procedure.zig");
const engine = @import("engine.zig");

pub const unit_file = "/etc/systemd/system/" ++ procedure.unit;
pub const socket_path = "/run/tume-recovery-demo/probe.sock";
pub const request = "TUME-PING 1\n";
pub const response = "TUME-PONG 1\n";

const Property = enum { Id, FragmentPath, LoadState, ActiveState, MainPID, Job, InvocationID, DropInPaths, NeedDaemonReload };

pub fn parseService(bytes: []const u8) ?engine.Service {
    var values: std.EnumMap(Property, []const u8) = .{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null) break;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse return null;
        const property = std.meta.stringToEnum(Property, line[0..separator]) orelse return null;
        if (values.contains(property)) return null;
        values.put(property, line[separator + 1 ..]);
    }
    if (!std.mem.eql(u8, values.get(.Id) orelse return null, procedure.unit) or
        !std.mem.eql(u8, values.get(.FragmentPath) orelse return null, unit_file) or
        !std.mem.eql(u8, values.get(.LoadState) orelse return null, "loaded") or
        !std.mem.eql(u8, values.get(.NeedDaemonReload) orelse return null, "no") or
        (values.get(.DropInPaths) orelse return null).len != 0) return null;
    const active = values.get(.ActiveState) orelse return null;
    const state = std.meta.stringToEnum(procedure.State, active) orelse procedure.State.transitioning;
    const pid = decimal(u32, values.get(.MainPID) orelse return null) orelse return null;
    const job = values.get(.Job) orelse return null;
    const job_id = if (job.len == 0) 0 else decimal(u32, job) orelse return null;
    const instance = values.get(.InvocationID) orelse return null;
    const invocation = procedure.parseId(instance) catch null;
    if (state == .active and invocation == null) return null;
    return .{ .state = state, .pid = pid, .job_pending = job_id != 0, .invocation = invocation };
}

fn decimal(comptime T: type, bytes: []const u8) ?T {
    if (bytes.len == 0) return null;
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseUnsigned(T, bytes, 10) catch null;
}

pub fn parseWindow(bytes: []const u8) ?engine.Window {
    if (!std.mem.startsWith(u8, bytes, procedure.policy) or bytes.len <= procedure.policy.len or
        bytes[bytes.len - 1] != '\n') return null;
    var fields = std.mem.splitScalar(u8, bytes[procedure.policy.len .. bytes.len - 1], ' ');
    const window: engine.Window = .{
        .boot = procedure.parseId(fields.next() orelse return null) catch return null,
        .start = decimal(u64, fields.next() orelse return null) orelse return null,
        .end = decimal(u64, fields.next() orelse return null) orelse return null,
    };
    return if (fields.next() == null and window.valid()) window else null;
}
