const std = @import("std");

pub const unit = "tume-recovery-demo.service";
pub const revision = 1;
pub const approval_lifetime_ms = 300_000;
pub const policy = "enable restart-demo revision 1 tume-recovery-demo.service\n";
pub const Target = enum { demo };
pub const Id = [16]u8;
pub const Identity = struct { actor: u32, device: Id, boot: Id };
pub const Dispatch = enum { exit_zero, uncertain };
pub const State = enum { active, failed, inactive, transitioning };
pub const Evidence = struct {
    service: State,
    main_pid: u32,
    functional: enum { passed, failed, skipped },
    invocation: ?Id = null,
};

pub fn parseTarget(value: []const u8) !Target {
    if (!std.mem.eql(u8, value, unit)) return error.UnregisteredTarget;
    return .demo;
}

pub fn parseId(value: []const u8) !Id {
    if (value.len != 32) return error.InvalidApprovalId;
    for (value) |c| {
        if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return error.InvalidApprovalId;
    }
    var id: Id = undefined;
    _ = std.fmt.hexToBytes(&id, value) catch return error.InvalidApprovalId;
    if (allZero(id)) return error.InvalidApprovalId;
    return id;
}

pub fn allZero(id: Id) bool {
    return std.mem.allEqual(u8, &id, 0);
}

pub fn equal(left: Id, right: Id) bool {
    return std.mem.eql(u8, &left, &right);
}

pub fn sameIdentity(left: Identity, right: Identity) bool {
    return left.actor == right.actor and equal(left.device, right.device) and equal(left.boot, right.boot);
}

pub const preview =
    "Procedure: restart-demo revision 1\n" ++
    "Target: " ++ unit ++ " (the registered noncritical demo service)\n" ++
    "Preconditions: Linux systemd, trusted registry enabled, loaded canonical unit, " ++
    "inactive or failed with no pending job, current local approval, durable audit capacity.\n" ++
    "Effect: one systemd restart, which can interrupt the demo service.\n" ++
    "Verification: systemd reports active without a pending job, and the service's main process " ++
    "answers the local Unix socket PING with the expected PONG.\n" ++
    "Approval: authenticated local operator, device and boot bound, expires in five minutes.\n" ++
    "Retry budget: zero automatic retries. Rollback: unavailable.\n" ++
    "Failure: escalate an unverified result to the operator; reconcile an ambiguous result before any new attempt.\n";
