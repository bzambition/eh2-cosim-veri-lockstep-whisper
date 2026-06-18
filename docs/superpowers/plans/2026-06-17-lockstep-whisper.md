# LOCKSTEP-WHISPER 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 在 `lockstep-whisper` 分支上验证并迁移到“瘦 UVM RVVI-TRACE 抽取 + 通用 cosim-arch-checker + Whisper lockstep”架构。

**架构：** Phase 0 只做可行性门：vendor 上游、评估 Bazel/VCS/RV32/Whisper server 集成，不删除 v2.0 Spike/tracecmp。Phase 1-2 在 RVVI-TRACE 后接通用 bridge 和 cosim-arch-checker，先让 smoke/cosim lockstep 通过。Phase 3 以后才删除 Spike-EH2 与离线 tracecmp。

**技术栈：** SystemVerilog/UVM/VCS、RVVI-TRACE、C++17 DPI、Tenstorrent cosim-arch-checker、Tenstorrent Whisper、Make/Python 回归框架。

---

### 任务 0：隔离分支与基线

**文件：**
- 创建工作区：`/home/host/eh2-cosim-veri-lockstep-whisper`
- 基线测试：`dv/uvm/core_eh2/scripts/tests/`

- [x] **步骤 1：从 `72c50d6` 创建隔离分支**

运行：`git clone /home/host/eh2-cosim-veri /home/host/eh2-cosim-veri-lockstep-whisper && git checkout -b lockstep-whisper 72c50d6`

- [x] **步骤 2：运行基线脚本测试**

运行：`python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q`
预期：`216 passed, 1 skipped`。

### 任务 1：Phase 0 vendor 与工具链调查

**文件：**
- 创建：`vendor/cosim-arch-checker/`
- 创建：`vendor/whisper/`
- 创建：`docs/lockstep_whisper_phase0.md`

- [ ] **步骤 1：vendor 上游源码**

运行：
```bash
git clone https://github.com/tenstorrent/cosim-arch-checker /tmp/cosim-arch-checker
git clone https://github.com/tenstorrent/whisper /tmp/whisper
cp -a /tmp/cosim-arch-checker vendor/cosim-arch-checker
cp -a /tmp/whisper vendor/whisper
rm -rf vendor/cosim-arch-checker/.git vendor/whisper/.git
find vendor/cosim-arch-checker vendor/whisper -type l
```
预期：源码在 vendor 下，`find ... -type l` 为空或记录需解引用处理的 symlink。

- [ ] **步骤 2：记录工具链现状**

运行：`command -v bazel || true; command -v whisper || true; command -v vcs || true; python3 --version; git --version`
预期：记录 Bazel 是否缺失、VCS 是否可用、Python/Git 版本。

- [ ] **步骤 3：分析 cosim-arch-checker 构建入口**

运行：`find vendor/cosim-arch-checker -maxdepth 3 -type f | sort`，阅读 `README.md`、`WORKSPACE`、`BUILD*`、`bridge/`、`env/`。
预期：列出 DPI 目标、monitor API、Whisper client 源文件、RV64/V 扩展假设。

- [ ] **步骤 4：分析 Whisper 构建入口**

运行：`find vendor/whisper -maxdepth 2 -type f | sort`，阅读 `README*`、`CMakeLists.txt` 或 Makefile。
预期：明确 `make whisper` 应该怎样构建 `vendor/whisper` 内的 `whisper` binary，以及 `--server` 支持入口。

### 任务 2：Phase 0 RV32/EH2 配置可行性

**文件：**
- 创建：`dv/cosim/cac/eh2_whisper_config.py` 或同等小脚本
- 创建：`dv/cosim/cac/config/eh2.json`
- 测试：`dv/uvm/core_eh2/scripts/tests/test_lockstep_whisper_phase0.py`

- [ ] **步骤 1：为 whisper.json 转换写失败测试**

测试应读取 `rtl/snapshots/default/whisper.json`，产出 checker 可用的 EH2 config，并断言 `xlen=32`、hart=1、自定义 CSR 配置存在。

- [ ] **步骤 2：实现最小转换脚本**

脚本只做结构转换和路径归一，不硬编码 RTL 层级。

- [ ] **步骤 3：运行单测**

运行：`python3 -m pytest dv/uvm/core_eh2/scripts/tests/test_lockstep_whisper_phase0.py -q`
预期：PASS。

### 任务 3：Phase 0 最小 PoC 决策报告

**文件：**
- 创建：`docs/lockstep_whisper_phase0.md`

- [ ] **步骤 1：记录三未知结论**

文档必须覆盖：Bazel↔VCS 选择、RV32 EH2 风险、Whisper server 进程/确定性/异步注入风险。

- [ ] **步骤 2：给出 go/no-go**

如果 Bazel 缺失但 C++ 源可抽编，则 Phase 1 走“抽源 Makefile 直编”。如果 Whisper 无法构建或 cosim-arch-checker RV32 不可行，则停在 no-go 并描述 Plan B。

### 任务 4：Phase 1-5 后续执行骨架

**文件：**
- 后续修改：`Makefile`、`dv/uvm/core_eh2/tb/core_eh2_tb_top.sv`、`dv/uvm/core_eh2/eh2_tb.f`
- 后续创建：通用 RVVI-TRACE bridge SV/C++ DPI 文件

- [ ] **步骤 1：只有 Phase 0 go 后才创建 bridge**

bridge 消费 `rvviTrace`，调用 cosim-arch-checker `monitor_*` DPI，不直接探 EH2 内部信号。

- [ ] **步骤 2：只有 smoke/cosim lockstep PASS 后才删除旧 tracecmp/Spike**

删除必须有 grep 验证：`grep -rn 'spike_cosim\|trace_compare_full\|tracecmp_only' dv/ Makefile | grep -v vendor` 无活引用。
