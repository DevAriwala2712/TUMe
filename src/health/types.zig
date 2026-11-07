pub const Target = struct {
    mount: []const u8,
    services: []const []const u8,
    thermal_zone: ?u8,
};

pub const Config = struct { target: Target, state_dir: ?[]const u8 };
pub const Stamp = struct { boot_id: [36]u8, unix_ms: i64, boot_ms: u64 };
pub const Reason = enum { unsupported, denied, unavailable, invalid, timeout, truncated };

pub fn Reading(comptime T: type) type {
    return union(enum) { value: T, reason: Reason };
}

pub const Memory = struct { total_bytes: u64, available_bytes: u64 };
pub const ActiveState = enum { active, inactive, failed, activating, deactivating, reloading };
pub const Service = struct { unit: []const u8, state: Reading(ActiveState) };

pub const Sample = struct {
    stamp: Stamp,
    collection_ms: u64,
    memory: Reading(Memory),
    memory_psi_bp: Reading(u16),
    cpu_psi_bp: Reading(u16),
    disk_used_bp: Reading(u16),
    services: []const Service,
    temperature_mc: ?Reading(i32),
};
