# 构建与发版

本文是开发者文档：本地构建与检查、云端验证、发版流程和代码结构。下载、安装与使用见 [README](../README.md)。

## 构建

本地 Linux 使用 `uv` 和 C++20 编译器（`c++`）生成模型、验证模型与原生数据格式，用 Go（版本见 `go.mod`）运行构建工具 `cmd/furnace-tools`（发版版本号与发版摘要、验证报告、IPA 检查、图标生成）；Swift/Metal 的编译和模拟器验证在 GitHub 的 Apple Silicon `xcode-27` runner 完成。

```sh
uv sync --locked
uv run --locked python scripts/generate_models.py
go run ./cmd/furnace-tools generate-icon
uv run --locked pytest scripts/tests
go test ./...
bash scripts/format.sh --check
bash scripts/format.sh --lint
# 以下命令需要 Xcode 27.0 和 XcodeGen 2.46.0：
xcodegen generate
bash scripts/build.sh
```

`scripts/format.sh` 就地格式化（Python 用 ruff format，Go 用 gofmt，Markdown/YAML/JSON 用 prettier，Shell 用 shfmt；版本固定在脚本内，配置见 `pyproject.toml` 的 `[tool.ruff]`、`.prettierrc.json`、`.editorconfig`，字节须保持不变的文件列在脚本 `EXCLUDE` 与 `.prettierignore`）。`scripts/format.sh --check` 只检查格式；`scripts/format.sh --lint` 跑 ruff check、shellcheck、SwiftLint（默认规则集，警告也算失败，配置见 `.swiftlint.yml`）、Python 函数认知复杂度上限（15，用 complexipy 量）、Swift 函数圈复杂度上限（15，用 lizard 量；两者都不认豁免注释，complexipy 也不认基线快照和配置文件里的放宽）与代码文件行数上限（2000 行）；两者有问题时非零退出，CI 同样运行它们。Linux x86_64 上脚本按固定版本与 SHA-256 下载 SwiftLint 静态二进制，缓存在 `~/.cache/furnace/`；静态版没有 SourceKit，默认规则里的 `statement_position` 在 Linux 上跳过，输出里有一行 warning。重排提交登记在 `.git-blame-ignore-revs`，本地运行 `git config blame.ignoreRevsFile .git-blame-ignore-revs` 让 blame 跳过它。

Linux 工具检查的汇总入口是 `bash scripts/check.sh`（格式、ruff check、shellcheck 与 SwiftLint 等检查、Python 允许清单、Go 的版本断言、go vet、staticcheck、认知复杂度与 go test、`uv sync --locked`、模型与图标生成、pytest，并要求生成后已跟踪文件不变；仓里的 Python 只能是 `scripts/python-allowlist.txt` 列出的文件，即依赖 coremltools 的模型生成与模型测试），**Build tools checks**（只由 **Release** 工作流调用）直接运行它。合入前运行 `bash scripts/check.sh`；普通提交与 PR 不触发远端 CI。依赖按周批量升级。按需触发 **Release** 工作流时，先算出版本号，再调用 **Build tools checks**（`.github/workflows/ci.yml`）完成格式与检查、模型/图标生成和 Python/原生数据构建测试，再做 macOS 原生构建、模拟器测试和 IPA 验证。Linux 工具检查本身不代表 Apple 平台或真机验收完成。

验证 Apple 平台改动时，在任意分支以 dry_run 运行发版工作流：`gh workflow run release.yml --ref <分支> -f dry_run=true`。它先复用同一套 Linux 检查，通过后才启动 macOS，完整执行私有 ANE 原生检查、Core ML 计算计划检查、设备构建和模拟器测试，最后在运行摘要里列出将要发布的版本、源提交和各资产 sha256，不打 tag、不发布。同一分支上新的 dry_run 会取消旧运行；正式发版排队执行，不被取消。

