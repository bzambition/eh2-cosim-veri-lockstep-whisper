# Tracecmp P4 交付说明

日期：2026-06-16

## 范围

本说明只覆盖 P4/P4.5 的离线 tracecmp 交付面：RVVI 采集、EH2-Spike 参考流、逐 retire 架构态比对、异步写回 tag 对齐、debug/interrupt 异步绕开，以及 riscvdv 残留归类。README、覆盖率门控诚实化、在线 lockstep 死代码清理和 onboarding recipe 留给 P5。

## 比对范围

`dv/uvm/core_eh2/scripts/trace_compare_full.py` 是 core-agnostic 比对器。输入是 DUT 与 ref 的通用 CSV，不读取 EH2 层级信号，也不硬编码 EH2 CSR 语义。

逐 retire 比对项：

| 状态 | 来源 | 比对方式 |
|---|---|---|
| hart | CSV `pad`/`operand` 中的 `hart=N` | 逐行相等 |
| PC | CSV `pc` | 32-bit 归一化后相等 |
| instruction | CSV `binary` | 任一侧非空时相等 |
| GPR | CSV `gpr` 写集合 | 寄存器名归一化后逐项相等 |
| CSR | CSV `csr` 写集合 | CSR 编号归一化后逐项相等，支持外部 `--csr-mask` |
| memory | `mem=addr:data:be` token | 按 byte-enable 展开成字节映射后相等 |

CSR mask 机制只在命令行外部传入，当前 `make regress TESTLIST=riscvdv` 路径没有对 P4/P4.5 全量结果传入额外 mask。已知非确定源和处理原则如下：

| CSR/来源 | 处理 |
|---|---|
| `mcycle`/`mcycleh` (`0xb00`/`0xb80`) | 支持用 `--csr-mask 0xb00:0x0`、`--csr-mask 0xb80:0x0` 完全屏蔽；P4.5 全量未依赖该 mask。 |
| `minstret`/`minstreth` (`0xb02`/`0xb82`) | 支持用 `--csr-mask 0xb02:0x0`、`--csr-mask 0xb82:0x0` 完全屏蔽；P4.5 全量未依赖该 mask。 |
| timer/中断/debug 异步路径 | 不进入离线 tracecmp；由 testlist 的 `tracecmp_bypass` 绑定到 UVM agent/signature handshake。 |
| WARL/WPRI 位 | 由 EH2 adapter 与 EH2-Spike reference 在采集/参考模型侧归一化；比对器本身不写核专属规则。 |

EH2 custom CSR 清单来自 `dv/uvm/core_eh2/riscv_dv_extension/riscv_core_setting.sv` 的 `custom_csr[]`，共 29 个：`0x7ff`、`0x7c0`、`0x7c9`、`0x7f8`、`0x7c6`、`0x7c2`、`0x7c4`、`0x7ce`、`0x7cf`、`0xfc4`、`0x7fc`、`0x7fe`、`0x7d2`、`0x7d5`、`0x7d3`、`0x7d6`、`0x7d4`、`0x7d7`、`0xbc0`、`0xfc0`、`0x7f0`、`0x7f1`、`0x7f2`、`0xbc8`、`0xfc8`、`0xbc9`、`0xbca`、`0xbcc`、`0xbcb`。

## 异步 tag 协议

RVVI dump 使用 pipe-delimited 文本协议，converter `dv/uvm/core_eh2/scripts/rvvi_trace_to_trace_csv.py` 负责把微架构延迟隐藏成架构 retire 行：

```text
hart|order|pc|insn|trap|mode|gpr=...|csr=...|mem=...|tag=load:N
A|hart|load|xRD:VALUE|tag=N
A|hart|div|xRD:VALUE|tag=N
C|hart|CSR:VALUE
M|hart|ADDR:DATA:BE
```

通用 converter 规则：

| 记录 | 行为 |
|---|---|
| retire `tag=load:N` / `tag=div:N` | 建立等待中的架构 retire 行；key 为 `(hart, source, tag, N)`，fallback 为 `(hart, source, rd)`。 |
| async `A|...|tag=N` | 优先精确 tag 认领，补写该 retire 行的 GPR 值；不改变 retire 顺序。 |
| async 无 tag | 仅作为兼容 fallback，按 `(hart, source, rd)` 认领唯一等待行。 |
| `M` / `C` | 在有限 retire 窗口内认领 store/CSR 写行，避免 bus/CSR 写脉冲时序泄漏到架构 CSV。 |

