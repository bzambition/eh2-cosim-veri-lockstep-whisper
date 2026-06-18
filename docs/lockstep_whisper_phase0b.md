# LOCKSTEP-WHISPER Phase 0b Report

Date: 2026-06-18

Workspace: `/home/host/eh2-cosim-veri-lockstep-whisper`

Branch/base: `lockstep-whisper` at `72c50d6`

## Decision

**GO for the next feasibility step on this server.**

Phase 0b overturns the Phase 0 environment no-go by switching from the wrong
`tenstorrent/whisper` C++20 fork to the correct VeeR native
`chipsalliance/VeeR-ISS` C++17 codebase.

What is proven:

1. A no-root GCC 9.3.1 toolchain runs from `/home/host/toolchains`.
2. Boost 1.75 `program_options` builds with that GCC 9 toolchain.
3. VeeR-ISS builds as `vendor/whisper/build-Linux/whisper`.
4. VeeR-ISS loads the EH2 `rtl/snapshots/default/whisper.json` config and runs
   `tests/asm/smoke.elf`.
5. The standalone smoke PC stream matches the DUT RVVI smoke trace for the first
   architectural retires.
6. VeeR-ISS `--server` writes a host/port file and accepts a socket client that
   steps one instruction and returns PC/opcode.

What is not done in Phase 0b:

1. No VCS/DPI lockstep integration.
2. No cosim-arch-checker bridge changes.
3. No CSR/memory comparison closure.
4. No async/debug/interrupt injection closure.
5. No deletion of Spike-EH2 or offline tracecmp.

## Source Selection

Phase 0 used the wrong fork:

| Path | Problem |
|---|---|
| `tenstorrent/whisper` | C++20, requires g++ 11+ and Boost 1.75+ |

Phase 0b uses the correct VeeR native fork:

| Path | Version used | Result |
|---|---|---|
| `vendor/whisper` | `chipsalliance/VeeR-ISS` HEAD `e6b4fb17bd9bf15a9df225bea804be663648903a` | builds with C++17 |

Tag `1.607` was tested first but failed with GCC 9 because `whisper.cpp` used
`std::atomic` without the later fixes present on HEAD. The selected HEAD remains
C++17 and contains `CsRegs`, `PmpManager`, `Server.cpp`, and the VeeR native
configuration support required for EH2.

## No-root GCC 9

The toolchain is installed under:

```text
/home/host/toolchains/devtoolset-9
```

RPMs downloaded from CentOS 7 SCL vault:

```text
https://vault.centos.org/centos/7/sclo/x86_64/rh/Packages/d/
```

RPM set:

```text
devtoolset-9-runtime-9.1-0.el7.x86_64.rpm
devtoolset-9-binutils-2.32-16.el7.x86_64.rpm
devtoolset-9-gcc-9.3.1-2.2.el7.x86_64.rpm
devtoolset-9-gcc-c++-9.3.1-2.2.el7.x86_64.rpm
devtoolset-9-libstdc++-devel-9.3.1-2.2.el7.x86_64.rpm
```

Reproducible setup:

```bash
mkdir -p /home/host/toolchains/src/devtoolset-9-rpms
cd /home/host/toolchains/src/devtoolset-9-rpms
for rpm in \
  devtoolset-9-runtime-9.1-0.el7.x86_64.rpm \
  devtoolset-9-binutils-2.32-16.el7.x86_64.rpm \
  devtoolset-9-gcc-9.3.1-2.2.el7.x86_64.rpm \
  devtoolset-9-gcc-c++-9.3.1-2.2.el7.x86_64.rpm \
  devtoolset-9-libstdc++-devel-9.3.1-2.2.el7.x86_64.rpm
do
  curl -L --fail --retry 3 -O \
    "https://vault.centos.org/centos/7/sclo/x86_64/rh/Packages/d/$rpm"
done

chmod -R u+rwX /home/host/toolchains/devtoolset-9 2>/dev/null || true
rm -rf /home/host/toolchains/devtoolset-9
mkdir -p /home/host/toolchains/devtoolset-9
cd /home/host/toolchains/devtoolset-9
for rpm in /home/host/toolchains/src/devtoolset-9-rpms/*.rpm
do
  rpm2cpio "$rpm" | cpio -idmu --no-preserve-owner --quiet \
    './opt/rh/devtoolset-9/*' './etc/scl/*'
  chmod -R u+rwX .
done
```

