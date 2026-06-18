# LOCKSTEP-WHISPER Phase 3 实现计划（可执行提示词）

> **面向执行代理（codex）：** 本文件是一期 Mx 提示词，执行时与 COMMON.md 的**五条铁律**拼接（COMMON 的 §3/§4 Spike+标准rvviApi-on-Spike 架构描述的是已脱钩的旧 `eh2-cosim-veri`，本平台不适用）。**逐任务按顺序实现，不并行、不跳级、不自行扩大范围**；每个任务末尾有"验收门"，跑过命令并确认输出才算完成；步骤用复选框（`- [ ]`）跟踪。**动手前必须先读"必读前置"。**

**目标：** 把 **cosim-arch-checker(CAC) 做成标准 RVVI-API 通用 checker**——实现官方 `rvviApi.h` 契约，**Whisper(VeeR-ISS) 作 RVVI-API 参考后端**，DUT 侧走通用 RVVI-API scoreboard，从而 core-agnostic、可复用、**减轻 UVM 负担**（每核唯一专属件 = RVVI-TRACE adapter）。同时删除 Spike/offline 与私有 `monitor_*` 路径，让 RVVI-API + Whisper lockstep 成为唯一 oracle。

**架构（目标态）：**
```
EH2 RTL → eh2_rvvi_adapter.sv → rvviTrace(官方)          ← 唯一核专属 UVM 件
        → rvvi_scoreboard.sv(通用, import rvviApiPkg)     ← 写一次复用, 瘦 UVM 驱动壳
        → [CAC 实现 rvviApi.h]  rvviDut*/rvviRefEventStep/rvviRef*Compare/rvviRefNetSet
        → [whisper_rvvi 后端]   rvviRef* ⇄ whisper_client ⇄ whisper --server (VeeR-ISS)
```
比较逻辑全在 CAC(C++)；SV 只是标准 RVVI-API 驱动循环。EH2 专属只在 `eh2_rvvi_adapter.sv` + `rtl/snapshots/*/whisper.json` + `config/*`。

**技术栈：** SystemVerilog/UVM + VCS 2021.09、官方 RVVI-API（`vendor/rvvi`，`rvviApi.h`/`rvviApiPkg.sv`）、C++17 DPI、cosim-arch-checker（Apache-2.0，加 RVVI-API facade）、chipsalliance/VeeR-ISS（"Whisper"，官方 ISS，C++17）、无 root devtoolset-9 + Boost 1.75。

---

## 必读前置（动手前）

| 文件 | 作用 |
|---|---|
| `docs/lockstep_whisper_phase0b.md` | 工具链来源（VeeR-ISS HEAD、devtoolset-9、Boost）、server 协议、可复用资产清单 |
| `docs/lockstep_whisper_phase1.md` | 现 CAC 全状态扩展、瘦 bridge、whisper_client 移植、ABI 切分 |
| `docs/lockstep_whisper_phase2.md` | riscvdv/compliance/双hart/异步在线注入证据、debug 残留、反作弊边界 |
| `eh2-cosim-veri-codex/MR3a.md`（历史提示词） | 当年标准 RVVI-API 在线 lockstep 的 SV/C 实装范本（参考其 rvviDut*/rvviRef*Compare 写法）|

**现状（Claude 已核实）：**
- DUT 侧已是标准 `rvviTrace`（`eh2_rvvi_adapter.sv`）。✓
- 但 `rvvi_cac_bridge.sv` 把 rvviTrace **翻译**成 CAC **私有** DPI `monitor_instr/gpr/csr/mem/async`（`rvvi_cac_bridge.sv:183` 等）；CAC **本身不是 RVVI**。
- `vendor/rvvi`（官方 `rvviApi.h`/`rvviApiPkg.sv`）在树里但**未被 CAC 路使用**。
- 待删：`vendor/spike`、`dv/cosim/spike_cosim.cc`、`dv/cosim/spike_rvvi_main.cc`、`dv/uvm/core_eh2/scripts/trace_compare_full.py`、`rvvi_trace_to_trace_csv.py`、私有 `monitor_*` SV 路径。
- Phase 2 资产（`vendor/whisper`、CAC 改动、bridge、config、phase 文档、VeeR-ISS reset 补丁）当前 untracked/uncommitted。

