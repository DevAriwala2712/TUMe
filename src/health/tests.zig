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

const probe = @import("probe.zig");

const FakeProbe = struct {
    now: u64 = 0,
    spawns: usize = 0,
    kills: usize = 0,
    reaped: bool = false,
    budget_expired: bool = false,

    fn from(ctx: ?*anyopaque) *FakeProbe {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn clock(ctx: ?*anyopaque) ?u64 {
        return from(ctx).now;
    }

    fn start(ctx: ?*anyopaque, request: probe.Request) ?probe.Child {
        const self = from(ctx);
        self.spawns += 1;
        if (request == .disk and self.budget_expired) {
            self.now = 1500;
            return null;
        }
        return .{ .pid = 1, .out = 3 };
    }

    fn drain(ctx: ?*anyopaque, _: *probe.Child, _: *probe.Capture, delay_ms: u16) probe.DrainError!void {
        from(ctx).now += delay_ms;
    }

    fn reap(ctx: ?*anyopaque, _: probe.Child) ?u32 {
        return if (from(ctx).reaped) 0 else null;
    }

    fn kill(ctx: ?*anyopaque, _: probe.Child) void {
        from(ctx).kills += 1;
    }

    fn close(_: ?*anyopaque, child: *probe.Child) void {
        child.out = -1;
        child.err = -1;
    }

    fn runner(self: *FakeProbe) probe.Runner {
        return .{ .ops = .{
            .ctx = self,
            .clock = clock,
            .start = start,
            .drain = drain,
            .reap = reap,
            .kill = kill,
            .close = close,
        } };
    }
};

test "tume health task 2 bounded helper lifecycle" {
    var fake = FakeProbe{};
    var runner = fake.runner();
    try testing.expectEqual(.timeout, runner.run(.{ .disk = "/" }, 1500).reason);
    try testing.expectEqual(@as(u64, 250), fake.now);
    try testing.expectEqual(.unavailable, runner.run(.{ .service = "gateway.service" }, 1500).reason);
    try testing.expectEqual(@as(usize, 1), fake.spawns);
    try testing.expectEqual(@as(usize, 1), fake.kills);
    fake.reaped = true;
    runner.stop();
    try testing.expectEqual(@as(usize, 1), fake.kills);
    try testing.expect(runner.child == null);
}

test "tume health task 2 typed probes" {
    var capture = probe.Capture{};
    try capture.add("x" ** 4096, true);
    try testing.expectError(error.OutputLimit, capture.add("x", false));
    try testing.expectEqual(.unsupported, probe.serviceReply(1, "LoadState=not-found\nActiveState=inactive\n").reason);
    try testing.expectEqual(.unavailable, probe.serviceReply(1, "LoadState=loaded\nActiveState=failed\n").reason);
    try testing.expectEqual(.activating, probe.serviceReply(0, "LoadState=loaded\nActiveState=activating\n").service);
    try testing.expectEqual(@as(u16, 9000), probe.diskReply(110, 20, 10, true).disk);
    try testing.expectEqual(.invalid, probe.diskReply(10, 10, 0, true).reason);
    try testing.expectEqual(.unsupported, probe.diskReply(110, 20, 10, false).reason);
    try testing.expectEqual(@as(i32, -500), probe.thermalReply("-500\n").temperature);
}

test "tume health task 2 collection keeps kernel data after external probe failure" {
    var fake = FakeProbe{ .budget_expired = true };
    var runner = fake.runner();
    const sample = try collect.assemble(testing.allocator, .{
        .mount = "/",
        .services = &.{"gateway.service"},
        .thermal_zone = 0,
    }, .{ .boot_id = undefined, .boot_ms = 0, .unix_ms = 0 }, &runner, .{
        .memory = .{ .value = .{ .total_bytes = 1000, .available_bytes = 100 } },
        .memory_psi_bp = .{ .value = 120 },
        .cpu_psi_bp = .{ .value = 50 },
    });
    defer testing.allocator.free(sample.services);
    try testing.expectEqual(@as(u64, 100), sample.memory.value.available_bytes);
    try testing.expectEqual(@as(u16, 120), sample.memory_psi_bp.value);
    try testing.expectEqual(.unavailable, sample.disk_used_bp.reason);
    try testing.expectEqual(.timeout, sample.services[0].state.reason);
    try testing.expectEqual(.timeout, sample.temperature_mc.?.reason);
    try testing.expectEqual(@as(usize, 1), fake.spawns);
}

test "tume health task 2 disk descriptor refuses a symlink" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makeDir("real");
    try temp.dir.symLink("real", "link", .{ .is_directory = true });
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_parent = try temp.dir.realpath(".", &path);
    const link = try std.fs.path.join(testing.allocator, &.{ resolved_parent, "link" });
    defer testing.allocator.free(link);
    if (probe.openDirectory(link)) |fd| {
        std.posix.close(fd);
        return error.ExpectedSymlinkRejection;
    } else |_| {}
}

