# 新核接入指南

本文说明如何把这个功能仿真框架接到一个新 RISC-V 核。EH2 是当前已接入的第一个对象。
权威平台说明见 `docs/index.html`；本文与其中的「新核接入」章节保持同一边界。

## 边界原则

换核时只改三处核专属层：

1. RVVI 适配器：把新核的 retire、写回、CSR、trap、store 和 hart/order 信号映射到标准 RVVI-TRACE。
2. 参考模型：基于 Spike 建模该核的自定义 CSR、PMP/ePMP、trap、内存映射和架构扩展行为。
3. 核配置：ISA、hart 数、reset PC、memory map、riscv-dv core setting、testlist 和 signoff profile。

这些部分保持核无关：

- vendored RVVI-TRACE 接口。
- RVVI-TRACE dump 到 CSV 的转换器。
- trace comparator：逐 retire 比 PC、GPR、CSR 和内存事件。
- riscv-dv 生成与 UVM 回归脚本。
- signoff 汇总、覆盖率收集和报告框架。
- compliance signature 流。

## 最小步骤

1. 建立核配置目录和 Makefile 变量，确定 ISA、XLEN、hart 数、reset PC、内存窗口和工具链参数。
2. 写 RVVI 适配器，把核内部 retire 信息转换成 `rvviTrace`。先只支持单 hart、单 retire，再扩展多发射或多 hart。
3. 写参考模型扩展。Spike 原生支持的 ISA 不要重复建模；只补该核 PRM 规定的自定义 CSR、PMP/ePMP、trap、memory map 和非标准 reset 状态。
4. 接入 standalone ref CSV 生成器，确保它能按 DUT hart schedule 逐步运行参考模型。
5. 跑最小 smoke：DUT RVVI-TRACE CSV 与 ref CSV 的 PC/insn 流一致。
6. 打开 GPR、CSR、内存事件比较，逐类增加 directed 测试。
7. 接 riscv-dv。普通同步测试默认走 tracecmp；异步 interrupt/debug/reset 类测试只有在有 UVM agent/signature handshake 证据时才允许 `tracecmp: disabled`。
8. 接 compliance signature。
9. 跑 full signoff，并在文档中记录 tracecmp/agent split、覆盖率 gate、已知 skip 项和参考模型信任假设。

## signoff 口径

新核接入后，文档必须把三类结论分开写：

- 已验证：stage 数字、coverage 数字、pytest 或脚本单测数字，以及证据目录。
- 未验证：`tracecmp: disabled` 的测试数量、替代 checker、`skip_in_signoff` 项和低覆盖项。
- 范围之外：formal、LEC、综合、STA、power、physical、gate-level sim、CDC/RDC、security/side-channel、PPA 和性能。

`riscvdv` stage 绿不自动等于所有 riscv-dv 测试都做了逐 retire tracecmp。若有 async/debug/interrupt 测试关闭 tracecmp，
必须在 testlist 和文档中写清替代 checker，例如 UVM agent 或 signature handshake。

## EH2 已填范例

| 层 | EH2 实现 | 说明 |
|---|---|---|
| RVVI 适配器 | `dv/uvm/core_eh2/common/rvvi_agent/eh2_rvvi_adapter.sv` | 处理双发射 i0/i1、NHART=1/2、异步 load/div 写回、CSR 和 store sideband。 |
| 参考模型 | `dv/cosim/spike_cosim.cc` / `.h` | 建模 EH2 自定义 CSR、PMP/ePMP、trap、DCCM、mailbox、低地址取指空洞、原子和异步写回行为。 |
| standalone ref | `dv/cosim/spike_rvvi_main.cc` | 直接调用 `SpikeCosim` ref-only helper，生成 riscv-dv 风格 CSV。 |
| 核配置 | `dv/uvm/core_eh2/riscv_dv_extension/riscv_core_setting.sv`、`testlist.yaml`、Makefile `CONFIG` | 配置 RV32、EH2 memory map、single/dual thread 和 signoff stage。 |

EH2 当前 full profile 的真实口径：

- `make signoff PROFILE=full`：PASS。
- `riscvdv`：395/395 PASS。
- 23/57 个 riscv-dv 测试是 `tracecmp: disabled`，由 UVM agent 或 signature handshake 验证。
- `riscv_csr_test` 和 `riscv_csr_hazard_test` 是 `skip_in_signoff` tracked-broken，未解决且未计入 signoff。
- coverage 只 gate line 和 functional；assert、branch、fsm、toggle、overall 当前是 collected but ungated。

## 接入检查清单

- RVVI-TRACE dump 中每条 retire 都有稳定的 hart、order、PC 和 instruction。
- GPR 写回只报告架构上真正提交的写；被 trap/fault 抑制的写不能进入 CSV。
- CSR 列表区分可比较、非确定、WPRI/WARL 和核自定义项；mask 必须有注释依据。
- Store 事件只报告已提交的架构内存写；bus error、misaligned split 和 atomic 写要按架构结果处理。
- 多 hart 时 ref CSV 按 DUT hart schedule 步进，不能假设 round-robin。
- 异步测试若关闭 tracecmp，testlist 必须写明替代 checker。
- signoff report 必须显示覆盖率数值以及 gated/collected but ungated 状态。

## 不要改的层

新核接入时，不要把核名、CSR 号或 memory map 硬编码进 trace comparator、RVVI-TRACE 转换器、signoff 聚合器或通用回归框架。发现确实需要核信息时，应把它放进核配置或参考模型，由通用层读取配置结果。
