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
CLEAN_PRESERVE_BUILD := r3b_final r4a_final nightly compliance_tb_compile.log \
                        signoff_p63_release signoff_p44_masked_clean signoff_release
CLEAN_PRESERVE_FIND  := $(foreach n,$(CLEAN_PRESERVE_BUILD),! -name '$(n)') ! -name 'archive_signoffs_*'

# ============================================================
# 用户可覆盖变量（详见 make help）
# ============================================================
CONFIG          ?= default
RISCV_DV_CONFIG ?= $(CONFIG)
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
.PHONY: help asm whisper cac check_nc_env compile compile_vcs compile_nc \
        smoke regress compliance watch_wave signoff clean

# ============================================================
# help
# ============================================================
define HELP_TEXT

EH2 Cosim 验证平台 — 顶层 Makefile 使用说明

定位：
  这是 RVVI-API + Whisper lockstep 协同验证平台的顶层入口。
  默认使用 VCS；NC/irun 为备选。机器相关路径只放在 env.mk。

第一次使用：
  1. cp env.mk.example env.mk
  2. 编辑 env.mk，至少设置：
       CAC_CXX             C++17 g++，用于构建 cosim-arch-checker DPI
       WHISPER_CXX         C++17 g++，用于构建 vendor/whisper
       WHISPER_BOOST_ROOT  Boost 安装根目录
       NC_INSTALL          Incisive/irun 路径，提供 svdpi.h 与 UVM-1.2
       VCS_HOME            可选，作为 svdpi.h fallback
       RISCV_PREFIX        可选，默认 riscv32-unknown-elf-
  3. make whisper
  4. make cac
  5. make smoke LOCKSTEP_WHISPER=1

