const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const bpf = linux.BPF;
const seccomp = linux.SECCOMP;

pub const supported = builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64;

const Instruction = extern struct { code: u16, jt: u8 = 0, jf: u8 = 0, k: u32 };
const Program = extern struct { len: u16, filter: [*]const Instruction };

fn load(offset: u32) Instruction {
    return .{ .code = bpf.LD | bpf.W | bpf.ABS, .k = offset };
}

fn equal(value: u32, yes: u8, no: u8) Instruction {
    return .{ .code = bpf.JMP | bpf.JEQ | bpf.K, .jt = yes, .jf = no, .k = value };
}

fn bits(value: u32, yes: u8, no: u8) Instruction {
    return .{ .code = bpf.JMP | bpf.JSET | bpf.K, .jt = yes, .jf = no, .k = value };
}

fn result(value: u32) Instruction {
    return .{ .code = bpf.RET | bpf.K, .k = value };
}

const denied = seccomp.RET.ERRNO | @as(u32, @intFromEnum(linux.E.PERM));
const allowed = seccomp.RET.ALLOW;

fn deny(syscall: linux.SYS, action: u32) [2]Instruction {
    return .{ equal(@intFromEnum(syscall), 0, 1), result(action) };
}

fn readOnlyOpen(syscall: linux.SYS, flags_offset: u32) [5]Instruction {
    // O_ACCMODE | O_CREAT | O_TRUNC | __O_TMPFILE. O_DIRECTORY remains allowed.
    const write_flags = 0x3 | 0x40 | 0x200 | 0x400000;
    return .{
        equal(@intFromEnum(syscall), 0, 4),
        load(flags_offset),
        bits(write_flags, 0, 1),
        result(denied),
        result(allowed),
    };
}

fn denyArguments(syscall: linux.SYS, offset: u32, comptime values: []const u32) [3 + values.len * 2]Instruction {
    var instructions: [3 + values.len * 2]Instruction = undefined;
    instructions[0] = equal(@intFromEnum(syscall), 0, instructions.len - 1);
    instructions[1] = load(offset);
    for (values, 0..) |value, i| {
        instructions[2 + i * 2] = equal(value, 0, 1);
        instructions[3 + i * 2] = result(denied);
    }
    instructions[instructions.len - 1] = result(allowed);
    return instructions;
}

pub fn install() bool {
    if (!supported) return false;
    // Linux UAPI audit architecture constants. Zig 0.15.2's audit enum
    // references an unavailable ELF machine entry when instantiated.
    const arch: u32 = switch (builtin.cpu.arch) {
        .x86_64 => 0xc000003e,
        .aarch64 => 0xc00000b7,
        else => unreachable,
    };
    const filter = comptime [_]Instruction{
        load(@offsetOf(seccomp.data, "arch")),
        equal(arch, 1, 0),
        result(seccomp.RET.KILL_PROCESS),
        load(@offsetOf(seccomp.data, "nr")),
    } ++ (if (builtin.cpu.arch == .x86_64)
        [_]Instruction{
            // x32 shares the audit architecture and sets this syscall bit.
            bits(0x40000000, 0, 1),
            result(denied),
        } ++ deny(.creat, denied) ++ readOnlyOpen(.open, @offsetOf(seccomp.data, "arg1"))
    else
        [_]Instruction{}) ++
        readOnlyOpen(.openat, @offsetOf(seccomp.data, "arg2")) ++
        deny(.openat2, denied) ++
        deny(.open_by_handle_at, denied) ++
        deny(.io_uring_setup, denied) ++
        deny(.pidfd_getfd, denied) ++
        deny(.socket, denied) ++
        deny(.socketpair, denied) ++
        deny(.kill, denied) ++
        deny(.tkill, denied) ++
        deny(.tgkill, denied) ++
        deny(.pidfd_send_signal, denied) ++
        deny(.rt_sigqueueinfo, denied) ++
        deny(.rt_tgsigqueueinfo, denied) ++
        deny(.ptrace, denied) ++
        deny(.process_vm_readv, denied) ++
        deny(.process_vm_writev, denied) ++
        // Linux UAPI F_SETOWN, F_SETSIG and F_SETOWN_EX.
        denyArguments(.fcntl, @offsetOf(seccomp.data, "arg1"), &.{ 8, 10, 15 }) ++
        // FIOSETOWN, SIOCSPGRP, TIOCSTI and TIOCSIG.
        denyArguments(.ioctl, @offsetOf(seccomp.data, "arg1"), &.{ 0x8901, 0x8902, 0x5412, 0x40045436 }) ++
        denyArguments(.prctl, @offsetOf(seccomp.data, "arg0"), &.{@intFromEnum(linux.PR.SET_PDEATHSIG)}) ++
        // clone3 could place a new process in another delegated cgroup.
        // ENOSYS keeps libc's traditional clone-based thread fallback usable.
        deny(.clone3, seccomp.RET.ERRNO | @as(u32, @intFromEnum(linux.E.NOSYS))) ++
        [_]Instruction{result(allowed)};
    const program: Program = .{ .len = filter.len, .filter = &filter };
    return linux.E.init(linux.seccomp(seccomp.SET_MODE_FILTER, 0, &program)) == .SUCCESS;
}
