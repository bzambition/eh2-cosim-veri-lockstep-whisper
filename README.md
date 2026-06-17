# eh2-cosim-veri

eh2-cosim-veri 是面向 EH2（RISC-V Cores-VeeR-EH2）的 cosim-only 验证平台。它做的是完整的功能仿真（dynamic-functional）验证：DUT 经 `rvvi_adapter.sv` 采集成标准 RVVI-TRACE，离线 `tracecmp` 将 PC、GPR、CSR 和内存事件与 `spike_cosim.cc` 驱动的 EH2-Spike 参考模型逐 retire 对齐比较；异步 interrupt/debug/reset/single-step 类测试由 UVM agent 和 signature handshake 检查；compliance 使用官方 signature 流。

`make signoff PROFILE=full` 的一次 PASS 表示：在已运行的 seed 和测试集上，走 tracecmp 的用例与 EH2-Spike 架构态一致，异步组通过 UVM/signature 检查，compliance signature 合规。它不表示 formal property、LEC、综合、STA、power、physical、gate-level sim、CDC/RDC、security/side-channel、PPA 或性能验证已经完成，这些不在本平台范围。

## 当前边界

- `riscvdv` 395/395 绿的组成是：约 34/57 个测试走完整离线 tracecmp；23/57 个 async/debug/interrupt/reset/single_step/dret 组测试标记 `tracecmp: disabled`，由 UVM agent/signature handshake 验证。
- `riscv_csr_test` 和 `riscv_csr_hazard_test` 是已知 `skip_in_signoff` tracked-broken 项，未计入 signoff。
- 覆盖率会收集，但 full profile 当前只 gate line 和 functional。P4.6 实测值：assert 33%、fsm 54%、toggle 53%、line 91%、branch 83%、functional 69%、overall 64%。报告会逐项标明 gated 或 collected but ungated。
- 参考模型信任假设：EH2-Spike 中的自定义 CSR、PMP/ePMP、trap 和内存行为按 EH2 PRM 建模。cosim 结果依赖该参考模型正确。

## 文档

- 设计与使用文档：[docs/index.html](docs/index.html)
- 新核接入 recipe：[docs/onboarding.md](docs/onboarding.md)

## 最快三行上手

```bash
cp env.mk.example env.mk
make spike
make smoke
```

`env.mk` 只放本机路径，例如支持 C++17 的 `SPIKE_CXX`、`NC_INSTALL`，以及可选的 `VCS_HOME`、`RISCV_PREFIX`。

## 常用命令

```bash
make regress TESTLIST=cosim
make smoke CONFIG=dual_thread SIM_OPTS="+rvvi_nhart=2"
make signoff PROFILE=full
python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q
```

`CONFIG=dual_thread` 对应 NHART=2 的双 hart SMT 配置。