---

## 运行环境（每个新 shell 先 export）

```bash
export CAC_CXX=/home/Xilinx/Vivado/2019.1/tps/lnx64/gcc-6.2.0/bin/g++
export WHISPER_PATH=vendor/whisper/build-Linux/whisper
export WHISPER_LD_LIBRARY_PATH=/home/host/toolchains/boost-gcc9/lib:/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr/lib64:/home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr/lib
```
`make` 把这些读作 make 变量；`LOCKSTEP_WHISPER=1` 时 Makefile 自动注入 `CAC_CSR_MASK_FILE` 与 lockstep `LD_LIBRARY_PATH`。VeeR-ISS 重构建见 phase0b（机器路径走 env.mk 的 `WHISPER_CXX`/`WHISPER_BOOST_ROOT`，见 P3.0）。VeeR-ISS 上游：`chipsalliance/VeeR-ISS` HEAD `e6b4fb17bd9bf15a9df225bea804be663648903a`。

---

## 贯穿全程的硬规则（违反即作废）

1. **CAC 做成标准 RVVI-API。** SV 侧只调官方 `rvviApiPkg`（`rvviDut*`/`rvviRefEventStep`/`rvviRef*Compare`/`rvviRefNetSet` …）；**严禁**新增/保留私有 `monitor_*` 作为 SV-facing 接口。conform 到 `vendor/rvvi/include/host/rvvi/rvviApi.h` 既有签名，不自创契约。
2. **瘦 UVM + 通用。** 比较逻辑在 CAC(C++)；SV scoreboard 是通用驱动壳、**零 EH2 硬编码**。每核唯一专属件 = `eh2_rvvi_adapter.sv`。
3. **CAC/scoreboard core-agnostic。** EH2 专属只在 adapter + `rtl/snapshots/*/whisper.json` + `config/*`。每个改 CAC/scoreboard 的任务结尾，`grep -rniE 'eh2|veer' vendor/cosim-arch-checker/ dv/uvm/core_eh2/common/rvvi_agent/rvvi_scoreboard.sv --include=*.cpp --include=*.h --include=*.sv` 应仅命中注释或为空。
4. **不用 Spike。** Spike/offline tracecmp 直接删（见 P3.0，备份在 `eh2-cosim-veri`）。参考模型唯一 = Whisper(VeeR-ISS)。
5. **直接删除（备份在 `eh2-cosim-veri`）。** Spike/offline tracecmp 的旧代码在 `eh2-cosim-veri` 仓有备份，**本仓直接删**（P3.0），不保留作 parity 对照、不搞新旧双路并跑。`monitor_*`/`rvvi_cac_bridge.sv` 在 `rvvi_scoreboard.sv` 落地时**直接替换**（P3.3）。
6. **不改 RTL 设计。** `git diff --name-only 72c50d6..HEAD | grep '^rtl/' | grep -v snapshots` 必须空。
7. **只认证据；真实不间断 signoff。** 无 artifact 路径不得称 PASS；目标是一次自然 `make signoff` 返回 **exit 0**，非 gate-summary 汇总、非 exit-code waiver。
8. **debug 措辞红线。** debug request 经 server command 真注入并 PASS 才可称 closure，否则降级"已设计未实现 + 在线兜底"。
9. **`jtag/irq` 等设计定制不进 checker。** 这些是每核定制刺激/检查，属 UVM/测试范畴，**不是通用 RVVI checker 的职责**，本计划不把它们迁进 CAC。
10. **COMMON 五条铁律。** 零符号链接、tracked 源零绝对路径（机器路径只在 env.mk）、单目录自包含/vendored、机器前提走 env.mk/PATH、极简不留死文件。
11. **RTL 是 symlink。** `find . -path ./.git -prune -o -type l -print` 必须空（`cp -rL`）。
12. **昂贵流程不冗余重跑**（full signoff ≈2–3h，只在标注 gate 跑，先 dry-run）；**分支 `lockstep-whisper`，未经指示不 push、不并 master**。

---

## 执行顺序与全跑预算