DIV/REM：adapter 在 issue 时分配软件 tag，retire dump 输出 `tag=div:N`，写回或 cancel-overwrite 路径输出 `A|hart|div|xRD:VALUE|tag=N`。

nb-load：adapter 在 load allocate 时保存硬件非阻塞 load tag，在 trace WB1 对齐后的 retire 行输出 `tag=load:N`；load data valid 时按硬件 tag 认领 pending row，输出 `A|hart|load|xRD:VALUE|tag=N`。当写端口因年轻同 rd 写回而取消时，adapter 仍输出精确 tag 的 load completion，使 converter 能把值归到正确 load retire 行，而不是用 `suppress_gpr` 屏蔽。

P4.5 修复点：

| 文件 | 作用 |
|---|---|
| `dv/uvm/core_eh2/tb/core_eh2_tb_top.sv` | 把 nb-load retire tag 延迟到 trace WB1，与 `dec_i*_inst_wb1` retire 行对齐。 |
| `dv/uvm/core_eh2/common/rvvi_agent/eh2_rvvi_adapter.sv` | retire tag 优先使用硬件 tag；load data valid 即使 `nb_load_wen` 被取消，也按 tag 输出 completion。 |
| `dv/uvm/core_eh2/scripts/tests/test_rvvi_trace_to_trace_csv.py` | 新增 nb-load retire tag、write-port cancel 精确认领和 TB WB1 延迟静态/转换测试。 |

验证证据：

| 项 | 修复前 | 修复后 |
|---|---|---|
| `riscv_stress_test` | `build/p4_gate_riscvdv_next2/riscv_stress_test_s1/trace_compare.log`：`[FAILED]: 13330 matched, 16 mismatch`，失配均为 load GPR 错位。 | `build/p45_full_riscvdv/riscv_stress_test_s1/trace_compare.log`：`[PASSED]: 13346 retire rows matched`。 |
| 单项 stress | 同上 | `build/p45_stress_wb1tag/riscv_stress_test_s1/trace_compare.log`：`[PASSED]: 13346 retire rows matched`。 |
| load/muldiv 回归 | 不适用 | `build/p45_load_store_check_seq`、`build/p45_unaligned_load_store_check`、`build/p45_mul_div_check` 均 PASS。 |

## 双 hart 与共享内存

双 hart tracecmp 不把核名写进比对器。DUT CSV 每行带 `hart=N`，EH2-Spike reference 由 DUT CSV 生成 hart schedule，按同一 hart 序列步进。比对器逐 retire 比较 hart/PC/instruction/GPR/CSR；共享 DCCM 一致性通过 `mem=addr:data:be` 的字节级写集合校验，任一 hart 对共享地址的 store 都必须与 reference 在同一架构行产生相同 byte map。

P4 已验证 `p4_dual_thread_next` 为 7/7 per-hart PASS；P4.5 未改变该机制。

## 异步绕开清单

以下 testlist 项明确禁用 tracecmp，并用对应 UVM agent 或 signature handshake 作为兜底。P4.5 未削弱这些 bypass。

| 测试 | 兜底路径 |
|---|---|
| `riscv_interrupt_test` | irq_agent/signature handshake |
| `riscv_irq_single_test` | irq_agent/signature handshake |
| `riscv_debug_test` | jtag/halt_run agent + directed debug checks |
| `riscv_debug_csr_test` | jtag/halt_run agent + directed debug checks |
| `riscv_breakpoint_test` | directed debug/UVM agent path |
| `riscv_reset_test` | UVM reset/interrupt checks |
| `riscv_single_step_test` | debug agent path |
| `riscv_debug_wfi_test` | directed debug agent path |
| `riscv_debug_during_csr_test` | debug agent path |
| `riscv_debug_ebreak_test` | debug agent path |
| `riscv_irq_wfi_test` | irq_agent/signature handshake |
| `riscv_irq_csr_test` | irq_agent/signature handshake |
| `riscv_irq_nest_test` | irq_agent/signature handshake |
| `riscv_irq_in_debug_test` | irq and debug agents |
| `riscv_debug_in_irq_test` | irq and debug agents |
| `riscv_dret_test` | debug agent path |
| `riscv_debug_ebreakmu_test` | debug agent path |
| `riscv_single_debug_pulse_test` | debug agent path |
| `riscv_debug_triggers_test` | debug agent path |
| `riscv_debug_stress_test` | debug agent path |
| `riscv_debug_branch_jump_test` | debug ROM/debug agent path |
| `riscv_debug_csr_entry_test` | debug agent path |
| `riscv_assorted_traps_interrupts_debug_test` | irq and debug agents |

