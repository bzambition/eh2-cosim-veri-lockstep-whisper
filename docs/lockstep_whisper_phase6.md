# LOCKSTEP-WHISPER Phase 6 收尾报告

## 结论

Phase 6 是发布前收口阶段，目标是保行为代码整理、架构文档补齐、最终 release signoff，以及发布到新 GitHub 仓。

本期不改变仿真语义：RVVI-API lockstep、Whisper 参考模型、debug downgrade、`mip(0x344)` MEIP-only mask、Spike/offline 删除状态均保持不变。

## P6.0 基线

起点为：

```text
6b4926e docs(lockstep): 通用 RVVI checker recipe + 诚实方法学最终化 (P5)
```

基线检查：

- `v3.0-lockstep-whisper` 初始指向 `6b4926e`。
- 脚本单测：`154 passed, 1 skipped, 1 warning`。
- CAC 牙齿：`make -C vendor/cosim-arch-checker test CC=$CAC_CXX` exit 0，保留 CSR/GPR/MEM mismatch 牙齿输出。

## P6.1 代码质量收口

提交：

```text
1a5fa40 refactor(lockstep): 代码质量收口（保行为，去屎山）(P6.1)
```

改动范围：

- `whisper_rvvi.cpp`：增加文件职责说明，资源字符改为具名常量，补充路径选择和未用 RVVI hook 分区注释。
- `rvvi_scoreboard.sv`：补充 thin SV shell、store sideband、debug 包边界和 retire compare 顺序注释。
- `test_regression_framework.py`：测试断言跟随具名常量更新，仍检查 `mip` 经 Whisper CSR poke 注入。

验证：

| 项目 | 结果 |
|---|---:|
| `make cac CAC_CXX=$CAC_CXX` | PASS |
| `make -C vendor/cosim-arch-checker test CC=$CAC_CXX` | PASS |
| `make smoke LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=0` | 1/1 PASS |
| `make regress LOCKSTEP_WHISPER=1 TESTLIST=cosim SIMULATOR=vcs COV=0 PARALLEL=1 OUT=build/p61_cosim` | 7/7 PASS |
| `python3 -m pytest dv/uvm/core_eh2/scripts/tests/ -q` | 154 passed, 1 skipped |

Core-agnostic grep 结果为空。

## P6.2 架构文档

新增：

- `docs/architecture.md`
- `CHANGELOG.md`

更新：

- `eh2_rvvi_adapter.sv` 顶部注释，移除旧 MR1/offline 说法，明确它是 EH2 专属 RVVI-TRACE adapter。

文档强调：

- 数据流：EH2 RTL → adapter → `rvviTrace` → scoreboard → CAC `rvviApi.h` → `whisper_rvvi` → Whisper。
- 复用边界：每核只提供 adapter、ISS 配置或后端、CSR mask。
- 工具链 ABI 切分：VCS DPI 与 Whisper server 通过 socket 解耦。
- 已知边界：debug 主动注入 downgrade，`mip` MEIP-only mask，coverage gate 只含 line/functional。

## P6.3 发布门

由于 P6.1 触碰了仿真路径源文件，本期执行一次 COV=1 full signoff 作为 release gate。

命令：

```bash
make signoff PROFILE=full LOCKSTEP_WHISPER=1 SIMULATOR=vcs COV=1 \
  SIGNOFF_OPTS="--no-fail-on-skip-in-signoff --timeout-s 14400" \
  SIGNOFF_OUT=build/signoff_p63_release
```

结果：`make exit=0`，顶层 `status=PASS`。证据：

- `build/signoff_p63_release/signoff_status.json`
- `build/signoff_p63_release/signoff_report.md`
- `build/signoff_p63_release/report.html`

Stage 汇总：

| Stage | Status | Total | Passed | Failed | Waivers |
|---|---:|---:|---:|---:|---|
| smoke | PASS | 1 | 1 | 0 | `[]` |
| directed | PASS | 40 | 40 | 0 | `[]` |
| cosim | PASS | 7 | 7 | 0 | `[]` |
| riscvdv | PASS | 395 | 395 | 0 | `[]` |
| compliance | PASS | 50 | 50 | 0 | `[]` |

Coverage：line `91.19%`（gated，threshold `55.00%`），functional `69.40%`（gated，threshold `40.00%`），overall `64.03%`。assert、branch、FSM、toggle、overall 为 collected but ungated。

该结果与 Phase 4 终签 stage 和 coverage 数字一致，确认 P6.1 保行为整理未造成仿真结果漂移。

## P6.4 发布

发布目标为新 GitHub 仓，不使用本地 `origin=/home/host/eh2-cosim-veri`：

```text
git@github.com:bzambition/eh2-cosim-veri-lockstep-whisper.git
```

Push 前终检：

| 检查 | 结果 |
|---|---|
| `git status -s` | 干净 |
| RTL 设计改动检查 | `RTL 未改: OK` |
| `find . -path ./.git -prune -o -type l -print` | 空 |
| tracked 源绝对路径 grep | `绝对路径 grep 为空: OK` |
| `git check-ignore env.mk` | `env.mk 已 ignore: OK` |

注：VCS 在 ignored `build/` 目录下生成过 `.so` 符号链接。发布前仅删除这些 ignored build symlink，保留 `build/signoff_p63_release` 下的 JSON、Markdown、HTML 证据文件。

最终发布命令：

```bash
git push github HEAD:main
git push --force github v3.0-lockstep-whisper
```

结果：

```text
c59e799..7f43eea  HEAD -> main
7f43a94...4679ac0 v3.0-lockstep-whisper -> v3.0-lockstep-whisper (forced update)
```

远端核对：

```text
7f43eea470a36ea06fa47e6dde6adfc44e62693f refs/heads/main
4679ac03230f3a45553e27ea719dd9050f9fddae refs/tags/v3.0-lockstep-whisper
7f43eea470a36ea06fa47e6dde6adfc44e62693f refs/tags/v3.0-lockstep-whisper^{}
```

本地 `HEAD` 与 `v3.0-lockstep-whisper^{}` 均指向 `7f43eea470a36ea06fa47e6dde6adfc44e62693f`。远端 `main` 与 tag 解引用一致，发布到新仓完成。
