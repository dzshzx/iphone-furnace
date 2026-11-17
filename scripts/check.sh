#!/usr/bin/env bash
# Linux 工具检查汇总入口：.github/workflows/ci.yml（Build tools checks）直接运行本脚本。
# 用法：bash scripts/check.sh
# 生成步骤改写已跟踪的 App 图标；跑完后已跟踪文件须与开始时一致，生成结果漂移即失败（模型输出在 gitignore 的 Models/）。
# Swift/Metal 编译、模拟器测试、IPA 验证与私有 ANE 原生检查需要 macOS，不在此列，经手动触发的 release.yml 运行（dry_run 只验证）。
# Go 构建工具（仓根 go.mod）：版本断言、go vet、staticcheck、go test、函数认知复杂度上限；gofmt 在 scripts/format.sh。
set -euo pipefail
cd "$(dirname "$0")/.."

# 工具版本、复杂度上限与共用检查函数在 scripts/gatelib.sh。
# shellcheck source=scripts/gatelib.sh
source scripts/gatelib.sh

tracked_state() { git status --porcelain --untracked-files=no && git diff HEAD | git hash-object --stdin; }
before=$(tracked_state)

# 仓里的 Python 只能是 scripts/python-allowlist.txt 列出的文件或目录（以 / 结尾）下的文件：coremltools 只有 Python 版，
# 模型生成与模型测试留在 Python，新工具用 Go 写。清单每一行都要对得上至少一个文件，删掉的脚本同时从清单里去掉。
gate_python_allowlist

# 工具链版本只写在 go.mod 的 go 行，不许有 toolchain 行；复杂度不认代码里的豁免标记。
gate_go_version .
gate_no_marker 'gocognit:ignore' '*.go'

bash scripts/format.sh --check
bash scripts/format.sh --lint
go vet ./...
gate_go_run "$STATICCHECK" ./...
gate_go_run "$GOCOGNIT" -over "$MAX_COGNITIVE" .
go test -count=1 ./...
uv sync --locked
uv run --locked python scripts/generate_models.py
go run ./cmd/furnace-tools generate-icon
uv run --locked pytest scripts/tests

if [[ "$(tracked_state)" != "$before" ]]; then
  echo "生成步骤改动了已跟踪文件，生成结果与入库版本不一致：" >&2
  git status --porcelain --untracked-files=no >&2
  exit 1
fi