const types = @import("types.zig");
const findings = @import("findings.zig");
const cli = @import("cli.zig");
const target: types.Target = .{ .mount = "/", .services = &.{"gateway.service"}, .thermal_zone = null };

fn testStamp(at: u64) types.Stamp {
    return .{ .boot_id = "fbce98d7-91ea-4477-818a-0bee5324792c".*, .unix_ms = @intCast(at), .boot_ms = at };
}

fn testSample(services: []const types.Service) types.Sample {
    return .{
        .stamp = testStamp(0),
        .collection_ms = 120,
        .memory = .{ .value = .{ .total_bytes = 1 << 30, .available_bytes = 512 << 20 } },
        .memory_psi_bp = .{ .value = 0 },
        .cpu_psi_bp = .{ .reason = .unsupported },
        .disk_used_bp = .{ .value = 7000 },
        .services = services,
        .temperature_mc = null,
    };
}

test "tume health task 3 threshold transitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var confirmed: findings.State = .{};
    var service = [_]types.Service{.{ .unit = target.services[0], .state = .{ .value = .failed } }};
    var sample = testSample(&service);
    try testing.expectEqual(@as(usize, 0), (try findings.advance(a, &confirmed, target, sample)).len);
    sample.stamp = testStamp(15000);
    try testing.expectEqual(.service_unavailable, (try findings.advance(a, &confirmed, target, sample))[0].rule_id);
    sample.stamp = testStamp(30000);
    service[0].state = .{ .value = .activating };
    const transitioning = (try findings.advance(a, &confirmed, target, sample))[0];
    try testing.expect(!transitioning.input_evaluable);
    try testing.expectEqual(@as(i64, 15000), transitioning.opened_at_unix_ms);
    sample.stamp = testStamp(45000);
    service[0].state = .{ .reason = .unsupported };
    try testing.expect(!(try findings.advance(a, &confirmed, target, sample))[0].input_evaluable);
    service[0].state = .{ .value = .active };
    sample.stamp = testStamp(60000);
    try testing.expectEqual(@as(usize, 1), (try findings.advance(a, &confirmed, target, sample)).len);
    sample.stamp = testStamp(75000);
    try testing.expectEqual(@as(usize, 0), (try findings.advance(a, &confirmed, target, sample)).len);

    sample.memory.value.available_bytes = 134217728;
    sample.memory_psi_bp.value = 999;
    sample.disk_used_bp.value = 8999;
    try testing.expectEqual(@as(usize, 0), (try findings.instant(a, target, sample)).len);
    sample.memory.value.available_bytes = 134217727;
    sample.memory_psi_bp.value = 1000;
    sample.disk_used_bp.value = 9000;
    const breaches = try findings.instant(a, target, sample);
    try testing.expectEqual(@as(usize, 3), breaches.len);
    try testing.expectEqual(.disk_capacity_high, breaches[0].rule_id);
    try testing.expectEqual(.memory_headroom_low, breaches[1].rule_id);
    try testing.expectEqual(.memory_stalled, breaches[2].rule_id);
    try testing.expectEqual(@as(usize, 0), (try findings.advance(a, &confirmed, target, sample)).len);
    try testing.expectEqual(@as(usize, 3), (try findings.advance(a, &confirmed, target, sample)).len);

    sample.memory.value.available_bytes = 167772160;
    sample.memory_psi_bp.value = 499;
    sample.disk_used_bp.value = 8500;
    try testing.expectEqual(@as(usize, 3), (try findings.advance(a, &confirmed, target, sample)).len);
    sample.memory.value.available_bytes = 167772159;
    sample.memory_psi_bp.value = 500;
    sample.disk_used_bp.value = 8501;
    try testing.expectEqual(@as(usize, 3), (try findings.advance(a, &confirmed, target, sample)).len);
    sample.memory.value.available_bytes = 167772160;
    sample.memory_psi_bp.value = 499;
    sample.disk_used_bp.value = 8500;
    try testing.expectEqual(@as(usize, 3), (try findings.advance(a, &confirmed, target, sample)).len);
    try testing.expectEqual(@as(usize, 0), (try findings.advance(a, &confirmed, target, sample)).len);
}

