# LOCKSTEP-WHISPER Phase 2 收尾报告

日期：2026-06-18

工作区：`/home/host/eh2-cosim-veri-lockstep-whisper`

分支：`lockstep-whisper`

## 结论

Phase 2 在隔离工作区拿到了功能 signoff 证据：`smoke 1/1`、`directed 40/40`、`cosim 7/7`、`riscvdv 395/395`、`compliance 50/50` 全部 PASS，`riscv_csr_test` 与 `riscv_csr_hazard_test` 继续作为 v2.0 既有 tracked-broken 项排除在 signoff 外，没有新增 skip。

但本报告不把「debug request 经 Whisper server `EnterDebug`/`ExitDebug` 主动 Poke」声明为已闭合。当前实现已经对 interrupt/MIP 做了 retire 前 `Poke` 并验证 `riscv_interrupt_test` PASS；debug 类测试仍走在线 lockstep 与架构状态比较，`riscv_debug_test` PASS，但主动 `EnterDebug`/`ExitDebug` 曾暴露双发射 retire 包内时序问题，已回滚。若把「debug 必须通过 server debug 命令主动注入」作为硬门，本阶段仍有一个明确 follow-up。

本相未删除 Spike-EH2/offline 路径，未并回 master，未改 RTL。

## 实现摘要

### 外部 CSR mask

新增外部配置 `config/cac_csr_masks.txt`，由 `CAC_CSR_MASK_FILE` 传给 CAC。格式为：

```text
<csr-address> <compare-mask> # reason
```

当前 mask 分两类：

- 非确定计数器/timer：`cycle/cycleh`、`time/timeh`、`instret/instreth`、`mcycle/mcycleh`、`minstret/minstreth`。
- `mip(0x344)`：用于异步 interrupt pending 采样/清除时序差异。Whisper EH2 config 本身也将 `mip` compare mask 配为 `0x0`，bridge 同时会在 retire 前将 DUT 可见 `mip` Poke 到 Whisper。

牙齿测试仍保留：mask 的 CSR 不触发假失配，未 mask 的 `CSR[0x7c0]` 仍 FAIL，MEM 失配仍 FAIL。

### Interrupt/MIP 在线 Poke

`rvvi_cac_bridge.sv` 在每条 valid retire 前调用 `monitor_async`，传入：

- `rvvi.csr[h][r][12'h344]`，即 DUT 可见 `mip`；
- `rvvi.intr[h][r]`；
- `rvvi.debug_mode[h][r]`。

CAC monitor 将这些字段放入 `sRvInstr.async`。bridge 在 `whisperStep` 前调用：

```text
whisperPoke(hart, 'c', 0x344, dutInstr.async.mip, valid)
```

这条路径已用 `riscv_interrupt_test` 重跑验证。

### Debug 在线覆盖与未闭合项

`riscv_debug_test` 在 lockstep 模式下 PASS，说明当前在线架构状态比较没有退回 offline bypass。

主动 `EnterDebug`/`ExitDebug` Poke 曾尝试接入，但失败复现如下：

- DUT 的 `rvvi.debug_mode` 是 retire 级状态；
- 在双发射 retire 包中，若第一条 retire 后立刻向 Whisper 发 `EnterDebug`，Whisper 进入 debug-halt；
- 同一 retire 包的下一条仍需要 step，Whisper server 返回 `Error: Single step while in debug-halt mode`，随后 PC 变为 `0` 并失配。

证据日志：

```text
build/regress_lockstep_async_poke_debug2/riscv_debug_test_s1/sim_riscv_debug_test_1.log
build/regress_lockstep_async_poke_debug2/riscv_debug_test_s1/whisper_connect.cmd.log
```

因此当前实现只保留 `mip` Poke，不保留 debug server command Poke。debug request 的主动注入需要一个按 retire 包边界建模的时序方案，不能用简单状态翻转补丁硬推。

### 双 hart

CAC hart 数由 `CAC_NUM_HARTS` 参数化，`LOCKSTEP_WHISPER=1 CONFIG=dual_thread` 使用：