Target 总览：
  make help
      打印本帮助，不构建、不仿真。

  make asm
      编译 tests/asm/*.S，生成 smoke 等手写测试的 .elf/.hex/.dis。
      常见用途：
        make asm
        make clean SCOPE=asm && make asm

  make whisper
      在 vendor/whisper 内构建 VeeR-ISS/Whisper server。
      依赖 env.mk 中的 WHISPER_CXX 与 WHISPER_BOOST_ROOT。
      产物：
        vendor/whisper/build-Linux/whisper
      示例：
        make whisper
        make whisper WHISPER_CXX=<gcc9-root>/bin/g++ WHISPER_BOOST_ROOT=<boost-root>

  make cac
      构建 cosim-arch-checker DPI 库 libcosim.so，内含 RVVI-API facade
      和 Whisper 后端。
      关键变量：
        CAC_CXX            C++17 编译器，默认 g++
        CAC_NUM_HARTS      checker hart 数，默认随 CONFIG 推导
        CAC_CXXFLAGS       传给 CAC 构建的 C++ flags
      产物：
        vendor/cosim-arch-checker/lib/libcosim.so
      示例：
        make cac CAC_CXX=$$CAC_CXX
        make -C vendor/cosim-arch-checker test CC=$$CAC_CXX

  make compile
      编译 RTL + UVM testbench。不会运行测试。
      SIMULATOR=vcs 时调用 compile_vcs，生成 build/compile_vcs/simv。
      SIMULATOR=nc  时调用 compile_nc，生成 build/compile_nc/INCA_libs。
      关键变量：
        SIMULATOR=vcs|nc   选择仿真器，默认 vcs
        CONFIG=default|dual_thread|default_mt
                            default 为 1 hart；dual_thread/default_mt 为 2 hart
        COV=0|1             是否编译覆盖率，默认 1
        WAVES=0|1           是否保留波形相关编译能力，默认 0
        BUILD_SUBDIR=dir    覆盖编译产物目录
      示例：
        make compile SIMULATOR=vcs COV=0
        make compile SIMULATOR=nc COV=0
        make compile CONFIG=dual_thread BUILD_SUBDIR=build/compile_dual_vcs

  make compile_vcs
      明确走 VCS 编译入口。通常直接用 make compile SIMULATOR=vcs。
      示例：
        make compile_vcs COV=0 BUILD_SUBDIR=build/my_vcs

  make compile_nc
      明确走 NC/irun 编译入口。通常直接用 make compile SIMULATOR=nc。
      依赖 env.mk 中的 NC_INSTALL。
      示例：
        make compile_nc COV=0 BUILD_SUBDIR=build/my_nc

  make smoke
      最小冒烟：自动 make asm、make compile，然后运行 tests/asm/smoke。
      默认启用 LOCKSTEP_WHISPER=1，经 RVVI-API scoreboard + CAC + Whisper 比对。
      关键变量：
        SIMULATOR=vcs|nc
        COV=0|1
        WAVES=0|1
        SIM_OPTS="<plusargs>"     追加传给仿真的 plusargs
        LOCKSTEP_WHISPER=0|1      是否启用 Whisper lockstep，默认 1
      示例：
        make smoke LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=0
        make smoke SIM_OPTS="+rvvi_debug_poke" COV=0
        make smoke CONFIG=dual_thread SIM_OPTS="+rvvi_nhart=2" COV=0

  make regress
      跑 testlist 回归：directed、cosim 或 riscvdv。
      会先编译 build/regress_<simulator>/。
      关键变量：
        TESTLIST=riscvdv|directed|cosim
                            默认 riscvdv
        TEST=<name>         只跑单个测试；为空则跑整个 testlist
        ITERATIONS=N        覆盖 testlist 中的迭代数
        SEED=N              起始 seed，默认 1
        PARALLEL=N          并行数，默认 4
        OUT=dir             覆盖结果输出目录
        SIM_OPTS="<args>"   追加仿真 plusargs
        COV=0|1             是否收覆盖率
        WAVES=0|1           是否 dump 波形
      示例：
        make regress TESTLIST=cosim COV=0 PARALLEL=1 OUT=build/cosim_smoke
        make regress TESTLIST=directed TEST=hello_world COV=0
        make regress TESTLIST=riscvdv TEST=riscv_interrupt_test ITERATIONS=3 PARALLEL=1 COV=0 OUT=build/irq
        make regress TESTLIST=riscvdv PARALLEL=8 COV=1
        make regress CONFIG=dual_thread TESTLIST=cosim OUT=build/dual_cosim

  make compliance
      跑 vendored riscv-tests compliance 套件。
      关键变量：
        SUITE=run|all|compile
          run 或空：默认 compliance 子集
          all：      compliance-all
          compile：  只编译 compliance 测试，不跑仿真
        RISCV_PREFIX          RISC-V GCC 前缀，默认 riscv32-unknown-elf-
        RISCV_TESTS_FW        riscv-tests 根目录，默认 vendor/riscv-tests
        RISCV_COMPLIANCE_FW   compliance framework 根目录，默认同 RISCV_TESTS_FW
        SIMULATOR=vcs|nc
      示例：
        make compliance SIMULATOR=vcs
        make compliance SUITE=all SIMULATOR=vcs
        make compliance SUITE=compile RISCV_PREFIX=<riscv-toolchain>/bin/riscv32-unknown-elf-

  make watch_wave TEST=<name>
      跑 tests/asm/<TEST>.hex 并打开波形。
      TEST 必填，读取 tests/asm/<TEST>.hex 与 tests/asm/<TEST>.elf。
      模式：
        MODE=batch 或空：
          离线跑完再看波形。
          SIMULATOR=vcs 打开 Verdi FSDB；SIMULATOR=nc 打开 SimVision SHM。
        MODE=live：
          NC/irun GUI 边仿真边看，需 X11。
      关键变量：
        TEST=<name>       必填，例如 smoke
        SIMULATOR=vcs|nc  batch 模式有效
        TIMEOUT_NS=N      live 模式超时，默认 10000000
        SIM_OPTS="<args>" batch 模式追加 plusargs
      示例：
        make watch_wave TEST=smoke SIMULATOR=vcs
        make watch_wave TEST=smoke SIMULATOR=nc
        make watch_wave TEST=smoke MODE=live

  make signoff
      签核入口。默认 PROFILE=full，包含 smoke、directed、cosim、
      riscvdv、compliance，并在 COV=1 时 gate line/functional coverage。
      关键变量：
        PROFILE=quick|cosim|riscvdv_smoke|nightly|full
          quick：        smoke + directed
          cosim：        smoke + cosim
          riscvdv_smoke：riscvdv stage
          nightly：      smoke + directed + cosim + riscvdv
          full：         smoke + directed + cosim + riscvdv + compliance
        SIMULATOR=vcs|nc
        COV=0|1
        PARALLEL=N
        SEED=N
        SIGNOFF_OUT=dir
        SIGNOFF_ITERATIONS=N
                            覆盖非 smoke stage 的每测试迭代数
        GATE_ONLY=0|1       只评估已有 stage 结果，不重新跑仿真
        SIGNOFF_OPTS="..."  透传给 signoff.py
        SIGNOFF_MIN_LINE_COV=N
        SIGNOFF_MIN_FUNCTIONAL_COV=N
        SIGNOFF_ALLOW_WARNINGS=0|1
        CLEANUP=0|1         signoff 后清理 .lck 等临时文件
      示例：
        make signoff PROFILE=full LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=1 SIGNOFF_OUT=build/signoff_release
        make signoff PROFILE=cosim COV=0 PARALLEL=1 SIGNOFF_OUT=build/signoff_cosim
        make signoff PROFILE=quick COV=0 SIGNOFF_ITERATIONS=1
        make signoff GATE_ONLY=1 SIGNOFF_OUT=build/signoff_release
        make signoff PROFILE=full COV=1 SIGNOFF_OPTS="--no-fail-on-skip-in-signoff --timeout-s 14400"

  make clean
      清理可再生产物。默认保留长耗时缓存和签发证据。
      关键变量：
        SCOPE=full|build|cov|vcs|nc|asm|docs
          full：  默认，清 build 可再生产物、asm 产物、常见仿真临时文件
          build： 清 build/ 下可再生产物，保留保护项
          cov：   只清覆盖率数据库
          vcs：   只清 build/*_vcs
          nc：    只清 build/*_nc
          asm：   只清 tests/asm 产物
          docs：  只清 docs/build
        FORCE=0|1           1 表示连保护项一起删除，谨慎使用
        MODE=delete|archive 默认 delete；archive 调 scripts/clean_workspace.sh
        DRY_RUN=0|1         MODE=archive 时预览
      示例：
        make clean
        make clean SCOPE=cov
        make clean SCOPE=vcs
        make clean SCOPE=build FORCE=1
        make clean MODE=archive DRY_RUN=1

常用变量速查：
  CONFIG=default|dual_thread|default_mt
      选择 RTL snapshot 和 hart 数。dual_thread/default_mt 会使用
      rtl/snapshots/default_mt，并令 RVVI_NHART=2。

  LOCKSTEP_WHISPER=0|1
      默认 1。为 1 时仿真 plusargs 自动包含：
        +cosim_arch_checker
        +whisper_path=$(WHISPER_PATH)
        +whisper_json_path=$(WHISPER_JSON)
      同时设置 CAC_CSR_MASK_FILE 与 LD_LIBRARY_PATH。

  WHISPER_PATH=path
      Whisper 可执行文件路径，默认 vendor/whisper/build-Linux/whisper。

  WHISPER_JSON=path
      Whisper 配置 JSON。LOCKSTEP_WHISPER=1 时默认使用：
        default：     config/whisper_default_lockstep.json
        dual_thread： config/whisper_default_mt_lockstep.json

  CAC_CSR_MASK_FILE=path
      CAC CSR mask 文件，默认 config/cac_csr_masks.txt。

  SIM_OPTS="<plusargs>"
      追加仿真 plusargs。示例：
        SIM_OPTS="+rvvi_debug_poke"
        SIM_OPTS="+rvvi_nhart=2"

推荐工作流：
  # 一次性准备
  cp env.mk.example env.mk
  $$EDITOR env.mk
  make whisper
  make cac

  # 快速确认平台可用
  make smoke LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=0

  # 跑核心 cosim directed
  make regress TESTLIST=cosim LOCKSTEP_WHISPER=1 COV=0 PARALLEL=1 OUT=build/cosim

  # 跑一个 riscv-dv 测试
  make regress TESTLIST=riscvdv TEST=riscv_interrupt_test ITERATIONS=3 COV=0 OUT=build/irq

  # 发布级签核
  make signoff PROFILE=full LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=1 \
    SIGNOFF_OPTS="--no-fail-on-skip-in-signoff --timeout-s 14400" \
    SIGNOFF_OUT=build/signoff_release

更多背景：
  docs/architecture.md       架构与数据流
  docs/onboarding.md         接入新核 recipe
  docs/lockstep_whisper_phase6.md  最新发布证据

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
CAC_CXXFLAGS ?= -std=c++17 -Wall -Werror -fpic -Ibridge/std -Ibridge/whisper/svdpi -Ibridge/whisper -I../rvvi/include/host/rvvi -Icac/src/lib -Icac/src -DCONFIG=MediumBoomVecConfig -DCAC_NUM_HARTS=$(CAC_NUM_HARTS)
CAC_LD_LIBRARY_PATH ?= $(dir $(CAC_CXX))../lib64:$(dir $(CAC_CXX))../lib
WHISPER_TOOLCHAIN_ROOT := $(patsubst %/bin/,%,$(dir $(WHISPER_CXX)))
WHISPER_DERIVED_LD_LIBRARY_PATH := $(if $(WHISPER_BOOST_ROOT),$(WHISPER_BOOST_ROOT)/lib,)$(if $(WHISPER_CXX),$(if $(WHISPER_BOOST_ROOT),:,)$(WHISPER_TOOLCHAIN_ROOT)/lib64:$(WHISPER_TOOLCHAIN_ROOT)/lib,)
WHISPER_LD_LIBRARY_PATH ?= $(WHISPER_DERIVED_LD_LIBRARY_PATH)
LOCKSTEP_LD_LIBRARY_PATH := $(CURDIR)/$(CAC_DIR)/lib:$(CAC_LD_LIBRARY_PATH)$(if $(WHISPER_LD_LIBRARY_PATH),:$(WHISPER_LD_LIBRARY_PATH),)
WHISPER_PATH ?= vendor/whisper/build-Linux/whisper
LOCKSTEP_WHISPER_JSON ?= $(if $(IS_DUAL_THREAD_CONFIG),config/whisper_default_mt_lockstep.json,config/whisper_default_lockstep.json)
WHISPER_JSON ?= $(if $(filter 1,$(LOCKSTEP_WHISPER)),$(LOCKSTEP_WHISPER_JSON),$(SNAPSHOTS)/whisper.json)
CAC_CSR_MASK_FILE ?= config/cac_csr_masks.txt
LOCKSTEP_CSR_MASK_FILE := $(CURDIR)/$(CAC_CSR_MASK_FILE)
LOCKSTEP_SIM_OPTS := +cosim_arch_checker +whisper_path=$(WHISPER_PATH) +whisper_json_path=$(WHISPER_JSON)
SIM_ENV := CAC_CSR_MASK_FILE=$(if $(filter 1,$(LOCKSTEP_WHISPER)),$(LOCKSTEP_CSR_MASK_FILE),) \
           NC_INSTALL=$(NC_INSTALL) NC_UVM_HOME=$(NC_UVM_HOME) \
           LD_LIBRARY_PATH=$(if $(filter 1,$(LOCKSTEP_WHISPER)),$(LOCKSTEP_LD_LIBRARY_PATH):,)$$LD_LIBRARY_PATH

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

check_nc_env:
	@test -n "$(NC_INSTALL)" || { \
	  echo "ERROR: SIMULATOR=nc 需要在 env.mk 设置 NC_INSTALL=<Incisive安装根目录>。"; \
	  echo "       当前 NC_INSTALL 为空，导致 NC_UVM_HOME 展开为 $(NC_UVM_HOME)。"; \
	  echo "       可用 'which irun' 找到 irun，再取其上层安装根目录写入 env.mk。"; \
	  exit 1; \
	}
	@test -d "$(NC_UVM_HOME)" || { \
	  echo "ERROR: NC_UVM_HOME 不存在：$(NC_UVM_HOME)"; \
	  echo "       请检查 env.mk 中 NC_INSTALL 是否指向 Incisive 安装根目录。"; \
	  echo "       若本机 UVM 目录不在默认位置，可直接设置 NC_UVM_HOME=<UVM-1.2目录>。"; \
	  exit 1; \
	}

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

compile_nc: check_nc_env cac | $(BUILD_DIR)
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
	$(SIM_ENV) python3 $(SCRIPTS_DIR)/run_regress.py \
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
	$(SIM_ENV) python3 $(SCRIPTS_DIR)/run_regress.py \
	  $(if $(TEST),--test $(TEST) --testlist $(TESTLIST_PATH),--testlist $(TESTLIST_PATH)) \
	  --config $(RISCV_DV_CONFIG) \
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
watch_wave: check_nc_env asm cac
	@if [ -z "$(TEST)" ]; then echo "ERROR: 必须指定 TEST=<name>，例：make watch_wave TEST=smoke MODE=live"; exit 1; fi
	@echo "=== [watch_wave] 形式③ NC 边仿真边看 TEST=$(TEST)（需 X11 forwarding）==="
	@mkdir -p $(BUILD_DIR)/watch_$(TEST)_nc/$(TEST)_s1
	$(SIM_ENV) irun -64bit -uvmhome $(NC_UVM_HOME) -sv -assert \
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
	  $(if $(filter 1,$(LOCKSTEP_WHISPER)),$(LOCKSTEP_SIM_OPTS) +whisper_server_file=$(BUILD_DIR)/watch_$(TEST)_nc/$(TEST)_s1/whisper_connect,) \
	  -l $(BUILD_DIR)/watch_$(TEST)_nc/$(TEST)_s1/sim.log \
	  -gui -input $(TB_DIR)/nc_waves_interactive.tcl
	@echo "=== [watch_wave] live 退出 ==="
else
watch_wave: asm
	@if [ -z "$(TEST)" ]; then echo "ERROR: 必须指定 TEST=<name>，例：make watch_wave TEST=smoke"; exit 1; fi
	@echo "=== [watch_wave] 形式①/② 离线 dump+查看 SIMULATOR=$(SIMULATOR) TEST=$(TEST) ==="
	@$(MAKE) --no-print-directory compile BUILD_SUBDIR=$(BUILD_DIR)/watch_$(TEST)_$(SIMULATOR) WAVES=1
	$(SIM_ENV) python3 $(SCRIPTS_DIR)/run_regress.py \
	  --test $(TEST) --binary $(ASM_DIR)/$(TEST).hex \
	  --simulator $(SIMULATOR) --seed 1 --rtl-test core_eh2_base_test \
	  --sim-opts "$(SIM_OPTS) $(if $(filter 1,$(LOCKSTEP_WHISPER)),$(LOCKSTEP_SIM_OPTS) +whisper_server_file=$(BUILD_DIR)/watch_$(TEST)_$(SIMULATOR)/$(TEST)_s1/whisper_connect,) +rvvi_elf=$(ASM_DIR)/$(TEST).elf +rvvi_trace_file=$(BUILD_DIR)/watch_$(TEST)_$(SIMULATOR)/$(TEST)_s1/rvvi_trace.log" \
	  --build-dir $(BUILD_DIR)/watch_$(TEST)_$(SIMULATOR) \
	  --output $(BUILD_DIR)/watch_$(TEST)_$(SIMULATOR) --waves
	@if [ "$(SIMULATOR)" = "vcs" ]; then \
	  if [ ! -f $(BUILD_DIR)/watch_$(TEST)_vcs/$(TEST)_s1/waves.fsdb ] && [ -f novas.fsdb ]; then \
	    mv novas.fsdb $(BUILD_DIR)/watch_$(TEST)_vcs/$(TEST)_s1/waves.fsdb; \
	  fi; \
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
	$(SIM_ENV) python3 $(SCRIPTS_DIR)/signoff.py \
	  --profile $(PROFILE) --simulator $(SIMULATOR) \
	  --config $(RISCV_DV_CONFIG) \
	  --seed $(SEED) --parallel $(PARALLEL) --output $(SIGNOFF_OUT) \
	  $(if $(filter 1,$(GATE_ONLY)),--gate-only,) \
	  $(if $(SIGNOFF_ITERATIONS),--iterations $(SIGNOFF_ITERATIONS),) \
	  $(if $(filter 1,$(COV)),--coverage --min-line-coverage $(SIGNOFF_MIN_LINE_COV) --min-functional-coverage $(SIGNOFF_MIN_FUNCTIONAL_COV),) \
	  $(if $(filter 1,$(COV)),,--no-require-coverage --min-line-coverage 0 --min-functional-coverage 0) \
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
