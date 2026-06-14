# eh2-cosim-veri

eh2-cosim-veri 是面向 EH2（RISC-V Cores-VeeR-EH2）的 cosim-only 验证平台，协同仿真走标准 RVVI-API（官方 `riscv-verification/RVVI`）在线 lockstep，而不是旧自定义比对层。

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