主线 = **给 CAC 加 rvviApi.h**。P3.0 固化资产并**直接删 Spike/offline**（备份在 `eh2-cosim-veri`）；P3.1–P3.3 建 RVVI-API 路（scoreboard 落地即直接替换 monitor_*/bridge）；P3.4–P3.5 接异步与全量；P3.6 干净 signoff；P3.7 收口。
需要 full signoff 全跑的只有 **P3.6**（COV=1 终签）。P3.3/P3.4/P3.5 用 smoke/cosim/单测试/子集验证，不全跑。

---

## 任务 0：基线自检（不改代码）

**文件：** 验证 `dv/uvm/core_eh2/scripts/tests/`、`vendor/cosim-arch-checker/`、`vendor/rvvi/`

- [ ] **步骤 1：分支与起点**

运行：
```bash
cd /home/host/eh2-cosim-veri-lockstep-whisper
git log --oneline -1            # 预期 HEAD=72c50d6, Phase 2 改动未 commit
ls vendor/rvvi/include/host/rvvi/rvviApi.h vendor/rvvi/source/host/rvvi/rvviApiPkg.sv   # 官方契约在树
```

- [ ] **步骤 2：单测/构建基线**

运行：
```bash
python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q          # 预期 224 passed, 1 skipped
make cac CAC_CXX=$CAC_CXX                                     # exit 0
make -C vendor/cosim-arch-checker test CC=$CAC_CXX            # exit 0, 含 CSR[0x7c0]/MEM 牙齿
find . -path ./.git -prune -o -type l -print                 # 空
```

**验收门：** 状态与 Phase 2 一致；`rvviApi.h`/`rvviApiPkg.sv` 在树。不 commit。

---

## 任务 1（P3.0）：资产固化 + 直接删除 Spike/offline（备份在 eh2-cosim-veri）

**文件：**
- 创建：`vendor/whisper-patches/0001-mrac-pma-postreset.patch`、`scripts/`（占位）
- 修改：`.gitignore`（忽略 `vendor/whisper/build-*/`、`*.o`、`tr_db.log`、`ucli.key`、`issfinal.log`）、`env.mk.example`（加 `WHISPER_CXX`/`WHISPER_BOOST_ROOT`）、`Makefile`（加 `whisper` 目标）
- 提交：`rvvi_cac_bridge.sv`、`eh2_rvvi_adapter.sv`、`eh2_tb.f`、`core_eh2_tb_top.sv`、`run_regress.py`、`signoff.py`、`config/`、`vendor/cosim-arch-checker/`、`vendor/whisper/`(去 build)、`docs/lockstep_whisper_phase*.md`

- [ ] **步骤 1：抽取 VeeR-ISS reset 补丁为 tracked patch**

`vendor/whisper/HartConfig.cpp` 的 `defineMracSideEffects()` 用 `registerPostReset(reset)` 修了 MRAC/PMA reset（修 `riscv_arithmetic_basic_test` seed2）。抽 diff：
```bash
mkdir -p vendor/whisper-patches /tmp/wp
git -C /tmp/wp clone https://github.com/chipsalliance/VeeR-ISS . 2>/dev/null && \
  git -C /tmp/wp checkout e6b4fb17bd9bf15a9df225bea804be663648903a 2>/dev/null && \
  diff -u /tmp/wp/HartConfig.cpp vendor/whisper/HartConfig.cpp > vendor/whisper-patches/0001-mrac-pma-postreset.patch || \
  echo "无网络：跳过 diff，依赖步骤2直接提交源码；patch 文件头注释写明基线 HEAD e6b4fb1"
```

- [ ] **步骤 2：忽略构建产物 + 提交 vendored 源码**

`.gitignore` 追加 `vendor/whisper/build-*/`、`vendor/whisper/**/*.o`、`/tr_db.log`、`/ucli.key`、`/issfinal.log`。沿用 `vendor/spike` 惯例：直接提交 `vendor/whisper` 源码（去 build），保证离线 re-clone 不丢 reset 修复。

- [ ] **步骤 3：`make whisper` 目标（机器路径走 env.mk，铁律 #10）**

