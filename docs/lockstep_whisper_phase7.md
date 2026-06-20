# LOCKSTEP-WHISPER Phase 7 报告

## 目标

本阶段系统核验顶层 `Makefile` 的 target 和主要 option 组合：先记录第一遍结果，再对失败项做系统化定位与最小修复，最后复跑矩阵确认没有回归。

## 基线

| 项目 | 结果 | 证据 |
|---|---|---|
| 起点提交 | `7726b79 docs(lockstep): 稳定 Phase 6 发布核验口径` | `git log --oneline -1` |
| 工作树 | 起点已有 Phase 7 前置修复未提交：`Makefile`、NC/VCS wave TCL、NC YAML、脚本测试 | `git status -s` |
| 脚本单测 | `154 passed, 1 skipped, 1 warning` | `python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q` |
| Release 证据保护 | 原计划路径在 Phase 7 起点不存在，无法备份 | `cp: cannot stat 'build/signoff_p63_release'`、`cp: cannot stat 'build/signoff_p44_masked_clean'` |
| NC/irun | 可用 | `command -v irun` |
| Verdi | 可用 | `command -v verdi` |
| SimVision | 可用 | `command -v simvision` |
| GUI DISPLAY | `:0` | `echo $DISPLAY` |

## 第一遍矩阵结果