- `-DCAC_NUM_HARTS=2`
- `+define+RVVI_NHART=2`
- `config/whisper_default_mt_lockstep.json` / `rtl/snapshots/default_mt/whisper.json`

验收结果：双 hart cosim directed `7/7 PASS`。

### VeeR-ISS MRAC/PMA reset 修复

`riscv_arithmetic_basic_test` seed 2 的早期失败来自 VeeR-ISS MRAC reset side effect 未同步：ISS 将 `0x8000015e` misaligned store 误判为 trap，而 DUT 正常完成 store。修复点：

```text
vendor/whisper/HartConfig.cpp
defineMracSideEffects(): registerPostReset(reset)
```

修复后 `riscv_arithmetic_basic_test` seeds 2-7 全部 PASS。这是参考模型 reset side-effect 修正，不是 mask，也不是 testlist waiver。

## 验证结果

### Full signoff 结果集

证据文件：

```text
build/signoff_lockstep_full_phase2_final3/signoff_status.json
build/signoff_lockstep_full_phase2_final3/signoff_report.md
```

结果：

| Stage | 结果 |
|---|---:|
| smoke | 1/1 PASS |
| directed | 40/40 PASS |
| cosim | 7/7 PASS |
| riscvdv | 395/395 PASS |
| compliance | 50/50 PASS |
| coverage | SKIP (`COV=0`, `required=false`) |

说明：最终 signoff 状态来自完整结果集的归档/gate 汇总；各 stage 的 `report.json` 显示 0 failed。`signoff_report.md` 中仍记录了 stage command exit code waiver，这是因为此前长跑/超时后用已完成结果集做 gate 汇总，不应表述为一次无中断的自然返回命令。

### riscv-dv 与 tracked-broken CSR

`riscvdv` signoff 结果为 `395/395 PASS`。`riscv_csr_test` 与 `riscv_csr_hazard_test` 继续保持：

```text
cosim: disabled
skip_in_signoff: true
```

这是 v2.0 既有状态，不是本相新增 waiver。早期 raw partial run 中 5 个失败全是 `riscv_csr_test` seeds 1-5，失败原因是 riscv-dv CSR generator 对 `misa`/WARL 等行为的预期与 EH2 实现不一致，非 lockstep/ISS 失配。

### Compliance

compliance 走原官方 signature 流，不经 cosim oracle。signoff 结果为 `50/50 PASS`。

### Async 代表验证

最终重跑命令：

```bash
/usr/bin/time -p make regress LOCKSTEP_WHISPER=1 TESTLIST=riscvdv \
  TEST=riscv_interrupt_test ITERATIONS=1 SIMULATOR=vcs COV=0 PARALLEL=1 \
  OUT=build/regress_lockstep_async_poke_interrupt_final \
  CAC_CXX=/home/Xilinx/Vivado/2019.1/tps/lnx64/gcc-6.2.0/bin/g++ \
  WHISPER_PATH=vendor/whisper/build-Linux/whisper \
  WHISPER_LD_LIBRARY_PATH=/home/host/toolchains/boost-gcc9/lib:/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr/lib64:/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr/lib
```

结果：

```text
riscv_interrupt_test seed=1: PASS 1/1
total_time_sec: 22.44
sim_time_sec: 1.32
cycles: 698
wall real: 49.67 s
```

`sim_riscv_interrupt_test_1.log` 中可见 `Total exceptions: 1`、mailbox PASS、0 UVM error。

Debug rollback 后代表验证：

```text
build/regress_lockstep_async_poke_debug4/report.json
riscv_debug_test seed=1: PASS 1/1
sim_time_sec: 7.26
cycles: 10752
```

这证明 debug 流在当前 lockstep 架构比较下可跑通，但不是主动 debug server command Poke 的 closure。

### 双 hart

双 hart cosim directed：

```text
make regress LOCKSTEP_WHISPER=1 TESTLIST=cosim CONFIG=dual_thread ...
Total: 7 | Passed: 7 | Failed: 0
```

### 单元与构建

新鲜验证：

```text
python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q
224 passed, 1 skipped, 1 warning in 3.33s
```

```text
make cac CAC_CXX=/home/Xilinx/Vivado/2019.1/tps/lnx64/gcc-6.2.0/bin/g++
exit 0
```