`env.mk.example` 追加：
```makefile
WHISPER_CXX        ?= /home/host/toolchains/devtoolset-9/opt/rh/devtoolset-9/root/usr/bin/g++
WHISPER_BOOST_ROOT ?= /home/host/toolchains/boost-gcc9
```
`Makefile` 加（`.PHONY` 加 `whisper`）：
```makefile
whisper:
	@test -n "$(WHISPER_CXX)"        || { echo "ERROR: env.mk 设 WHISPER_CXX"; exit 1; }
	@test -n "$(WHISPER_BOOST_ROOT)" || { echo "ERROR: env.mk 设 WHISPER_BOOST_ROOT"; exit 1; }
	@cd vendor/whisper && $(MAKE) -f GNUmakefile CXX=$(WHISPER_CXX) \
	  BOOST_ROOT=$(WHISPER_BOOST_ROOT) STATIC_LINK=0 -j4 build-Linux/whisper
	@test -x vendor/whisper/build-Linux/whisper && echo "=== [whisper] done ==="
```

- [ ] **步骤 4：直接删除 Spike + offline tracecmp（备份在 eh2-cosim-veri，无需保留）**

删文件：
```bash
git rm -r vendor/spike dv/cosim/spike_cosim.cc dv/cosim/spike_cosim.h dv/cosim/spike_rvvi_main.cc \
  dv/uvm/core_eh2/scripts/trace_compare_full.py dv/uvm/core_eh2/scripts/rvvi_trace_to_trace_csv.py \
  dv/uvm/core_eh2/scripts/tests/test_trace_compare_full.py \
  dv/uvm/core_eh2/scripts/tests/test_rvvi_trace_to_trace_csv.py
```
改引用：`run_regress.py` 删离线 import（`:37-38`）、`write_hart_schedule_from_csv`（`:328`）、`run_trace_compare`（`:337`）、`uses_trace_compare`（`:283`）、`trace_compare_enabled` 路径（`:512-518,569-570`）、`--disable-trace-compare`（`:759-760`）；`test_regression_framework.py:278-293`（读 spike_cosim 的两测试）删；`Makefile` 删 `spike`/`cosim($(LIBCOSIM))`/`rvviref` 目标、help 的 `make spike`、`CLEAN_PRESERVE_BUILD` 的 spike_objs。README/onboarding/index.html 先去掉 Spike/offline 描述（最终架构叙述在 P3.7 定稿）。**保留** `rvvi_cac_bridge.sv`+monitor_*（P3.3 被 scoreboard 替换前仍是活路径）、`vendor/rvvi`、`vendor/whisper`、`vendor/cosim-arch-checker`。
验证：
```bash
grep -rn 'spike_cosim\|trace_compare_full\|rvvi_trace_to_trace_csv\|make spike' dv/ scripts/ Makefile 2>/dev/null | grep -v '^docs/'   # 无活引用
python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q   # 绿（数目相应下降）
make smoke LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=0     # monitor_* lockstep 路仍 1/1（删 Spike/offline 不影响它）
```

- [ ] **步骤 5：构建回归 + commit**

