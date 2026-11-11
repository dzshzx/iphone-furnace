#!/usr/bin/env bash
# 统一格式化与检查入口：Python 用 ruff，JS/TS 与 Markdown/YAML/JSON 用 prettier，Shell 用 shfmt 与 shellcheck。
# 用法：scripts/format.sh [--check | --lint]
#   无参数：就地格式化本仓跟踪的文件与未被忽略的新文件；--check：只检查格式，不一致时列出文件并非零退出；
#   --lint：跑 ruff check、Python 函数复杂度上限、shellcheck，并检查代码文件不超过 MAX_LINES 行，有问题时非零退出。
# 工具版本只在下方常量固定；各工具配置：pyproject.toml 的 [tool.ruff]、.prettierrc.json/.prettierignore、.editorconfig（shfmt）。
set -euo pipefail

RUFF_VERSION=0.17.3
PRETTIER_VERSION=3.9.10
SHFMT_VERSION=3.14.1
# shfmt 经 PyPI 包 shfmt-py 分发，该版本内置上面的 shfmt。
SHFMT_PY_VERSION=4.2.0
SHELLCHECK_VERSION=0.11.0
# PyPI 包 shellcheck-py 分发 shellcheck，该版本内置上面的 shellcheck。
SHELLCHECK_PY_VERSION=0.11.0.1
# 单个 Python 函数的圈复杂度上限与单个代码文件的行数上限。
MAX_COMPLEXITY=15
MAX_LINES=2000
# 字节须保持不变的文件（git pathspec），各语言共用；与 .prettierignore 同步维护。
EXCLUDE=(
  ':(exclude)**/node_modules/**' ':(exclude)**/vendor/**' ':(exclude)**/dist/**'
  # 锁文件；Xcode 维护的资源目录描述；原样随包分发的第三方许可声明。
  ':(exclude)uv.lock' ':(exclude)**/*.xcassets/**' ':(exclude)THIRD_PARTY_NOTICES.md'
)

CHECK=0
LINT=0
case "${1:-}" in
  "") ;;
  --check) CHECK=1 ;;
  --lint) LINT=1 ;;
  -h | --help)
    sed -n '2,6p' "$0"
    exit 0
    ;;
  *)
    echo "未知参数：$1" >&2
    exit 2
    ;;
esac
[ $# -le 1 ] || {
  echo "参数过多" >&2
  exit 2
}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

files() {
  local f
  git ls-files -z --cached --others --exclude-standard -- "$@" "${EXCLUDE[@]}" | while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    printf '%s\0' "$f"
  done
}

ruff() {
  if command -v uvx >/dev/null 2>&1; then
    uvx -q "ruff==$RUFF_VERSION" "$@"
  else
    pipx run --spec "ruff==$RUFF_VERSION" ruff "$@"
  fi
}

shfmt() {
  # 本机已装同版本（Homebrew 输出 3.x.y，官方二进制输出 v3.x.y）则直接用；否则与 ruff 同样经 uvx/pipx 取 shfmt-py。
  local have
  have=$(command shfmt --version 2>/dev/null || true)
  if [ -n "$have" ] && [ "${have#v}" = "$SHFMT_VERSION" ]; then
    command shfmt "$@"
  elif command -v uvx >/dev/null 2>&1; then
    uvx -q --from "shfmt-py==$SHFMT_PY_VERSION" shfmt "$@"
  else
    pipx run --spec "shfmt-py==$SHFMT_PY_VERSION" shfmt "$@"
  fi
}

shellcheck() {
  # 取法同 shfmt：本机已装同版本则直接用；否则经 uvx/pipx 取 shellcheck-py。
  local have
  have=$(command shellcheck --version 2>/dev/null | awk '$1 == "version:" { print $2 }' || true)
  if [ "$have" = "$SHELLCHECK_VERSION" ]; then
    command shellcheck "$@"
  elif command -v uvx >/dev/null 2>&1; then
    uvx -q --from "shellcheck-py==$SHELLCHECK_PY_VERSION" shellcheck "$@"
  else
    pipx run --spec "shellcheck-py==$SHELLCHECK_PY_VERSION" shellcheck "$@"
  fi
}

