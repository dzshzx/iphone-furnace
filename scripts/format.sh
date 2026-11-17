#!/usr/bin/env bash
# 统一格式化与检查入口。本仓启用哪些工具、排除哪些路径写在 scripts/format.conf，工具版本与上限在 scripts/gatelib.sh。
# 用法：scripts/format.sh [--check | --lint]
#   无参数：就地格式化本仓跟踪的文件与未被忽略的新文件；--check：只检查格式，不一致时列出文件并非零退出；
#   --lint：跑本仓启用的检查器与复杂度上限，并检查代码文件不超过行数上限，有问题时非零退出。后两种门禁用。
# 格式化：prettier、shfmt、ruff format、gofmt；检查：shellcheck、ruff check 与 complexipy、SwiftLint、lizard、行数上限。
# 各工具自己的配置（.prettierrc.json、.prettierignore、.editorconfig、ruff.toml 等）照常生效。
# 本文件与 scripts/gatelib.sh 在各仓逐字节相同，由同步命令 gate-sync 从同一份源头写入，不在各仓里单独改。
set -euo pipefail

CHECK=0
LINT=0
case "${1:-}" in
  "") ;;
  --check) CHECK=1 ;;
  --lint) LINT=1 ;;
  -h | --help)
    sed -n '2,8p' "$0"
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
# shellcheck source=scripts/gatelib.sh
source scripts/gatelib.sh

# scripts/format.conf 可设的项（bash 语法），没写的项取下面的默认值，默认什么都不启用：
#   EXCLUDE          不格式化也不检查的路径，git pathspec，如 ':(exclude)**/testdata/**'
#   LINT_EXCLUDE     只对 --lint 生效的排除：这些路径照常格式化，但不做检查
#   PRETTIER         npx：经 npx 取 PRETTIER_VERSION；node_modules：用本仓 devDependency，版本须等于 PRETTIER_VERSION
#   PRETTIER_EXT     交给 prettier 的文件扩展名
#   SHFMT、SHELLCHECK、PYTHON、GOFMT、SWIFTLINT    设为 1 即启用；PYTHON 是 ruff format、ruff check 与 complexipy
#   SHELLCHECK_ARGS  shellcheck 的额外参数
#   SHEBANG          1：没有扩展名的文件按首行 shebang 归入 Shell，启用 PYTHON 时也归入 Python
#   CHEZMOI          1：chezmoi 源文件按去掉属性前缀后的目标名归类，.bashrc、.profile 算 Shell
#   LIZARD           查函数圈复杂度的语言：java、swift、csharp
#   LINES_EXT        Shell、Python 之外计入行数上限的代码文件扩展名；MAX_LINES=0 时不查行数
EXCLUDE=()
LINT_EXCLUDE=()
PRETTIER=
PRETTIER_EXT=(js mjs cjs jsx ts mts cts tsx md yml yaml json)
SHFMT=0
SHELLCHECK=0
SHELLCHECK_ARGS=()
PYTHON=0
GOFMT=0
SWIFTLINT=0
SHEBANG=0
CHEZMOI=0
LIZARD=()
LINES_EXT=()
if [ ! -f scripts/format.conf ]; then
  echo "format: 缺少 scripts/format.conf（本仓启用哪些工具、排除哪些路径）" >&2
  exit 2
fi
# shellcheck source=/dev/null
source scripts/format.conf

