# Furnace

个人 iPhone 计算负载实验室。针对 iPhone 18 Pro Max / iOS 27，支持 CPU、GPU、NPU 单独运行、两路组合和三路并发。前台持续提交负载，温度变化只记录，不主动减载。系统仍掌握硬件调度、调频和进程生命周期。

## 下载与安装

1. 打开 [iOS build](https://github.com/dzshzx/iphone-furnace/actions/workflows/ios.yml)，选择最新成功运行。
2. 下载 `Furnace-unsigned-<编号>` artifact，解压得到 `Furnace-unsigned.ipa`。
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

私有 API 在普通签名的目标 iPhone 上是否可访问仍需真机验证。符号存在不等于可用；权限错误不会回退成 CPU 并冒充成功。调用可能使进程终止：App 会保留进入私有调用前的阶段，下次启动显示中断位置并默认选择 Core ML。缺少 `summary.json` 的报告属于中断会话。

Core ML 后端使用 `.cpuAndNeuralEngine`，检查主要卷积预计被分配到 ANE；预计分配不证明实际执行位置，系统运行时仍可能调整调度。

## 指标与报告

| 字段 | 含义 |
|---|---|
| CPU % | 当前进程 CPU 时间增量 / 墙钟时间 / 设备核心数；包含 GPU/NPU 调度 |
| GPU 次/秒、ms | 本 App 完成的批次数和 command buffer 时间，不是整颗 GPU 利用率 |
| NPU 次/秒、ms | 推理完成次数及端到端时间；Core ML 分配计划单独记录 |
| 内存 | 进程 physical footprint |
| 热状态 | 系统 nominal/fair/serious/critical 分类，不是摄氏温度 |
| 功耗、ANE 利用率 | 不可用，不推算或显示虚构数值 |

每次会话生成 `metadata.json`、`samples.jsonl`、`samples.csv` 和 `summary.json`。元数据包含配置、系统、设备、版本和指标口径。界面只保留最近 180 个样本；单次逐秒日志达到 64 MiB 后停止写入新样本，继续计算，最终 summary 记录丢弃样本数及累计值。已有日志不自动删除。

如需进一步验证 ANE 执行及功耗趋势，可附加 iOS 的 Performance Trace，或通过 Mac 上的 Instruments 采集；App 中含 `FurnaceSession` signpost。连接充电器时 Power Profiler 的整机功耗读数有额外限制，见 [Apple 文档](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)。

## 构建

本地 Linux 只需要 `uv` 生成模型与验证 Python 工具；Swift/Metal 的编译和模拟器验证在 GitHub 的 Apple Silicon `xcode-27` runner 完成。

```sh
uv sync --frozen
uv run python scripts/generate_models.py
uv run python scripts/generate_icon.py
# 以下命令需要 Xcode 27.0 和 XcodeGen 2.46.0：
xcodegen generate
bash scripts/build.sh
```

工作流锁定依赖、Action 提交与 XcodeGen 下载摘要，显式选择 iOS 27 SDK。先编译设备版，再跑模拟器测试，全部通过后上传 arm64 Release IPA；包验证器拒绝模拟器二进制、缺失模型/Metal 内核及意外签名包。产物附带 dSYM、工具链/Git 信息和模拟器界面截图。仅修改 README/验证文档不重新构建。版本 `0.1.0` 表示开发构建，build 号取 Actions run number。

测试：Xcode 的 `Furnace` scheme 包含会话生命周期、七种选择组合、错误回收、报告、原生 CPU 校验和模拟器 NPU 不可用测试。模拟器与云端 macOS 结果不能证明目标 iPhone 的 GPU/ANE 性能。

## 结构与依赖

- `Sources/Core`：会话、协议、遥测和报告。
- `Sources/Engines`、`Sources/Native`：独立 CPU/Metal/Core ML 引擎与私有桥接。引擎资源仅在准备、运行、清理三个阶段流转；停止完成后才能创建下一次会话。
- `scripts`：可重复模型/图标生成、构建及 IPA 完整性验证；`project.yml` 为工程来源。

运行时使用 Apple 系统框架；模型生成复用 coremltools/NumPy，工程生成复用 XcodeGen。专用 CPU/Metal 压测内核和私有 ABI 桥接是本项目的领域实现。第三方代码归属见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 验收状态

云端构建、模拟器测试、真机安装、持续负载和 ANE 执行分别验收。实际结果记录在 [docs/validation.md](docs/validation.md)。用户在手机自签安装后导出完整自测报告，才能继续确认默认负载参数和真机结果。
