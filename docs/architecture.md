# Lockstep Whisper 架构说明

本文面向第一次阅读本仓库的开发者，说明 RVVI-API lockstep 路的分层、数据流、复用边界和已知限制。

## 数据流

当前在线协同验证路径如下：

```text
EH2 RTL
  -> eh2_rvvi_adapter.sv
  -> official rvviTrace
  -> rvvi_scoreboard.sv
  -> cosim-arch-checker implementing rvviApi.h
  -> whisper_rvvi.cpp
  -> Whisper / VeeR-ISS server
```

`eh2_rvvi_adapter.sv` 是 EH2 专属件，负责把 RTL retire、异步写回、CSR、trap、interrupt、debug 和 store sideband 映射到标准 `rvviTrace`。`rvvi_scoreboard.sv` 是通用 SystemVerilog 驱动壳，只消费 `rvviTrace` 并调用官方 `rvviApiPkg`。比较策略、mask、错误文案和 reference state 都在 C++ 侧的 cosim-arch-checker 中维护。

Whisper 作为独立 server 运行。`whisper_rvvi.cpp` 实现 `rvviApi.h` ref 侧和 DUT staging 入口，通过 socket client 驱动 Whisper step、peek、poke、EnterDebug 和 ExitDebug。

## RVVI-API 映射

Scoreboard 每条 retire 的调用顺序固定为：

1. 异步 net：interrupt pending 通过 `rvviRefNetGroupSet` 和 `rvviRefNetSet` 同步到 ref。
2. retire / trap：普通 retire 调 `rvviDutRetire`，trap 调 `rvviDutTrap`。
3. GPR：`rvviDutGprSet` stage 本条 retire 写回的 GPR。
4. CSR：`rvviDutCsrSet` stage 本条 retire 可见的 CSR。
5. memory：store / AMO 通过 `rvviDutBusWrite` stage 已提交写。
6. ref step：`rvviRefEventStep` 驱动 Whisper 退休一条参考指令，并拉取 PC、instruction、GPR、CSR 和 memory change。
7. compare：`rvviRefPcCompare`、`rvviRefInsBinCompare`、`rvviRefGprsCompareWritten`、`rvviRefCsrsCompare` 依次比较。

比较失败时，C++ 侧通过 `rvviErrorGet` 返回具体 mismatch；SV 侧只 `$error` 和 `$finish`，不承载核相关比较逻辑。

## 复用边界

本平台的复用边界是标准 RVVI-TRACE。

每个新核只应提供 3 类专属件：

- `<core>_rvvi_adapter.sv`：把该核的 retire/RVFI/probe 信号映射到 `rvviTrace`。
- 参考 ISS 配置或后端：例如 Whisper `whisper.json`，或另一个实现 `rvviApi.h` ref 侧契约的后端。
- 核配置与 CSR mask：ISA、XLEN、hart 数、reset PC、memory map、testlist、`cac_csr_masks.txt`。

以下层应零改复用：

- `rvvi_scoreboard.sv`
- `vendor/cosim-arch-checker`
- `vendor/cosim-arch-checker/bridge/whisper/whisper_rvvi.cpp`
- `vendor/rvvi/include/host/rvvi/rvviApi.h`
- `vendor/rvvi/source/host/rvvi/rvviApiPkg.sv`

接入步骤详见 [onboarding.md](onboarding.md)。

## 工具链与 ABI 切分

VCS DPI 侧使用仿真器兼容的 C++17 编译器构建 `libcosim.so`，由 `CAC_CXX` 指定。Whisper server 使用 devtoolset-9 和 Boost 1.75 构建，路径来自 `env.mk` 中的 `WHISPER_CXX`、`WHISPER_BOOST_ROOT`、`WHISPER_PATH` 和 `WHISPER_LD_LIBRARY_PATH`。

两侧通过 socket command protocol 通信。这个进程边界避免把 Whisper 的较新 C++ runtime ABI 直接加载进 VCS 进程。

## Reference Model 信任假设

Whisper / VeeR-ISS 是 EH2 的原生 ISS。当前 vendored Whisper 包含 MRAC/PMA post-reset 修复，补丁记录在 `vendor/whisper-patches/0001-mrac-pma-postreset.patch`。本平台验证的是 RTL 与该参考模型在当前配置下的在线 lockstep 一致性，不替代对 Whisper 自身的独立形式化证明。

## 已知边界

- Debug 主动注入保持 downgrade：`+rvvi_debug_poke` 能触发 Whisper `EnterDebug`，但 halt/resume 包边界仍未 closure；默认路径采用在线 lockstep 比较兜底，不声称 debug 主动注入 closure。
- `mip(0x344)` 使用 MEIP-only mask：除 bit 11 外的 pending 位参与比较，MEIP 因外部中断采样 / 清除相对 retire 异步而保留 mask。
- Coverage gate 只包括 line 和 functional coverage；assert、branch、FSM、toggle、overall 为 collected but ungated。
- `riscv_csr_test` 和 `riscv_csr_hazard_test` 是既有 tracked-broken 项，保持 `skip_in_signoff`。

## 范围之外

formal property、LEC、综合、STA、power、physical、gate-level sim、CDC/RDC、security/side-channel、PPA、性能签核和第二核 bring-up 不在本仓库当前签核范围内。