# chezmoi 源文件名去掉属性前缀后的目标名写进 TARGET，例如 private_dot_zshrc → .zshrc、executable_foo.sh → foo.sh。
chezmoi_target() {
  local b=$1 prev=
  while [ "$b" != "$prev" ]; do
    prev=$b
    b=${b#create_}
    b=${b#modify_}
    b=${b#run_}
    b=${b#encrypted_}
    b=${b#private_}
    b=${b#readonly_}
    b=${b#empty_}
    b=${b#executable_}
    b=${b#literal_}
  done
  case $b in dot_*) b=.${b#dot_} ;; esac
  TARGET=$b
}

PRETTIER_FILES=()
SH=()
PY=()
GO=()
SWIFT=()
SWIFT_LIZARD=()
JAVA=()
CS=()
LINES=()
prettier_ext=" ${PRETTIER_EXT[*]} "
lines_ext=" ${LINES_EXT[*]} "
lizard_langs=" ${LIZARD[*]} "

# classify <路径>：按扩展名把文件放进各工具的清单；没有扩展名的按 shebang 归类（SHEBANG=1 时）。
classify() {
  local f=$1 name ext="" first
  name=${f##*/}
  if [ "$CHEZMOI" -eq 1 ]; then
    chezmoi_target "$name"
    name=$TARGET
    case $name in .bashrc | .profile) ext="sh" ;; esac
  fi
  if [ -z "$ext" ]; then
    case $name in
      *.*) ext=${name##*.} ;;
      *)
        [ "$SHEBANG" -eq 1 ] || return 0
        first=
        IFS= read -r first <"$f" || true
        case $first in
          '#!'*zsh*) ;;
          '#!'*bash* | '#!'*/sh | '#!'*/sh' '* | '#!'*' sh' | '#!'*' sh '*) ext="sh" ;;
          '#!'*python* | '#!'*'uv run'*) ext="py" ;;
        esac
        ;;
    esac
  fi
  [ -n "$ext" ] || return 0
  if [ -n "$PRETTIER" ] && [[ $prettier_ext == *" $ext "* ]]; then PRETTIER_FILES+=("$f"); fi
  case $ext in
    sh | bash)
      SH+=("$f")
      LINES+=("$f")
      return 0
      ;;
    py | pyi)
      if [ "$PYTHON" -eq 1 ]; then
        PY+=("$f")
        LINES+=("$f")
        return 0
      fi
      ;;
    go) if [ "$GOFMT" -eq 1 ]; then GO+=("$f"); fi ;;
    swift) if [ "$SWIFTLINT" -eq 1 ]; then SWIFT+=("$f"); fi ;;
  esac
  case $ext in
    java) if [[ $lizard_langs == *" java "* ]]; then JAVA+=("$f"); fi ;;
    swift) if [[ $lizard_langs == *" swift "* ]]; then SWIFT_LIZARD+=("$f"); fi ;;
    cs) if [[ $lizard_langs == *" csharp "* ]]; then CS+=("$f"); fi ;;
  esac
  if [[ $lines_ext == *" $ext "* ]]; then LINES+=("$f"); fi
}

pathspec=("${EXCLUDE[@]}")
if [ "$LINT" -eq 1 ]; then pathspec+=("${LINT_EXCLUDE[@]}"); fi
while IFS= read -r -d '' f; do
  # 跳过工作区里已不存在的跟踪文件（删了还没 git rm）与符号链接。
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  classify "$f"
done < <(git ls-files -z --cached --others --exclude-standard -- "${pathspec[@]}")
# 进程替换的退出码不会自动传出：wait "$!" 取回，git ls-files 失败时随 set -e 退出。
wait "$!"

# 经 uvx 运行固定的版本：缓存里已有就离线启动（不联网确认），缓存缺失时在线取。uvx 的包参数与工具参数用 -- 分隔。
uvx_pinned() {
  local spec=()
  while [ "$1" != -- ]; do
    spec+=("$1")
    shift
  done
  shift
  if uvx --offline -q "${spec[@]}" --version >/dev/null 2>&1; then
    uvx --offline -q "${spec[@]}" "$@"
  else
    uvx -q "${spec[@]}" "$@"
  fi
}

# py_tool <PyPI 包==版本> <命令> [参数...]：经 uvx 运行，没有 uvx 时经 pipx。
py_tool() {
  local pkg=$1 cmd=$2
  shift 2
  if command -v uvx >/dev/null 2>&1; then
    uvx_pinned --from "$pkg" "$cmd" -- "$@"
  else
    pipx run --spec "$pkg" "$cmd" "$@"
  fi
}

ruff() { py_tool "ruff==$RUFF_VERSION" ruff "$@"; }
# 缓存放仓外：complexipy 默认在当前目录建 .complexipy_cache。
complexipy() { py_tool "complexipy==$COMPLEXIPY_VERSION" complexipy --cache-dir "${XDG_CACHE_HOME:-$HOME/.cache}/complexipy" "$@"; }
lizard() { py_tool "lizard==$LIZARD_VERSION" lizard "$@"; }

