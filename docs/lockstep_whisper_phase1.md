# LOCKSTEP-WHISPER Phase 1 Report

Date: 2026-06-18

Workspace: `/home/host/eh2-cosim-veri-lockstep-whisper`

Branch: `lockstep-whisper`

## Decision

**GO for Phase 2 planning.**

Phase 1 proves the new online path on this CentOS 7.9 server:

```text
EH2 RTL -> eh2_rvvi_adapter.sv -> RVVI-TRACE
        -> rvvi_cac_bridge.sv -> cosim-arch-checker DPI
        -> VeeR-ISS whisper --server
```

The old Spike-EH2 and offline tracecmp path was not deleted in this phase.

## What Was Built

### VeeR-ISS Client

`vendor/cosim-arch-checker/bridge/whisper/whisper_client.*` now speaks the
current `chipsalliance/VeeR-ISS` server protocol proven in Phase 0b.  It uses
the VeeR `WhisperMessage` layout and drives:

- `Step`
- `Change`
- `Peek`
- `Poke`
- `Quit`

Each RTL test starts its own VeeR-ISS process through:

```text
+rvvi_elf=<test elf>
+whisper_path=vendor/whisper/build-Linux/whisper
+whisper_json_path=rtl/snapshots/default/whisper.json
+whisper_server_file=<test output>/whisper_connect
```

This keeps parallel tests isolated by server file and log path.

### cosim-arch-checker Full-State Extensions

The vendored checker was extended beyond the original PC/GPR/FPR/VR path:

- CSR state IDs are dynamically generated from CSR addresses.
- Memory state IDs are dynamically generated from physical addresses.
- `monitor_csr` updates DUT CSR state.
- `monitor_mem` updates DUT store state.
- VeeR-ISS `Change` entries for `c` and `m` update reference CSR/memory state.
- State names now print as `CSR[0x...]` and `MEM[0x...]`.

Known Phase 1 limitation: nondeterministic CSR masking is not yet generalized
for riscv-dv async/debug workloads.  The Phase 1 proof is smoke plus the seven
cosim directed tests.

### RVVI-TRACE Thin Bridge

Added `dv/uvm/core_eh2/common/rvvi_agent/rvvi_cac_bridge.sv`.

The bridge is intentionally thin:

- It consumes standard `rvviTrace`.
- It calls external DPI monitor functions.
- It does not compare DUT vs reference in SystemVerilog.
- It is enabled by `+cosim_arch_checker` or `+lockstep_whisper`.

Store bus writes are buffered and attached to the next retiring RVVI store
instruction.  This fixed the initial `cosim_load_store` mismatch where memory
sideband events were being attributed to the preceding ALU instruction.

### Makefile / Runner Integration

`LOCKSTEP_WHISPER=1` selects the new online checker path:

- `make cac` builds `vendor/cosim-arch-checker/lib/libcosim.so`.
- VCS links the CAC DPI library instead of the Spike DPI library.
- `run_regress.py --disable-trace-compare` disables the old offline comparator
  only for this proof path.
- `run_regress.py` still supplies per-test `+rvvi_elf` so VeeR-ISS can load the
  same ELF as the DUT program.
- `WHISPER_LD_LIBRARY_PATH` lets the no-root GCC9/Boost runtime be provided
  without hardcoding machine paths into tracked sources.

ABI split used for the proof:

| Component | Compiler/runtime |
|---|---|
| CAC DPI shared library loaded by VCS | VCS-compatible GCC 6.2, with static libstdc++/libgcc |
| VeeR-ISS server process | no-root GCC 9.3.1 + Boost 1.75 from Phase 0b |
| Transport | TCP socket via `whisper --server` |

## Evidence

### CAC Teeth Test

Command:

```bash
make -C vendor/cosim-arch-checker clean all test \
  CC=/home/Xilinx/Vivado/2019.1/tps/lnx64/gcc-6.2.0/bin/g++ \
  CFLAGS='-std=c++17 -Wall -Werror -fpic -Imon/mon_instr -Ibridge/std -Ibridge -Ienv -Ibridge/whisper/svdpi -Ibridge/whisper -Icac/src/lib -Icac/src -DCONFIG=MediumBoomVecConfig'
```

