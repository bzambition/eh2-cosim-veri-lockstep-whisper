# ============================================================
# EH2 Cosim 验证平台 — 顶层 Makefile（cosim-only 精简版 / 草稿）
# ============================================================
# 来源：eh2-veri v1.1 顶层 Makefile（1574 行）裁剪重整为 cosim 协同验证专用。
#
# 相对旧版的改动：
#   - 删 lint / formal / synth / demo / signoff_replay 五个 target
#   - 删旧的 `make run GOAL=...` 入口（wrapper.mk 调度，主流程不用）
#   - 删 Xcelium(compile_xlm) 路径（老服务器无 Xcelium）
#   - 删全部 deprecated alias；wave_nc → watch_wave（三形式/两模式）
#   - 删 700 行内嵌 HELP_TEXT，换成精简 help
#   - 保留：asm / cosim / compile / smoke / regress / compliance / watch_wave / signoff / clean
#   - 保留 VCS(主) + NC/irun(备选) 双路；产物按 build/<target>_<sim>/ 隔离；保留覆盖率
#
# 铁律：tracked 文件零绝对路径、零符号链接。机器相关路径全部走 env.mk（见 env.mk.example）。
# ============================================================

SHELL := /bin/bash

# 机器相关变量集中放 env.mk（SPIKE_CXX / NC_INSTALL / VCS_HOME 等），软引用、缺失不报错
-include env.mk

# ============================================================
# 目录与文件（全相对路径）
# ============================================================
RTL_DIR      := rtl/design
DUAL_THREAD_CONFIGS := dual_thread default_mt
IS_DUAL_THREAD_CONFIG := $(filter $(CONFIG),$(DUAL_THREAD_CONFIGS))
SNAPSHOTS    := $(if $(IS_DUAL_THREAD_CONFIG),rtl/snapshots/default_mt,rtl/snapshots/default)
RVVI_NHART := $(if $(IS_DUAL_THREAD_CONFIG),2,1)
TB_DIR       := dv/uvm/core_eh2
SHARED_DIR   := shared/rtl
SCRIPTS_DIR  := $(TB_DIR)/scripts
DV_EXT_DIR   := $(TB_DIR)/riscv_dv_extension
RISCV_DV_DIR := vendor/google_riscv-dv
ASM_DIR      := tests/asm
BUILD_DIR    := build

# 每个仿真类 target 覆盖此变量 → 产物落各自岛屿 build/<target>_<sim>/
BUILD_SUBDIR ?= $(BUILD_DIR)/compile_$(SIMULATOR)
COMPLIANCE_BUILD_SUBDIR ?= $(BUILD_DIR)/compile_$(SIMULATOR)
COMPLIANCE_SIMV ?= $(CURDIR)/$(COMPLIANCE_BUILD_SUBDIR)/simv

DEFINES      := $(SNAPSHOTS)/common_defines.vh
RTL_F        := $(TB_DIR)/eh2_rtl.f
SHARED_F     := $(TB_DIR)/eh2_shared.f
TB_F         := $(TB_DIR)/eh2_tb.f

# clean 默认保留清单（删了要重跑数小时 / 签发证据）
CLEAN_PRESERVE_BUILD := r3b_final r4a_final nightly compliance_tb_compile.log
CLEAN_PRESERVE_FIND  := $(foreach n,$(CLEAN_PRESERVE_BUILD),! -name '$(n)') ! -name 'archive_signoffs_*'

# ============================================================
# 用户可覆盖变量（详见 make help）
# ============================================================
CONFIG          ?= default
SEED            ?= 1
TEST            ?=
TESTLIST        ?= riscvdv
SIMULATOR       ?= vcs
VERBOSITY       ?= UVM_MEDIUM
TIMEOUT_NS      ?= 10000000
WAVES           ?= 0
COV             ?= 1
ITERATIONS      ?=
PARALLEL        ?= 4
OUT             ?=
SIM_OPTS        ?=
LOCKSTEP_WHISPER ?= 1

