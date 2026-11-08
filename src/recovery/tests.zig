const std = @import("std");
const procedure = @import("procedure.zig");
const ledger = @import("ledger.zig");
const engine = @import("engine.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "preview accepts only the exact registered target" {
    try expectEqual(procedure.Target.demo, try procedure.parseTarget("tume-recovery-demo.service"));
    for ([_][]const u8{ "Tume-recovery-demo.service", "tume-recovery-demo", "--help", "tume-recovery-demo.service\n" }) |value| {
        try expectError(error.UnregisteredTarget, procedure.parseTarget(value));
    }
    try expectError(error.InvalidApprovalId, procedure.parseId("0000000000000000000000000000000g"));
    try expectError(error.InvalidApprovalId, procedure.parseId("AA000000000000000000000000000000"));
}

const original: engine.Identity = .{ .actor = 1001, .device = @splat(1), .boot = @splat(2) };
const first_id: procedure.Id = @splat(5);
const second_id: procedure.Id = @splat(6);

const Fixture = struct {
    directory: std.fs.Dir,
    now: u64 = 1_000,
    service: ?engine.Service = .{ .state = .failed, .pid = 0 },
    functional: bool = true,
    dispatch: engine.Dispatch = .exit_zero,
    dispatches: usize = 0,
    last_effect: ?engine.Effect = null,
    durable_intent: bool = false,
    precondition_time: ?u64 = null,
    replace_during_probe: bool = false,
    job_after_first_inspection: bool = false,
    inspections: usize = 0,

    fn ops(self: *Fixture) engine.Ops {
        return .{ .context = self, .now = current, .inspect = inspect, .restart = restart, .probe = probe };
    }

    fn from(context: *anyopaque) *Fixture {
        return @ptrCast(@alignCast(context));
    }

    fn current(context: *anyopaque) ?u64 {
        return from(context).now;
    }

    fn inspect(context: *anyopaque) ?engine.Service {
        const self = from(context);
        if (self.precondition_time) |time| self.now = time;
        self.inspections += 1;
        if (self.job_after_first_inspection and self.inspections > 1) self.service.?.job_pending = true;
        return self.service;
    }

    fn restart(context: *anyopaque, _: std.posix.fd_t, permit: engine.Permit) engine.Dispatch {
        const self = from(context);
        if (!permit.allows(self.ops())) return .uncertain;
        self.dispatches += 1;
        self.last_effect = permit.effect();
        const file = self.directory.openFile("audit.json", .{}) catch return .uncertain;
        defer file.close();
        var bytes: [4096]u8 = undefined;
        const len = file.readAll(&bytes) catch return .uncertain;
        self.durable_intent = std.mem.indexOf(u8, bytes[0..len], "\"intent\"") != null or
            std.mem.indexOf(u8, bytes[0..len], "\"automatic_intent\"") != null;
        self.service = .{ .state = .active, .pid = 1234, .invocation = @splat(7) };
        return self.dispatch;
    }

    fn probe(context: *anyopaque, pid: u32) bool {
        const self = from(context);
        if (self.replace_during_probe) self.service.?.invocation = @splat(19);
        return pid == 1234 and self.functional;
    }
};

test "invalid principal device boot and stale approvals cause zero effects" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    var fixture: Fixture = .{ .directory = temp.dir };
    const ops = fixture.ops();
    try expectError(error.ProcedureDisabled, engine.approve(&store, ops, false, original, .demo, first_id));
    try engine.approve(&store, ops, true, original, .demo, first_id);
    try expectError(error.ApprovalAlreadyPending, engine.approve(&store, ops, true, original, .demo, second_id));
    try expectError(error.ProcedureDisabled, engine.execute(&store, ops, false, original, first_id));
    try expectError(error.UnknownApproval, engine.execute(&store, ops, true, original, second_id));
    const impostors = [_]engine.Identity{
        .{ .actor = 1002, .device = original.device, .boot = original.boot },
        .{ .actor = original.actor, .device = @splat(3), .boot = original.boot },
        .{ .actor = original.actor, .device = original.device, .boot = @splat(4) },
    };
    for (impostors) |identity| try expectError(error.ApprovalBindingMismatch, engine.execute(&store, ops, true, identity, first_id));
    fixture.precondition_time = 301_000;
    try expectError(error.ApprovalExpired, engine.execute(&store, ops, true, original, first_id));
    try expectEqual(@as(usize, 0), fixture.dispatches);
}

