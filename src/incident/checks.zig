const findings = @import("../health/findings.zig");

pub const Check = struct {
    code: []const u8,
    description: []const u8,
    evidence_id: []const u8 = "",
    historical: bool = false,
};

pub const missing_coverage: Check = .{
    .code = "verify_observation_coverage",
    .description = "Check whether TUMe can observe this input now. The suggested checks are based on retained evidence.",
};

pub fn forRule(rule: findings.RuleId) [2]Check {
    return switch (rule) {
        .memory_headroom_low => .{
            .{ .code = "inspect_memory_consumers", .description = "Review the protected workload and largest memory users." },
            .{ .code = "compare_memory_and_stalls", .description = "Compare available memory with memory PSI when it was observed." },
        },
        .memory_stalled => .{
            .{ .code = "review_pressure_window", .description = "Check whether memory stalls coincided with the workload symptom." },
            .{ .code = "compare_headroom", .description = "Review the latest available-memory reading and check for missing coverage." },
        },
        .disk_capacity_high => .{
            .{ .code = "inspect_mount_usage", .description = "Identify what is growing on the configured mount." },
            .{ .code = "review_retention_and_writes", .description = "Review log, data and backup retention before making changes." },
        },
        .service_unavailable => .{
            .{ .code = "verify_unit_state", .description = "Check the unit's current state and its dependencies." },
            .{ .code = "review_service_events", .description = "Review the unit's incident timeline and any visible journal metadata." },
        },
    };
}

pub fn nextCheck(rule: findings.RuleId) []const u8 {
    return forRule(rule)[0].code;
}