max_lines() {
  # 列出行数超过 MAX_LINES 的文件并非零退出。末尾加 /dev/null 保证 wc 总会多打一行合计，sed 把这一行去掉。
  wc -l -- "$@" /dev/null | sed '$d' | awk -v max="$MAX_LINES" '$1 > max { print; bad = 1 } END { exit bad }'
}

mapfile -d '' PY < <(files '*.py' '*.pyi')
# 进程替换的退出码不会自动传出：每个 < <(...) 之后 wait "$!" 取回，git ls-files 失败时随 set -e 退出。
wait "$!"
mapfile -d '' JS < <(files '*.js' '*.mjs' '*.cjs' '*.jsx' '*.ts' '*.mts' '*.cts' '*.tsx' '*.md' '*.yml' '*.yaml' '*.json')
wait "$!"
mapfile -d '' SH < <(files '*.sh' '*.bash')
wait "$!"

if [ "$LINT" -eq 1 ]; then
  # 每一步直接调用工具并原样透出它的输出，非零即随 set -e 退出。
  mapfile -d '' CODE < <(files '*.py' '*.pyi' '*.sh' '*.bash' '*.swift' '*.metal' '*.h' '*.mm' '*.m' '*.cpp' \
    '*.js' '*.mjs' '*.cjs' '*.jsx' '*.ts' '*.mts' '*.cts' '*.tsx')
  wait "$!"
  if [ ${#PY[@]} -gt 0 ]; then
    echo "== ruff check"
    ruff check --output-format concise -- "${PY[@]}"
    # 复杂度不认行内的 noqa，要放宽只能改这里或 pyproject.toml。
    echo "== Python 函数圈复杂度不超过 $MAX_COMPLEXITY"
    ruff check --select C901 --ignore-noqa --config "lint.mccabe.max-complexity=$MAX_COMPLEXITY" \
      --output-format concise -- "${PY[@]}"
  fi
  if [ ${#SH[@]} -gt 0 ]; then
    echo "== shellcheck"
    shellcheck -- "${SH[@]}"
  fi
  echo "== 代码文件不超过 $MAX_LINES 行"
  max_lines "${CODE[@]}"
  echo "lint: ok"
  exit 0
fi

FAIL=0
if [ ${#PY[@]} -gt 0 ]; then
  if [ "$CHECK" -eq 1 ]; then
    ruff format --check --output-format concise -- "${PY[@]}" || FAIL=1
  else
    ruff format -- "${PY[@]}"
  fi
fi
if [ ${#JS[@]} -gt 0 ]; then
  if [ "$CHECK" -eq 1 ]; then
    npm_config_loglevel=warn npx --yes "prettier@$PRETTIER_VERSION" --check -- "${JS[@]}" || FAIL=1
  else
    npm_config_loglevel=warn npx --yes "prettier@$PRETTIER_VERSION" --write --log-level warn -- "${JS[@]}"
  fi
fi
if [ ${#SH[@]} -gt 0 ]; then
  if [ "$CHECK" -eq 1 ]; then
    # -l 在有不一致文件或解析失败时都非零退出，两种都算失败。
    rc=0
    bad=$(shfmt -l -- "${SH[@]}") || rc=$?
    if [ -n "$bad" ] || [ "$rc" -ne 0 ]; then
      printf 'shfmt: 需要重排：\n%s\n' "$bad"
      FAIL=1
    fi
  else
    shfmt -w -- "${SH[@]}"
  fi
fi

if [ "$CHECK" -eq 1 ]; then
  if [ "$FAIL" -eq 0 ]; then
    echo "format: ok"
  else
    echo "format: 格式不一致，运行 scripts/format.sh 修复" >&2
  fi
fi
exit "$FAIL"
