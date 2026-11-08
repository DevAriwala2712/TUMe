# T3 recovery checkpoint

The operator-approved path registers only `tume-recovery-demo.service`. The guarded automatic path is opt-in for the same disposable service. It uses a root-owned boot-bound window, a stop switch, a shared action lock, one attempt per boot, and a durable circuit breaker.

On the authorized arm64 Ubuntu 24.04 VM with systemd 255, the earlier operator-approved trial verified a restart, refused replay and a different operator, and kept an exit-zero restart unverified when the functional probe failed. An interruption during dispatch left an auditable intent. Reconciliation verified current health without issuing another restart.

The initial guarded VM trial confirmed that the timer was inactive, absent or invalid windows and the stop switch prevented dispatch, a competing lock and pending manual approval took priority, and a verified automatic action consumed the boot allowance. The trial used the dedicated oneshot unit.

After those trials, review prompted changes to make automatic dispatch start-only, persist rollback eligibility and the observed invocation, and exercise the optional timer in the guarded harness. The usage limit interrupted the updated native trial. At this checkpoint the arm64 VM passed all 91 Zig tests and the integrated recovery preview. ReleaseSmall built the CLI and both recovery executors for Linux arm64 and x86_64. The manual and guarded VM harnesses still need a rerun against this checkpoint, including the timer and reboot behavior. The external-controller race is documented in the [operator guide](../operations/verified-recovery.md).

Real-device workload impact, operator time and unintended effects compared with manual or systemd-only handling remain unmeasured.
