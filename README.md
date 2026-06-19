# eh2-cosim-veri-lockstep-whisper

`eh2-cosim-veri-lockstep-whisper` 是面向 VeeR-EH2 的 cosim-only 动态功能仿真平台变体。当前方法学是：

```text
EH2 RTL
  -> eh2_rvvi_adapter.sv
  -> official rvviTrace
  -> generic rvvi_scoreboard.sv
  -> cosim-arch-checker implementing official rvviApi.h
  -> Whisper / VeeR-ISS reference model
```

UVM 侧保持很薄：每核唯一专属 UVM 件是 RVVI-TRACE adapter。比较逻辑在外部 C++ checker 中完成，checker 通过官方 `rvviApi.h` 消费 DUT 退休事件并驱动 Whisper 在线 lockstep。Spike 和离线 tracecmp 路径已在 Phase 3 删除。

## 当前签核状态

Phase 6 发布门最终证据位于：

- `build/signoff_p63_release/signoff_status.json`
- `build/signoff_p63_release/signoff_report.md`
- `build/signoff_p63_release/report.html`

`make signoff PROFILE=full LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=1` 自然返回 `make exit=0`：

| Stage | Status | Total | Passed | Failed | Waivers |
|---|---:|---:|---:|---:|---|
| smoke | PASS | 1 | 1 | 0 | `[]` |
| directed | PASS | 40 | 40 | 0 | `[]` |
| cosim | PASS | 7 | 7 | 0 | `[]` |
| riscvdv | PASS | 395 | 395 | 0 | `[]` |
| compliance | PASS | 50 | 50 | 0 | `[]` |

Coverage：line `91.19%`（gated，threshold `55.00%`），functional `69.40%`（gated，threshold `40.00%`），overall `64.03%`。assert、branch、fsm、toggle、overall 是 collected but ungated。

## 边界与状态

- `riscv_csr_test` 和 `riscv_csr_hazard_test` 是既有 tracked-broken 项，保持 `skip_in_signoff`，不计入 full signoff。
- Debug request 主动注入保持 opt-in downgrade：`+rvvi_debug_poke` 能触发 Whisper `EnterDebug`，但代表用例仍未 closure；默认路径采用在线 lockstep 比较兜底，不能声称 debug 主动注入 closure。
- `mip(0x344)` mask 已从全 mask 收窄为 MEIP-only mask：除 MEIP bit 11 外的 pending 位参与比较。
- 参考模型信任假设：Whisper / VeeR-ISS 是 EH2 原生 ISS；本仓 vendored Whisper 含 MRAC/PMA post-reset 修复，审阅补丁见 `vendor/whisper-patches/0001-mrac-pma-postreset.patch`。
- formal property、LEC、综合、STA、power、physical、gate-level sim、CDC/RDC、security/side-channel、PPA 或性能签核不在本平台范围。
- 历史离线路径曾记录 `23/57` 个 riscv-dv async/debug/interrupt 组使用 `tracecmp: disabled`；该 Spike/offline tracecmp split 已在 Phase 3 删除，不是当前 oracle。

## 文档

- 平台文档：`docs/index.html`
- 新核接入 recipe：`docs/onboarding.md`
- Phase 3 架构与 signoff：`docs/lockstep_whisper_phase3.md`
- Phase 4 牙齿、debug/mip 收口：`docs/lockstep_whisper_phase4.md`
- Phase 5 发布收口：`docs/lockstep_whisper_phase5.md`

## 最快三行上手

```bash
cp env.mk.example env.mk
make whisper
make cac
make smoke LOCKSTEP_WHISPER=1
```

`env.mk` 只放本机路径，例如支持 C++17 的 `WHISPER_CXX`、`WHISPER_BOOST_ROOT`、`CAC_CXX`、`VCS_HOME` 或 `NC_INSTALL`、`RISCV_PREFIX`。

## 常用命令

```bash
make regress LOCKSTEP_WHISPER=1 TESTLIST=cosim
make smoke LOCKSTEP_WHISPER=1 CONFIG=dual_thread SIM_OPTS="+rvvi_nhart=2"
make signoff LOCKSTEP_WHISPER=1 PROFILE=full SIMULATOR=vcs COV=1
python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q
```

`CONFIG=dual_thread` 对应 `NHART=2` 的双 hart SMT 配置。

未经用户明确授权，不 push、不并 master。
