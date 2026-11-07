const std = @import("std");
const builtin = @import("builtin");
const collect = @import("collect.zig");
const config = @import("config.zig");
const findings = @import("findings.zig");
const probe = @import("probe.zig");
const report = @import("report.zig");
const types = @import("types.zig");

const Mode = enum { snapshot };
const Args = struct { mode: Mode, config_path: []const u8 };

fn arguments(args: []const []const u8) !Args {
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--config")) return error.InvalidUsage;
    const mode = std.meta.stringToEnum(Mode, args[0]) orelse return error.InvalidUsage;
    return .{ .mode = mode, .config_path = args[2] };
}

fn readConfig(a: std.mem.Allocator, path: []const u8) !types.Config {
    const fd = try std.posix.open(path, .{ .CLOEXEC = true, .NONBLOCK = true }, 0);
    const file: std.fs.File = .{ .handle = fd };
    defer file.close();
    if ((try file.stat()).kind != .file) return error.InvalidConfig;
    var buffer: [4097]u8 = undefined;
    const len = try file.readAll(&buffer);
    return config.parse(a, buffer[0..len]);
}

pub fn snapshot(a: std.mem.Allocator, target: types.Target, sample: types.Sample) ![]u8 {
    return report.encode(a, .{
        .target = target,
        .sample = sample,
        .mode = .snapshot,
        .findings = try findings.instant(a, target, sample),
    });
}

fn collectSnapshot(a: std.mem.Allocator, target: types.Target) !void {
    var runner: probe.Runner = .{};
    defer runner.stop();
    const sample = try collect.take(a, target, try collect.stamp(), &runner);
    try std.fs.File.stdout().writeAll(try snapshot(a, target, sample));
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    if (builtin.os.tag != .linux) {
        std.debug.print("health requires Linux\n", .{});
        return 2;
    }
    const options = arguments(args) catch {
        std.debug.print("Usage: nanoclaw-next health snapshot --config PATH\n", .{});
        return 2;
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = readConfig(a, options.config_path) catch |err| {
        std.debug.print("health config: {s}\n", .{@errorName(err)});
        return 2;
    };
    const result = switch (options.mode) {
        .snapshot => collectSnapshot(a, loaded.target),
    };
    result catch |err| {
        std.debug.print("health: {s}\n", .{@errorName(err)});
        return 3;
    };
    return 0;
}