```bash
make cac CAC_CXX=$CAC_CXX                                  # exit 0
find . -path ./.git -prune -o -type l -print              # 空
git add -A
git status -s    # 人工确认无 build-Linux/、无大产物
git commit -m "feat(lockstep): 固化 Phase 2 资产 + reset 补丁；直接删 Spike/offline (P3.0)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**验收门：** 资产+reset 补丁 tracked、`make whisper` 存在；**Spike/offline 已删、grep 无活引用、pytest 绿、smoke 仍 1/1**；cac exit 0、无 symlink；已 commit。

---

## 任务 2（P3.1）：`whisper_rvvi` —— RVVI-API 参考后端（Whisper 背书）

实现 `rvviApi.h` 的 **ref 侧**，后端是 Whisper（复用 `whisper_client`）。这是"加 RVVI"的地基。

**文件：**
- 创建：`vendor/cosim-arch-checker/bridge/whisper/whisper_rvvi.cpp`（rvviRef* 实现，调 `whisper_client`）
- 修改：CAC 构建（Makefile/`make cac`）链入 `whisper_rvvi` + `vendor/rvvi` include
- 测试：`vendor/cosim-arch-checker` C++ 单测

- [ ] **步骤 1：对照官方契约列出要实现的 rvviRef* 子集**

读 `vendor/rvvi/include/host/rvvi/rvviApi.h`，列出 ref 侧函数：`rvviVersionCheck`、`rvviRefConfigSet*`、`rvviRefInit`、`rvviRefPcSet`、`rvviRefEventStep`、`rvviRefPcGet`、`rvviRefGprGet`、`rvviRefCsrGet`、`rvviRefMemoryRead`、`rvviRefNetSet`、`rvviRefCsrSetVolatile`、`rvviRefMetricGet`、`rvviErrorGet` 等。**只实现 EH2 lockstep 实际用到的子集**，其余空桩 + 注释。

- [ ] **步骤 2：实现映射到 whisper_client**

`whisper_rvvi.cpp`：
- `rvviRefInit(elf)` → 起 `whisper --server`（per-test server 文件/端口，复用 Phase 1 进程管理）、load elf。
- `rvviRefEventStep(hart)` → `whisperStep` 一条；用 `whisper_client` 的 Change/Peek 把 ref 的 PC/insn/GPR/CSR/mem 变化拉进 per-hart ref 暂存。
- `rvviRefPcGet/GprGet/CsrGet/MemoryRead(hart,...)` → 读 ref 暂存。
- `rvviRefNetSet(hart,net,val)` / 中断注入 → `whisperPoke`（mip/debug 在线注入的标准入口，P3.4 用）。
- `rvviRefMetricGet` / `rvviErrorGet` → 计数 + 文案。

- [ ] **步骤 3：standalone parity 测试（仿 MR2）**

写 C++ 单测或最小 driver：`rvviRefInit(tests/asm/smoke.elf)` 后连续 `rvviRefEventStep`，打印 ref PC/GPR 流，与 DUT smoke RVVI-TRACE（或反汇编）对齐。
运行：`make -C vendor/cosim-arch-checker test CC=$CAC_CXX`
**预期**：ref retire PC 流 == DUT smoke（`80000000→04→08→0c`）。

**验收门：** `whisper_rvvi` 后端能 init+step+读回 ref 全状态；smoke 上 ref 流与 DUT 对齐（证据：单测输出 / server log）。

---

## 任务 3（P3.2）：CAC 的 RVVI-API DUT staging + 比较

实现 `rvviApi.h` 的 **DUT 侧 + 比较**，复用 CAC 现有全状态比较引擎（Phase 1 已验证 PC/GPR/CSR/mem）。

**文件：**
- 创建/修改：`vendor/cosim-arch-checker/`（rvviDut*/rvvi*Compare facade over 现有引擎）
- 测试：CAC C++ 单测（牙齿）

- [ ] **步骤 1：实现 DUT staging**

per-hart DUT 暂存（仿 MR3a）：`rvviDutGprSet(h,i,v)`（置 wmask）、`rvviDutCsrSet(h,c,v)`、`rvviDutRetire(h,pc,insn,dbg)`、store/mem staging。内部复用 CAC 现有 `monitor_*` 引擎的暂存结构（facade，不重写引擎）。

- [ ] **步骤 2：实现比较函数**

`rvviRefPcCompare`、`rvviRefInsBinCompare`（压缩指令低位对齐）、`rvviRefGprsCompareWritten(h,ignoreX0)`、`rvviRefCsrsCompare(h)`（走外部 mask `config/cac_csr_masks.txt`，非 mask 真比）、`rvviRefMemoryCompare`。失配 `rvviErrorGet` 给文案、metric++。每条 retire 比完清 wmask/csr_written。

- [ ] **步骤 3：牙齿测试**

CAC 单测：喂入一条 DUT retire，故意改 1 个 GPR / 1 个 CSR / 1 字节 mem，断言对应 compare 返回失配；mask 内的非确定 CSR 不假失配。
运行：`make -C vendor/cosim-arch-checker test CC=$CAC_CXX`
**预期**：牙齿全中（改值→FAIL，mask CSR→不 FAIL）。

**验收门：** CAC 经 `rvviApi.h` 真比 PC+GPR+CSR(含自定义)+mem；牙齿不退。

---

## 任务 4（P3.3）：通用 RVVI-API SV scoreboard（取代 monitor_* bridge）

**文件：**
- 创建：`dv/uvm/core_eh2/common/rvvi_agent/rvvi_scoreboard.sv`（通用，`import rvviApiPkg::*`）
- 修改：`eh2_tb.f`（加 `vendor/rvvi/source/host/rvvi/rvviApiPkg.sv` + 新 scoreboard、去掉 bridge）、`core_eh2_tb_top.sv`（例化 scoreboard）、`run_regress.py`/Makefile（lockstep 路恒走 RVVI-API）
- 删除：`rvvi_cac_bridge.sv` + CAC 的 monitor_* SV-facing DPI（被 scoreboard + rvviApi.h 取代；内部比较引擎保留）

- [ ] **步骤 1：写通用 scoreboard**

`rvvi_scoreboard.sv`：`build` 调 `rvviVersionCheck`+`rvviRefInit(<elf>)`；主循环每拍对每条 `rvvi.valid[h][r]`：`rvviDutGprSet`(逐 x_wb) → `rvviDutCsrSet`(逐 csr_wb) → `rvviDutRetire(h,pc,insn,debug_mode)` → `rvviRefEventStep(h)` → `ok = rvviRefPcCompare & rvviRefInsBinCompare & rvviRefGprsCompareWritten(h,1) & rvviRefCsrsCompare & rvviRefMemoryCompare`；`!ok` → `uvm_error(rvviErrorGet())`。结束比 `rvviRefMetricGet(RETIRES)` 与 DUT retire 数。**零 EH2 硬编码。**

- [ ] **步骤 2：集成 + 直接替换 monitor_* bridge**

tb_top 例化 `rvvi_scoreboard`，连 `rvviTrace`（adapter 已驱动），`LOCKSTEP_WHISPER=1` 即走 RVVI-API 路。**删除 `rvvi_cac_bridge.sv` 与 CAC 的 monitor_* SV-facing DPI**（内部比较引擎保留，已由 rvviApi.h facade 复用）；`eh2_tb.f`/`core_eh2_tb_top.sv` 去掉 bridge、加 scoreboard + `rvviApiPkg.sv`。grep 确认无 `rvvi_cac_bridge`/`monitor_instr` 活引用。

- [ ] **步骤 3：smoke + cosim 跑通（RVVI-API 为唯一路径）**

```bash
make smoke LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=0
make regress LOCKSTEP_WHISPER=1 TESTLIST=cosim SIMULATOR=vcs COV=0 PARALLEL=1 OUT=build/p33_cosim
```
**预期**：smoke 1/1 + cosim 7/7 经 RVVI-API 在线 lockstep PASS。

**验收门：** smoke+cosim 7/7 PASS；`rvvi_cac_bridge.sv`/monitor_* 已删、grep 无活引用；scoreboard/CAC 无 EH2 泄漏。

---

## 任务 5（P3.4）：异步/中断/debug 经 `rvviRefNetSet` 在线注入（分级）

把 mip/中断/debug 注入从 bridge 的 ad-hoc `whisperPoke` 改走标准 `rvviRefNetSet`/中断 API。

**文件：** `whisper_rvvi.cpp`（rvviRefNetSet→whisperPoke 映射）、`rvvi_scoreboard.sv`（retire 包边界检测 debug_mode/mip 边沿后调 rvviRefNetSet）

- [ ] **步骤 1：mip/中断**

scoreboard 在每条 retire 前，按 `rvvi.csr[h][r][0x344]`/`rvvi.intr[h][r]` 经 `rvviRefNetSet` 同步 ref，再 step。
```bash
make regress LOCKSTEP_WHISPER=1 TESTLIST=riscvdv TEST=riscv_interrupt_test ITERATIONS=1 OUT=build/p34_irq
```
**预期**：`riscv_interrupt_test` 1/1 PASS。

- [ ] **步骤 2：debug（分级收口）**

建 retire-包边界时序模型：`debug_mode` 0→1/1→0 边沿只在包**所有** retire 处理完后、下次 step 前经 `rvviRefNetSet`/EnterDebug 注入（不在双发射包中途 halt，解决 `Single step while in debug-halt`）。
```bash
make regress LOCKSTEP_WHISPER=1 TESTLIST=riscvdv TEST=riscv_debug_test ITERATIONS=1 OUT=build/p34_debug
```
- **能通（promote）**：扩 debug 组代表测试验证；报告可称 closure。
- **不收敛（downgrade）**：保留在线 lockstep debug 比较兜底，记 Phase 4，**不称 closure**。

**验收门（二选一）：** ①debug 经标准 API 注入 PASS；②文档化降级 + 兜底绿 + 记 Phase 4。interrupt 组 PASS。

**执行记录（2026-06-19）：downgrade。**

- `mip`/interrupt 已改走标准 `rvviRefNetSet`：SV scoreboard 通过
  `rvviRefNetIndexGet("mip")` + `rvviRefNetGroupSet(..., hart)` 选择
  hart，后端将该 net 映射到 Whisper CSR `mip(0x344)` poke。
- 证据：`build/p34_irq_api/report.json`，`riscv_interrupt_test`
  `ITERATIONS=1`，`Total: 1 | Passed: 1 | Failed: 0`。
- debug server command 后端已实现为 opt-in 能力：
  `rvviRefNetIndexGet("debug_mode")` + `rvviRefNetSet` 可映射到
  Whisper `EnterDebug`/`ExitDebug`，但只有传入 `+rvvi_debug_poke`
  时 scoreboard 才会主动发送命令。
- 主动 debug 注入仍未闭合：开启实验路径后
  `build/p34_debug_api/` 中 `riscv_debug_test` 失败，
  `whisper_connect.cmd.log` 记录到 `enter_debug true` 后
  下一次 step 失败，符合 Phase 2 已记录的 debug halt 时序风险。
- 默认路径保持在线 lockstep debug 兜底，不声称 debug closure。
  证据：`build/p34_debug_downgrade_default/report.json`，
  `riscv_debug_test` `ITERATIONS=1`，
  `Total: 1 | Passed: 1 | Failed: 0`。

---

## 任务 6（P3.5）：riscvdv + 双 hart + 性能（RVVI-API 路全量验证）

RVVI-API 路全量验证：riscvdv 无未解释失配 + 双 hart + 性能可接受。

- [ ] **步骤 1：性能门（先测单条）**

```bash
/usr/bin/time -p make regress LOCKSTEP_WHISPER=1 TESTLIST=riscvdv TEST=riscv_stress_test ITERATIONS=1 OUT=build/p35_perf
```
**预期**：吞吐与 Phase 2 的 monitor_* 路相当（同为 socket-step；不可接受则停下报告优化）。

- [ ] **步骤 2：riscvdv 全量 + 双 hart**

```bash
make regress LOCKSTEP_WHISPER=1 TESTLIST=riscvdv OUT=build/p35_riscvdv
make regress LOCKSTEP_WHISPER=1 TESTLIST=cosim CONFIG=dual_thread OUT=build/p35_dual
```
**预期**：riscvdv 无未解释失配（仅 `riscv_csr_test`/`riscv_csr_hazard_test` 既有 tracked-broken）；双 hart cosim 7/7 PASS。

**验收门：** riscvdv 无未解释失配（仅 2 个既有 tracked-broken csr）+ 双 hart PASS + 性能可接受。

---

## 任务 7（P3.6）：干净 full signoff（COV=1）

前置门：P3.0–P3.5 全绿（Spike/offline 已在 P3.0 删、monitor_*/bridge 已在 P3.3 替换为 rvvi_scoreboard）。

- [ ] **步骤 1：signoff exit-code 修复**

`signoff.py:416/441` 的 stage exit-code waiver 源于 `run_regress.py:709 regression_exit_code` 把 `skip_in_signoff`（`riscv_csr_test`/`hazard`）算进 `summary.failed`。修 `regression_exit_code` 不计 skip_in_signoff，使真绿→自然 exit 0。加单测 `test_signoff_gates.py::test_skip_in_signoff_tests_do_not_force_nonzero_exit`；`pytest` 绿。

- [ ] **步骤 2：干净 full signoff（COV=1，唯一全跑 gate）**

```bash
make signoff PROFILE=full LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=1 \
  SIGNOFF_OPTS=--no-fail-on-skip-in-signoff OUT=build/signoff_p36_final