test "exit zero with a failed functional probe is recorded unverified and cannot replay" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var fixture: Fixture = .{ .directory = temp.dir, .functional = false };
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    try engine.approve(&store, fixture.ops(), true, original, .demo, first_id);
    try expectEqual(engine.Outcome.unverified, try engine.execute(&store, fixture.ops(), true, original, first_id));
    try expect(fixture.durable_intent);
    try expectEqual(engine.Effect.restart, fixture.last_effect.?);
    const recorded = store.last(first_id).?;
    try expect(!recorded.rollback_eligible);
    try expectEqual(@as(procedure.Id, @splat(7)), recorded.evidence.?.invocation.?);
    store.close();
    store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    try expectError(error.ApprovalConsumed, engine.execute(&store, fixture.ops(), true, original, first_id));
    try expectEqual(@as(usize, 1), fixture.dispatches);
}

test "ambiguous dispatch holds the target until explicit read-only reconciliation" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var fixture: Fixture = .{ .directory = temp.dir, .dispatch = .uncertain };
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    try engine.approve(&store, fixture.ops(), true, original, .demo, first_id);
    try expectEqual(engine.Outcome.ambiguous, try engine.execute(&store, fixture.ops(), true, original, first_id));
    store.close();
    store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    try expectError(error.ReconciliationRequired, engine.approve(&store, fixture.ops(), true, original, .demo, second_id));
    try expectError(error.ReconciliationRequired, engine.execute(&store, fixture.ops(), true, original, first_id));
    fixture.service = .{ .state = .active, .pid = 1234, .job_pending = true };
    try expectError(error.VerificationUnavailable, engine.reconcile(&store, fixture.ops(), original, first_id));
    fixture.service.?.job_pending = false;
    try expectEqual(engine.Outcome.verified, try engine.reconcile(&store, fixture.ops(), original, first_id));
    try expectEqual(@as(usize, 1), fixture.dispatches);
    try expectError(error.ApprovalConsumed, engine.execute(&store, fixture.ops(), true, original, first_id));
}

test "an intent-only record after interruption is reconciled without another restart" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var fixture: Fixture = .{ .directory = temp.dir };
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    try engine.approve(&store, fixture.ops(), true, original, .demo, first_id);
    try store.append(.{ .kind = .intent, .id = first_id, .identity = original, .at = 1_001 });
    store.close();
    store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    try expectError(error.ReconciliationRequired, engine.execute(&store, fixture.ops(), true, original, first_id));
    try expectEqual(engine.Outcome.unverified, try engine.reconcile(&store, fixture.ops(), original, first_id));
    try expectEqual(@as(usize, 0), fixture.dispatches);
}

test "audit capacity is reserved before a privileged effect" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    var fixture: Fixture = .{ .directory = temp.dir };
    for (0..ledger.max_events - 2) |i| {
        fixture.now = 1_000 + i * 300_001;
        const id: procedure.Id = @splat(@intCast(i + 1));
        try engine.approve(&store, fixture.ops(), true, original, .demo, id);
    }
    const last_id: procedure.Id = @splat(ledger.max_events - 2);
    try expectError(error.AuditFull, engine.execute(&store, fixture.ops(), true, original, last_id));
    try expectEqual(@as(usize, 0), fixture.dispatches);
}

test "a competing executor cannot acquire the target lock" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    try expectError(error.TargetBusy, ledger.Store.lock(temp.dir, std.testing.allocator));
}

