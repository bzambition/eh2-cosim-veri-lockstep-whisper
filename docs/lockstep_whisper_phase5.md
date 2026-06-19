# LOCKSTEP-WHISPER Phase 5 收尾报告

## 结论

Phase 5 完成发布前文档收口：

- 结构核查确认 `vendor/cosim-arch-checker`、`rvvi_scoreboard.sv` 和 `vendor/rvvi` 没有 EH2/核名泄漏。
- `docs/onboarding.md` 已改写为通用 RVVI checker 接入新核 recipe。
- `README.md` 和 `docs/index.html` 已最终化为“瘦 UVM + 通用外部 RVVI checker + Whisper”方法学。
- 文档保留 Phase 4 的真实边界：debug 主动注入 downgrade，`mip(0x344)` MEIP-only mask，coverage 只有 line/functional gated。
- 本期不做仿真功能改动，不改 RTL，不 push，不并 master。

## P5.0 基线

起点提交：

```text
73e10f5 test(lockstep): Phase 4 牙齿与 debug/mip 分级收口 (P4)
b7c4f34 docs(lockstep): Phase 3 收尾报告与复现入口 (P3.7)
d30b1ed fix(signoff): 干净 COV=1 signoff 与 mailbox/LD 收口 (P3.6)
```

脚本单测：

```bash
python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q
```

结果：`154 passed, 1 skipped, 1 warning`。

## P5.1 通用性核查

结构核查命令：

```bash
grep -rniE 'eh2|veer|riscv_core_setting|core_eh2' \
  vendor/cosim-arch-checker/ \
  dv/uvm/core_eh2/common/rvvi_agent/rvvi_scoreboard.sv \
  vendor/rvvi/ --include=*.cpp --include=*.h --include=*.sv | grep -viE 'test|//|license'
```

结果：空。通用 checker、scoreboard 和 RVVI API 层没有 EH2 知识。

核专属边界：

- `dv/uvm/core_eh2/common/rvvi_agent/eh2_rvvi_adapter.sv`
- `rtl/snapshots/default/whisper.json`
- `rtl/snapshots/default_mt/whisper.json`
- `config/cac_csr_masks.txt`

零改复用层：

- `dv/uvm/core_eh2/common/rvvi_agent/rvvi_scoreboard.sv`
- `vendor/cosim-arch-checker/bridge/whisper/whisper_rvvi.cpp`
- `vendor/rvvi/include/host/rvvi/rvviApi.h`
- `vendor/rvvi/source/host/rvvi/rvviApiPkg.sv`

`docs/onboarding.md` 已写入接入新核的 3 件专属件：RVVI-TRACE adapter、ISS 配置或 RVVI ref 后端、CSR mask；并明确比较在 CAC(C++) 外部完成。

## P5.2 文档最终化

`README.md` 与 `docs/index.html` 已更新为当前事实：

- 方法学：瘦 UVM（每核唯一 RVVI-TRACE adapter）+ 通用外部 RVVI checker（CAC 实现 `rvviApi.h`）+ Whisper 在线参考模型。
- Spike/offline tracecmp 路径已删，仅在历史说明中出现。
- Phase 4 full signoff 证据：`build/signoff_p44_masked_clean/signoff_status.json`。
- Stage：smoke 1/1、directed 40/40、cosim 7/7、riscvdv 395/395、compliance 50/50，waivers 均为 `[]`。
- Coverage：line `91.19%`、functional `69.40%` gated PASS；assert/branch/fsm/toggle/overall collected but ungated。
- Debug 主动注入：opt-in downgrade，不称 closure。
- `mip(0x344)`：MEIP-only mask，其余 pending 位参与比较。
- 范围之外：formal、LEC、综合、STA、power、physical、gate-level sim、CDC/RDC、security/side-channel、PPA、性能签核。

文档残留核查：

```bash
grep -rniE 'spike|tracecmp|offline|trace_compare' README.md docs/onboarding.md docs/index.html | grep -viE '历史|已删|Phase 3'
```

预期：无虚假或死引用。

## P5.3 发布收口

本地 tag：

```bash
git tag -a v3.0-lockstep-whisper -m "RVVI-API lockstep + Whisper, thin UVM general checker"
```

Push 和合并保持 user-gated，未执行。待用户授权后可执行：

```bash
git push origin lockstep-whisper
git push origin v3.0-lockstep-whisper
```

是否并入 `master` 需要用户另行明确。

## 反作弊

Phase 5 终检项：

- `git diff --name-only 72c50d6..HEAD | grep '^rtl/' | grep -v snapshots` 为空。
- `find . -path ./.git -prune -o -type l -print` 为空。
- tracked 源绝对路径 grep 为空。
- `python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q` 通过。
- 本期只改文档和本地 tag，不改仿真行为。