test "tume health task 3 snapshot contract" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sample = testSample(&.{.{ .unit = target.services[0], .state = .{ .value = .failed } }});
    const stdout = try cli.snapshot(a, target, sample);
    const json = (try std.json.parseFromSlice(std.json.Value, a, stdout, .{})).value.object;
    try testing.expectEqual(@as(i64, 1), json.get("schema_version").?.integer);
    try testing.expectEqualStrings("snapshot", json.get("mode").?.string);
    try testing.expectEqual(@as(i64, 120), json.get("collection_ms").?.integer);
    const finding = json.get("findings").?.array.items[0].object;
    try testing.expectEqualStrings("service:gateway.service", finding.get("evidence_key").?.string);
    const observations = json.get("observations").?.array.items;
    try testing.expectEqual(@as(usize, 5), observations.len);
    for (observations) |observation| {
        const key = observation.object.get("key").?.string;
        try testing.expect(!std.mem.eql(u8, key, "sensor.temperature"));
        if (std.mem.eql(u8, key, "host.cpu_psi")) {
            try testing.expectEqual(.null, std.meta.activeTag(observation.object.get("value").?));
            try testing.expectEqualStrings("unsupported", observation.object.get("reason").?.string);
        }
    }
    try testing.expect(!json.contains("streaks"));
    try testing.expect(stdout.len <= 65536 and stdout[stdout.len - 1] == '\n');
}

const state = @import("state.zig");
const watch = @import("watch.zig");

test "tume health task 4 cadence across restarts" {
    try testing.expectEqual(.sample, watch.cadence(null, 0));
    try testing.expectEqual(.skip, watch.cadence(0, 14999));
    try testing.expectEqual(.sample, watch.cadence(0, 15000));
    try testing.expectEqual(.sample_reset, watch.cadence(0, 30000));
    try testing.expectEqual(.fresh, state.freshness(testStamp(0), testStamp(44999), true));
    try testing.expectEqual(.stale, state.freshness(testStamp(0), testStamp(45000), true));
    try testing.expectEqual(.invalid, state.freshness(testStamp(200), testStamp(199), true));
    try testing.expectEqual(.incompatible, state.freshness(testStamp(0), testStamp(1), false));
    var reboot = testStamp(1);
    reboot.boot_id[0] = 'a';
    try testing.expectEqual(.stale, state.freshness(testStamp(0), reboot, true));
}

fn failBeforeRename(_: std.posix.fd_t, phase: state.SyncPhase) !void {
    if (phase == .file) return error.InputOutput;
}

fn failAfterRename(_: std.posix.fd_t, phase: state.SyncPhase) !void {
    if (phase == .directory) return error.InputOutput;
}