```text
make -C vendor/cosim-arch-checker test CC=/home/Xilinx/Vivado/2019.1/tps/lnx64/gcc-6.2.0/bin/g++
exit 0
```

CAC 自测输出中故意包含 `CSR[0x7c0]` 与 MEM mismatch，用于证明非 mask CSR 和内存牙齿仍在。

## 性能数据

性能门早期单条样本：

```text
riscv_arithmetic_basic_test: PASS
wall real: 41.55 s
sim_time_sec: 2.65
```

最终 interrupt 样本：

```text
riscv_interrupt_test: PASS
wall real: 49.67 s
sim_time_sec: 1.32
```

Full signoff 结果集中 `riscvdv` 的仿真时间统计：

```text
total: 395
sim_time sum: 16034.29 s
sim_time min: 0.71 s
sim_time max: 1064.74 s
sim_time mean: 40.59 s
compile_time sum: 118.02 s
```

当前 signoff 输出没有结构化保存完整 wall-clock 总耗时；前序终端记录显示完整 lockstep 长跑 wall 约 `7790.71 s`，后续 gate 汇总约 `331.72 s`，仅作为非结构化参考。在线 socket 每 retire step 的性能风险仍真实存在；当前证据显示可完成 full signoff，但若要扩展更长随机或更多 seed，仍建议评估 batch step、Unix domain socket 或 shared-memory 通道。

## 反作弊与边界

已检查：

```text
git diff -- dv/uvm/core_eh2/riscv_dv_extension/testlist.yaml \
  dv/uvm/core_eh2/directed_tests/directed_testlist.yaml
# 空

git diff --name-only | rg '^rtl/' || true
# 空
```

本相未新增 testlist skip，未降低 iteration，未改 RTL，未删除 Spike-EH2/offline tracecmp 路径。

EH2 专属逻辑仍应限制在 adapter、Whisper JSON/配置与 core_eh2 集成层。`vendor/cosim-arch-checker` 中新增的是通用 async transaction 与 CSR Poke plumbing，不包含 EH2 名称硬编码。

## 与 v2.0 offline 对照

本相相对 v2.0 offline 的提升：

- riscv-dv signoff 集合达到 `395/395 PASS`，旧 Spike-EH2 offline 随机流中的系统性 CSR/PMP/trap 建模缺口不再出现。
- compliance 保持官方 signature `50/50 PASS`。
- 双 hart 在线 lockstep cosim `7/7 PASS`。
- interrupt pending state 可通过 Whisper server `Poke` 在线同步，异步 interrupt 代表样本不再 offline bypass。

保留的限制：

- `riscv_csr_test` / `riscv_csr_hazard_test` 仍是 v2.0 既有 tracked-broken，不在本相补 EH2 CSR directed。
- debug request 没有通过 `EnterDebug`/`ExitDebug` server command 主动注入；当前只证明 debug 测试在线 lockstep 可通过。
- `mip` 在 CAC 外部 mask 中保留，避免异步采样/清除时序造成假失配；这应在后续事件时序模型成熟后收窄。

## Phase 3 前置事项

`vendor/whisper/` 与本报告等文件当前仍可能是 untracked。并回主仓前必须把 VeeR-ISS MRAC/PMA reset 修复固化为可追踪资产：

- 推荐：提交一个 tracked patch，并在构建时 apply 到纯净 vendored Whisper；
- 或者：提交 `vendor/whisper` 源码改动。

否则 re-clone 后会丢失 `HartConfig.cpp` 的 `registerPostReset(reset)` 修复，`riscv_arithmetic_basic_test` seed 2 等会重新回归失败。

## 判定

功能覆盖与 signoff 结果集达到 v2.0 等同/更优的主要目标；interrupt 的在线 MIP Poke 已实现并验证；双 hart、riscv-dv、compliance 均有 PASS 证据。

严格 T2 口径下，debug request 的主动 server command Poke 未完成，应作为 Phase 2 残留或 Phase 3 前置 follow-up 记录，不能宣称「async/debug/interrupt 全部 via Poke closure」。
