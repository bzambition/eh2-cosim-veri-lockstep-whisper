# eh2-cosim-veri

eh2-cosim-veri 是面向 EH2（RISC-V Cores-VeeR-EH2）的 cosim-only 验证平台，协同仿真走标准 RVVI-API（官方 `riscv-verification/RVVI`）在线 lockstep，而不是原 eh2-veri 的自定义比对层。

## 架构

`EH2 RTL -> rvvi_adapter.sv（双发射 i0/i1->order、双 hart SMT、异步写回映射到标准 rvviTrace）-> DPI(rvviApi.h) -> rvvi_scoreboard.sv（RVVI-API 在线 lockstep + 自定义 CSR 豁免窗）-> spike_rvvi.cc（Spike 包成 RVVI-API 参考模型）`

## 能力

- 单 hart 和双 hart（SMT，`NHART=2`）核内 lockstep。
- UVM、riscv-dv 随机激励、riscv_compliance、覆盖率和 sign-off。
- Spike 源码、riscv-dv、RVVI、riscv-tests 已 vendored，`make spike` 在库内构建 Spike。

## 机器前提

- Synopsys VCS 或 Cadence Incisive（`irun`）。
- 支持 C++17 的 `g++`，系统 `g++ 4.8.5` 不满足要求。
- `riscv32-unknown-elf-*` 工具链。

机器相关路径写入本地 `env.mk`，不要提交。

## 上手

```bash
cp env.mk.example env.mk
# 按本机环境填写 SPIKE_DIR、SPIKE_CXX、NC_INSTALL、GCC_PREFIX 等
make spike
make smoke SIM_OPTS="+use_rvvi_cosim=1"
```

## 常用命令

```bash
make smoke
make signoff
make regress TESTLIST=cosim SIM_OPTS="+use_rvvi_cosim=1"
make regress TESTLIST=cosim CONFIG=dual_thread SIM_OPTS="+use_rvvi_cosim=1 +rvvi_nhart=2"
make watch_wave TEST=smoke
```

## 目录

- `rtl/`：EH2 DUT。
- `shared/`：AXI4 等共享 RTL。
- `dv/cosim/`：Spike DPI 和 `spike_rvvi.cc`。
- `dv/uvm/core_eh2/`：UVM testbench、RVVI agent 和 scoreboard。
- `dv/uvm/riscv_compliance/`：riscv_compliance 集成。
- `tests/asm/`：directed/smoke 汇编测试。
- `vendor/`：`spike`、`google_riscv-dv`、`rvvi`、`riscv-tests`。

## 文档

其余设计说明和移植细节后续补充。
