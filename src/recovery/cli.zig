const std = @import("std");
const procedure = @import("procedure.zig");

pub fn run(_: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len != 2 or !std.mem.eql(u8, args[0], "preview")) {
        std.debug.print("Usage: nanoclaw-next recovery preview {s}\n", .{procedure.unit});
        return 2;
    }
    _ = procedure.parseTarget(args[1]) catch |err| {
        std.debug.print("recovery: {s}\n", .{@errorName(err)});
        return 2;
    };
    std.fs.File.stdout().writeAll(procedure.preview) catch return 3;
    return 0;
}
