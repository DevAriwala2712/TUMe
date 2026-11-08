const std = @import("std");
const procedure = @import("procedure.zig");
const ledger = @import("ledger.zig");

pub const Identity = procedure.Identity;
pub const Dispatch = procedure.Dispatch;
pub const Service = struct {
    state: procedure.State,
    pid: u32,
    job_pending: bool = false,
    invocation: ?procedure.Id = null,
};
pub const Outcome = enum { verified, unverified, ambiguous };
pub const Effect = enum { restart, start };
pub const Window = struct {
    boot: procedure.Id,
    start: u64,
    end: u64,

    pub fn valid(self: Window) bool {
        return self.start < self.end and self.end - self.start <= 120_000;
    }

    fn contains(self: Window, boot: procedure.Id, now: u64) bool {
        return self.valid() and procedure.equal(self.boot, boot) and now >= self.start and now < self.end;
    }
};

pub const AutoGate = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque) ?Window,
};

pub const Permit = union(enum) {
    approval_expiry: u64,
    automatic: struct { window: Window, gate: AutoGate },

    pub fn effect(self: Permit) Effect {
        return switch (self) {
            .approval_expiry => .restart,
            .automatic => .start,
        };
    }

    pub fn allows(self: Permit, ops: Ops) bool {
        return switch (self) {
            .approval_expiry => |expiry| (ops.time() catch return false) < expiry,
            .automatic => |authority| {
                const current = authority.gate.read(authority.gate.context) orelse return false;
                return std.meta.eql(authority.window, current) and
                    current.contains(authority.window.boot, ops.time() catch return false);
            },
        };
    }
};

pub const Ops = struct {
    context: *anyopaque,
    now: *const fn (*anyopaque) ?u64,
    inspect: *const fn (*anyopaque) ?Service,
    restart: *const fn (*anyopaque, std.posix.fd_t, Permit) Dispatch,
    probe: *const fn (*anyopaque, u32) bool,

    fn time(self: Ops) !u64 {
        return self.now(self.context) orelse error.ClockUnavailable;
    }
};

pub fn approve(store: *ledger.Store, ops: Ops, enabled: bool, identity: Identity, target: procedure.Target, id: procedure.Id) !void {
    if (!enabled) return error.ProcedureDisabled;
    if (store.pending() != null) return error.ReconciliationRequired;
    if (store.last(id) != null) return error.DuplicateApprovalId;
    const now = try ops.time();
    if (hasCurrentApproval(store, identity, target, now)) return error.ApprovalAlreadyPending;
    const expires = std.math.add(u64, now, procedure.approval_lifetime_ms) catch return error.ClockUnavailable;
    try store.append(.{ .kind = .approval, .id = id, .identity = identity, .at = now, .target = target, .expires = expires });
}

fn hasCurrentApproval(store: *const ledger.Store, identity: Identity, target: procedure.Target, now: u64) bool {
    for (store.events()) |event| {
        if (event.kind != .approval or event.revision != procedure.revision or event.target != target or
            !procedure.equal(identity.device, event.identity.device) or !procedure.equal(identity.boot, event.identity.boot) or
            now >= event.expires.?) continue;
        if (store.last(event.id).?.kind == .approval) return true;
    }
    return false;
}

pub fn execute(store: *ledger.Store, ops: Ops, enabled: bool, identity: Identity, id: procedure.Id) !Outcome {
    if (!enabled) return error.ProcedureDisabled;
    if (store.pending() != null) return error.ReconciliationRequired;
    const approved = store.last(id) orelse return error.UnknownApproval;
    if (approved.kind != .approval) return error.ApprovalConsumed;
    if (approved.revision != procedure.revision or !procedure.sameIdentity(approved.identity, identity)) {
        return error.ApprovalBindingMismatch;
    }
    try withinApproval(try ops.time(), approved);
    try store.reserve(3);
    try precondition(ops, false);
    const event: ledger.Event = .{ .kind = .intent, .id = id, .identity = identity, .at = try ops.time(), .target = approved.target };
    try withinApproval(event.at, approved);
    try store.append(event);
    // Service state and approval are checked again after the durable write.
    precondition(ops, false) catch return .ambiguous;
    withinApproval(ops.time() catch return .ambiguous, approved) catch return .ambiguous;
    return dispatchAndVerify(store, ops, event, .{ .approval_expiry = approved.expires.? });
}