# sign-off
PROFILE         ?= full
GATE_ONLY       ?= 0
CLEANUP         ?= 0
SIGNOFF_OUT     ?= $(BUILD_DIR)/signoff_$(SIMULATOR)
SIGNOFF_OPTS    ?= --no-fail-on-skip-in-signoff
SIGNOFF_ITERATIONS ?=
SIGNOFF_MIN_LINE_COV       ?= 55
SIGNOFF_MIN_FUNCTIONAL_COV ?= 40
SIGNOFF_ALLOW_WARNINGS     ?= 1

# 各 target 自己的模式开关（互不复用，避免歧义）：
#   clean      : MODE=delete|archive
#   watch_wave : MODE=batch|live
#   compliance : SUITE=run|all|compile
MODE            ?=
SUITE           ?=

# clean
SCOPE           ?= full
DRY_RUN         ?= 0
FORCE           ?= 0

# 仿真器命令
VCS  := vcs
IRUN := irun

# NC UVM-1.2 源（由 NC_INSTALL 派生；NC_INSTALL 在 env.mk 设）
NC_UVM_HOME ?= $(NC_INSTALL)/tools/methodology/UVM/CDNS-1.2

# ============================================================
# 覆盖率配置（对齐 lowRISC Ibex：line+tgl+assert+fsm+branch；dut-only scope）
# ============================================================
VCS_COV_METRICS := line+tgl+assert+fsm+branch
VCS_COV_HIER    := $(TB_DIR)/cover.cfg
VCS_FSM_CFG     := $(TB_DIR)/cov_fsm.cfg
VCS_FSM_RESET_FILTER := $(TB_DIR)/cov_fsm_reset_filter.cfg
# -cm_tgl structarr 在 VCS 2018 是 LCA 选项，需 -lca；若 license 不允许，删 structarr 与 -lca 即可
VCS_COMPILE_COV_OPTS := -lca \
                        -cm $(VCS_COV_METRICS) -cm_dir $(BUILD_SUBDIR)/cov \
                        -cm_hier $(VCS_COV_HIER) \
                        -cm_tgl portsonly -cm_tgl structarr \
                        -cm_report noinitial -cm_seqnoconst \
                        -cm_fsmcfg $(VCS_FSM_CFG) \
                        -cm_fsmresetfilter $(VCS_FSM_RESET_FILTER) \
                        -cm_fsmopt report2StateFsms+allowTmp+reportvalues+reportWait+upto64
VCS_RUN_COV_OPTS := -cm $(VCS_COV_METRICS) -cm_dir $(BUILD_SUBDIR)/cov \
                    -cm_name $(TEST)_$(SEED) +enable_eh2_fcov=1

# NC(irun) 覆盖率：用 cov_full_nc.ccf 限定 dut-only scope（cover.cfg 等价物）
NC_COV_CCF      := $(TB_DIR)/cov_full_nc.ccf
NC_COMPILE_COV_OPTS := -coverage all -covworkdir $(BUILD_SUBDIR)/cov_work -covoverwrite -covdut core_eh2_tb_top -covfile $(NC_COV_CCF)

# testlist 路由：directed / cosim / riscvdv(默认)
TESTLIST_PATH := $(if $(filter directed,$(TESTLIST)),$(TB_DIR)/directed_tests/directed_testlist.yaml,\
                 $(if $(filter cosim,$(TESTLIST)),$(TB_DIR)/directed_tests/cosim_testlist.yaml,\
                 $(DV_EXT_DIR)/testlist.yaml))

# ============================================================
# .PHONY
# ============================================================
.PHONY: help asm whisper cac compile compile_vcs compile_nc \
        smoke regress compliance watch_wave signoff clean

# ============================================================
# help（精简版；完整文档待补）
# ============================================================
define HELP_TEXT

EH2 Cosim 验证平台 — Makefile 入口（cosim-only 精简版）
默认仿真器 = VCS；NC/irun 为备选（SIMULATOR=nc）。产物隔离在 build/<target>_<simulator>/。
机器相关路径在 env.mk 设置（参考 env.mk.example）。

