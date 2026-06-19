# LOCKSTEP-WHISPER Phase 4 收尾报告

## 结论

Phase 4 完成了 RVVI-API lockstep 路的剩余深度收口：

- 端到端 sim 牙齿已补齐：临时注入 GPR 分歧时 smoke 变红，回退后同一路径恢复为 PASS。
- debug request 主动注入保持 downgrade：`+rvvi_debug_poke` 能发出 Whisper `EnterDebug`，但最小用例仍在主动 halt 后失配；默认在线 lockstep 兜底同 seed PASS，未称 closure。
- `mip(0x344)` mask 已从全 mask 收窄为仅屏蔽 MEIP bit 11：其余 pending 位参与比较。全比对在 full signoff 中暴露 `riscv_irq_single_test_s5` 的 MEIP 异步采样差异，因此最终保留 MEIP-only mask。
- 因 `mip` mask 改动会影响仿真结果，Phase 4 已在最终 mask 下执行一次 COV=1 full signoff，结果 PASS。

## P4.0 基线

基线仍为 Phase 3 RVVI-API 终态：

- HEAD：`b7c4f34 docs(lockstep): Phase 3 收尾报告与复现入口 (P3.7)`。
- `dv/uvm/core_eh2/common/rvvi_agent/rvvi_scoreboard.sv` 存在。
- `dv/uvm/core_eh2/common/rvvi_agent/rvvi_cac_bridge.sv` 不存在。
- 脚本单测：`python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q`，结果 `154 passed, 1 skipped, 1 warning`。
- CAC 牙齿：`make -C vendor/cosim-arch-checker test CC=$CAC_CXX` 通过，日志保留 CSR/MEM mismatch 牙齿。

## P4.1 端到端 sim 牙齿

临时在 `rvvi_scoreboard.sv` 中加入 `+rvvi_inject_gpr_fault` hook，翻转第一处写回 GPR 的 bit。该 hook 已通过 `git checkout -- dv/uvm/core_eh2/common/rvvi_agent/rvvi_scoreboard.sv` 回退，未进入提交。

证据：

| 项目 | 结果 | 证据 |
|---|---:|---|
| 注入跑 | FAIL | `build/p41_teeth_inject.log`，make exit=2，`build/smoke_vcs/smoke_s1/result.yaml` 为失败 |
| mismatch 行 | 有 | `TEMP P4.1 teeth: injecting GPR x10 mismatch, dut=00000000d0580000 fault=00000000d0580001` |
| 回退后 clean smoke | PASS | `build/smoke_vcs/report.json`：`total=1 passed=1 failed=0` |

结论：RVVI scoreboard 的 `$error`/`$finish` 可在真实 sim 中把绿回归打红，端到端牙齿成立。

## P4.2 debug 主动注入

`+rvvi_debug_poke` 仍按 opt-in 保留，未转默认。

最小用例：

```bash
make regress LOCKSTEP_WHISPER=1 TESTLIST=riscvdv TEST=riscv_debug_test \
  ITERATIONS=1 SIMULATOR=vcs COV=0 PARALLEL=1 \
  SIM_OPTS=+rvvi_debug_poke OUT=build/p42_debug_min
```

结果：FAIL，`build/p42_debug_min/report.json` 显示 `total=1 passed=0 failed=1`。Whisper 命令日志 `build/p42_debug_min/riscv_debug_test_s1/whisper_connect.cmd.log` 有：

```text
hart=0 enter_debug true # ts=0
hart=0 step #146 # ts=146
```

未出现 `Single step while in debug-halt`。失败现象是 ref 在 `EnterDebug` 后停在 `#146`，DUT 继续 retire 到后续 PC，scoreboard 在 `rvvi_scoreboard.sv:92` 结束仿真。该行为说明主动 debug halt 的时序模型仍未与 DUT/UVM debug request/resume 流闭合。

兜底验证：

```bash
make regress LOCKSTEP_WHISPER=1 TESTLIST=riscvdv TEST=riscv_debug_test \
  ITERATIONS=1 SIMULATOR=vcs COV=0 PARALLEL=1 OUT=build/p42_debug_fallback
```

结果：PASS，`build/p42_debug_fallback/report.json` 显示 `total=1 passed=1 failed=0`。

判定：downgrade。debug 主动注入已设计并可触发 `EnterDebug`，但未达到 closure；默认路径仍采用在线 lockstep 比较兜底。Phase 5+ 需要继续收敛 debug halt/resume 包边界模型。

## P4.3 mip mask 收窄

改动：将 `config/cac_csr_masks.txt` 中的 `0x344 0x00000000` 收窄为：

```text
0x344 0xfffffffffffff7ff # mip: compare all pending bits except MEIP(bit 11), whose sample/clear edge is asynchronous to retire.
```

含义：`mip(0x344)` 除 MEIP bit 11 外全部参与比较。MEIP 保留 mask 的原因来自一次全 bit 比对尝试：`build/signoff_vcs/signoff_status.json` 顶层为 PASS，但 run-level 扫描发现 `riscv_irq_single_test_s5` 失败，日志 `build/signoff_vcs/runs/riscvdv/riscv_irq_single_test_s5/sim_riscv_irq_single_test_5.log` 报：