pub fn automatic(store: *ledger.Store, ops: Ops, gate: AutoGate, identity: Identity, id: procedure.Id) !Outcome {
    if (identity.actor != 0) return error.TrustedRootRequired;
    const window = gate.read(gate.context) orelse return error.AutomaticPolicyDisabled;
    const now = try ops.time();
    if (!window.contains(identity.boot, now)) return error.MaintenanceWindowClosed;
    if (store.pending() != null) return error.ReconciliationRequired;
    if (hasCurrentApproval(store, identity, .demo, now)) return error.ApprovalAlreadyPending;
    for (store.events()) |event| {
        if (event.kind != .automatic_intent) continue;
        const last = store.last(event.id).?;
        if (last.kind != .finished or outcome(last.evidence.?) != .verified) return error.AutomaticCircuitOpen;
        if (procedure.equal(event.identity.boot, identity.boot)) return error.AutomaticRateLimited;
    }
    if (store.last(id) != null) return error.DuplicateApprovalId;
    try store.reserve(3);
    try precondition(ops, true);
    const event: ledger.Event = .{ .kind = .automatic_intent, .id = id, .identity = identity, .at = try ops.time() };
    if (!window.contains(identity.boot, event.at)) return error.MaintenanceWindowClosed;
    try store.append(event);
    precondition(ops, true) catch return .ambiguous;
    const permit: Permit = .{ .automatic = .{ .window = window, .gate = gate } };
    if (!permit.allows(ops)) return .ambiguous;
    return dispatchAndVerify(store, ops, event, permit);
}

fn precondition(ops: Ops, automatic_only: bool) !void {
    const service = ops.inspect(ops.context) orelse return error.PreconditionsUnavailable;
    const permitted = service.state == .failed or (!automatic_only and service.state == .inactive);
    if (service.job_pending or service.pid != 0 or !permitted) return error.PreconditionsFailed;
}

fn dispatchAndVerify(store: *ledger.Store, ops: Ops, intent: ledger.Event, permit: Permit) !Outcome {
    var event = intent;
    const dispatch = ops.restart(ops.context, store.lock_fd, permit);
    event.kind = .dispatch;
    event.at = ops.time() catch return .ambiguous;
    event.dispatch = dispatch;
    store.append(event) catch return error.AmbiguousAuditWrite;
    if (dispatch != .exit_zero) return .ambiguous;

    const evidence = verification(ops) orelse return .ambiguous;
    event.kind = .finished;
    event.at = ops.time() catch return .ambiguous;
    event.dispatch = null;
    event.evidence = evidence;
    store.append(event) catch return error.AmbiguousAuditWrite;
    return outcome(evidence);
}

fn withinApproval(now: u64, approved: ledger.Event) !void {
    if (now < approved.at or now >= approved.expires.?) return error.ApprovalExpired;
}

pub fn reconcile(store: *ledger.Store, ops: Ops, identity: Identity, id: procedure.Id) !Outcome {
    const pending = store.pending() orelse return error.NoAmbiguousAttempt;
    if (!procedure.equal(id, pending.id)) return error.UnknownApproval;
    if (!procedure.equal(identity.device, pending.identity.device) or
        (identity.actor != 0 and identity.actor != pending.identity.actor) or
        pending.revision != procedure.revision) return error.ApprovalBindingMismatch;
    try store.reserve(1);
    const evidence = verification(ops) orelse return error.VerificationUnavailable;
    try store.append(.{
        .kind = .reconciled,
        .id = id,
        .identity = identity,
        .at = try ops.time(),
        .target = pending.target,
        .revision = pending.revision,
        .evidence = evidence,
    });
    return outcome(evidence);
}

fn verification(ops: Ops) ?procedure.Evidence {
    const service = ops.inspect(ops.context) orelse return null;
    if (service.job_pending or service.state == .transitioning) return null;
    if (service.state != .active or service.pid == 0) {
        return .{ .service = service.state, .main_pid = service.pid, .functional = .skipped, .invocation = service.invocation };
    }
    const passed = ops.probe(ops.context, service.pid);
    const confirmed = ops.inspect(ops.context) orelse return null;
    if (!std.meta.eql(service, confirmed)) return null;
    return .{ .service = service.state, .main_pid = service.pid, .functional = if (passed) .passed else .failed, .invocation = service.invocation };
}

fn outcome(evidence: procedure.Evidence) Outcome {
    return if (evidence.service == .active and evidence.functional == .passed) .verified else .unverified;
}