echo "make exit=$?"
```
**预期**：`make exit=0`；signoff PASS；无 `stage command exit code` waiver；coverage line/functional gated 达阈（基线 line91/func69，阈值 `SIGNOFF_MIN_LINE_COV`/`FUNCTIONAL_COV`）。

- [ ] **步骤 3：commit**

**验收门：** 干净 `make signoff` COV=1 exit 0、无 exit-code waiver、覆盖率 gated；已 commit。

---

## 任务 8（P3.7）：通用性验证 + 文档 + 复现 + 反作弊

- [ ] **步骤 1：复现入口** `scripts/bootstrap_lockstep.sh`（`source env.mk` → `make whisper` → `make cac` → `make smoke LOCKSTEP_WHISPER=1`），零绝对路径。预期 smoke 1/1。
- [ ] **步骤 2：反作弊 + core-agnostic + 绝对路径核查**

```bash
git diff 72c50d6 -- dv/uvm/core_eh2/riscv_dv_extension/testlist.yaml dv/uvm/core_eh2/directed_tests/directed_testlist.yaml   # 无放水
git diff --name-only 72c50d6..HEAD | grep '^rtl/' | grep -v snapshots || echo OK
grep -rniE 'eh2|veer' vendor/cosim-arch-checker/ --include=*.cpp --include=*.h | grep -viE 'test|//'   # 空: CAC 通用
grep -rnE '/home/(host|cadence|Xilinx)|toolchains/' --include='*.yaml' --include='*.sv' --include='*.cc' --include='*.cpp' --include='*.h' --include='*.py' --include='Makefile' dv/ config/ Makefile | grep -v snapshots   # 空
python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q
```

- [ ] **步骤 3：Phase 3 报告**（仿 phase2 结构）：RVVI-API facade 设计、whisper_rvvi 后端、通用 scoreboard、smoke/cosim/riscvdv/双hart/signoff 证据、debug 分级结果、删除清单与 grep、**core-agnostic 通用性论证**（每核唯一专属件=adapter）、与 Phase 2 monitor_* 路对照。
- [ ] **步骤 4：commit**

**验收门：** 终签 exit 0；反作弊 + core-agnostic + 绝对路径全绿；复现脚本出 smoke 1/1；报告 commit。

---

## 最终验收清单

- [ ] CAC 实现 `rvviApi.h`（SV 只调 `rvviApiPkg`，无 SV-facing `monitor_*`）
- [ ] Whisper 作 RVVI-API 参考后端（`whisper_rvvi`）；Spike/offline 全删、grep 无活引用
- [ ] 通用 `rvvi_scoreboard.sv` 零 EH2；CAC 零 EH2（grep 空）——每核唯一专属件 = adapter
- [ ] smoke/cosim/riscvdv/双hart 经 RVVI-API 路 PASS；干净 `make signoff` COV=1 exit 0、无 exit-code waiver、覆盖率 gated
- [ ] debug：promote 或 downgrade（措辞合规）
- [ ] 未改 RTL、未放水 testlist、无 symlink、无绝对路径泄漏、未 push/未并 master

## 范围之外

- `jtag/irq/reset/single-step` 等**每核定制刺激与检查**：属 UVM/测试范畴，**不是通用 RVVI checker 职责**，不迁进 CAC。
- formal/LEC/综合/STA/power/physical/gate-level/CDC/RDC/PPA：非本平台范围。
- `riscv_csr_test`/`riscv_csr_hazard_test`：v2.0 既有 tracked-broken，保持 `skip_in_signoff`，非完成阻塞项。

## 分级项（promote 理想 / downgrade 可接受）

| 任务 | promote | downgrade（文档化 + Phase 4） |
|---|---|---|
| P3.4 debug 注入 | 经标准 API 真注入 PASS，称 closure | 已设计未实现 + 在线 lockstep 兜底 |
| P3.5 性能 | 吞吐≈现状，直接 scale | 不可接受则停下报告 + 提优化（batch step/UDS/共享内存）|

确定项（必须达成）：P3.0 固化、P3.1–P3.3 RVVI-API 路建成、P3.6 删除+干净 signoff、P3.7 通用性+文档。
