# Furnace

个人 iPhone 计算负载实验室。针对 iPhone 18 Pro Max / iOS 27，支持 CPU、GPU、NPU 单独运行、两路组合和三路并发。前台持续提交负载，温度变化只记录，不主动减载。系统仍掌握硬件调度、调频和进程生命周期。

## 下载与安装

1. 打开 [Releases](https://github.com/dzshzx/iphone-furnace/releases/latest)，下载最新版本的 `Furnace-unsigned.ipa`（同目录的 `.sha256` 可核对摘要），直接交给签名工具。新安装包只随版本号发布，见「构建」中的发版说明。
2. 符号、构建信息和截图在对应 [iOS build](https://github.com/dzshzx/iphone-furnace/actions/workflows/ios.yml) 运行的 `build-diagnostics-<编号>` 产物中，保留 7 天。
3. 使用自己的签名工具、开发者证书和包含设备的描述文件重新签名并安装。IPA 本身未签名，不能直接点击安装；无需向本仓库或 GitHub 提供 Apple 账号。
4. 如系统要求，在“设置 → 隐私与安全性 → 开发者模式”开启开发者模式。首次启动使用 Core ML 后端。

可以使用 Windows/macOS 上的 [Sideloadly](https://sideloadly.io/) 或已有自签工具。iOS 27 的具体安装兼容性以设备和签名工具的实际结果为准。不要向 App 添加未获描述文件授权的私有 entitlement；动态加载私有框架本身不授予这些权限。

## 使用

- 点选 CPU / GPU / NPU；底部“开始压测”启动，“停止”等待在途计算结束。运行中不修改配置。
- 默认三路开启、持续运行、屏幕亮度保持不变。可选 5、15、30 分钟。
- CPU 默认使用运行时可用核心数；GPU 可选 FP32、FP16 矩阵或混合计算/纹理；Core ML 可选 256/384/512 通道以及 1/2/4 路独立请求。
- “运行完整自测”执行七种组合各一分钟，再执行十五分钟三路联合；准备时间另计。任一后端失败会结束整个会话和后续自测，并保留报告。
- “比较 NPU 1 / 2 / 4 路并发”使用当前模型通道数，每档运行三十秒，生成三份可对比的报告。自动测试结束或取消后恢复原手动配置。
- 锁屏、进入后台或系统内存警告会结束会话。回到前台不会自动恢复。
- “历史报告”可分享 JSON/CSV；也可在“文件 → 我的 iPhone → Furnace → Reports”读取。

单烤只控制压力引擎，GPU/NPU 运行时仍需要 CPU 调度。实验使用合成工作负载，没有将计算次数称为硬件利用率，也没有声称已经达到整机最高瓦数。

## 私有 ANE 实验

点击“NPU 后端”可选择私有 ANE 实验。它动态探测 `_ANEInMemoryModel` 路径，执行编译、加载、双输入验证后才开始持续运行。此后端串行执行，不使用 Core ML 并发设置。

私有模型标识按框架返回的下划线连接格式保留，同时限制为安全的单层目录名。权重使用 MILBlob v2 文件头、每层实际字节数和绝对数据偏移；构建测试使用 coremltools 读取三档模型的全部 16 层权重。

私有模型的编译、加载、执行和卸载统一使用 `QOS_CLASS_DEFAULT`（21）。目标设备曾将数值 0 的请求拒绝为需要受限连接的实时优先级；普通优先级不代表已获得私有权限，后续仍以设备的编译、加载和执行结果为准。

私有 API 在普通签名的目标 iPhone 上是否可访问仍需真机验证。符号存在不等于可用；权限错误不会回退成 CPU 并冒充成功。调用可能使进程终止：App 会保留进入私有调用前的阶段，紧接的下一次启动显示一次中断位置（读到即清除）并默认选择 Core ML。缺少 `summary.json` 的报告属于中断会话。

Core ML 后端使用 `.cpuAndNeuralEngine`，识别包含版本前缀的卷积算子，并检查卷积全部预计被分配到 ANE。报告保留原始算子名和 ANE/CPU/GPU/未知分配计数；无法识别卷积与未分配到 ANE 分别报错。预计分配不证明实际执行位置，系统运行时仍可能调整调度。

## 指标与报告

| 字段             | 含义                                                             |
| ---------------- | ---------------------------------------------------------------- |
| CPU %            | 当前进程 CPU 时间增量 / 墙钟时间 / 设备核心数；包含 GPU/NPU 调度 |
| GPU 次/秒、ms    | 本 App 完成的批次数和 command buffer 时间，不是整颗 GPU 利用率   |
| NPU 次/秒、ms    | 推理完成次数及端到端时间；Core ML 分配计划单独记录               |
| 内存             | 进程 physical footprint                                          |
| 热状态           | 系统 nominal/fair/serious/critical 分类，不是摄氏温度            |
| 功耗、ANE 利用率 | 不可用，不推算或显示虚构数值                                     |

每次会话生成 `metadata.json`、`samples.jsonl`、`samples.csv` 和 `summary.json`。元数据包含配置、系统、设备、版本和指标口径。界面只保留最近 180 个样本；单次逐秒日志达到 64 MiB 后停止写入新样本，继续计算，最终 summary 记录丢弃样本数及累计值。已有日志不自动删除。

如需进一步验证 ANE 执行及功耗趋势，可附加 iOS 的 Performance Trace，或通过 Mac 上的 Instruments 采集；App 中含 `FurnaceSession` signpost。连接充电器时 Power Profiler 的整机功耗读数有额外限制，见 [Apple 文档](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)。

## 构建

本地 Linux 使用 `uv` 和 C++20 编译器（`c++`）生成模型、验证 Python 工具与原生数据格式；Swift/Metal 的编译和模拟器验证在 GitHub 的 Apple Silicon `xcode-27` runner 完成。

```sh
uv sync --frozen
uv run --locked python scripts/generate_models.py
uv run --locked python scripts/generate_icon.py
uv run --locked pytest scripts/tests
bash -n scripts/build.sh scripts/check_private_ane.sh
bash scripts/format.sh --check
# 以下命令需要 Xcode 27.0 和 XcodeGen 2.46.0：
xcodegen generate
bash scripts/build.sh
```

提交前运行 `scripts/format.sh` 就地格式化（Python 用 ruff format，Markdown/YAML/JSON 用 prettier，Shell 用 shfmt；版本固定在脚本内，配置见 `pyproject.toml` 的 `[tool.ruff]`、`.prettierrc.json`、`.editorconfig`，字节须保持不变的文件列在脚本 `EXCLUDE` 与 `.prettierignore`）。`scripts/format.sh --check` 只检查，不一致时非零退出，CI 同样运行它。重排提交登记在 `.git-blame-ignore-revs`，本地运行 `git config blame.ignoreRevsFile .git-blame-ignore-revs` 让 blame 跳过它。

日常改动完成本地工具检查后用 `land --no-recut` 同步 master；不触发普通提交或 PR 的远端 CI。Renovate PR 经对应门禁验收后人工合入。按需触发 **iOS build** 时，先调用 **Build tools checks**（`.github/workflows/ci.yml`）完成格式、模型/图标生成、shell 语法和 Python/原生数据构建测试，再做 macOS 原生构建、模拟器测试和 IPA 验证。Linux 工具检查本身不代表 Apple 平台或真机验收完成。

需要交付或验证 Apple 平台改动时，手动运行 **iOS build**。它先复用同一套 Linux 检查，通过后才启动 macOS，完整执行私有 ANE 原生检查、Core ML 计算计划检查、设备构建和模拟器测试。两套工作流各自取消同一分支的旧运行，普通提交的工具检查不会取消手动构建。

同次 macOS 运行的 Summary 和 `build-diagnostics-<编号>` 内 `validation-report.md` 记录提交/build 号、工具版本、准备/构建/测试耗时、模拟器通过/失败/跳过数及可提取的原因。原始 `tests.xcresult` 与构建、测试日志仍随诊断产物保留。报告分别列出模拟器、未签名 IPA、真机与 ANE 状态；CI 无真机时后两项保持 pending。手机人工验收记录字段见 [验证记录](docs/validation.md#同提交完整验收清单)。报告只使用 CI 的合成测试和构建证据，不收集手机报告、凭据或环境变量。

工作流锁定依赖、Action 提交与 XcodeGen 下载摘要，显式选择 iOS 27 SDK。先编译设备版，再跑模拟器测试；两者通过后发布 arm64 Release IPA，即使截图步骤失败也照常发布已验证安装包。包验证器拒绝模拟器二进制、缺失模型/Metal 内核及意外签名包。dSYM、工具链/Git 信息和截图放在诊断产物中。

发版：版本号取 `project.yml` 的 `MARKETING_VERSION`，build 号取 Actions run number。在 `master` 上运行 iOS build 且 tag `v<版本号>` 尚不存在时，工作流把 IPA 与 `.sha256` 发布为 GitHub Release，正文为 `validation-report.md`；tag 已存在或不在 `master` 上运行时只做验证、不出安装包。要出新安装包，先提交升级后的 `MARKETING_VERSION`（默认升 patch）再运行。已发布的 tag 不移动、不复用，修复用下一个 patch。

构建环境的关键约定：

- GitHub 镜像可能未安装 Metal 编译组件；工作流显式执行 `xcodebuild -downloadComponent MetalToolchain`。
- 测试和截图共用显式选定的模拟器 UUID，关闭测试克隆，并在截图前确认启动状态。
- 安装包只经 GitHub Release 交付，不作为 Actions 产物保存；诊断文件经 `actions/upload-artifact` 归档，保留 7 天。
- 只有发布步骤需要 `contents: write`；checkout 设 `persist-credentials: false`，令牌不写进 git 配置，也不进入构建脚本的环境变量。

模型生成后可运行 `uv run --locked pytest scripts/tests` 验证构建工具；Xcode 的 `Furnace` scheme 包含会话生命周期、七种选择组合、错误回收、报告、原生 CPU、Metal 和模型数值校验，以及模拟器 NPU 不可用测试。完整 Xcode 命令以工作流为准。模拟器与云端 macOS 结果不能证明目标 iPhone 的 GPU/ANE 性能。

计算计划回归覆盖三档真实编译模型的卷积识别，以及 CPU/GPU/未知分配必须拒绝启动。云端另用 `scripts/check_compute_plan.swift` 检查 macOS 的 CPU-only 与 CPU+ANE 计划，记录原始算子名；宿主是否可用 ANE 不作为 iPhone 验收结论。

私有后端的原生检查为 `bash scripts/check_private_ane.sh`（需要 macOS）。它先用模型替身检查四个实际 ObjC 调用的优先级、请求和错误传递，再运行 App 使用的框架加载、模型构造、真实标识验证和模型文件写入路径，覆盖三档通道数；ANE 编译、加载与实际执行仍需要真机验证。失败报告保留私有后端阶段及底层错误域/错误码。

## 结构与依赖

领域术语见 [GLOSSARY.md](GLOSSARY.md)。

- `Sources/Core`：会话、协议、遥测和报告。
- `Sources/Engines`、`Sources/Native`：独立 CPU/Metal/Core ML 引擎与私有桥接。引擎资源仅在准备、运行、清理三个阶段流转；停止完成后才能创建下一次会话。
- `scripts`：可重复模型/图标生成、构建及 IPA 完整性验证；`project.yml` 为工程来源。

运行时使用 Apple 系统框架；模型生成复用 coremltools/NumPy，工程生成复用 XcodeGen。专用 CPU/Metal 压测内核和私有 ABI 桥接是本项目的领域实现。第三方代码归属见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 验收状态

云端构建、模拟器测试、真机安装、持续负载和 ANE 执行分别验收。实际结果记录在 [docs/validation.md](docs/validation.md)。用户在手机自签安装后导出完整自测报告，才能继续确认默认负载参数和真机结果。
