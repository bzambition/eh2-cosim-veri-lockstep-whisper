# eh2-cosim-veri

eh2-cosim-veri-lockstep-whisper 是面向 EH2（RISC-V Cores-VeeR-EH2）的 cosim-only 验证平台变体。它做的是完整的功能仿真（dynamic-functional）验证：DUT 经 `eh2_rvvi_adapter.sv` 采集成标准 RVVI-TRACE，再进入 cosim-arch-checker（CAC）与 VeeR-ISS（Whisper）在线 lockstep 比较。Spike/offline tracecmp 路径已删除；当前 Phase 3 正在把 CAC 收敛成标准 RVVI-API checker。

`make signoff PROFILE=full LOCKSTEP_WHISPER=1` 的一次 PASS 表示：在已运行的 seed 和测试集上，在线 lockstep 用例与 Whisper 架构态一致，允许的 `skip_in_signoff` 项按既有 tracked-broken 处理，compliance signature 合规。它不表示 formal property、LEC、综合、STA、power、physical、gate-level sim、CDC/RDC、security/side-channel、PPA 或性能验证已经完成，这些不在本平台范围。

## 当前边界

- `riscvdv` 全量 closure 以 lockstep-Whisper 路径为准；`riscv_csr_test` / `riscv_csr_hazard_test` 是 v2.0 既有 tracked-broken 项，保持 `skip_in_signoff`。
- `riscv_csr_test` 和 `riscv_csr_hazard_test` 是已知 `skip_in_signoff` tracked-broken 项，未计入 signoff。
- 覆盖率会收集，但 full profile 当前只 gate line 和 functional。P4.6 实测值：assert 33%、fsm 54%、toggle 53%、line 91%、branch 83%、functional 69%、overall 64%。报告会逐项标明 gated 或 collected but ungated。
- 参考模型信任假设：Whisper/VeeR-ISS 是 EH2 原生 ISS；本仓 vendor 的 reset 修复见 `vendor/whisper-patches/0001-mrac-pma-postreset.patch`。

## 文档

- 设计与使用文档：[docs/index.html](docs/index.html)
- 新核接入 recipe：[docs/onboarding.md](docs/onboarding.md)

## 最快三行上手

```bash
cp env.mk.example env.mk
make whisper
make cac
make smoke LOCKSTEP_WHISPER=1
```

`env.mk` 只放本机路径，例如支持 C++17 的 `WHISPER_CXX`、`WHISPER_BOOST_ROOT`、`NC_INSTALL`，以及可选的 `VCS_HOME`、`RISCV_PREFIX`。

## 常用命令

```bash
make regress LOCKSTEP_WHISPER=1 TESTLIST=cosim
make smoke LOCKSTEP_WHISPER=1 CONFIG=dual_thread SIM_OPTS="+rvvi_nhart=2"
make signoff LOCKSTEP_WHISPER=1 PROFILE=full
python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q
```

`CONFIG=dual_thread` 对应 NHART=2 的双 hart SMT 配置。
