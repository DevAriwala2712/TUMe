const std = @import("std");
const testing = std.testing;
const config = @import("config.zig");
const collect = @import("collect.zig");

test "tume health task 1 canonical config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ab = try config.parse(a, "{\"mount\":\"/\",\"services\":[\"a.service\",\"b.service\"]}");
    const ba = try config.parse(a, "{\"services\":[\"b.service\",\"a.service\"],\"mount\":\"/\",\"state_dir\":\"/tmp/tume\"}");
    try testing.expect(config.sameTarget(ab.target, ba.target));
    try testing.expectEqualStrings("a.service", ba.target.services[0]);
    for ([_][]const u8{
        "{\"mount\":\"/\",\"mount\":\"/tmp\"}",
        "{\"mount\":\"/\",\"services\":[\"a.service\",\"b.service\",\"c.service\",\"d.service\",\"e.service\"]}",
        "{\"mount\":\"/tmp/../data\"}",
        "{\"mount\":\"/\",\"services\":[\"-a.service\"]}",
        "{\"mount\":\"/\",\"services\":[\"a.service\",\"a.service\"]}",
        "{\"mount\":\"/\",\"thermal_zone\":\"3\"}",
        "{\"mount\":\"/\",\"extra\":true}",
        " " ** 4097,
    }) |input| try testing.expectError(error.InvalidConfig, config.parse(a, input));
}

test "tume health task 1 memory and PSI stay independent" {
    try testing.expectEqual(@as(u64, 134217728), collect.memory("MemTotal: 524288 kB\nMemAvailable: 131072 kB\n").value.available_bytes);
    try testing.expectEqual(.invalid, collect.memory("MemTotal: 524288 kB\nMemFree: 131072 kB\n").reason);
    try testing.expectEqual(.invalid, collect.memory("MemTotal: 18446744073709551615 kB\nMemAvailable: 1 kB\n").reason);
    try testing.expectEqual(@as(u16, 101), collect.psi("some avg10=1.005 avg60=0.00 total=4\n").value);
    try testing.expectEqual(.invalid, collect.psi("some avg10=nan total=4\n").reason);
}