## debug-CSR triage 结论

旧残留 `riscv_debug_during_csr_test`、`riscv_debug_stress_test`、`riscv_debug_csr_entry_test` 的 seed 1 timeout 不是 RTL bug。根因在 UVM debug resume 协议：部分 directed debug 路径写 `DMI_DMCONTROL = 32'h40000000`，同时清掉 `dmactive`。稳定路径是先写 `32'h40000001` 发 resume request 并保持 `dmactive=1`，再写 `32'h00000001` 清 resume request。

P4.5 修复：

| 文件 | 作用 |
|---|---|
| `dv/uvm/core_eh2/tests/core_eh2_base_test.sv` | 新增 `send_debug_resume()` helper。 |
| `dv/uvm/core_eh2/tests/core_eh2_test_lib.sv` | 将裸 `32'h40000000` resume 改为 helper。 |
| `dv/uvm/core_eh2/scripts/tests/test_regression_framework.py` | 新增静态测试，禁止 directed debug resume 清掉 `dmactive`。 |

P4.5 全量证据：

| 测试 | 结果 | 证据 |
|---|---|---|
| `riscv_debug_during_csr_test` | PASS | `build/p45_full_riscvdv/riscv_debug_during_csr_test_s1/sim_riscv_debug_during_csr_test_1.log`：`--- EH2 UVM TEST PASSED ---`。 |
| `riscv_debug_stress_test` | PASS | `build/p45_full_riscvdv/riscv_debug_stress_test_s1/sim_riscv_debug_stress_test_1.log`：`--- EH2 UVM TEST PASSED ---`。 |
| `riscv_debug_csr_entry_test` | PASS | `build/p45_full_riscvdv/riscv_debug_csr_entry_test_s1/sim_riscv_debug_csr_entry_test_1.log`：`--- EH2 UVM TEST PASSED ---`。 |

因此这 3 条归类为「我方 debug agent resume 协议问题，已修复 PASS」，没有 RTL bug waiver。

## riscvdv 残留归类

P4.5 全量命令：

```bash
make regress TESTLIST=riscvdv OUT=build/p45_full_riscvdv
```

结果：`Total: 57 | Passed: 55 | Failed: 2`，exit 0。未出现未解释 tracecmp mismatch。

| 测试 | P4.5 结果 | 分类 | 证据/备注 |
|---|---:|---|---|
| `riscv_stress_test` | PASS | 已修 | nb-load 精确 tag 对齐；`trace_compare.log` 13346/13346 matched。 |
| `riscv_debug_during_csr_test` | PASS | 已修 | debug resume 保持 `dmactive`。 |
| `riscv_debug_stress_test` | PASS | 已修 | debug resume 保持 `dmactive`。 |
| `riscv_debug_csr_entry_test` | PASS | 已修 | debug resume 保持 `dmactive`。 |
| `riscv_csr_test` | FAIL | `skip_in_signoff` 已知 tracked-broken | testlist 已有 `skip_in_signoff: true`，`cosim: disabled`；证据 `build/p45_full_riscvdv/riscv_csr_test_s1/sim_riscv_csr_test_1.log`。 |
| `riscv_csr_hazard_test` | FAIL | `skip_in_signoff` 已知 tracked-broken | testlist 已有 `skip_in_signoff: true`，`cosim: disabled`；证据 `build/p45_full_riscvdv/riscv_csr_hazard_test_s1/sim_riscv_csr_hazard_test_1.log`。 |

归类结论：上述单轮 `make regress TESTLIST=riscvdv` 门下无未解释失配；剩余 2 项均为已标注 `skip_in_signoff` 的 tracked-broken CSR 测试。该结论不能外推到 `make signoff PROFILE=full` 的多 iteration riscvdv stage，full signoff 实测结果见下一节。

## signoff 结论

P4.5 已真实运行 full signoff：

```bash
make signoff PROFILE=full SIGNOFF_OPTS=--no-fail-on-skip-in-signoff
```

