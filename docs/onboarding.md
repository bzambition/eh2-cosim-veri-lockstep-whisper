# 新核接入指南

本文给出把一个新 RISC-V 核接到本通用 RVVI checker 的最小 recipe。EH2 是当前仓库中已经接入并完成 signoff 的实例；实际第二核 bring-up 不在本 EH2 仓范围内，新核应在自己的仓库中复用 `vendor/cosim-arch-checker`、`vendor/rvvi` 和同一套 RVVI-API contract。

## 方法学边界

本平台的复用边界是标准 RVVI-TRACE：

```text
Core RTL
  -> <core>_rvvi_adapter.sv
  -> official rvviTrace
  -> generic rvvi_scoreboard.sv
  -> cosim-arch-checker / rvviApi.h
  -> reference ISS backend
```

SV scoreboard 只是通用驱动壳：它从 `rvviTrace` 取 retire、GPR、CSR、memory 和 net 事件，调用官方 `rvviApiPkg`。真正的 PC、instruction、GPR、CSR 和 memory 比较在 cosim-arch-checker(C++) 中完成。不要把核名、CSR 语义、memory map 或 debug/irq 策略写进 checker 或 scoreboard。

## 每核只提供三类专属件

1. **RVVI 适配器 / RVVI-TRACE adapter**

   提供 `<core>_rvvi_adapter.sv`，把新核 retire/RVFI/probe 信号映射成标准 `rvviTrace`。这是唯一每核专属 UVM 件。EH2 范本是 `dv/uvm/core_eh2/common/rvvi_agent/eh2_rvvi_adapter.sv`。

2. **参考模型 / 参考 ISS 配置或后端**

   对 Whisper/VeeR-ISS 这类原生 ISS，提供该核的 `whisper.json` 或等价配置，描述 ISA、reset PC、hart、memory map 和实现相关行为。若新核不使用 Whisper，应提供实现官方 `rvviApi.h` ref 侧契约的后端。

3. **核配置与非确定 CSR mask**

   提供 ISA、XLEN、hart 数、reset PC、memory map、testlist、signoff profile 和 `cac_csr_masks.txt`。CSR mask 只 mask 真实非确定或异步采样位，每个 mask 必须有注释依据。EH2 当前 `mip(0x344)` 只屏蔽 MEIP bit 11，其余 pending 位参与比较。

## 零改复用层

以下组件应零改复用：

- `dv/uvm/core_eh2/common/rvvi_agent/rvvi_scoreboard.sv`：通用 RVVI-API scoreboard。
- `vendor/cosim-arch-checker`：实现官方 `rvviApi.h` 的外部 checker。
- `vendor/cosim-arch-checker/bridge/whisper/whisper_rvvi.cpp`：Whisper ref 后端。
- `vendor/rvvi/include/host/rvvi/rvviApi.h` 和 `vendor/rvvi/source/host/rvvi/rvviApiPkg.sv`：官方 RVVI-API。
- `vendor/whisper`：当前 EH2 参考 ISS 源码。
- 回归、signoff、coverage 汇总脚本。

这些层必须保持核无关；新核信息只能通过 adapter、ISS 配置、核配置或 CSR mask 进入系统。

Phase 5 结构核查命令：

```bash
grep -rniE 'eh2|veer|riscv_core_setting|core_eh2' \
  vendor/cosim-arch-checker/ \
  dv/uvm/core_eh2/common/rvvi_agent/rvvi_scoreboard.sv \
  vendor/rvvi/ --include=*.cpp --include=*.h --include=*.sv | grep -viE 'test|//|license'
```

预期为空。空结果表示通用 checker、scoreboard 和 RVVI API 层没有 EH2 知识。

## 最小接入步骤

1. 固定新核的 ISA、XLEN、hart 数、reset PC、memory map、工具链和仿真入口。
2. 编写 `<core>_rvvi_adapter.sv`，先支持单 hart、单 retire；确认每条 retire 都有稳定 hart、order、PC、instruction 和 trap 信息。
3. 接入 ISS 配置或后端，确认 `rvviRefInit`、`rvviRefEventStep`、`rvviRefPcGet`、`rvviRefGprGet`、`rvviRefCsrGet` 和 `rvviRefMemoryRead` 能返回参考态。
4. 跑最小 smoke：DUT retire 流与 ref step 流在 PC/instruction 上一致。
5. 打开 GPR、CSR、memory 比较；每一类先用 directed 测试收敛，再扩大到随机。
6. 编写 `cac_csr_masks.txt`，只保留有架构或时序依据的 mask。
7. 接 riscv-dv 和 directed testlist。异步 debug/irq/reset 刺激属于每核 UVM/测试范畴，不应迁入通用 checker。
8. 跑 full signoff，并在报告中明确 stage 数字、coverage gate、skip 项、debug 状态和 ref-model 信任假设。

## EH2 已填范例

| 类别 | EH2 文件 | 说明 |
|---|---|---|
| RVVI adapter | `dv/uvm/core_eh2/common/rvvi_agent/eh2_rvvi_adapter.sv` | 处理双发射、hart/order、异步写回、CSR、trap、store sideband。 |
| ISS 配置 | `rtl/snapshots/default/whisper.json`、`rtl/snapshots/default_mt/whisper.json` | 单 hart 与双 hart Whisper 配置。 |
| CSR mask | `config/cac_csr_masks.txt` | 记录 counter、非确定 CSR 和 `mip` MEIP-only mask。 |
| 通用 scoreboard | `dv/uvm/core_eh2/common/rvvi_agent/rvvi_scoreboard.sv` | 零 EH2 硬编码，调用 `rvviApiPkg`。 |
| 通用 checker | `vendor/cosim-arch-checker` | C++ RVVI-API checker，外接 Whisper。 |

## 接入检查清单

- `rvviTrace` 中每条 retire 的 hart/order/PC/instruction 稳定且单调语义清楚。
- GPR 写回只报告架构上真正提交的写；trap/fault 抑制的写不能进入比较。
- CSR 写区分可比、WARL/WPRI、核自定义和非确定项；mask 必须有注释依据。
- Store 事件只报告已提交架构内存写；byte-enable、misaligned split 和 atomic 写要按架构结果处理。
- 多 hart 时 ref 按 DUT retire schedule 步进，不假设 round-robin。
- Debug/irq/reset 等异步刺激在每核 UVM/test 层建模；checker 只比较同步后的架构态和经 `rvviRefNetSet` 注入的标准 net。
- signoff report 必须区分 gated coverage 与 collected-but-ungated coverage。

## 不要改的层

新核接入时，不要把核名、CSR 号、memory map、debug ROM 或 interrupt controller 语义硬编码进 `rvvi_scoreboard.sv` 或 `vendor/cosim-arch-checker`。发现确实需要核信息时，把它放进 adapter、ISS 配置或 CSR mask，由通用层通过标准 RVVI-API 消费结果。