| ID | 命令 | 预期 | 第一遍结果 | 修复后结果 | 证据 |
|---|---|---|---|---|---|
| T1 | `make help` | PASS | PASS | PASS | `/tmp/t1.log`、`/tmp/p74_t1.log` |
| T2a | `make asm` | PASS | PASS | PASS | `/tmp/t2.log`、`/tmp/p74_t2.log` |
| T2b | `make clean SCOPE=asm && make asm` | PASS | PASS | PASS | `/tmp/t12asm.log` |
| T3a | `make whisper` | PASS | PASS | PASS | `/tmp/t3.log` |
| T3b | `make whisper WHISPER_CXX= WHISPER_BOOST_ROOT=` | 预期明确报错 | PASS（exit 2） | PASS | `/tmp/t3err.log` |
| T4a | `make cac CAC_CXX=$CAC_CXX` | PASS | PASS | PASS | `/tmp/t4.log`、`/tmp/p74_t4.log` |
| T4b | `make cac CAC_CXX=$CAC_CXX CAC_NUM_HARTS=2` | PASS | PASS | PASS | `/tmp/t4b.log`、`/tmp/p74_t4b.log` |
| T4c | `make -C vendor/cosim-arch-checker test CC=$CAC_CXX` | PASS | FAIL（未 export `CAC_CXX` 时旧 `libstdc++`） | PASS | `/tmp/t4c.log`、`/tmp/t4c_exported.log`、`/tmp/p74_t4c.log` |
| T5a | `make compile_vcs COV=0 BUILD_SUBDIR=build/p7_compile_vcs_cov0` | PASS | PASS | PASS | `/tmp/t5a.log`、`/tmp/p74_t5a.log` |
| T5b | `make compile_vcs COV=1 BUILD_SUBDIR=build/p7_compile_vcs_cov1` | PASS | PASS | 第一遍已覆盖 | `/tmp/t5b.log` |
| T5c | `make compile CONFIG=dual_thread COV=0 BUILD_SUBDIR=build/p7_compile_dual` | PASS | PASS | PASS | `/tmp/t5c.log`、`/tmp/p74_t5c.log` |
| T6 | `make compile_nc COV=0 BUILD_SUBDIR=build/p7_compile_nc` | PASS | PASS | PASS | `/tmp/t6.log`、`/tmp/p74_t6.log` |
| T7a | `make smoke LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=0` | PASS | PASS | PASS | `/tmp/t7a.log`、`/tmp/p73_smoke.log`、`/tmp/p74_t7a.log` |
| T7b | `make smoke LOCKSTEP_WHISPER=1 COV=1` | PASS | PASS | 第一遍已覆盖 | `/tmp/t7b.log` |
| T7c | `make smoke LOCKSTEP_WHISPER=0 COV=0` | PASS 或明确报错 | PASS | PASS | `/tmp/t7c.log`、`/tmp/p74_t7c.log` |
| T7d | `make smoke CONFIG=dual_thread SIM_OPTS="+rvvi_nhart=2" COV=0` | PASS | PASS | PASS | `/tmp/t7d.log`、`/tmp/p74_t7d.log` |
| T7e | `make smoke SIM_OPTS="+rvvi_debug_poke" COV=0` | PASS 或已知 debug downgrade 失败需解释 | PASS | 第一遍已覆盖 | `/tmp/t7e.log` |
| T7f | `make smoke SIMULATOR=nc COV=0` | PASS | PASS | PASS | `/tmp/t7nc.log`、`/tmp/p74_t7f.log` |
| T8a | `make regress TESTLIST=cosim COV=0 PARALLEL=1 OUT=build/p7_cosim` | 7/7 PASS | PASS | PASS | `/tmp/t8a.log`、`/tmp/p73_cosim.log`、`/tmp/p74_t8a.log` |
| T8b | `make regress TESTLIST=directed COV=0 PARALLEL=2 OUT=build/p7_directed` | PASS | PASS | PASS | `/tmp/t8b.log`、`/tmp/p74_t8b.log` |
| T8c | `make regress TESTLIST=riscvdv TEST=riscv_interrupt_test ITERATIONS=2 COV=0 PARALLEL=1 OUT=build/p7_irq` | 2/2 PASS | PASS | PASS | `/tmp/t8c.log`、`/tmp/p74_t8c.log` |
| T8d | `make regress TESTLIST=riscvdv TEST=riscv_arithmetic_basic_test ITERATIONS=1 COV=1 OUT=build/p7_cov` | PASS | PASS | 第一遍已覆盖 | `/tmp/t8d.log` |
| T8e | `make regress CONFIG=dual_thread TESTLIST=cosim COV=0 PARALLEL=1 OUT=build/p7_dual_cosim` | PASS | PASS | 第一遍已覆盖 | `/tmp/t8e.log` |
| T8f | `make regress TESTLIST=cosim TEST=alu_basic_test COV=0 WAVES=1 PARALLEL=1 OUT=build/p7_cosim_waves` | PASS + wave | FAIL（测试名不在 cosim testlist） | PASS（改用 `TEST=cosim_alu`） | `/tmp/t8f.log`、`/tmp/p73_cosim_waves.log`、`/tmp/p74_t8f.log` |
| T9a | `make compliance SUITE=compile` | PASS | PASS | PASS | `/tmp/t9a.log`、`/tmp/p74_t9a.log` |
| T9b | `make compliance SIMULATOR=vcs` | PASS | PASS | PASS | `/tmp/t9b.log`、`/tmp/p74_t9b.log` |
| T9c | `make compliance SUITE=all SIMULATOR=vcs` | PASS | PASS | 第一遍已覆盖 | `/tmp/t9c.log` |
| T10a | `make watch_wave` | 预期明确报错 | PASS（exit 2） | PASS（exit 2） | `/tmp/t10err.log`、`/tmp/p74_t10err.log` |
| T10b | `make watch_wave TEST=smoke SIMULATOR=vcs` | PASS + FSDB | PASS | PASS | `/tmp/t10a.log`、`/tmp/p74_t10b.log`、`waves.fsdb` |
| T10c | `make watch_wave TEST=smoke SIMULATOR=nc` | PASS + SHM | PASS | PASS | `/tmp/t10nc.log`、`/tmp/p74_t10c.log`、`waves.shm` |
| T10d | `make watch_wave TEST=smoke MODE=live` | GUI 交互可 SKIP | SKIP（timeout，已到 ncsim ready） | SKIP | `/tmp/t10live.log` |
| T11a | `make signoff SIMULATOR=foo` | 预期明确报错 | PASS（exit 2） | PASS（exit 2） | `/tmp/t11err.log`、`/tmp/p74_t11err.log` |
| T11b | `make signoff PROFILE=cosim COV=0 PARALLEL=1 SIGNOFF_OUT=build/p7_signoff_cosim` | PASS | FAIL（COV=0 仍 gate coverage） | PASS | `/tmp/t11a.log`、`/tmp/p73_signoff_cosim.log`、`/tmp/p74_t11b.log` |
| T11c | `make signoff PROFILE=quick COV=0 SIGNOFF_ITERATIONS=1 SIGNOFF_OUT=build/p7_signoff_quick` | PASS | FAIL（COV=0 仍 gate coverage） | PASS | `/tmp/t11b.log`、`/tmp/p73_signoff_quick.log`、`/tmp/p74_t11c.log` |
| T11d | `make signoff GATE_ONLY=1 SIGNOFF_OUT=<已有结果>` | PASS 或 SKIP(no prior signoff) | FAIL（默认 full profile 检查 cosim-only 目录） | PASS（指定 `PROFILE=cosim`） | `/tmp/t11c.log`、`/tmp/p73_gate_cosim.log`、`/tmp/p74_t11d.log` |
| T12a | `make clean SCOPE=cov` | PASS | PASS | PASS | `/tmp/t12cov.log` |
| T12b | `make clean SCOPE=asm && make asm` | PASS | PASS | PASS | `/tmp/t12asm.log` |
| T12c | `make clean SCOPE=docs` | PASS | PASS | PASS | `/tmp/t12docs.log` |
| T12d | `make clean MODE=archive DRY_RUN=1` | PASS | PASS | PASS | `/tmp/t12arch.log` |
| T12e | `make clean SCOPE=vcs BUILD_DIR=build/p7_clean_sandbox` | PASS，只删沙箱 | PASS | PASS | `/tmp/t12vcs.log`、`/tmp/p74_t12vcs.log` |
| T12f | `make clean SCOPE=build BUILD_DIR=build/p7_clean_sandbox` | PASS，只删沙箱 | PASS | PASS | `/tmp/t12build.log`、`/tmp/p74_t12build.log` |

