# LOCKSTEP-WHISPER Phase 0 Feasibility Report

Date: 2026-06-17

Workspace: `/home/host/eh2-cosim-veri-lockstep-whisper`

Branch/base: `lockstep-whisper` at `72c50d6`

## Decision

**NO-GO on this machine for Phase 1/2 implementation.**

Do not delete `spike_cosim`, offline `tracecmp`, or any v2.0 signoff path.
The Phase 0 gate found one hard environment blocker and two integration gaps:

1. The vendored Whisper source cannot be built with the available compiler stack.
2. The current cosim-arch-checker bridge is BOOM/Ocelot-oriented and does not
   provide the full EH2 signoff comparison scope out of the box.
3. Async/debug/interrupt injection and process lifecycle handling require new
   integration work after Whisper can be built and launched.

The current v2.0 offline tracecmp platform remains the only proven green path.

## Inputs Vendored

The sources were copied with symlink dereference into:

| Path | Upstream HEAD checked | Notes |
|---|---:|---|
| `vendor/cosim-arch-checker` | `157c66370acef1ce9e9e19106abca7f3d81e2c52` | Apache-2.0, C++ checker + DPI monitor APIs |
| `vendor/whisper` | `dde803963c9b4cb2fddde3a38ae4fe18909b64d7` | Apache-2.0, VeeR-ISS / Whisper |

Checks run:

```bash
find vendor/cosim-arch-checker vendor/whisper -type l
find vendor/cosim-arch-checker vendor/whisper -maxdepth 2 -type d -name .git -print
```

Both commands produced no output after cleanup.

## Toolchain Findings

Available:

| Tool | Result |
|---|---|
| VCS | `/home/synopsys/vcs-mx/O-2018.09-1/bin/vcs` |
| Bazel | not found |
| System Whisper | not found |
| Python | `Python 3.6.8` |
| Git | `git version 1.8.3.1` |
| System g++ | `/usr/bin/g++`, GCC 4.8.5 |
| Xilinx g++ | `/home/Xilinx/Vivado/2019.1/tps/lnx64/gcc-6.2.0/bin/g++`, GCC 6.2.0 |
| Cadence g++ | `/home/cadence/SPECTRE181/tools.lnx86/cdsgcc/gcc/6.3/install/bin/g++`, GCC 6.3.0 |
| Boost found | Xilinx Boost 1.64 libraries, including `libboost_program_options.so` |

Whisper upstream requirements from `vendor/whisper/README.md`:

| Requirement | Current machine |
|---|---|
| g++ 11 or higher | not found |
| Boost 1.75 or higher compiled with C++20 | not found |

The C++20 probe failed with both system GCC and Xilinx GCC:

```text
g++: error: unrecognized command line option '-std=c++20'
```

## Build Feasibility

### cosim-arch-checker

Bazel is not available, but the vendored project includes a Makefile. A direct
Makefile build of its C++ DPI library succeeded with GCC 6.2 and C++17:

```bash
make -C vendor/cosim-arch-checker clean all \
  CC=/home/Xilinx/Vivado/2019.1/tps/lnx64/gcc-6.2.0/bin/g++ \
  CFLAGS='-std=c++17 -Wall -fpic -DCONFIG=MediumBoomVecConfig \
  -Imon/mon_instr -Ibridge/std -Ibridge -Ienv \
  -Ibridge/whisper/svdpi -Ibridge/whisper -Icac/src/lib -Icac/src'
```

Result: `vendor/cosim-arch-checker/lib/libcosim.so` was produced during the
probe, then removed as a build artifact.

Conclusion: Bazel is not a hard blocker for the checker side. Phase 1 should
prefer direct source compilation under the top-level Makefile if the migration
continues on a machine with a buildable Whisper.

### Whisper

The Whisper build probe failed immediately because the available compiler does
not support `-std=c++20`:

```bash
timeout 60 make -f GNUmakefile build-Linux/whisper \
  CXX=/home/Xilinx/Vivado/2019.1/tps/lnx64/gcc-6.2.0/bin/g++ \
  BOOST_ROOT=/home/Xilinx/Vivado/2019.1 STATIC_LINK=0 \
  SOFT_FLOAT=0 PCI=0 TRACE_READER=0 VIRT_MEM=0 MEM_CALLBACKS=0 \
  REMOTE_FRAME_BUFFER=0 -j2
```

Observed failure:

```text
g++ ... -std=c++20 ... -c -o build-Linux/whisper.cpp.o whisper.cpp
g++: error: unrecognized command line option '-std=c++20'
make: *** [GNUmakefile:140: build-Linux/whisper.cpp.o] Error 1
```

Conclusion: **Whisper cannot be built on the current machine without adding a
new external machine prerequisite**: GCC 11+ and Boost 1.75+ built for C++20.
This violates the existing machine prerequisite set unless the project
explicitly accepts that prerequisite change.

## cosim-arch-checker Integration Findings

The upstream checker is useful but not a drop-in replacement for the current
v2.0 offline tracecmp path.

### DUT monitor API

The checker exposes custom DPI monitor functions, not RVVI:

```c++
monitor_gpr(char *name, int hart, uint64_t cycle, uint32_t addr, uint64_t data)
monitor_fpr(char *name, int hart, uint64_t cycle, uint32_t addr, uint64_t data)
monitor_vr(char *name, int hart, uint64_t cycle, uint32_t addr, uint64_t *data)
monitor_csr(char *name, int hart, uint64_t cycle, uint32_t addr, uint64_t data)
monitor_instr(char *name, int hart, uint64_t cycle, uint64_t tag,
              uint64_t pc, uint64_t opcode, uint32_t trap)
```