Environment:

```bash
export DTS=/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr
export PATH="$DTS/bin:$PATH"
export LD_LIBRARY_PATH="$DTS/lib64:$DTS/lib:${LD_LIBRARY_PATH:-}"
```

Validation:

```text
/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr/bin/g++
g++ (GCC) 9.3.1 20200408 (Red Hat 9.3.1-2)
/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr/bin/as
GNU assembler version 2.32-16.el7
if_constexpr_status=0
```

Note: keep `LD_LIBRARY_PATH` pointing at devtoolset `lib64/lib` when invoking
this GCC directly; its bundled assembler needs `libopcodes-2.32-16.el7.so`.

## Boost 1.75

Boost is installed under:

```text
/home/host/toolchains/boost-gcc9
```

Reproducible setup:

```bash
export DTS=/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr
export PATH="$DTS/bin:$PATH"
export LD_LIBRARY_PATH="$DTS/lib64:$DTS/lib:${LD_LIBRARY_PATH:-}"

mkdir -p /home/host/toolchains/src /home/host/toolchains/boost-gcc9
cd /home/host/toolchains/src
curl -L --fail --retry 3 -o boost_1_75_0.tar.gz \
  'https://downloads.sourceforge.net/project/boost/boost/1.75.0/boost_1_75_0.tar.gz'
tar xf boost_1_75_0.tar.gz
cd boost_1_75_0
./bootstrap.sh --prefix=/home/host/toolchains/boost-gcc9 \
  --with-libraries=program_options
./b2 -j4 toolset=gcc cxxstd=17 link=shared runtime-link=shared \
  --with-program_options install
```

Validation:

```text
boost_probe_status=0
```

This avoids the Xilinx Boost 1.64 dual-ABI risk.

## VeeR-ISS Build

`vendor/whisper` was replaced with `chipsalliance/VeeR-ISS` HEAD
`e6b4fb17bd9bf15a9df225bea804be663648903a` using `cp -rL`; `.git` was removed.

Build command:

```bash
export DTS=/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr
export PATH="$DTS/bin:$PATH"
export LD_LIBRARY_PATH="/home/host/toolchains/boost-gcc9/lib:$DTS/lib64:$DTS/lib:${LD_LIBRARY_PATH:-}"

cd /home/host/eh2-cosim-veri-lockstep-whisper/vendor/whisper
make -f GNUmakefile CXX="$DTS/bin/g++" \
  BOOST_ROOT=/home/host/toolchains/boost-gcc9 \
  STATIC_LINK=0 -j4 build-Linux/whisper
```

Validation:

```text
vendor/whisper/build-Linux/whisper --help
Simulate a RISCV system running the program specified by the given ELF
```

The actual compile line uses `-std=c++17`, not C++20.

## Standalone Smoke Oracle Check

Smoke ELF was built in the isolated workspace:

```bash
make asm
```

Standalone VeeR-ISS command:

```bash
export LD_LIBRARY_PATH="/home/host/toolchains/boost-gcc9/lib:/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr/lib64:/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr/lib:${LD_LIBRARY_PATH:-}"

vendor/whisper/build-Linux/whisper \
  --target tests/asm/smoke.elf \
  --configfile rtl/snapshots/default/whisper.json \
  --maxinst 40 \
  --logfile build/phase0b_whisper/smoke_whisper.log \
  --csvlog
```