[ 验证主线 ]
  make signoff            cosim sign-off（默认 PROFILE=full：smoke/directed/cosim/riscvdv/compliance + 覆盖率）
                          变量：SIMULATOR=vcs|nc  PROFILE=full|cosim|quick  GATE_ONLY=0|1  COV=0|1  PARALLEL=N
  make smoke              1 个冒烟测试（自动 compile+asm），<2 分钟
  make regress            回归；TESTLIST=riscvdv|directed|cosim  TEST=<单测>  ITERATIONS=N  PARALLEL=N
  make compliance         RISC-V compliance 套件；SUITE=run|all|compile

[ 构建 ]
  make asm                编译 tests/asm/*.S → hex/elf/dis
  make whisper            在 vendor/whisper 内构建 VeeR-ISS server
  make cac                编译 cosim-arch-checker / Whisper DPI 库
  make compile            编译 UVM testbench（SIMULATOR=vcs→simv / nc→INCA_libs）；COV=0|1  WAVES=0|1

[ 看波形 / 清理 ]
  make watch_wave TEST=<n>  看波形 —— 三形式 / 两模式：
                          MODE=batch(默认,跑完离线看)：SIMULATOR=vcs→Verdi ；SIMULATOR=nc→SimVision
                          MODE=live (NC 边仿真边看，ncsim+SimVision GUI；需 X11)
  make clean              清产物，默认保留签发证据+缓存；SCOPE=full|build|cov|vcs|nc|asm|docs  FORCE=1 彻底删  MODE=archive 归档

[ 常用变量 ]
  SIMULATOR=vcs|nc   COV=0|1   WAVES=0|1   PARALLEL=N   SEED=N   SIM_OPTS="<plusargs>"
  TESTLIST=riscvdv|directed|cosim   PROFILE=full|cosim|quick   GATE_ONLY=0|1

endef
export HELP_TEXT

help:
	@echo "$$HELP_TEXT"

# ============================================================
# build 目录
# ============================================================
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# ============================================================
# lockstep — 编译 CAC / Whisper DPI
# ============================================================
CAC_DIR := vendor/cosim-arch-checker
LIBCAC_COSIM := $(CAC_DIR)/lib/libcosim.so
CAC_CXX ?= g++
CAC_NUM_HARTS ?= $(RVVI_NHART)
CAC_CXXFLAGS ?= -std=c++17 -Wall -Werror -fpic -Imon/mon_instr -Ibridge/std -Ibridge -Ienv -Ibridge/whisper/svdpi -Ibridge/whisper -I../rvvi/include/host/rvvi -Icac/src/lib -Icac/src -DCONFIG=MediumBoomVecConfig -DCAC_NUM_HARTS=$(CAC_NUM_HARTS)
CAC_LD_LIBRARY_PATH ?= $(dir $(CAC_CXX))../lib64:$(dir $(CAC_CXX))../lib
WHISPER_LD_LIBRARY_PATH ?=
LOCKSTEP_LD_LIBRARY_PATH := $(CURDIR)/$(CAC_DIR)/lib:$(CAC_LD_LIBRARY_PATH)$(if $(WHISPER_LD_LIBRARY_PATH),:$(WHISPER_LD_LIBRARY_PATH),)
WHISPER_PATH ?= vendor/whisper/build-Linux/whisper
LOCKSTEP_WHISPER_JSON ?= $(if $(IS_DUAL_THREAD_CONFIG),config/whisper_default_mt_lockstep.json,config/whisper_default_lockstep.json)
WHISPER_JSON ?= $(if $(filter 1,$(LOCKSTEP_WHISPER)),$(LOCKSTEP_WHISPER_JSON),$(SNAPSHOTS)/whisper.json)
CAC_CSR_MASK_FILE ?= config/cac_csr_masks.txt
LOCKSTEP_CSR_MASK_FILE := $(CURDIR)/$(CAC_CSR_MASK_FILE)
LOCKSTEP_SIM_OPTS := +cosim_arch_checker +whisper_path=$(WHISPER_PATH) +whisper_json_path=$(WHISPER_JSON)

RISCV_PREFIX   ?= riscv32-unknown-elf-
RISCV_TESTS_FW ?= $(CURDIR)/vendor/riscv-tests
RISCV_COMPLIANCE_FW ?= $(RISCV_TESTS_FW)
WHISPER_CXX ?=
WHISPER_BOOST_ROOT ?=

# svdpi.h 来源：优先 NC，其次 VCS；可用 SVDPI_INCLUDE=<dir> 覆盖
NC_INSTALL    ?=
SVDPI_INCLUDE ?= $(firstword \
  $(wildcard $(NC_INSTALL)/tools/include/svdpi.h) \
  $(wildcard $(VCS_HOME)/include/svdpi.h))
SVDPI_INCLUDE_DIR := $(dir $(SVDPI_INCLUDE))

whisper:
	@echo "=== [whisper] build vendor/whisper (chipsalliance/VeeR-ISS HEAD) ==="
	@test -n "$(WHISPER_CXX)" || { echo "ERROR: 在 env.mk 设 WHISPER_CXX（devtoolset-9 g++）"; exit 1; }
	@test -n "$(WHISPER_BOOST_ROOT)" || { echo "ERROR: 在 env.mk 设 WHISPER_BOOST_ROOT"; exit 1; }
	@cd vendor/whisper && $(MAKE) -f GNUmakefile CXX=$(WHISPER_CXX) \
	  BOOST_ROOT=$(WHISPER_BOOST_ROOT) STATIC_LINK=0 -j4 build-Linux/whisper
	@test -x vendor/whisper/build-Linux/whisper && echo "=== [whisper] done: $(WHISPER_PATH) ==="

cac:
	@echo "=== [cac] 构建 cosim-arch-checker DPI (CXX=$(CAC_CXX)) ==="
	$(MAKE) -C $(CAC_DIR) all CC=$(CAC_CXX) CFLAGS='$(CAC_CXXFLAGS)'

# ============================================================
# asm — 编译 tests/asm/*.S → hex/elf/dis
# ============================================================
asm:
	@echo "=== [asm] 构建 tests/asm/*.hex ==="
	@$(MAKE) --no-print-directory -C $(ASM_DIR) all
	@echo "=== [asm] 完成 ==="

# ============================================================
# compile — RTL/TB 编译（VCS / NC）
# ============================================================
compile: compile_$(SIMULATOR)

compile_vcs: cac | $(BUILD_DIR)
	@echo "=== [compile] VCS UVM testbench (BUILD_SUBDIR=$(BUILD_SUBDIR)) ==="
	@mkdir -p $(BUILD_SUBDIR)
	$(VCS) -full64 -assert svaext -sverilog \
	  -ntb_opts uvm-1.2 +error+500 \
	  +define+GTLSIM +define+UVM_VERDI_COMPWAVE \
	  +define+RVVI_NHART=$(RVVI_NHART) \
	  $(DEFINES) \
	  +incdir+$(SNAPSHOTS) \
	  $(SNAPSHOTS)/eh2_pdef.vh \
	  +incdir+$(TB_DIR)/common/axi4_agent \
	  +incdir+$(TB_DIR)/common/trace_agent \
	  +incdir+$(TB_DIR)/common/irq_agent \
	  +incdir+$(TB_DIR)/common/jtag_agent \
	  -f $(RTL_F) -f $(SHARED_F) -f $(TB_F) \
	  -top core_eh2_tb_top \
	  $(CURDIR)/$(LIBCAC_COSIM) \
	  -Mdir=$(BUILD_SUBDIR)/csrc -o $(BUILD_SUBDIR)/simv \
	  -l $(BUILD_SUBDIR)/compile.log \
	  -timescale=1ns/1ps -debug_access+all -kdb \
	  $(if $(filter 1,$(COV)),$(VCS_COMPILE_COV_OPTS),)
	@echo "=== [compile] simv 完成: $(BUILD_SUBDIR)/simv ==="

compile_nc: cac | $(BUILD_DIR)
	@echo "=== [compile] NC (irun) UVM testbench (BUILD_SUBDIR=$(BUILD_SUBDIR)) ==="
	@mkdir -p $(BUILD_SUBDIR)
	$(IRUN) -64bit -uvmhome $(NC_UVM_HOME) -sv -assert \
	  -vlog_ext +.vh +define+UVM_NO_DEPRECATED +define+GTLSIM \
	  +define+RVVI_NHART=$(RVVI_NHART) \
	  $(DEFINES) \
	  +incdir+$(SNAPSHOTS) \
	  $(SNAPSHOTS)/eh2_pdef.vh \
	  +incdir+$(TB_DIR)/common/axi4_agent \
	  +incdir+$(TB_DIR)/common/trace_agent \
	  +incdir+$(TB_DIR)/common/irq_agent \
	  +incdir+$(TB_DIR)/common/jtag_agent \
	  -f $(RTL_F) -f $(SHARED_F) -f $(TB_F) \
	  -top core_eh2_tb_top -elaborate \
	  -nclibdirname $(BUILD_SUBDIR)/INCA_libs \
	  -access +rwc -timescale 1ns/1ps -errormax 500 \
	  -sv_lib $(CURDIR)/$(LIBCAC_COSIM) \
	  -l $(BUILD_SUBDIR)/compile.log \
	  $(if $(filter 1,$(COV)),$(NC_COMPILE_COV_OPTS),)
	@echo "=== [compile] NC 完成: $(BUILD_SUBDIR)/INCA_libs ==="

# ============================================================
# 仿真 — smoke / regress / compliance
# ============================================================
smoke: asm
	@$(MAKE) --no-print-directory compile BUILD_SUBDIR=$(BUILD_DIR)/smoke_$(SIMULATOR)
	@echo "=== [smoke] 运行 smoke 测试 ==="
	CAC_CSR_MASK_FILE=$(if $(filter 1,$(LOCKSTEP_WHISPER)),$(LOCKSTEP_CSR_MASK_FILE),) LD_LIBRARY_PATH=$(if $(filter 1,$(LOCKSTEP_WHISPER)),$(LOCKSTEP_LD_LIBRARY_PATH):,)$$LD_LIBRARY_PATH python3 $(SCRIPTS_DIR)/run_regress.py \
	  --test smoke --binary $(ASM_DIR)/smoke.hex \
	  --simulator $(SIMULATOR) --seed 1 \
	  --rtl-test core_eh2_base_test \
	  --sim-opts "$(SIM_OPTS) $(LOCKSTEP_SIM_OPTS) +rvvi_elf=$(ASM_DIR)/smoke.elf +whisper_server_file=$(BUILD_DIR)/smoke_$(SIMULATOR)/smoke_s1/whisper_connect" \
	  --build-dir $(BUILD_DIR)/smoke_$(SIMULATOR) \
	  --output $(BUILD_DIR)/smoke_$(SIMULATOR) \
	  $(if $(filter 1,$(COV)),--coverage,) \
	  $(if $(filter 1,$(WAVES)),--waves,)
	@echo "=== [smoke] 完成 ==="

regress:
	@$(MAKE) --no-print-directory compile BUILD_SUBDIR=$(BUILD_DIR)/regress_$(SIMULATOR)
	@echo "=== [regress] testlist=$(TESTLIST) parallel=$(PARALLEL) iter=$(if $(ITERATIONS),$(ITERATIONS),testlist) ==="
	CAC_CSR_MASK_FILE=$(if $(filter 1,$(LOCKSTEP_WHISPER)),$(LOCKSTEP_CSR_MASK_FILE),) LD_LIBRARY_PATH=$(if $(filter 1,$(LOCKSTEP_WHISPER)),$(LOCKSTEP_LD_LIBRARY_PATH):,)$$LD_LIBRARY_PATH python3 $(SCRIPTS_DIR)/run_regress.py \
	  $(if $(TEST),--test $(TEST) --testlist $(TESTLIST_PATH),--testlist $(TESTLIST_PATH)) \
	  --simulator $(SIMULATOR) --seed $(SEED) \
	  $(if $(ITERATIONS),--iterations $(ITERATIONS),) --parallel $(PARALLEL) \
	  --sim-opts "$(SIM_OPTS) $(LOCKSTEP_SIM_OPTS)" \
	  --build-dir $(BUILD_DIR)/regress_$(SIMULATOR) \
	  --output $(if $(OUT),$(OUT),$(BUILD_DIR)/regress_$(SIMULATOR)) \
	  $(if $(filter riscvdv,$(TESTLIST)),$(if $(TEST),,--min-passed 50),) \
	  $(if $(filter 1,$(COV)),--coverage,) \
	  $(if $(filter 1,$(WAVES)),--waves,)
	@echo "=== [regress] 完成 ==="

compliance:
	@echo "=== [compliance] suite=$(or $(SUITE),run) ==="
	+@if [ "$(SUITE)" != "compile" ]; then \
	  $(MAKE) --no-print-directory compile BUILD_SUBDIR=$(COMPLIANCE_BUILD_SUBDIR); \
	fi
	+@$(MAKE) -C dv/uvm/riscv_compliance \
	  RISCV_COMPLIANCE_FW="$(RISCV_COMPLIANCE_FW)" \
	  RISCV_TESTS_FW="$(RISCV_TESTS_FW)" \
	  RISCV_PREFIX="$(RISCV_PREFIX)" \
	  NC_INSTALL="$(NC_INSTALL)" \
	  SIMULATOR="$(SIMULATOR)" \
	  BUILD_DIR="$(CURDIR)/$(COMPLIANCE_BUILD_SUBDIR)" \
	  SIMV="$(COMPLIANCE_SIMV)" \
	  $(if $(filter all,$(SUITE)),compliance-all,$(if $(filter compile,$(SUITE)),compliance-compile,compliance))

# ============================================================
# watch_wave — 看波形：三形式 / 两模式
#   MODE=batch(默认)：跑完离线看  —— SIMULATOR=vcs→Verdi(FSDB) / SIMULATOR=nc→SimVision(SHM)
#   MODE=live        ：NC 边仿真边看（ncsim + SimVision GUI，强制 NC，需 X11）
#   TEST 必填（读 tests/asm/<TEST>.hex）
# ============================================================
ifeq ($(MODE),live)
watch_wave: asm cac
	@if [ -z "$(TEST)" ]; then echo "ERROR: 必须指定 TEST=<name>，例：make watch_wave TEST=smoke MODE=live"; exit 1; fi
	@echo "=== [watch_wave] 形式③ NC 边仿真边看 TEST=$(TEST)（需 X11 forwarding）==="
	@mkdir -p $(BUILD_DIR)/watch_$(TEST)_nc/$(TEST)_s1
	irun -64bit -uvmhome $(NC_UVM_HOME) -sv -assert \
	  -vlog_ext +.vh +define+UVM_NO_DEPRECATED +define+GTLSIM \
	  +define+RVVI_NHART=$(RVVI_NHART) \
	  $(DEFINES) +incdir+$(SNAPSHOTS) $(SNAPSHOTS)/eh2_pdef.vh \
	  +incdir+$(TB_DIR)/common/axi4_agent +incdir+$(TB_DIR)/common/trace_agent \
	  +incdir+$(TB_DIR)/common/irq_agent +incdir+$(TB_DIR)/common/jtag_agent \
	  -f $(RTL_F) -f $(SHARED_F) -f $(TB_F) -top core_eh2_tb_top \
	  -nclibdirname $(BUILD_DIR)/watch_$(TEST)_nc/INCA_libs \
	  -access +rwc -timescale 1ns/1ps -errormax 500 \
	  -sv_lib $(CURDIR)/$(LIBCAC_COSIM) \
	  +UVM_TESTNAME=core_eh2_base_test +bin=$(ASM_DIR)/$(TEST).hex \
	  +seed=1 +timeout_ns=$(TIMEOUT_NS) \
	  +rvvi_elf=$(ASM_DIR)/$(TEST).elf \
	  -l $(BUILD_DIR)/watch_$(TEST)_nc/$(TEST)_s1/sim.log \
	  -gui -input $(TB_DIR)/nc_waves_interactive.tcl
	@echo "=== [watch_wave] live 退出 ==="
else
watch_wave: asm
	@if [ -z "$(TEST)" ]; then echo "ERROR: 必须指定 TEST=<name>，例：make watch_wave TEST=smoke"; exit 1; fi
	@echo "=== [watch_wave] 形式①/② 离线 dump+查看 SIMULATOR=$(SIMULATOR) TEST=$(TEST) ==="
	@$(MAKE) --no-print-directory compile BUILD_SUBDIR=$(BUILD_DIR)/watch_$(TEST)_$(SIMULATOR) WAVES=1
	python3 $(SCRIPTS_DIR)/run_regress.py \
	  --test $(TEST) --binary $(ASM_DIR)/$(TEST).hex \
	  --simulator $(SIMULATOR) --seed 1 --rtl-test core_eh2_base_test \
	  --sim-opts "$(SIM_OPTS) +rvvi_elf=$(ASM_DIR)/$(TEST).elf +rvvi_trace_file=$(BUILD_DIR)/watch_$(TEST)_$(SIMULATOR)/$(TEST)_s1/rvvi_trace.log" \
	  --build-dir $(BUILD_DIR)/watch_$(TEST)_$(SIMULATOR) \
	  --output $(BUILD_DIR)/watch_$(TEST)_$(SIMULATOR) --waves
	@if [ "$(SIMULATOR)" = "vcs" ]; then \
	  echo "启动 Verdi 看 FSDB..."; \
	  verdi -ssf $(BUILD_DIR)/watch_$(TEST)_vcs/$(TEST)_s1/waves.fsdb & \
	else \
	  echo "启动 SimVision 看 SHM..."; \
	  simvision $(BUILD_DIR)/watch_$(TEST)_nc/$(TEST)_s1/waves.shm & \
	fi
endif

# ============================================================
# signoff — cosim sign-off（stage: smoke/directed/cosim/riscvdv/compliance + 覆盖率）
# ============================================================
signoff:
	@if [ "$(SIMULATOR)" != "vcs" ] && [ "$(SIMULATOR)" != "nc" ]; then \
	  echo "ERROR: signoff 仅支持 SIMULATOR=vcs (默认) 或 nc (当前 $(SIMULATOR))。"; exit 1; fi
	@$(if $(filter 1,$(GATE_ONLY)),,$(MAKE) --no-print-directory asm)
	@$(if $(filter 1,$(GATE_ONLY)),,$(MAKE) --no-print-directory compile BUILD_SUBDIR=$(SIGNOFF_OUT) COV=$(COV))
	@echo "=== [signoff] profile=$(PROFILE) gate_only=$(GATE_ONLY) out=$(SIGNOFF_OUT) ==="
	CAC_CSR_MASK_FILE=$(if $(filter 1,$(LOCKSTEP_WHISPER)),$(LOCKSTEP_CSR_MASK_FILE),) LD_LIBRARY_PATH=$(if $(filter 1,$(LOCKSTEP_WHISPER)),$(LOCKSTEP_LD_LIBRARY_PATH):,)$$LD_LIBRARY_PATH python3 $(SCRIPTS_DIR)/signoff.py \
	  --profile $(PROFILE) --simulator $(SIMULATOR) \
	  --seed $(SEED) --parallel $(PARALLEL) --output $(SIGNOFF_OUT) \
	  $(if $(filter 1,$(GATE_ONLY)),--gate-only,) \
	  $(if $(SIGNOFF_ITERATIONS),--iterations $(SIGNOFF_ITERATIONS),) \
	  $(if $(filter 1,$(COV)),--coverage --min-line-coverage $(SIGNOFF_MIN_LINE_COV) --min-functional-coverage $(SIGNOFF_MIN_FUNCTIONAL_COV),) \
	  $(if $(filter 1,$(SIGNOFF_ALLOW_WARNINGS)),--allow-warnings,) \
	  $(if $(filter 1,$(LOCKSTEP_WHISPER)),--lockstep-whisper --whisper-path $(WHISPER_PATH) --whisper-json $(WHISPER_JSON),) \
	  $(if $(filter 1,$(WAVES)),--waves,) \
	  $(SIGNOFF_OPTS)
	@$(if $(filter 1,$(CLEANUP)),bash scripts/clean_workspace.sh --lck-only 2>/dev/null || true,)
	@echo "=== [signoff] 完成。报告：$(SIGNOFF_OUT)/report.html ==="

# ============================================================
# clean — 默认保留签发证据+长耗时缓存；SCOPE/MODE/FORCE 控制
# ============================================================
clean:
	@echo "=== [clean] scope=$(SCOPE) mode=$(or $(MODE),delete) force=$(FORCE) dry_run=$(DRY_RUN) ==="
	@if [ "$(MODE)" = "archive" ]; then \
	  bash scripts/clean_workspace.sh $(if $(filter 1,$(DRY_RUN)),--dry-run,); exit 0; fi; \
	case "$(SCOPE)" in \
	  cov) \
	    find $(BUILD_DIR) -mindepth 2 -maxdepth 2 \
	      \( -name 'cov.vdb' -o -name 'cov' -o -name 'cov_report' -o -name 'simv.vdb' \
	         -o -name 'cov_work' -o -name 'cov_merged' \) -exec rm -rf {} + 2>/dev/null || true; \
	    echo "[clean] 已清覆盖率数据库" ;; \
	  vcs) \
	    find $(BUILD_DIR) -mindepth 1 -maxdepth 1 -name '*_vcs' -exec rm -rf {} + 2>/dev/null || true; \
	    echo "[clean] 已清 *_vcs（保留 NC）" ;; \
	  nc) \
	    find $(BUILD_DIR) -mindepth 1 -maxdepth 1 -name '*_nc' -exec rm -rf {} + 2>/dev/null || true; \
	    echo "[clean] 已清 *_nc（保留 VCS）" ;; \
	  asm) \
	    $(MAKE) --no-print-directory -C $(ASM_DIR) clean; \
	    echo "[clean] 已清 tests/asm 产物" ;; \
	  docs) \
	    rm -rf docs/build; echo "[clean] 已清 docs 产物" ;; \
	  build) \
	    if [ "$(FORCE)" = "1" ]; then rm -rf $(BUILD_DIR); mkdir -p $(BUILD_DIR); \
	      echo "[clean] FORCE=1：已彻底清 $(BUILD_DIR)/（含 r3b_final/r4a_final）"; \
	    else \
	      if [ -d $(BUILD_DIR) ]; then find $(BUILD_DIR) -mindepth 1 -maxdepth 1 $(CLEAN_PRESERVE_FIND) -exec rm -rf {} + ; fi; \
	      mkdir -p $(BUILD_DIR); \
	      echo "[clean] 已清 build/ 可再生产物（保留签发证据+缓存）"; fi ;; \
	  full|*) \
	    if [ "$(FORCE)" = "1" ]; then rm -rf $(BUILD_DIR); \
	      echo "[clean] FORCE=1：连保护项一起删"; \
	    else \
	      if [ -d $(BUILD_DIR) ]; then find $(BUILD_DIR) -mindepth 1 -maxdepth 1 $(CLEAN_PRESERVE_FIND) -exec rm -rf {} + ; fi; fi; \
	    $(MAKE) --no-print-directory -C $(ASM_DIR) clean 2>/dev/null || true; \
	    rm -rf out/* .pytest_cache csrc; \
	    rm -f top.vcd tr_db.log ucli.key vc_hdrs.h CDS.log *.fsdb *.fss *.lck *.svf default.svf command.log; \
	    rm -rf verdiLog novas_* DVEfiles INCA_libs cov_work; \
	    rm -f irun.log irun.history ncsim.log .simvision stack.info.* stack_*.log; \
	    mkdir -p out $(BUILD_DIR); \
	    if [ "$(FORCE)" = "1" ]; then echo "[clean] 已彻底清理（FORCE=1）"; \
	    else echo "[clean] 已清可再生产物（保留 r3b_final/r4a_final 等证据；彻底删加 FORCE=1）"; fi ;; \
	esac