Result:

```text
PASS
```

The unit test intentionally injects a CSR mismatch and a memory mismatch and
asserts that CAC reports both as failures.

### smoke Online Lockstep

Command:

```bash
make smoke LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=0 \
  CAC_CXX=/home/Xilinx/Vivado/2019.1/tps/lnx64/gcc-6.2.0/bin/g++ \
  WHISPER_PATH=vendor/whisper/build-Linux/whisper \
  WHISPER_LD_LIBRARY_PATH=/home/host/toolchains/boost-gcc9/lib:/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr/lib64:/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr/lib
```

Result:

```text
Total: 1 | Passed: 1 | Failed: 0
```

Evidence files:

- `build/smoke_vcs/smoke_s1/result.yaml`
- `build/smoke_vcs/smoke_s1/whisper_connect.cmd.log`
- `build/smoke_vcs/smoke_s1/whisper_connect.log`

Smoke VeeR-ISS command log shows four online steps:

```text
hart=0 step #1
hart=0 step #2
hart=0 step #3
hart=0 step #4
hart=0 quit
```

### cosim Directed Online Lockstep

Command:

```bash
make regress LOCKSTEP_WHISPER=1 TESTLIST=cosim SIMULATOR=vcs COV=0 PARALLEL=1 \
  CAC_CXX=/home/Xilinx/Vivado/2019.1/tps/lnx64/gcc-6.2.0/bin/g++ \
  WHISPER_PATH=vendor/whisper/build-Linux/whisper \
  WHISPER_LD_LIBRARY_PATH=/home/host/toolchains/boost-gcc9/lib:/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr/lib64:/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr/lib
```

Result:

```text
Total: 7 | Passed: 7 | Failed: 0
Pass rate: 100.0%
```

Passed tests:

- `cosim_smoke`
- `cosim_alu`
- `cosim_load_store`
- `cosim_dual_issue`
- `cosim_bitmanip`
- `cosim_exception_compare`
- `cosim_atomic_basic`

## Debug Notes

Two concrete blockers were found and fixed:

1. `simv` could not load `libcosim.so` in lockstep mode because
   `LD_LIBRARY_PATH` did not include `vendor/cosim-arch-checker/lib`.
   The Makefile now builds a lockstep runtime path that includes the CAC
   library directory and optional `WHISPER_LD_LIBRARY_PATH`.
2. Directed regressions initially did not pass `+rvvi_elf`, so CAC started
   Whisper without an ELF and crashed on first step.  `run_regress.py` now adds
   the per-test ELF and per-test `whisper_connect` server file whenever the
   lockstep plusarg is present.

The first full cosim run then exposed a real bridge ordering issue:

```text
cosim_load_store: memory store was attached to the preceding addi retire
```

The bridge now buffers store sideband events and emits `monitor_mem` when the
corresponding RVVI store instruction retires.

## Not Done in Phase 1

- No deletion of Spike-EH2.
- No deletion of offline tracecmp.
- No riscv-dv closure.
- No compliance closure.
- No dual-hart lockstep closure.
- No async/debug/interrupt injection closure.
- No full signoff.
- No general nondeterministic CSR mask policy.

These remain Phase 2+ work.

## Current Assessment

The basic architecture is viable on this machine:

- VCS can load the CAC DPI `.so`.
- The DPI `.so` can launch and connect to VeeR-ISS.
- The DUT side remains RVVI-TRACE.
- The comparison is outside UVM in CAC.
- PC, GPR, CSR, and memory comparison paths exist and have basic teeth.
- `smoke` and the seven cosim directed tests pass online lockstep.

Phase 2 can now decide how to scale this path to riscv-dv, async injection,
compliance, and dual hart before any old Spike/tracecmp deletion.
