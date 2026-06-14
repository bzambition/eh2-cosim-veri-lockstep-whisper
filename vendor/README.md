# Vendored 依赖

本目录存放项目级依赖的固定拷贝，目标是让 `eh2-cosim-veri` 保持单目录自包含。这里的内容固定版本使用，不自动追随上游；升级时应单独评估、验证并提交。

- `vendor/google_riscv-dv`：来自 riscv-dv，已去除 `.git`，用于随机指令生成和相关脚本。
- `vendor/spike`：来自 Spike 源码，已去除 `.git` 和本地构建产物；`make spike` 会在库内构建生成 `vendor/spike/install/`。
- `vendor/rvvi`：来自官方 RVVI，包含 `rvviTrace.sv`、`rvviApi.h` 和 `rvviApiPkg.sv` DPI 封装，未改上游。
- `vendor/riscv-tests`：来自 riscv-tests，用作 compliance 套件来源。
