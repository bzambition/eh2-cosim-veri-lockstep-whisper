# EH2 UVM 验证平台（DV）

本目录包含 VeeR EH2 RISC-V 核的 UVM 验证环境，对标 lowRISC Ibex 验证平台。

## 快速开始

三步跑通 smoke 测试：

```bash
# 1. 编译 RTL + TB
make compile SIMULATOR=vcs

# 2. 跑 smoke 测试
make run TEST=smoke

# 3. 跑 sign-off（含 cosim）
make signoff SIGNOFF_PROFILE=quick PARALLEL=4
```

## 环境要求

- VCS 2022.06+（或 Xcelium / Questa）
- RISC-V GCC 工具链（`riscv32-unknown-elf-gcc`）
- Python 3.8+（含 PyYAML）
- Spike ISS（用于 cosim，已编译为 `build/libcosim.so`）

## 目录结构

```
dv/uvm/core_eh2/
├── tb/                       # 顶层 testbench（DUT 实例化 + 时钟复位 + AXI mem）
├── env/                      # UVM env：env、cfg、scoreboard、vseqr、接口定义
├── common/                   # 各 UVM agent
│   ├── axi4_agent/          # AXI4 监视器（passive，4 端口：IFU/LSU/SB/DMA）
│   ├── irq_agent/           # 中断激励（active）
│   ├── jtag_agent/          # JTAG 调试（active）
│   ├── halt_run_agent/      # MPC halt/run（active）
│   ├── trace_agent/         # trace 监视器（passive，从 RTL trace_pkt 取 retired 指令）
│   └── rvvi_agent/          # RVVI adapter + RVVI-API lockstep scoreboard
├── tests/                    # base test、test_lib、seq_lib、vseq
├── fcov/                     # 功能覆盖率（fcov_if、fcov_bind、pmp_fcov_if）
├── riscv_dv_extension/       # riscv-dv 扩展（asm_program_gen、testlist.yaml）
├── scripts/                  # Python 脚本（run_regress、collect_results、signoff）
├── yaml/                     # rtl_simulation.yaml（VCS/Xcelium/Questa 配置）
├── directed_tests/           # 定向测试（ASM + testlist）
│   ├── directed_testlist.yaml  # 13 个 directed test
│   └── cosim_testlist.yaml     # 5 个 cosim proof test
├── waivers/                  # 覆盖率 refinement
└── Makefile                  # 本地 make 入口
```

## 如何跑回归

### Profile 说明

| Profile | 包含 Stage | 用途 |
|---------|-----------|------|
| quick | smoke + directed | 快速验证，<2 min |
| cosim | smoke + cosim | cosim 专项 |
| nightly | smoke + directed + cosim + riscvdv | 夜间回归 |
| full | smoke + directed + cosim + riscvdv | 发布签发 |

### 回归命令

```bash
# 快速回归（smoke + directed）
make signoff SIGNOFF_PROFILE=quick PARALLEL=4

# cosim 专项
make signoff SIGNOFF_PROFILE=cosim PARALLEL=4

# 完整回归
make signoff SIGNOFF_PROFILE=full PARALLEL=4

# 指定 seed 和 iterations
make signoff SIGNOFF_PROFILE=full PARALLEL=4 SIGNOFF_ITERATIONS=3
```

### 单个测试

```bash
# 跑单个 riscv-dv 测试
make run TEST=riscv_arithmetic_basic_test SEED=12345

# 跑定向测试
make run TEST=directed_smoke

# 跑 cosim proof 测试
make run TEST=cosim_alu
```

## 如何跑 Sign-off

Sign-off Gate 是发布签发的最终关卡，4 个 stage 全 PASS 方可签发：

```bash
# 标准签发（推荐）
make signoff SIGNOFF_PROFILE=full PARALLEL=4 SIGNOFF_ITERATIONS=1

# 带覆盖率采集
make signoff SIGNOFF_PROFILE=full PARALLEL=4 COV=1

# 指定输出目录
make signoff SIGNOFF_PROFILE=full PARALLEL=4 SIGNOFF_OUT=build/sf_release
```

**Sign-off 报告**位于输出目录的 `signoff_report.md`，包含各 stage 通过率、覆盖率数据和 cosim 例外列表。

## 如何加新测试

### 添加 riscv-dv 随机测试

编辑 `riscv_dv_extension/testlist.yaml`，追加条目：

```yaml
- test: riscv_my_new_test
  description: My new test description
  gen_test: riscv_rand_instr_test
  gen_opts: '+instr_cnt=10000 +boot_mode=m'
  rtl_test: core_eh2_base_test
  iterations: 5
```

### 添加 directed 测试

1. 在 `tests/asm/` 下创建 `.S` 汇编文件（参考 `cosim_smoke.S` 模板）
2. 在 `directed_tests/directed_testlist.yaml` 追加条目：

```yaml
- test: directed_my_test
  desc: "My directed test description"
  config: eh2_directed
  test_srcs: tests/asm/directed_my_test.S
  iterations: 1
```

3. 运行验证：`make run TEST=directed_my_test`

### 添加 cosim proof 测试

1. 在 `tests/asm/` 下创建 `.S` 汇编文件
2. 在 `directed_tests/cosim_testlist.yaml` 追加条目（使用 `eh2_cosim` config）
3. 运行验证：`make run TEST=cosim_my_proof`

### 添加功能覆盖率

编辑 `fcov/eh2_fcov_if.sv` 或 `fcov/eh2_pmp_fcov_if.sv`，添加 covergroup 或 coverpoint。

## 架构参考

- [CONTEXT.md](../../../CONTEXT.md)：领域语境与术语定义
- [docs/adr/](../../../docs/adr/)：架构决策记录（ADR-0001 ~ ADR-0008）
- [docs/cosim-correctness-analysis.md](../../../docs/cosim-correctness-analysis.md)：cosim 数据通路与风险分析
- [docs/release-notes-v1.0.md](../../../docs/release-notes-v1.0.md)：v1.0 Release Notes