This confirms the required architecture if the migration continues:

```text
EH2 retire signals -> eh2_rvvi_adapter.sv -> rvviTrace
  -> generic RVVI-TRACE-to-monitor bridge -> cosim-arch-checker
  -> whisper_client -> whisper --server
```

The bridge must consume RVVI-TRACE. It must not directly probe EH2 internals.

### Current comparison coverage

The current upstream bridge updates CAC with:

| State | DUT side | Whisper side | Current upstream status |
|---|---|---|---|
| PC | yes | yes | compared |
| GPR | yes | yes | compared |
| FPR | yes | yes | compared |
| Vector registers | yes | yes | compared, BOOM/Ocelot style |
| CSR | monitor stores CSR writes in `rvInstr.csrs` | Whisper can report changes | not pushed into CAC by `bridge.cc` |
| Memory | whisper client has MCM APIs | no DUT monitor path wired | not compared by current bridge |

The CAC core itself also only generates register state ids for fixed, float,
and vector registers; CSR and memory support are not complete in the visible
bridge/core path. That is below the v2.0 signoff scope, where tracecmp compares
PC + GPR + CSR including 29 EH2 custom CSRs + memory.

### Configuration assumptions

`vendor/cosim-arch-checker/env/params.h` only configures:

```c++
#if ((CONFIG == MediumBoomVecConfig) || (CONFIG == MediumOcelotVecConfig))
  const int k_NumHarts = 1;
  const int k_VLen = 256;
#endif
```

There is no EH2 config, no RV32-specific xlen parameter, and the shipped
Whisper configs under `vendor/cosim-arch-checker/bridge/whisper/config/` are
RV64 examples. EH2 does have native Whisper configs already:

| Config | `xlen` | `harts` |
|---|---:|---:|
| `rtl/snapshots/default/whisper.json` | 32 | 1 |
| `rtl/snapshots/default_mt/whisper.json` | 32 | 2 |

Those configs are the right source of truth, but the checker side needs a new
`CONFIG=EH2...` path and RV32-aware bridge parameters.

## Whisper Server Findings

Whisper supports server mode via `--server <file>`. The current upstream
checker bridge launches it with:

```text
whisper <test> <bootcode> --harts <N> --raw --configfile <json>
  --logfile iss_cosim.log --traceload --commandlog isscmd.log
  --server whisper_connect &
```

Whisper writes a host/port pair into the server file and the checker connects
through `whisperConnect("whisper_connect")`.

Open integration work:

| Area | Risk |
|---|---|
| Process lifecycle | Current bridge starts Whisper with `system(... &)` and does not provide robust cleanup or unique per-test server files. Parallel regressions would need isolation. |
| Determinism | Lockstep timing depends on one retire at a time and stable server connection. Needs smoke/cosim proof after Whisper builds. |
| Async injection | Existing v2.0 async/debug/interrupt flow uses UVM handshake and bypasses tracecmp. The checker/Whisper route needs explicit `whisperPoke` or server commands for interrupt/debug state, not just retire stepping. |
| Multi-hart | EH2 has `default_mt` Whisper config, but checker `params.h` currently hard-codes one hart for its supported configs. |

## Go/No-Go Criteria

Phase 1 may start only after all of these are true:

1. A project-accepted machine prerequisite provides GCC 11+ and Boost 1.75+
   for C++20, or a proven older Whisper revision/build mode is selected and
   documented.
2. `vendor/whisper/GNUmakefile` builds `build-Linux/whisper` inside this repo.
3. A minimal checker + Whisper smoke harness can launch `whisper --server`,
   connect, step one RV32 EH2 instruction stream, and compare at least PC/GPR.
4. The planned bridge extension for CSR and memory comparison is accepted as
   Phase 1/2 scope, because upstream cosim-arch-checker does not currently
   provide v2.0-equivalent PC+GPR+CSR+memory checking.

Until then, the migration remains blocked.

## Plan B

If the project must stay on the current old server prerequisites, do not proceed
with the cosim-arch-checker + current Whisper source migration.

The viable choices are:

1. Keep `master` / v2.0 offline tracecmp + Spike-EH2 as the released green
   platform.
2. If Whisper becomes mandatory, first provide a buildable Whisper binary or
   upgrade the machine prerequisite set, then rerun Phase 0.
3. If cosim-arch-checker remains too BOOM/RV64/vector-oriented after toolchain
   upgrade, fall back to the earlier RVVI-API scoreboard Plan B from `b4c8be5`
   and implement a `whisper_rvvi.cc` reference wrapper. This still requires a
   buildable Whisper or a supplied compatible Whisper library/binary.

## Files Not Deleted

Per the "先证后删" rule, these remain intact:

| Area | Current status |
|---|---|
| `dv/cosim/spike_cosim.cc/.h` | retained |
| `dv/cosim/spike_rvvi_main.cc` | retained |
| `dv/uvm/core_eh2/scripts/trace_compare_full.py` | retained |
| `dv/uvm/core_eh2/scripts/rvvi_trace_to_trace_csv.py` | retained |
| `run_regress.py` offline tracecmp path | retained |
| top-level Makefile Spike/tracecmp targets | retained |

No RTL design files were modified.
