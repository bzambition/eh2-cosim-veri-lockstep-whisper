# Changelog

## v3.0-lockstep-whisper

### 架构

- 将 cosim oracle 收敛为 RVVI-API + Whisper 在线 lockstep。
- DUT 侧通过 `eh2_rvvi_adapter.sv` 输出官方 `rvviTrace`。
- 通用 `rvvi_scoreboard.sv` 只调用 `rvviApiPkg`，比较逻辑迁入 C++ checker。
- `vendor/cosim-arch-checker` 实现官方 `rvviApi.h` 的 DUT staging、ref step、PC/GPR/CSR/memory compare 和 metric/error API。
- `whisper_rvvi.cpp` 通过 socket 驱动 Whisper / VeeR-ISS 作为参考模型。

### 删除

- 删除 Spike 参考路径。
- 删除离线 trace compare / trace CSV 路径。
- 删除旧 `rvvi_cac_bridge.sv` 和 SV-facing `monitor_*` 接口。

### 验证

- RVVI-API lockstep smoke、directed、cosim、riscv-dv 和 compliance 全量 signoff 通过。
- Phase 4 终签证据：`build/signoff_p44_masked_clean/signoff_status.json`。
- Stage 结果：smoke 1/1、directed 40/40、cosim 7/7、riscvdv 395/395、compliance 50/50，waivers 均为 `[]`。
- Coverage：line 91.19%、functional 69.40%，均通过 gate；overall 64.03% 为 collected but ungated。
- 端到端牙齿已验证：临时 GPR 分歧能让真实 sim 从 PASS 变 FAIL，回退后恢复 PASS。

### 已知边界

- Debug 主动注入保持 opt-in downgrade。`+rvvi_debug_poke` 能发送 Whisper `EnterDebug`，但 halt/resume 包边界未 closure；默认路径不声称 debug 主动注入 closure。
- `mip(0x344)` 为 MEIP-only mask：bit 11 之外的 pending 位参与比较。
- `riscv_csr_test` 和 `riscv_csr_hazard_test` 保持既有 `skip_in_signoff`。

### 文档

- 新增 `docs/onboarding.md`，给出接入新核的 RVVI-TRACE recipe。
- 新增 `docs/architecture.md`，说明数据流、RVVI-API 映射、工具链 ABI 切分和签核边界。