## 失败项与修复记录

1. `make -C vendor/cosim-arch-checker test CC=$CAC_CXX` 第一遍失败。根因不是代码，而是执行 shell 未按计划导出 `CAC_CXX`，导致 `CC=` 为空，测试二进制运行时拿到系统旧 `libstdc++`。按计划导出本机 `env.mk` 中的 `CAC_CXX` 后复跑通过。
2. `make regress TESTLIST=cosim TEST=alu_basic_test ... WAVES=1` 第一遍失败。根因是矩阵命令选了不存在于 `cosim_testlist.yaml` 的测试名。改用真实测试 `cosim_alu` 后通过，证明 `WAVES=1` 路径可用。
3. `make signoff PROFILE=cosim/quick COV=0` 第一遍失败。根因是顶层 Makefile 只在 `COV=1` 时传 `--coverage`，但没有在 `COV=0` 时传 `--no-require-coverage`；`signoff.py` 默认 `--min-line-coverage=60`，因此功能 stage 全绿仍被 coverage blocker 打红。修复为 `COV=0` 时显式传 `--no-require-coverage --min-line-coverage 0 --min-functional-coverage 0`。下游 `smoke`、`regress TESTLIST=cosim`、`signoff PROFILE=cosim`、`signoff PROFILE=quick` 均已通过。
4. `make signoff GATE_ONLY=1 SIGNOFF_OUT=build/p7_signoff_cosim` 第一遍失败。根因是命令未指定 `PROFILE=cosim`，默认按 full profile 去检查 cosim-only 目录。指定匹配 profile 后 gate-only 通过。
5. clean 保留清单加固：`CLEAN_PRESERVE_BUILD` 新增 `signoff_p63_release`、`signoff_p44_masked_clean`、`signoff_release`，沙箱验证 `SCOPE=build` 会保留 `signoff_p63_release`。

## 复跑结果

P7.4 复跑覆盖了所有 headless 组合和全部修复点：`help`、`asm`、`cac`、CAC 牙齿、VCS/NC compile、VCS/NC smoke、cosim/directed/riscvdv/compliance、VCS/NC watch_wave、cosim/quick signoff、gate-only、clean 沙箱。所有应 PASS 的组合均 PASS；错误路径（无 `TEST`、错误 `SIMULATOR`）均明确非零报错；`MODE=live` 验证到 ncsim/SimVision ready 后由 timeout 退出，按 GUI 交互 SKIP。

发布级 full COV=1 signoff 已重跑：

```bash
make signoff PROFILE=full LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=1 \
  SIGNOFF_OPTS="--no-fail-on-skip-in-signoff --timeout-s 14400" \
  SIGNOFF_OUT=build/signoff_p7_final
```

结果：`make exit=0`，`build/signoff_p7_final/signoff_status.json` 为 PASS。stage 结果为 smoke 1/1、directed 40/40、cosim 7/7、riscvdv 395/395、compliance 50/50，所有 stage `waivers=[]`。覆盖率 gate 通过：line 91.19%（阈值 55%）、functional 69.40%（阈值 40%）；overall 64.03%、toggle 52.11%、fsm 54.74%、branch 83.42%、assert 33.33% 为 collected-but-ungated。

本阶段修复只改 Makefile flow 参数和 clean 保护，不改仿真比较、mask、step、RTL 或 testlist。本机 Phase 7 起点已缺失 `build/signoff_p63_release` / `build/signoff_p44_masked_clean`，因此不能声称本地复用这些目录；本阶段新生成的发布证据为 `build/signoff_p7_final`。

## 终检

| 检查 | 结果 | 证据 |
|---|---|---|
| RTL 设计 | 未改 | `git diff --name-only | grep '^rtl/' | grep -v snapshots || echo OK` |
| symlink | 已清空 | `find . -path ./.git -prune -o -type l -print` |
| tracked 源机器绝对路径 | 无新增命中 | 按 COMMON 绝对路径 grep 规则检查 |
| 脚本单测 | `154 passed, 1 skipped, 1 warning` | `python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q` |
| diff 检查 | 通过 | `git diff --check` |

本阶段提交内容限于 Makefile/help/flow 修复、NC/VCS wave 脚本、NC YAML 运行模型、脚本测试断言和 Phase 7 报告。未改 RTL、testlist、CAC compare/mask/step 语义。