test "systemd inspection rejects alias, drop-in, stale and malformed observations" {
    const protocol = @import("protocol.zig");
    const common = "LoadState=loaded\nActiveState=active\nMainPID=1234\nJob=\n" ++
        "InvocationID=5123456789abcdef0123456789abcdef\n";
    const canonical = "Id=tume-recovery-demo.service\nFragmentPath=/etc/systemd/system/tume-recovery-demo.service\n";
    const trusted = "DropInPaths=\nNeedDaemonReload=no\n";
    const valid = protocol.parseService(canonical ++ common ++ trusted).?;
    try expectEqual(procedure.State.active, valid.state);
    try expectEqual(@as(u32, 1234), valid.pid);
    try expect(!valid.job_pending);
    try expect(protocol.parseService(canonical ++ common ++ "DropInPaths=/etc/systemd/system/a.conf\nNeedDaemonReload=no\n") == null);
    try expect(protocol.parseService(canonical ++ common ++ "DropInPaths=\nNeedDaemonReload=yes\n") == null);
    try expect(protocol.parseService("Id=alias.service\nFragmentPath=/etc/systemd/system/tume-recovery-demo.service\n" ++ common ++ trusted) == null);
    try expect(protocol.parseService(canonical ++ common ++ trusted ++ "Job=\n") == null);
}

test "failed intent publication prevents restart" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    var fixture: Fixture = .{ .directory = temp.dir };
    try engine.approve(&store, fixture.ops(), true, original, .demo, first_id);
    try temp.dir.makeDir(".audit.tmp");
    if (engine.execute(&store, fixture.ops(), true, original, first_id)) |_| {
        return error.UnexpectedDispatch;
    } else |_| {}
    try expectEqual(@as(usize, 0), fixture.dispatches);
    try expectEqual(ledger.Event{ .kind = .approval, .id = first_id, .identity = original, .at = 1000, .expires = 301000 }, store.last(first_id).?);
}

test "a replaced systemd invocation cannot verify the previous instance" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    var fixture: Fixture = .{ .directory = temp.dir, .replace_during_probe = true };
    try engine.approve(&store, fixture.ops(), true, original, .demo, first_id);
    try expectEqual(engine.Outcome.ambiguous, try engine.execute(&store, fixture.ops(), true, original, first_id));
    try expectEqual(@as(usize, 1), fixture.dispatches);
    try expectError(error.ReconciliationRequired, engine.approve(&store, fixture.ops(), true, original, .demo, second_id));
}

const AutoFixture = struct {
    window: ?engine.Window = .{ .boot = original.boot, .start = 900, .end = 2_000 },
    checks: usize = 0,
    revoke_after_intent: bool = false,

    fn gate(self: *AutoFixture) engine.AutoGate {
        return .{ .context = self, .read = read };
    }

    fn read(ctx: *anyopaque) ?engine.Window {
        const self: *AutoFixture = @ptrCast(@alignCast(ctx));
        self.checks += 1;
        if (self.revoke_after_intent and self.checks > 1) return null;
        return self.window;
    }
};

test "automatic recovery refuses stale windows and preserves a pending manual approval" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    var fixture: Fixture = .{ .directory = temp.dir };
    var auto: AutoFixture = .{};
    var root = original;
    root.actor = 0;
    root.boot = @splat(3);
    try expectError(error.MaintenanceWindowClosed, engine.automatic(&store, fixture.ops(), auto.gate(), root, first_id));
    root.boot = original.boot;
    fixture.now = 2000;
    try expectError(error.MaintenanceWindowClosed, engine.automatic(&store, fixture.ops(), auto.gate(), root, first_id));
    fixture.now = 1000;
    fixture.service = .{ .state = .inactive, .pid = 0 };
    try expectError(error.PreconditionsFailed, engine.automatic(&store, fixture.ops(), auto.gate(), root, first_id));
    fixture.service = .{ .state = .failed, .pid = 0 };
    try engine.approve(&store, fixture.ops(), true, original, .demo, first_id);
    try expectError(error.ApprovalAlreadyPending, engine.automatic(&store, fixture.ops(), auto.gate(), root, second_id));
    try expectEqual(@as(usize, 0), fixture.dispatches);
    try expectEqual(engine.Outcome.verified, try engine.execute(&store, fixture.ops(), true, original, first_id));
}

test "automatic intent durably limits the target to one attempt per boot" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    var fixture: Fixture = .{ .directory = temp.dir };
    var auto: AutoFixture = .{};
    var root = original;
    root.actor = 0;
    try expectEqual(engine.Outcome.verified, try engine.automatic(&store, fixture.ops(), auto.gate(), root, first_id));
    try expect(fixture.durable_intent);
    try expectEqual(engine.Effect.start, fixture.last_effect.?);
    store.close();
    store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    fixture.service = .{ .state = .failed, .pid = 0 };
    auto.window = .{ .boot = root.boot, .start = 1_001, .end = 3_000 };
    fixture.now = 1002;
    try expectError(error.AutomaticRateLimited, engine.automatic(&store, fixture.ops(), auto.gate(), root, second_id));
    try expectEqual(@as(usize, 1), fixture.dispatches);
}