同次 macOS 运行的 Summary 和 `build-diagnostics-<编号>` 内 `validation-report.md` 记录提交/build 号、工具版本、准备/构建/测试耗时、模拟器通过/失败/跳过数及可提取的原因。原始 `tests.xcresult` 与构建、测试日志仍随诊断产物保留。报告分别列出模拟器、未签名 IPA、真机与 ANE 状态；CI 无真机时后两项保持 pending。手机人工验收记录字段见 [验证记录](validation.md#同提交完整验收清单)。报告只使用 CI 的合成测试和构建证据，不收集手机报告、凭据或环境变量。

工作流锁定依赖、Action 提交与 XcodeGen 下载摘要，显式选择 iOS 27 SDK。先编译设备版，再跑模拟器测试；两者通过后才打 tag 并发布 arm64 Release IPA，截图步骤失败不影响发布已验证的安装包。包验证器拒绝模拟器二进制、缺失模型/Metal 内核及意外签名包。dSYM、工具链/Git 信息和截图放在诊断产物中。

构建环境的关键约定：

- GitHub 镜像可能未安装 Metal 编译组件；工作流显式执行 `xcodebuild -downloadComponent MetalToolchain`。
- 测试和截图共用显式选定的模拟器 UUID，关闭测试克隆，并在截图前确认启动状态。
- 安装包只经 GitHub Release 交付，不作为 Actions 产物保存；诊断文件经 `actions/upload-artifact` 归档，保留 7 天。
- 只有发布步骤需要 `contents: write`；checkout 设 `persist-credentials: false`，令牌不写进 git 配置，也不进入构建脚本的环境变量。

模型生成后可运行 `uv run --locked pytest scripts/tests` 验证模型，`go test ./...` 验证构建工具；Xcode 的 `Furnace` scheme 包含会话生命周期、七种选择组合、错误回收、报告、原生 CPU、Metal 和模型数值校验，以及模拟器 NPU 不可用测试。完整 Xcode 命令以工作流为准。模拟器与云端 macOS 结果不能证明目标 iPhone 的 GPU/ANE 性能。

计算计划回归覆盖三档真实编译模型的卷积识别，以及 CPU/GPU/未知分配必须拒绝启动。云端另用 `scripts/check_compute_plan.swift` 检查 macOS 的 CPU-only 与 CPU+ANE 计划，记录原始算子名；宿主是否可用 ANE 不作为 iPhone 验收结论。

私有后端的原生检查为 `bash scripts/check_private_ane.sh`（需要 macOS）。它先用模型替身检查四个实际 ObjC 调用的优先级、请求和错误传递，再运行 App 使用的框架加载、模型构造、真实标识验证和模型文件写入路径，覆盖三档通道数；ANE 编译、加载与实际执行仍需要真机验证。失败报告保留私有后端阶段及底层错误域/错误码。

## 发版

发版只有一条命令：`gh workflow run release.yml --ref master -f bump=patch`。`bump` 可选 `patch`、`minor`、`major`；minor（用户能感知的新能力）与 major（含 0.x→1.0）须维护者先确认，内部重构、目录搬迁、删兼容层不算破坏性变更。加 `-f dry_run=true` 只验证不发布，可在任意分支运行；正式发版只能在 `master` 上运行。

- 版本号：工作流取仓库里最高的纯 `vX.Y.Z` tag（按语义化版本比较），按 `bump` 升一档。`scripts/build.sh` 把版本号与 build 号作为 xcodebuild 参数（`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`）传入，不改 `project.yml`，也不提交回仓库；仓里放开发占位值 `0.0.0`，本地构建显示 `0.0.0 (0)`。
- build 号（`CURRENT_PROJECT_VERSION`）：`major × 1000000 + minor × 1000 + patch`，例如 `0.1.1` 为 `1001`，随版本单调递增；minor 或 patch 达到 1000 时工作流报错。
- 流程：核对分支、是否已发过版并算出版本号 → Linux 门禁 → 带新版本号的 macOS 构建与模拟器测试 → 核对 IPA 里的版本号与 build 号 → 删除同名旧草稿 → 建含全部资产的草稿 Release → 打附注 tag `v<版本号>` → 草稿转正。资产为 `Furnace-unsigned.ipa` 与 `.sha256`，正文为 `validation-report.md` 加 `source_commit`。
- 已发过版：`master` 头提交带纯 `vX.Y.Z` tag，且同名 GitHub Release 已发布（非草稿）。这时正式发版在门禁之前直接失败。
- 续跑：头提交有这样的 tag 但同名 Release 未发布，说明上次发版没做完；重跑时沿用这个版本（不再升档），跳过打 tag，继续发布。
- 出错后怎么办：修好后用同一条命令重跑，不用手工删 tag、删草稿或补发布。已发布的 tag 不移动、不删除、不复用，版本只升不降，出问题修代码后发下一个 patch。

## 结构与依赖

领域术语见 [GLOSSARY.md](../GLOSSARY.md)。

- `Sources/Core`：会话、协议、遥测和报告。
- `Sources/Engines`、`Sources/Native`：独立 CPU/Metal/Core ML 引擎与私有桥接。引擎资源仅在准备、运行、清理三个阶段流转；停止完成后才能创建下一次会话。
- `scripts`：可重复模型/图标生成、构建及 IPA 完整性验证；`project.yml` 为工程来源。

运行时使用 Apple 系统框架；模型生成复用 coremltools/NumPy，工程生成复用 XcodeGen，构建工具 `cmd/furnace-tools` 用 howett.net/plist 读 Info.plist。专用 CPU/Metal 压测内核和私有 ABI 桥接是本项目的领域实现。第三方代码归属见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