Observed status:

```text
WHISPER_STATUS=0
CSR mhartid cannot be configured.
Ignoring mhartid CSR configuration in config file.
Stopped -- Reached instruction limit
Retired 40 instructions
```

The `mhartid` warning is not an unknown custom CSR failure; VeeR-ISS ignores
attempted configuration of that CSR.

VeeR-ISS PC stream:

```text
80000000 80000004 80000008 8000000c 8000000c ...
```

Smoke disassembly:

```text
80000000: d0580537  lui a0,0xd0580
80000004: 0ff00593  li a1,255
80000008: 00b50023  sb a1,0(a0)
8000000c: a001      j 8000000c
```

DUT RVVI smoke trace from the existing v2.0 signoff build:

```text
/home/host/eh2-cosim-veri/build/signoff_vcs/runs/smoke/smoke_s1/rvvi_trace.log

0|0|80000000|d0580537|0|3|gpr=x10:d0580000|csr=
0|1|80000004|0ff00593|0|3|gpr=x11:000000ff|csr=
M|0|d0580000:000000ff:1
0|2|80000008|00b50023|0|3|gpr=|csr=
0|3|8000000c|0000a001|0|3|gpr=|csr=
```

Conclusion: the smoke PC/opcode stream is aligned between VeeR-ISS and DUT.

## Server Mode Check

VeeR-ISS server command:

```bash
vendor/whisper/build-Linux/whisper \
  --target tests/asm/smoke.elf \
  --configfile rtl/snapshots/default/whisper.json \
  --server build/phase0b_whisper/server.info \
  --logfile build/phase0b_whisper/server.log
```

Observed server file:

```text
IC_EDA 59815
```

A minimal `/tmp` client using VeeR-ISS `WhisperMessage.h` and the
`Server.cpp` network-byte-order serialization protocol connected and stepped one
instruction:

```text
pc=0x80000000 insn=0xd0580537 changes=1 type=5 disasm=lui      x10, -0x2fa80
```

Server log:

```text
#1 0 80000000 d0580537 r 0a         d0580000  lui      x10, -0x2fa80
```

Important compatibility note: the Tenstorrent cosim-arch-checker
`whisper_client` is not wire-compatible with this VeeR-ISS HEAD because its
vendored `WhisperMessage.h` has extra `size/instrTag/time` and MCM fields.
Phase 1 must either:

1. update the checker-side client to the VeeR-ISS protocol, or
2. write a small VeeR-ISS client shim and keep it isolated from generic checker
   comparison logic.

## Remaining Phase 1+ Work

GO here only means the server can host a VeeR-ISS oracle on this machine. The
next phase still has real design work:

1. Decide checker path:
   - extend cosim-arch-checker for VeeR-ISS protocol + CSR/memory, or
   - use the RVVI-API scoreboard Plan B and write a `whisper_rvvi.cc` shim.
2. Preserve DUT boundary through `eh2_rvvi_adapter.sv` and RVVI-TRACE.
3. Close CSR/memory comparison parity with v2.0 tracecmp.
4. Define async/debug/interrupt injection into VeeR-ISS server.
5. Only after smoke/cosim lockstep passes may Spike-EH2 and offline tracecmp be
   deleted.

## Files Not Deleted

Per the "先证后删" rule, these remain present:

```text
dv/cosim/spike_cosim.cc
dv/cosim/spike_cosim.h
dv/uvm/core_eh2/scripts/trace_compare_full.py
dv/uvm/core_eh2/scripts/rvvi_trace_to_trace_csv.py
```

No RTL design files were modified.

## Final Verification

Fresh checks run after the Phase 0b work:

```text
find . -type l
# no output

python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q
# 216 passed, 1 skipped, 1 warning in 2.41s

git diff --name-only | grep '^rtl/' | grep -v snapshots
# no output
```

No VeeR-ISS server or probe process was left running.