test "failed automatic verification keeps the circuit open after a reboot" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    var fixture: Fixture = .{ .directory = temp.dir, .functional = false };
    var auto: AutoFixture = .{};
    var root = original;
    root.actor = 0;
    try expectEqual(engine.Outcome.unverified, try engine.automatic(&store, fixture.ops(), auto.gate(), root, first_id));
    root.boot = @splat(3);
    auto.window.?.boot = root.boot;
    fixture.service = .{ .state = .failed, .pid = 0 };
    try expectError(error.AutomaticCircuitOpen, engine.automatic(&store, fixture.ops(), auto.gate(), root, second_id));
    try expectEqual(@as(usize, 1), fixture.dispatches);
}

test "revoking automatic policy after intent prevents dispatch" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    var fixture: Fixture = .{ .directory = temp.dir };
    var auto: AutoFixture = .{ .revoke_after_intent = true };
    var root = original;
    root.actor = 0;
    try expectEqual(engine.Outcome.ambiguous, try engine.automatic(&store, fixture.ops(), auto.gate(), root, first_id));
    try expectEqual(@as(usize, 0), fixture.dispatches);
    try expectError(error.ReconciliationRequired, engine.approve(&store, fixture.ops(), true, original, .demo, second_id));
    try expectEqual(engine.Outcome.unverified, try engine.reconcile(&store, fixture.ops(), root, first_id));
    auto.revoke_after_intent = false;
    try expectError(error.AutomaticCircuitOpen, engine.automatic(&store, fixture.ops(), auto.gate(), root, second_id));
    try engine.approve(&store, fixture.ops(), true, original, .demo, second_id);
    try expectEqual(engine.Outcome.verified, try engine.execute(&store, fixture.ops(), true, original, second_id));
    try expectEqual(@as(usize, 1), fixture.dispatches);
}

test "a newly queued job after durable manual intent prevents restart" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    var fixture: Fixture = .{ .directory = temp.dir, .job_after_first_inspection = true };
    try engine.approve(&store, fixture.ops(), true, original, .demo, first_id);
    try expectEqual(engine.Outcome.ambiguous, try engine.execute(&store, fixture.ops(), true, original, first_id));
    try expectEqual(@as(usize, 0), fixture.dispatches);
    try expectError(error.ReconciliationRequired, engine.execute(&store, fixture.ops(), true, original, first_id));
}

test "automatic policy accepts only its registered bounded window grammar" {
    const protocol = @import("protocol.zig");
    const header = "enable restart-demo revision 1 tume-recovery-demo.service\n";
    const boot = "02020202020202020202020202020202";
    try expectEqual(engine.Window{ .boot = original.boot, .start = 1000, .end = 121000 }, protocol.parseWindow(header ++ boot ++ " 1000 121000\n").?);
    try expect(protocol.parseWindow(header ++ boot ++ " 1000 121001\n") == null);
    try expect(protocol.parseWindow(header ++ boot ++ " 2000 1000\n") == null);
    try expect(protocol.parseWindow(header ++ boot ++ " 1000  2000\n") == null);
    try expect(protocol.parseWindow(header ++ boot ++ " 1000 2000\nextra") == null);
    try expect(protocol.parseWindow(header ++ "00000000000000000000000000000000 1000 2000\n") == null);
}

test "the demo audit rejects rollback eligibility for revision one" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.posix.fchmod(temp.dir.fd, 0o700);
    var store = try ledger.Store.lock(temp.dir, std.testing.allocator);
    defer store.close();
    try expectError(error.InvalidAudit, store.append(.{
        .kind = .approval,
        .id = first_id,
        .identity = original,
        .at = 1000,
        .expires = 301000,
        .rollback_eligible = true,
    }));
    try expectEqual(@as(usize, 0), store.events().len);
}
