#!/usr/bin/env bash
# 统一格式化与检查入口：Python 用 ruff，JS/TS 与 Markdown/YAML/JSON 用 prettier，Shell 用 shfmt 与 shellcheck，
# Swift 用 SwiftLint 与 lizard。
# 用法：scripts/format.sh [--check | --lint]
#   无参数：就地格式化本仓跟踪的文件与未被忽略的新文件；--check：只检查格式，不一致时列出文件并非零退出；
#   --lint：跑 ruff check、shellcheck、SwiftLint、Python 与 Swift 函数复杂度上限，并检查代码文件不超过 MAX_LINES 行，
#   有问题时非零退出。
# 工具版本只在下方常量固定；各工具配置：pyproject.toml 的 [tool.ruff]、.prettierrc.json/.prettierignore、.editorconfig（shfmt）、
# .swiftlint.yml。
set -euo pipefail

RUFF_VERSION=0.17.3
PRETTIER_VERSION=3.9.10
SHFMT_VERSION=3.14.1
# shfmt 经 PyPI 包 shfmt-py 分发，该版本内置上面的 shfmt。
SHFMT_PY_VERSION=4.2.0
SHELLCHECK_VERSION=0.11.0
# PyPI 包 shellcheck-py 分发 shellcheck，该版本内置上面的 shellcheck。
SHELLCHECK_PY_VERSION=0.11.0.1
SWIFTLINT_VERSION=0.65.1
# 该版本 GitHub Release 资产 swiftlint_linux_amd64.zip 的 SHA-256。
SWIFTLINT_LINUX_AMD64_SHA256=caeed6f4a679c35539ffaf124f6c4ab4a8416917f7d8796279dc52b74026059d
LIZARD_VERSION=1.26.0
# 单个 Python 或 Swift 函数的圈复杂度上限与单个代码文件的行数上限。
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
    sed -n '2,9p' "$0"
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

swiftlint() {
  # 本机已装同版本（如 macOS 的 Homebrew）则直接用。否则在 Linux x86_64 上下载官方 Release 里的静态二进制，
  # 校验 SHA-256 后放进仓外的用户缓存目录，之后复用。静态版不带 SourceKit：默认规则里只有 statement_position
  # 依赖它，在这里会被跳过，并打印一行 warning；其余默认规则照常检查。
  local have dir bin tmp
  have=$(command swiftlint version 2>/dev/null || true)
  if [ "$have" = "$SWIFTLINT_VERSION" ]; then
    command swiftlint "$@"
    return
  fi
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/furnace/swiftlint-$SWIFTLINT_VERSION"
  bin="$dir/swiftlint-static"
  if [ ! -x "$bin" ]; then
    if [ "$(uname -s)-$(uname -m)" != Linux-x86_64 ]; then
      echo "swiftlint: 需要 SwiftLint $SWIFTLINT_VERSION；只有 Linux x86_64 会自动下载，其他平台请先安装该版本" >&2
      return 1
    fi
    mkdir -p "$dir"
    tmp=$(mktemp -d "$dir/download.XXXXXX")
    curl -fsSL --retry 3 -o "$tmp/swiftlint.zip" \
      "https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/swiftlint_linux_amd64.zip"
    echo "$SWIFTLINT_LINUX_AMD64_SHA256  $tmp/swiftlint.zip" | sha256sum -c --quiet -
    unzip -q "$tmp/swiftlint.zip" swiftlint-static -d "$tmp"
    # 校验与解压都成功后才放到位，中断不会留下半个二进制。
    mv "$tmp/swiftlint-static" "$bin"
    rm -rf "$tmp"
  fi
  "$bin" "$@"
}

lizard() {
  if command -v uvx >/dev/null 2>&1; then
    uvx -q "lizard==$LIZARD_VERSION" "$@"
  else
    pipx run --spec "lizard==$LIZARD_VERSION" lizard "$@"
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
  mapfile -d '' SWIFT < <(files '*.swift')
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
  if [ ${#SWIFT[@]} -gt 0 ]; then
    echo "== SwiftLint"
    swiftlint lint --strict --quiet --no-cache -- "${SWIFT[@]}"
    # 复杂度不认豁免，要放宽只能改 MAX_COMPLEXITY：lizard 会放过带 #lizard forgives 注释的函数、注释里含
    # GENERATED CODE 的整个文件和 whitelizard.txt 里列的函数，所以先查一遍。
    echo "== Swift 函数圈复杂度不超过 $MAX_COMPLEXITY"
    if grep -n -i -e 'lizard forgive' -e 'generated code' -- "${SWIFT[@]}" || [ -e whitelizard.txt ]; then
      echo "lint: 不接受 lizard 的豁免注释（#lizard forgives、GENERATED CODE）与 whitelizard.txt" >&2
      exit 1
    fi
    lizard -l swift -C "$MAX_COMPLEXITY" -w -- "${SWIFT[@]}"
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