首次运行完成时间为 2026-06-16 12:49:26，所有仿真 stage 均已实跑，实跑覆盖率为 102/104 (98.1%)。检查报告时发现 `signoff.py` 只重读 UVM sim log，会把 `run_regress.py` 已记录的 `TRACECMP_MISMATCH` 覆盖成 PASS，形成假绿。P4.5 已修正 signoff 聚合逻辑：`TRACECMP_MISMATCH` 属于 recorded-only failure，归档报告重评估时不得被干净 UVM log 覆盖。

修正后用同一批真实 stage 结果做 gate-only 重评估：

```bash
python3 dv/uvm/core_eh2/scripts/signoff.py \
  --profile full --simulator vcs --output build/signoff_vcs --gate-only \
  --skip-precheck \
  --stage-result smoke=build/signoff_vcs/runs/smoke \
  --stage-result directed=build/signoff_vcs/runs/directed \
  --stage-result cosim=build/signoff_vcs/runs/cosim \
  --stage-result riscvdv=build/signoff_vcs/runs/riscvdv \
  --stage-result compliance=build/signoff_vcs/runs/compliance \
  --coverage --min-line-coverage 55 --min-functional-coverage 40 \
  --allow-warnings --no-fail-on-skip-in-signoff
```

最新权威报告：

| 文件 | 时间戳 | 结论 |
|---|---|---|
| `build/signoff_vcs/signoff_status.json` | 2026-06-16 12:53:54 +0800 | `FAIL` |
| `build/signoff_vcs/signoff_report.md` | 2026-06-16 12:53:54 +0800 | `FAIL` |
| `build/signoff_vcs/report.html` | 2026-06-16 12:53:54 +0800 | HTML 明细 |

Stage 明细：

| Stage | Status | Total | Passed | Failed | 说明 |
|---|---:|---:|---:|---:|---|
| smoke | PASS | 1 | 1 | 0 | 冒烟通过。 |
| directed | PASS | 40 | 34 | 6 | 6 条 `TRACECMP_MISMATCH` 被 stage threshold waiver 覆盖。 |
| cosim | PASS | 7 | 7 | 0 | cosim directed 通过。 |
| riscvdv | FAIL | 395 | 225 | 170 | full signoff 默认采用 testlist 多 iteration；失败率 43.0%，超过 waiver 上限。 |
| compliance | PASS | 50 | 50 | 0 | rv32i 41/41、rv32im 8/8、rv32imc 1/1。 |
| coverage | PASS | - | - | - | overall 65.25%、line 95.05%、functional 69.44%。 |

`--no-fail-on-skip-in-signoff` 只避免 `riscv_csr_test` / `riscv_csr_hazard_test` 这两个已知 `skip_in_signoff` 项把整体状态误判为失败；报告仍保留 `skip_in_signoff_tests` 字段和 stage 明细，不能视为 100% 绿。

Full signoff riscvdv 失败分布：

| Failure mode | Count | 归类 |
|---|---:|---|
| `TRACECMP_MISMATCH` | 138 | full 多 iteration 新暴露的离线 tracecmp blocker，未在 P4.5 四项残留范围内修复。 |
| `TEST_FAIL` | 22 | UVM/signature 失败，需后续按测试拆分 triage。 |
| `UVM_ERROR` | 4 | UVM agent/checker 失败。 |
| `SIM_TIMEOUT` | 3 | 仿真超时。 |
| `NO_PASS_SIGNATURE` | 3 | 未看到通过签名。 |

高频失败测试：`riscv_pmp_out_of_bounds_test` 36、`riscv_stress_test` 17、`riscv_random_instr_test` 15、`riscv_rand_jump_test` 8、`riscv_load_store_test` 8、`riscv_mul_div_test` 8、`riscv_pmp_random_test` 8、`riscv_jump_stress_test` 8、`riscv_dual_issue_test` 7。

最终结论：P4.5 原 4 项残留中，nb-load seed 1 stress 失配已修，3 条 debug-CSR seed 1 timeout 已修，单轮 riscvdv 门无未解释失配；但真实 full signoff 仍为 FAIL，blocker 为多 iteration riscvdv 的 170 条失败，其中 138 条为 `TRACECMP_MISMATCH`。因此 P5 的「full signoff 已整体 PASS」前置尚未满足。
