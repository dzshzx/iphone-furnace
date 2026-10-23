# 验证记录

目标：iPhone 18 Pro Max，iOS 27 正式版，普通开发者签名，前台运行。

当前可下载交付为开发构建 `0.1.0 (19)`。2026-10-09（北京时间）对源码提交 `e8f603605fd11904c3ae2f28ab5b4159aebba015` 手动运行 `iOS build`，同一运行先完成 Linux 工具检查，再完成 macOS 构建；2026-10-14 重新下载 IPA 验证。

- [同提交完整 iOS 运行](https://github.com/dzshzx/iphone-furnace/actions/runs/37899722943)：Linux 工具检查（13 项测试）与 macOS 构建均成功
- [Release v0.1.0](https://github.com/dzshzx/iphone-furnace/releases/tag/v0.1.0)：build 19 未签名 IPA 与 `.sha256`；tag 指向上述源码提交，IPA 由 Actions 产物在过期前取回后发布，摘要与原产物一致
- build 19 诊断产物（报告、日志、xcresult、构建信息与截图）已于 2026-10-16 过期删除

新安装包按 [README](../README.md#构建) 的发版说明随版本号发布为 GitHub Release。build 15（[完整运行](https://github.com/dzshzx/iphone-furnace/actions/runs/35850124766)，提交 `550edff7ff680ca08300da43a472bdcdbbe2236f`）的产物已过期删除，与 build 14 的[完整运行](https://github.com/dzshzx/iphone-furnace/actions/runs/35838168344)（提交 `d16e06544cd996dd76618f18134f88b6c9aba5fe`）一并保留为历史证据。build 15 之后改动 App 源码的提交为 `ab6a88d`（私有 ANE 中断提示只显示一次）与 `64a7d7e`（Swift 改用 Mutex 与 Duration.formatted）。普通提交与手动 iOS 构建的分工见 [README](../README.md#构建)。

build 19 实际工具链为 Xcode 27.0 / build 27A266a、iOS SDK 27.0、macOS 27.0 / 26A428、Python 3.14.7、uv 0.12.24、XcodeGen 2.46.0。macOS 准备、设备构建、模拟器测试分别耗时 198 / 27 / 33 秒。完整计时和阶段状态在诊断产物的 `validation-report.md`。
构建机上的模拟器计算使用宿主硬件，不作为目标 iPhone 的性能证据。

| 验证项                    | 状态                     | 证据                                                                                                                                                                                                                                                  |
| ------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 三档模型生成              | 已通过                   | 本地 coremltools 9.0，256/384/512 通道模型完成转换                                                                                                                                                                                                    |
| Python / 原生数据构建测试 | 已通过                   | build 19 Linux 工具检查通过 13 项；build 15 时 Linux 与 macOS 均通过 10 项，覆盖模型图与 IPA 检查、真实格式的模型标识校验、三档私有权重全部 16 层数值，以及 CI 报告解析                                                                               |
| 私有 ANE 原生模型构造     | 已通过                   | 三档均 `model construction=YES`，阶段“模型文件就绪”，无错误；不涉及 ANE 编译、加载或执行                                                                                                                                                              |
| 私有 ANE 调用参数回归     | 已通过（模型替身）       | 捕获编译、加载、执行、卸载四个实际 ObjC 调用：均为 `QOS_CLASS_DEFAULT=21`；请求对象与底层错误正确传递                                                                                                                                                 |
| macOS Core ML 计算计划    | 已通过                   | 三档模型、CPU-only / CPU+ANE 共六组；每组识别 16 层 `ios18.conv`，旧匹配计数均为 0；宿主均计划分配到 CPU，均被拒绝作为 NPU 压测                                                                                                                       |
| 模拟器测试                | 已通过                   | build 19 iPhone 18 Pro Max / iOS 27.0，17 项、0 失败、0 跳过；`testStopDuringPreparationPreventsLaterStart` 在 xcresult 与测试日志中均为 Passed；涵盖真实 CPU、三种 Metal 负载、Core ML CPU 数值校验及生命周期                                        |
| arm64 未签名 IPA          | 已通过                   | 2026-10-14 下载的 build 19 IPA 与 GitHub artifact 摘要 SHA-256 `934f044ce8ea2155ee2fb1a40dff6f5137b2288f5eb6dc6e6fb5e6b48b3ebb81` 一致；本地重新运行验证器通过；Info.plist 为 `0.1.0 (19)` / iOS 27.0，三档模型、Metal 内核完整，无签名目录和描述文件 |
| 界面截图                  | build 19 模拟器截图正常  | 诊断产物 `simulator-dashboard.png` 显示负载开关、进程 CPU 图表、各路读数和开始按钮（build 15 截图仅白底和状态栏）。模拟器截图不代替真机 UI 验收                                                                                                       |
| 真机安装与启动            | build 8 已获用户运行报告 | `iPhone19,2` / iOS `27.0`；签名方式未提供                                                                                                                                                                                                             |
| 真机 CPU / GPU 初步试跑   | 用户反馈正常             | 2026-09-23 反馈；持续时间、负载组合及对应报告待补                                                                                                                                                                                                     |
| 真机 Core ML NPU 初步试跑 | 修复后用户反馈可运行     | 2026-09-23 反馈，未附新运行的构建号、持续时长和报告；原 build 8 的 `0/0` 失败报告保留为历史证据                                                                                                                                                       |
| 真机持续负载与停止响应    | 待验证                   | 手机完整自测报告                                                                                                                                                                                                                                      |
| ANE 实际执行              | 待验证                   | Core ML 计算计划只表示预计分配；需要真机轨迹                                                                                                                                                                                                          |
| 私有 ANE 普通签名可用性   | 待 QoS 修复版真机复测    | 新截图已越过模型标识检查，编译请求因实时优先级要求受限连接而失败；目标设备编译/加载/双输入校验仍无通过证据                                                                                                                                            |
| 整机功耗上限              | 未测量                   | 不由吞吐量或负载开关推断                                                                                                                                                                                                                              |

CI 保留一项工具提示：未依赖 AppIntents，因此跳过该框架的元数据提取；这与当前功能一致，不影响编译或测试。

修复机制与验证入口统一见 [README 的私有 ANE 与构建说明](../README.md#私有-ane-实验)。以下只保留定位与回归所需的历史证据：

| 失败样例                                                                                                                                                             | 回归证据                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| build 8 的 Core ML 卷积分配为 `0/0`                                                                                                                                  | build 10 起识别 `ios18.conv`；对同一实际计划，旧匹配计数 0，新匹配 16                                                                                              |
| 私有模型标识被拒绝                                                                                                                                                   | [诊断运行 11](https://github.com/dzshzx/iphone-furnace/actions/runs/35833893901)记录三段各 64 个十六进制字符以 `_` 连接，合计 194 字符；修复后保留安全单层目录校验 |
| 私有权重长度固定 1 MiB、数据偏移 0、层数 1                                                                                                                           | 三档全部 16 层已通过 coremltools 读取与数值检查；格式依据 [MILBlob v2](https://github.com/apple/coremltools/blob/9.0/mlmodel/src/MILBlob/Blob/StorageFormat.hpp)   |
| 2026-09-23 16:21 真机截图：`Realtime priority requires restricted access connection`，要求 `com.apple.aned.private.allow`，错误域/码 `com.apple.appleneuralengine/2` | [参数回归运行 13](https://github.com/dzshzx/iphone-furnace/actions/runs/35837854811)的模型替身捕获四个阶段均为 QoS 0；build 14 均为 21，真机执行仍待复测           |

Core ML 持续负载验收可先使用 NPU 单独运行、256 通道、1 路并发，持续约一分钟后停止并导出报告，核对 completed 增长和停止响应。私有后端先单独使用 256 通道复测，并提供 build 号、reason 和 detail。

手机验收时记录签名方式、iOS 完整版本、App build 号、是否充电和环境条件。运行完整自测，确认 UI 可操作、没有持续内存增长、每路计数持续增加，停止后计数停止。停止超过两秒时保留报告，用于缩小单批计算量。

私有后端单独测试。API 不可用是能力探测结果，不能记为 NPU 已验证；若应用退出，导出中断会话并记录下次启动显示的阶段；该提示只在中断后的第一次启动出现，再次启动即消失。

下载包的 bundle ID 为 `com.dzshzx.furnace`，设备类型为 iPhone，方向为竖屏。
用户已反馈 CPU、GPU、Core ML 初步试跑可用；完整持续负载、功耗和 ANE 实际执行仍待各自证据。

## 同提交完整验收清单

每次完整验收固定一个 commit：先核对该 SHA 的 Linux 工具检查，再对同一 SHA 手动运行 `iOS build`。记录 Actions 运行链接、`build-diagnostics-<编号>` 中的 `validation-report.md` / `tests.xcresult` / `build-info.txt`，以及对应的未签名 IPA。`validation-report.md` 列出 Xcode、SDK、macOS、uv、XcodeGen 版本，测试范围与失败/跳过原因，以及准备、构建、测试耗时；失败时继续核对原始日志。未运行或缺少证据的项目保持 pending。

| 字段                                 | 本次记录                                                                                                |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| commit / App 版本与 build 号         | 被验 `e8f603605fd11904c3ae2f28ab5b4159aebba015` / `0.1.0 (19)`；`build-info.txt` 与 IPA 已核对          |
| CI 宿主 / Xcode / iOS SDK / XcodeGen | macOS 27.0 / Xcode 27.0 / iOS SDK 27.0 / XcodeGen 2.46.0；见 `validation-report.md` 与 `build-info.txt` |
| 模拟器设备 / iOS 版本                | iPhone 18 Pro Max / iOS 27.0；见 xcresult destination                                                   |
| 真机型号 / iOS 完整版本 / 签名方式   | pending；由手机验收者填写                                                                               |
| 测试条件                             | pending；充电状态、环境条件、所选负载及持续时间                                                         |

| 步骤                              | 预期                                                                                    | 实际                                                                           | 证据                                                                                           |
| --------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| Linux 工具检查                    | 模型、图标、Python/原生数据构建测试通过                                                 | 通过；13 项测试                                                                | [同次运行的 checks / tools](https://github.com/dzshzx/iphone-furnace/actions/runs/37899722943) |
| macOS 私有原生检查与 Core ML 计划 | 模型构造/调用替身通过；计划识别三档模型                                                 | 通过；四阶段 QoS 均 21，三档构造 YES；六组计划各识别 16 层卷积，宿主均分配 CPU | `private-ane-*.log`、`compute-plan.log`                                                        |
| 模拟器 XCTest                     | 生命周期、选择组合、真实 CPU/Metal/Core ML 调用与准备中停止均通过；失败和跳过逐项记原因 | 通过；17/17、失败 0、跳过 0；准备中停止测试 Passed                             | `validation-report.md`、`tests.xcresult`、`simulator-test.log`                                 |
| 未签名 IPA                        | arm64 iOS 包，模型和 Metal 内核齐全，无签名                                             | 通过；build 19 下载读回及 SHA-256 核对                                         | IPA、`build-info.txt`、`device-build.log`、验证器输出                                          |
| 真机安装与持续负载                | 同 build 可签名安装；完整自测各路计数增加，停止后计数停止，报告完整                     | pending                                                                        | 签名/安装结果及导出的会话报告                                                                  |
| Core ML 实际 ANE 执行             | 真机轨迹证明实际执行位置                                                                | pending                                                                        | Performance Trace 或 Instruments 轨迹                                                          |
| 私有 ANE 普通签名可用性           | 分别记录编译、加载、双输入校验和持续执行阶段                                            | pending                                                                        | 真机阶段、reason/detail、报告或中断记录                                                        |

真机原始资料由验收者保管；CI 诊断包只放构建和模拟器的合成测试证据。填写“通过”时同时写明实际现象和对应证据位置；任何一步失败或跳过均记录原因，不以模拟器或模型构造结果替代真机结论。
