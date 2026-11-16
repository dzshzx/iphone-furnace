#!/usr/bin/env bash
# Linux 工具检查汇总入口：.github/workflows/ci.yml（Build tools checks）直接运行本脚本。
# 用法：bash scripts/check.sh
# 生成步骤改写已跟踪的 App 图标；跑完后已跟踪文件须与开始时一致，生成结果漂移即失败（模型输出在 gitignore 的 Models/）。
# Swift/Metal 编译、模拟器测试、IPA 验证与私有 ANE 原生检查需要 macOS，不在此列，经手动触发的 release.yml 运行（dry_run 只验证）。
# Go 构建工具（仓根 go.mod）：版本断言、go vet、staticcheck、go test、函数认知复杂度上限；gofmt 在 scripts/format.sh。
set -euo pipefail
cd "$(dirname "$0")/.."

STATICCHECK=honnef.co/go/tools/cmd/staticcheck@v0.8.2
GOCOGNIT=github.com/uudashr/gocognit/cmd/gocognit@v1.3.0
# 单个 Go 函数的认知复杂度上限，测试文件里的函数也算。
MAX_COGNITIVE=30

# staticcheck 与 gocognit 经 go run 包@版本 取用：先查本机模块缓存，缓存里没有才走代理下载。
go_tool() {
  GOPROXY="file://$(go env GOMODCACHE)/cache/download,$(go env GOPROXY)" go run "$@"
}

tracked_state() { git status --porcelain --untracked-files=no && git diff HEAD | git hash-object --stdin; }
before=$(tracked_state)

# 仓里的 Python 只能是允许清单里的文件：coremltools 只有 Python 版，模型生成与模型测试留在 Python。
unexpected=$(git ls-files -- '*.py' | grep -vxF -f scripts/python-allowlist.txt || true)
if [[ -n "$unexpected" ]]; then
  printf 'check: 以下 Python 文件不在 scripts/python-allowlist.txt 里，新工具用 Go 写：\n%s\n' "$unexpected" >&2
  exit 1
fi

# 工具链版本只写在 go.mod 的 go 行：本机的 Go 比它旧时 go 命令自己下载并换用这一版；比它新时直接用本机那一版，
# 下面的断言报出来。toolchain 行会让 go 命令和 CI 的 setup-go 改按它选版本，版本就有了第二个来源。
want="go$(sed -n 's/^go \([0-9][0-9.]*\)$/\1/p' go.mod)"
have=$(go env GOVERSION)
if [[ "$want" != "$have" ]]; then
  echo "check: Go 工具链是 ${have}，与 go.mod 的 ${want} 不符：把 go.mod 的 go 行改成本机这一版，或设 GOTOOLCHAIN=${want} 运行" >&2
  exit 1
fi
if grep -q '^toolchain' go.mod; then
  echo "check: go.mod 不应有 toolchain 行，版本只由 go 行固定" >&2
  exit 1
fi
# 复杂度不认代码里的豁免标记；gocognit 没有关掉它的开关，这里直接查标记。
if git grep -n 'gocognit:ignore' -- '*.go'; then
  echo "check: 不接受上面的 gocognit:ignore 标记，要放宽复杂度上限只能改 MAX_COGNITIVE" >&2
  exit 1
fi

bash scripts/format.sh --check
bash scripts/format.sh --lint
go vet ./...
go_tool "$STATICCHECK" ./...
go_tool "$GOCOGNIT" -over "$MAX_COGNITIVE" .
# -count=1：测试读包目录外的文件（入库图标、工作流与 shell 脚本），测试缓存不跟踪这些输入。
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