shfmt() {
  # 本机已装同版本（Homebrew 输出 3.x.y，官方二进制输出 v3.x.y）则直接用；否则取 PyPI 包 shfmt-py。
  local have
  have=$(command shfmt --version 2>/dev/null || true)
  if [ -n "$have" ] && [ "${have#v}" = "$SHFMT_VERSION" ]; then
    command shfmt "$@"
  else
    py_tool "shfmt-py==$SHFMT_PY_VERSION" shfmt "$@"
  fi
}

shellcheck() {
  # 本机已装同版本则直接用；否则取 PyPI 包 shellcheck-py。
  local have
  have=$(command shellcheck --version 2>/dev/null | awk '$1 == "version:" { print $2 }' || true)
  if [ "$have" = "$SHELLCHECK_VERSION" ]; then
    command shellcheck "$@"
  else
    py_tool "shellcheck-py==$SHELLCHECK_PY_VERSION" shellcheck "$@"
  fi
}

# --cache 按文件内容、prettier 版本与选项跳过上次已确认格式正确的文件；缓存放在本 worktree 自己的 git 目录
# （不进工作树，随 worktree 删除），不与其他 worktree 并发读写同一文件。
prettier() {
  local cache bin have
  cache=$(git rev-parse --absolute-git-dir)/prettier-cache
  if [ "$PRETTIER" = node_modules ]; then
    # 没装依赖时先 npm ci；装不上（如在 npm run 里被 npm 拒绝）就报错，让人在仓根自己装。
    [ -x node_modules/.bin/prettier ] || npm_config_loglevel=warn npm ci >&2 || true
    if [ ! -x node_modules/.bin/prettier ]; then
      echo "format: 缺少 node_modules/.bin/prettier，先在仓根运行 npm ci" >&2
      return 1
    fi
    have=$(node_modules/.bin/prettier --version)
    if [ "$have" != "$PRETTIER_VERSION" ]; then
      echo "format: node_modules 里的 prettier 是 $have，与 scripts/gatelib.sh 固定的 $PRETTIER_VERSION 不符：把 package.json 的 prettier 改成这一版并重装依赖" >&2
      return 1
    fi
    node_modules/.bin/prettier --cache --cache-location "$cache" "$@"
    return
  fi
  # 先用 npx --offline 解析 npx 缓存里这个精确版本的可执行文件并直接运行（不联网解析版本）；缓存里没有才经在线 npx 取。
  # 离线解析失败只决定走哪条路，不计入格式检查结果。
  bin=$(npm_config_loglevel=silent npx --offline --yes -p "prettier@$PRETTIER_VERSION" -c 'command -v prettier' 2>/dev/null) || bin=
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    "$bin" --cache --cache-location "$cache" "$@"
  else
    npm_config_loglevel=warn npx --yes "prettier@$PRETTIER_VERSION" --cache --cache-location "$cache" "$@"
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
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/gate-tools/swiftlint-$SWIFTLINT_VERSION"
  bin="$dir/swiftlint-static"
  if [ ! -x "$bin" ]; then
    if [ "$(uname -s)-$(uname -m)" != Linux-x86_64 ]; then
      echo "swiftlint: 需要 SwiftLint ${SWIFTLINT_VERSION}；只有 Linux x86_64 会自动下载，其他平台请先安装该版本" >&2
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

# lizard_check <lizard 语言名> <显示名> [文件...]：函数圈复杂度不超过 MAX_COMPLEXITY。
lizard_check() {
  local lang=$1 label=$2
  shift 2
  [ $# -gt 0 ] || return 0
  echo "== $label 函数圈复杂度不超过 $MAX_COMPLEXITY"
  lizard -l "$lang" -C "$MAX_COMPLEXITY" -w -- "$@"
  # 复杂度不认豁免：lizard 会放过带 #lizard forgives 注释的函数、注释里含 GENERATED CODE 的整个文件
  # 和仓根 whitelizard.txt 里列的函数，所以另查一遍。
  if grep -n -i -e 'lizard forgive' -e 'generated code' -- "$@" || [ -e whitelizard.txt ]; then
    echo "lint: 不接受 lizard 的豁免注释（#lizard forgives、GENERATED CODE）与 whitelizard.txt" >&2
    exit 1
  fi
}

if [ "$LINT" -eq 1 ]; then
  # 每一步直接调用工具并原样透出它的输出，非零即随 set -e 退出。
  if [ "$PYTHON" -eq 1 ]; then
    if [ ${#PY[@]} -gt 0 ]; then
      echo "== ruff check"
      ruff check --output-format concise -- "${PY[@]}"
      # --no-ignore：不认行内的 noqa: complexipy；--snapshot-ignore：不认基线快照 complexipy-snapshot.json；
      # --isolated：不读 pyproject.toml、complexipy.toml 里的配置。要放宽只能改 MAX_COMPLEXITY。
      echo "== Python 函数认知复杂度不超过 $MAX_COMPLEXITY"
      complexipy --max-complexity-allowed "$MAX_COMPLEXITY" --no-ignore --snapshot-ignore --isolated --failed --plain \
        -- "${PY[@]}"
    else
      echo "== ruff check、函数认知复杂度：没有要查的 Python 文件"
    fi
  fi
  if [ "$SHELLCHECK" -eq 1 ] && [ ${#SH[@]} -gt 0 ]; then
    echo "== shellcheck"
    shellcheck "${SHELLCHECK_ARGS[@]}" -- "${SH[@]}"
  fi
  if [ ${#SWIFT[@]} -gt 0 ]; then
    echo "== SwiftLint"
    swiftlint lint --strict --quiet --no-cache -- "${SWIFT[@]}"
  fi
  lizard_check java Java "${JAVA[@]}"
  lizard_check swift Swift "${SWIFT_LIZARD[@]}"
  lizard_check csharp 'C#' "${CS[@]}"
  if [ "$MAX_LINES" -gt 0 ]; then
    echo "== 代码文件不超过 $MAX_LINES 行"
    # 列出超过上限的文件并非零退出。末尾加 /dev/null 保证 wc 总会多打一行合计，sed 把这一行去掉。
    wc -l -- "${LINES[@]}" /dev/null | sed '$d' | awk -v max="$MAX_LINES" '$1 > max { print; bad = 1 } END { exit bad }'
  fi
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
if [ ${#PRETTIER_FILES[@]} -gt 0 ]; then
  if [ "$CHECK" -eq 1 ]; then
    prettier --check -- "${PRETTIER_FILES[@]}" || FAIL=1
  else
    prettier --write --log-level warn -- "${PRETTIER_FILES[@]}"
  fi
fi
if [ "$SHFMT" -eq 1 ] && [ ${#SH[@]} -gt 0 ]; then
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
# Go 文件按所属模块（往上最近的 go.mod 所在目录）分组：每个模块先核对 go 行固定的工具链（gate_go_version），
# 再用这份工具链自带的 gofmt。gofmt 的输出随 Go 版本变，PATH 里的 gofmt 属于本机那份 Go，不一定是同一版。
module_of() {
  local d=$1
  while [ "$d" != . ]; do
    case $d in */*) d=${d%/*} ;; *) d=. ;; esac
    [ "$d" = . ] || [ ! -f "$d/go.mod" ] || break
  done
  MODULE=$d
}
if [ ${#GO[@]} -gt 0 ]; then
  GO_MODULE=()
  MODULES=()
  for f in "${GO[@]}"; do
    module_of "$f"
    GO_MODULE+=("$MODULE")
    [[ " ${MODULES[*]} " == *" $MODULE "* ]] || MODULES+=("$MODULE")
  done
  for mod in "${MODULES[@]}"; do
    members=()
    for i in "${!GO[@]}"; do
      if [ "${GO_MODULE[$i]}" = "$mod" ]; then members+=("${GO[$i]}"); fi
    done
    if ! gate_go_version "$mod"; then
      FAIL=1
      continue
    fi
    gofmt_bin="$(cd "$mod" && go env GOROOT)/bin/gofmt"
    if [ "$CHECK" -eq 1 ]; then
      # 解析失败时非零退出、原因已在 stderr；有输出则列出需要重排的文件。
      rc=0
      bad=$("$gofmt_bin" -l -- "${members[@]}") || rc=$?
      if [ "$rc" -ne 0 ]; then
        FAIL=1
      elif [ -n "$bad" ]; then
        printf 'gofmt: 需要重排：\n%s\n' "$bad"
        FAIL=1
      fi
    else
      "$gofmt_bin" -w -- "${members[@]}"
    fi
  done
fi

if [ "$CHECK" -eq 1 ]; then
  if [ "$FAIL" -eq 0 ]; then
    echo "format: ok"
  else
    echo "format: 格式不一致，运行 scripts/format.sh 修复" >&2
  fi
fi
exit "$FAIL"
