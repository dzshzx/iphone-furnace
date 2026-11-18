# shellcheck shell=bash
# 门禁共用的常量与函数，由各仓的门禁脚本与 scripts/format.sh 用 source 读入，不单独运行。
# 本文件与 scripts/format.sh 在各仓逐字节相同，由同步命令 gate-sync 从同一份源头写入；要改就改源头再同步，
# 不在各仓里单独改。
# 只用 POSIX sh 语法（另用 local）：有的仓用 sh 运行门禁、对 scripts/*.sh 跑 sh -n，或要兼容 bash 3.2。
# 函数失败时返回非零、原因写到 stderr，不退出调用方的 shell。
# shellcheck disable=SC2034 # 常量由读入本文件的脚本使用

# 工具版本，各仓只在这里写一次。
PRETTIER_VERSION=3.10.1
SHFMT_VERSION=3.14.1
# PyPI 包 shfmt-py 分发 shfmt，该版本内置上面的 shfmt。
SHFMT_PY_VERSION=4.2.0
SHELLCHECK_VERSION=0.11.0
# PyPI 包 shellcheck-py 分发 shellcheck，该版本内置上面的 shellcheck。
SHELLCHECK_PY_VERSION=0.11.0.1
RUFF_VERSION=0.17.5
COMPLEXIPY_VERSION=9.0.0
LIZARD_VERSION=1.26.0
SWIFTLINT_VERSION=0.65.1
# 该版本 GitHub Release 资产 swiftlint_linux_amd64.zip 的 SHA-256。
SWIFTLINT_LINUX_AMD64_SHA256=caeed6f4a679c35539ffaf124f6c4ab4a8416917f7d8796279dc52b74026059d
# Go 的检查器与复杂度工具经 gate_go_run 取用，不进 go.mod。
STATICCHECK=honnef.co/go/tools/cmd/staticcheck@v0.8.2
GOCOGNIT=github.com/uudashr/gocognit/cmd/gocognit@v1.3.0

# 上限：单个代码文件的行数；单个函数的复杂度（Python 量认知复杂度，Java、Swift、C#、Kotlin 量圈复杂度）；
# 单个 Go 函数的认知复杂度（测试文件里的函数也算）。
MAX_LINES=2000
MAX_COMPLEXITY=15
MAX_COGNITIVE=30

# gate_go_run <包@版本> [参数...]：go run 包@版本，先查本机模块缓存，缓存里没有才走原来的代理下载。
gate_go_run() {
  GOPROXY="file://$(go env GOMODCACHE)/cache/download,$(go env GOPROXY)" go run "$@"
}

# gate_go_version <目录>：Go 工具链版本只写在 <目录>/go.mod 的 go 行，并且在 <目录> 里 go 命令选出的就是这一版。
# 本机的 Go 比 go 行旧时 go 命令自己下载并换用这一版；比它新时直接用本机那一版，这里报出来。
# toolchain 行会让 go 命令和 CI 的 setup-go 改按它选版本，版本就有了第二个来源，所以不许有。
gate_go_version() {
  local want have
  if grep -q '^toolchain' "$1/go.mod"; then
    echo "gate: $1/go.mod 不应有 toolchain 行，版本只由 go 行固定" >&2
    return 1
  fi
  want=go$(sed -n 's/^go \([0-9][0-9.]*\)$/\1/p' "$1/go.mod")
  have=$(cd "$1" && go env GOVERSION 2>/dev/null) || have=
  if [ "$have" != "$want" ]; then
    echo "gate: $1 的 Go 工具链是 ${have:-（没有 go）}，与 $1/go.mod 的 $want 不符：把 go 行改成本机这一版，或设 GOTOOLCHAIN=$want 运行" >&2
    return 1
  fi
}

# gate_no_marker <标记> <路径模式...>：在受跟踪的文件里找标记（git grep），找到就列出并失败。
# 复杂度与检查器不认代码里的豁免标记（gocognit:ignore、biome-ignore 等）：工具自己会跳过带标记的代码，所以另查一遍。
gate_no_marker() {
  local marker
  marker=$1
  shift
  if git grep -n -e "$marker" -- "$@"; then
    echo "gate: 不接受上面的 $marker 标记，要放宽只能改上限" >&2
    return 1
  fi
}

# gate_python_allowlist [清单文件]：受跟踪的 *.py 只能是清单列出的，清单默认 scripts/python-allowlist.txt。
# 清单每行是精确路径，或以 / 结尾的目录（# 起注释），每一行都要还对得上至少一个文件。只按路径判断，不读文件内容。
# 没有清单文件时仓里不许有任何 .py。
gate_python_allowlist() {
  local list py
  list=${1:-scripts/python-allowlist.txt}
  if [ ! -f "$list" ]; then
    py=$(git ls-files -- '*.py')
    if [ -n "$py" ]; then
      printf 'gate: 仓里不许有 Python 文件，改用 Go：\n%s\n' "$py" >&2
      return 1
    fi
    return 0
  fi
  git ls-files -z -- '*.py' | tr '\0' '\n' | awk -v list="$list" '
    NR == FNR { if ($0 != "" && $0 !~ /^#/) { allow[$0] = 1; used[$0] = 0 } next }
    {
      hit = 0
      for (a in allow) if ($0 == a || (a ~ /\/$/ && index($0, a) == 1)) { used[a] = 1; hit = 1 }
      if (!hit) { print "gate: " $0 " 是 Python，不在 " list " 里；改用 Go，或登记进清单并写明原因"; bad = 1 }
    }
    END {
      for (a in used) if (!used[a]) { print "gate: " list " 这一行没有对应的文件：" a; bad = 1 }
      exit bad
    }' "$list" - >&2
}

# gate_go_deps <清单文件> <包模式...>：这些包（按 linux/amd64、CGO_ENABLED=0 构建）链接的第三方 Go 模块与清单逐行相同，
# 多一个少一个都失败。清单一行一个模块路径、按字典序（LC_ALL=C）不重复，# 起注释。在 go.mod 所在目录调用。
gate_go_deps() {
  local list want got status
  list=$1
  shift
  want=$(mktemp)
  got=$(mktemp)
  status=0
  grep -v '^[[:space:]]*\(#\|$\)' "$list" >"$want" || [ -f "$list" ] || status=1
  if [ "$status" -eq 0 ] && ! LC_ALL=C sort -u -c "$want" 2>/dev/null; then
    echo "gate: $list 须按字典序排列且不重复" >&2
    status=1
  fi
  if [ "$status" -eq 0 ] && ! GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go list -deps \
    -f '{{if not .Standard}}{{with .Module}}{{if not .Main}}{{.Path}}{{end}}{{end}}{{end}}' "$@" >"$got"; then
    status=1
  fi
  if [ "$status" -eq 0 ]; then
    sed '/^$/d' "$got" | LC_ALL=C sort -u >"$got.sorted"
    if ! cmp -s "$want" "$got.sorted"; then
      echo "gate: 链接的第三方模块与 $list 不符（< 清单，> 实际）：" >&2
      diff "$want" "$got.sorted" >&2
      status=1
    fi
    rm -f "$got.sorted"
  fi
  rm -f "$want" "$got"
  return "$status"
}
