#!/usr/bin/env bash
# Linux 工具检查汇总入口：与 .github/workflows/ci.yml（Build tools checks）各步同源，合入前门禁（.merge-gate.toml）运行它。
# 用法：bash scripts/check.sh
# 生成步骤改写已跟踪的 App 图标；跑完后已跟踪文件须与开始时一致，生成结果漂移即失败（模型输出在 gitignore 的 Models/）。
# Swift/Metal 编译、模拟器测试、IPA 验证与私有 ANE 原生检查需要 macOS，不在此列，经手动 iOS build 运行。
set -euo pipefail
cd "$(dirname "$0")/.."

tracked_state() { git status --porcelain --untracked-files=no && git diff HEAD | git hash-object --stdin; }
before=$(tracked_state)

bash scripts/format.sh --check
bash -n scripts/build.sh scripts/check_private_ane.sh
uv sync --locked
uv run --locked python scripts/generate_models.py
uv run --locked python scripts/generate_icon.py
uv run --locked pytest scripts/tests

if [[ "$(tracked_state)" != "$before" ]]; then
  echo "生成步骤改动了已跟踪文件，生成结果与入库版本不一致：" >&2
  git status --porcelain --untracked-files=no >&2
  exit 1
fi