```text
CSR mismatch hart=0 index=0x344 dut=0x800 ref=0x0 mask=0xffffffffffffffff
```

该差异只落在 MEIP bit 11，符合外部中断 pending 采样 / 清除边界相对 retire 的异步性。

验证：

| 测试 | 命令摘要 | 结果 | 证据 |
|---|---|---:|---|
| interrupt（全比对探针） | `riscv_interrupt_test ITERATIONS=3` | 3/3 PASS | `build/p43_irq/report.json` |
| irq CSR（全比对探针） | `riscv_irq_csr_test ITERATIONS=2` | 2/2 PASS | `build/p43_irq_csr/report.json` |
| irq single（MEIP-only mask） | `riscv_irq_single_test ITERATIONS=5` | 5/5 PASS | `build/p43_irq_single_masked/report.json` |
| interrupt（MEIP-only mask） | `riscv_interrupt_test ITERATIONS=3` | 3/3 PASS | `build/p43_irq_masked/report.json` |
| irq CSR（MEIP-only mask） | `riscv_irq_csr_test ITERATIONS=2` | 2/2 PASS | `build/p43_irq_csr_masked/report.json` |

牙齿：

临时在 scoreboard 中用 `+rvvi_inject_mip_fault` stage 一个错误的 DUT `mip` 值。该 hook 已回退，未进入提交。注入跑：

```bash
make regress LOCKSTEP_WHISPER=1 TESTLIST=riscvdv TEST=riscv_interrupt_test \
  ITERATIONS=1 SIMULATOR=vcs COV=0 PARALLEL=1 \
  SIM_OPTS=+rvvi_inject_mip_fault OUT=build/p43_mip_teeth2
```

结果：FAIL，`build/p43_mip_teeth2/report.json` 显示 `total=1 passed=0 failed=1`。关键日志位于 `build/p43_mip_teeth2/riscv_interrupt_test_s1/sim_riscv_interrupt_test_1.log`：

```text
RVVI scoreboard mismatch: CSR mismatch hart=0 index=0x344 dut=0x1 ref=0x0 mask=0xffffffffffffffff
```

判定：promote。`mip(0x344)` 从全 mask 收窄为 MEIP-only mask，interrupt 代表组通过，非 MEIP 比较位有牙齿。

## P4.4 复签

由于 P4.3 修改了 `mip` mask，必须执行一次 full signoff。签核命令：

```bash
make signoff PROFILE=full LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=1 \
  SIGNOFF_OPTS="--no-fail-on-skip-in-signoff --timeout-s 14400" \
  SIGNOFF_OUT=build/signoff_p44_masked_clean
```

结果：PASS。证据：`build/signoff_p44_masked_clean/signoff_status.json`、`build/signoff_p44_masked_clean/signoff_report.md`、`build/signoff_p44_masked_clean/report.html`。

Stage 汇总：

| Stage | 结果 | Total | Passed | Failed | Waivers |
|---|---:|---:|---:|---:|---|
| smoke | PASS | 1 | 1 | 0 | `[]` |
| directed | PASS | 40 | 40 | 0 | `[]` |
| cosim | PASS | 7 | 7 | 0 | `[]` |
| riscvdv | PASS | 395 | 395 | 0 | `[]` |
| compliance | PASS | 50 | 50 | 0 | `[]` |

Coverage：`status=PASS`，line `91.19%`（gate `55.00%`），functional `69.40%`（gate `40.00%`），overall `64.03%`。

说明：此前 `build/signoff_p44_masked` 因 signoff 默认 `--timeout-s 7200` 在 riscvdv 仍有子进程继续写结果时提前汇总，出现 stage exit-code timeout waiver；该目录不作为 Phase 4 终签证据。最终证据仅采用本次 `SIGNOFF_OUT=build/signoff_p44_masked_clean` 的自然 `make exit=0` 结果。

## 反作弊

最终提交前已执行并确认以下检查：

- `git diff --name-only | grep '^rtl/' | grep -v snapshots` 为空。
- testlist diff 不扩大 `skip_in_signoff`，不降低 iteration，不新增 disable。
- `find . -path ./.git -prune -o -type l -print` 为空。
- `rvvi_inject_gpr_fault` / `rvvi_inject_mip_fault` / `TEMP P4.1 teeth` 在源码中无残留。
- CAC 与通用 scoreboard 仍保持 core-agnostic；`eh2`/`veer` 命中仅限既有路径名、adapter 或注释语境。
- tracked 源绝对路径 grep 为空；机器路径未进入本次改动。
- 脚本单测：`154 passed, 1 skipped, 1 warning`。
- CAC 牙齿：`make -C vendor/cosim-arch-checker test CC=$CAC_CXX` exit 0，并保留 CSR/MEM mismatch 牙齿输出。

## Phase 5+ 遗留

- debug 主动注入闭合：继续定位 `EnterDebug` 后 DUT/ref halt/resume 包边界差异，在 server command 真注入并代表组 PASS 前不得称 closure。
- 第二核 bring-up、文档诚实化、tag/push 仍留 Phase 5。
