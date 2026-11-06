# Inherited NanoClaw-Next benchmark evidence

All reports currently in this directory came from NanoClaw-Next research before the TUMe product split. They preserve their original dates, model/backend settings, hardware conditions and limitations.

- [Memory-cap comparison](2026-11-05-linux-vm/REPORT.md): fixed 1.7B model versus adaptive selection, plus a separately injected real OOM recovery check.
- [Quantization/context grid](2026-11-06-quantization-grid/REPORT.md): 54 held-out inference observations across Q4/Q5/Q8 and two model sizes.

These are not TUMe maintenance-product benchmarks, not security-detection evaluations, and not 54 distinct user tasks. Retain them as provenance; new product results must identify the TUMe version and evaluate the actual monitoring/diagnosis/recovery workload. No new experiments were run to establish this repository.
