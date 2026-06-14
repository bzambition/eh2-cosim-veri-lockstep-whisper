# eh2-cosim-veri

eh2-cosim-veri 是面向 EH2（RISC-V Cores-VeeR-EH2）的 cosim-only 验证平台，协同仿真走标准 RVVI-API（官方 `riscv-verification/RVVI`）在线 lockstep，而不是旧自定义比对层。

核心链路：`rvvi_adapter.sv` 将 EH2 retire 流映射到标准 `rvviTrace`，`rvvi_scoreboard.sv` 通过 RVVI-API 在线逐指令比对，`spike_rvvi.cc` 把 Spike 包成参考模型。

支持单 hart 和双 hart SMT；双 hart 使用 `CONFIG=dual_thread` 并按 `NHART=2` 运行。

## 文档

完整设计与使用文档见 [docs/index.html](docs/index.html)，可用浏览器直接离线打开。

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
make signoff PROFILE=cosim
python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q
```