test "tume health task 4 durable local status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try std.posix.mkdirat(temp.dir.fd, "state", 0o700);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try temp.dir.realpath("state", &path_buffer);
    var dir = try temp.dir.openDir("state", .{});
    defer dir.close();
    var store = try state.Store.fromDirectory(try probe.openDirectory(path));
    defer store.close();
    try store.lock();
    var other = try state.Store.fromDirectory(try probe.openDirectory(path));
    defer other.close();
    try testing.expectError(error.WatcherLocked, other.lock());

    var cursor: watch.Cursor = .{};
    var sample = testSample(&.{.{ .unit = target.services[0], .state = .{ .value = .failed } }});
    try testing.expect(try cursor.publish(a, &store, target, sample));
    const original = try dir.readFileAlloc(a, "latest.json", 65536);
    const first = other.load(a, target, testStamp(1));
    try testing.expectEqual(.fresh, first.freshness);
    try testing.expectEqual(@as(u2, 1), first.confirmed.?.entries[3].breach);
    const fresh_status = try cli.statusResponse(a, first);
    try testing.expectEqual(@as(u8, 0), fresh_status.code);
    try testing.expect(std.mem.indexOf(u8, fresh_status.body, "\"streaks\"") == null);

    cursor = watch.Cursor.fromLoaded(first);
    sample.stamp = testStamp(1);
    try testing.expect(!(try cursor.publish(a, &store, target, sample)));
    try testing.expectEqualStrings(original, try dir.readFileAlloc(a, "latest.json", 65536));
    cursor = watch.Cursor.fromLoaded(other.load(a, target, testStamp(30000)));
    sample.stamp = testStamp(30000);
    try testing.expect(try cursor.publish(a, &store, target, sample));
    const gap = other.load(a, target, testStamp(30000));
    try testing.expectEqual(@as(u2, 1), gap.confirmed.?.entries[3].breach);
    try testing.expectEqual(@as(usize, 0), gap.report.?.findings.len);

    const before_failure = try dir.readFileAlloc(a, "latest.json", 65536);
    sample.stamp = testStamp(45000);
    store.sync = failBeforeRename;
    try testing.expectError(error.InputOutput, cursor.publish(a, &store, target, sample));
    try testing.expectEqualStrings(before_failure, try dir.readFileAlloc(a, "latest.json", 65536));
    try testing.expectEqual(@as(?i64, 45000), cursor.confirmed.entries[3].opened_at_unix_ms);
    store.sync = failAfterRename;
    sample.stamp = testStamp(60000);
    try testing.expectError(error.UncertainDurability, cursor.publish(a, &store, target, sample));
    const visible = other.load(a, target, testStamp(60000));
    try testing.expectEqual(.fresh, visible.freshness);
    try testing.expectEqual(@as(i64, 45000), visible.report.?.findings[0].opened_at_unix_ms);

    const changed: types.Target = .{ .mount = "/", .services = &.{"different.service"}, .thermal_zone = null };
    const incompatible = other.load(a, changed, testStamp(60000));
    try testing.expectEqual(.incompatible, incompatible.freshness);
    try testing.expect(incompatible.report == null);
    const unavailable = try cli.statusResponse(a, incompatible);
    try testing.expectEqual(@as(u8, 3), unavailable.code);
    try testing.expectEqualStrings("{\"schema_version\":1,\"freshness\":\"incompatible\",\"report\":null}\n", unavailable.body);
    var reboot = testStamp(1);
    reboot.boot_id[0] = 'a';
    try testing.expect(other.load(a, target, reboot).report == null);
    try testing.expectEqual(.stale, other.load(a, target, reboot).freshness);

    try dir.writeFile(.{ .sub_path = "latest.json", .data = "{\"schema_version\":2,\"future\":true}" });
    try testing.expectEqual(.incompatible, other.load(a, target, testStamp(60000)).freshness);
    try dir.writeFile(.{ .sub_path = "latest.json", .data = "{\"schema_version\":1" });
    try testing.expectEqual(.invalid, other.load(a, target, testStamp(60000)).freshness);

    try dir.deleteFile("latest.json");
    try dir.symLink("writer.lock", "latest.json", .{});
    try testing.expectEqual(.unavailable, other.load(a, target, testStamp(60000)).freshness);
    sample.stamp = testStamp(75000);
    try testing.expectError(error.SymLinkLoop, cursor.publish(a, &store, target, sample));
}

test "tume health task 4 watcher refuses a symlink lock" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try std.posix.mkdirat(temp.dir.fd, "state", 0o700);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try temp.dir.realpath("state", &path_buffer);
    var dir = try temp.dir.openDir("state", .{});
    defer dir.close();
    try dir.symLink("other", "writer.lock", .{});
    var store = try state.Store.fromDirectory(try probe.openDirectory(path));
    defer store.close();
    try testing.expectError(error.SymLinkLoop, store.lock());
}
