# 验证记录

目标：iPhone 18 Pro Max，iOS 27 正式版，普通开发者签名，前台运行。

当前交付为开发构建 `0.1.0 (14)`，2026-09-23（北京时间）完成云端验证和 IPA 下载读回。
构建提交：`d16e06544cd996dd76618f18134f88b6c9aba5fe`。

安装包之后的 `7773a10` 调整了 CI 入口，应用、模型生成器和测试源码相对 build 14 无变化。[当前 Linux 工具检查](https://github.com/dzshzx/iphone-furnace/actions/runs/35841117087)已通过；普通提交的检查与手动 iOS 构建的分工见 [README](../README.md#构建)。新的 Linux → macOS 组合流程尚待首次手动完整运行，现有 build 14 的回执对应此前的完整 iOS 流程。本次收尾审计不触发新构建。

- [完整成功运行](https://github.com/dzshzx/iphone-furnace/actions/runs/35838168344)
- [直接下载 Furnace-unsigned.ipa](https://github.com/dzshzx/iphone-furnace/actions/runs/35838168344/artifacts/10739714830)
- [dSYM、构建信息、截图及测试诊断](https://github.com/dzshzx/iphone-furnace/actions/runs/35838168344/artifacts/10740556762)

实际工具链为 Xcode 27.0 / build 27A266a、iOS SDK 27.0、macOS 27.0 / 26A5406e。
构建机上的模拟器计算使用宿主硬件，不作为目标 iPhone 的性能证据。

| 验证项 | 状态 | 证据 |
|---|---|---|
| 三档模型生成 | 已通过 | 本地 coremltools 9.0，256/384/512 通道模型完成转换 |
| Python / 原生数据构建测试 | 已通过 | 8 项；模型图与 IPA 检查、真实格式的模型标识校验、coremltools 读取三档私有权重并验证全部 16 层数值 |
| 私有 ANE 原生模型构造 | 已通过 | 三档均 `model construction=YES`，阶段“模型文件就绪”，无错误；不涉及 ANE 编译、加载或执行 |
| 私有 ANE 调用参数回归 | 已通过（模型替身） | 捕获编译、加载、执行、卸载四个实际 ObjC 调用：均为 `QOS_CLASS_DEFAULT=21`；请求对象与底层错误正确传递 |
| macOS Core ML 计算计划 | 已通过 | 三档模型、CPU-only / CPU+ANE 共六组；每组识别 16 层 `ios18.conv`，旧匹配计数均为 0；宿主均计划分配到 CPU，均被拒绝作为 NPU 压测 |
| 模拟器测试 | 已通过 | 16 项、0 失败、0 跳过；包括四项新计算计划回归，以及真实 CPU、三种 Metal 负载、Core ML CPU 数值校验及生命周期 |
| arm64 未签名 IPA | 已通过 | 云端生成后重新下载检查：Mach-O iOS 平台、arm64、最低 iOS 27.0、全部模型及 Metal 内核完整，无签名目录和描述文件 |
| 界面截图 | build 14 云端仪表盘与用户真机错误画面均已读回 | build 14 的负载选择、读数和开始按钮显示正常；用户截图记录此前编译错误，未显示 build 号；build 10 / 12 的白屏截图不作为界面验收证据 |
| 真机安装与启动 | build 8 已获用户运行报告 | `iPhone19,2` / iOS `27.0`；签名方式未提供 |
| 真机 CPU / GPU 初步试跑 | 用户反馈正常 | 2026-09-23 反馈；持续时间、负载组合及对应报告待补 |
| 真机 Core ML NPU 初步试跑 | 修复后用户反馈可运行 | 2026-09-23 反馈，未附新运行的构建号、持续时长和报告；原 build 8 的 `0/0` 失败报告保留为历史证据 |
| 真机持续负载与停止响应 | 待验证 | 手机完整自测报告 |
| ANE 实际执行 | 待验证 | Core ML 计算计划只表示预计分配；需要真机轨迹 |
| 私有 ANE 普通签名可用性 | 待 QoS 修复版真机复测 | 新截图已越过模型标识检查，编译请求因实时优先级要求受限连接而失败；目标设备编译/加载/双输入校验仍无通过证据 |
| 整机功耗上限 | 未测量 | 不由吞吐量或负载开关推断 |

CI 保留一项工具提示：未依赖 AppIntents，因此跳过该框架的元数据提取；这与当前功能一致，不影响编译或测试。

修复机制与验证入口统一见 [README 的私有 ANE 与构建说明](../README.md#私有-ane-实验)。以下只保留定位与回归所需的历史证据：

| 失败样例 | 回归证据 |
|---|---|
| build 8 的 Core ML 卷积分配为 `0/0` | build 10 起识别 `ios18.conv`；对同一实际计划，旧匹配计数 0，新匹配 16 |
| 私有模型标识被拒绝 | [诊断运行 11](https://github.com/dzshzx/iphone-furnace/actions/runs/35833893901)记录三段各 64 个十六进制字符以 `_` 连接，合计 194 字符；修复后保留安全单层目录校验 |
| 私有权重长度固定 1 MiB、数据偏移 0、层数 1 | 三档全部 16 层已通过 coremltools 读取与数值检查；格式依据 [MILBlob v2](https://github.com/apple/coremltools/blob/9.0/mlmodel/src/MILBlob/Blob/StorageFormat.hpp) |
| 2026-09-23 16:21 真机截图：`Realtime priority requires restricted access connection`，要求 `com.apple.aned.private.allow`，错误域/码 `com.apple.appleneuralengine/2` | [参数回归运行 13](https://github.com/dzshzx/iphone-furnace/actions/runs/35837854811)的模型替身捕获四个阶段均为 QoS 0；build 14 均为 21，真机执行仍待复测 |

Core ML 持续负载验收可先使用 NPU 单独运行、256 通道、1 路并发，持续约一分钟后停止并导出报告，核对 completed 增长和停止响应。私有后端先单独使用 256 通道复测，并提供 build 号、reason 和 detail。

手机验收时记录签名方式、iOS 完整版本、App build 号、是否充电和环境条件。运行完整自测，确认 UI 可操作、没有持续内存增长、每路计数持续增加，停止后计数停止。停止超过两秒时保留报告，用于缩小单批计算量。

私有后端单独测试。API 不可用是能力探测结果，不能记为 NPU 已验证；若应用退出，导出中断会话并记录下次启动显示的阶段。

下载包的 bundle ID 为 `com.dzshzx.furnace`，设备类型为 iPhone，方向为竖屏。
用户已反馈 CPU、GPU、Core ML 初步试跑可用；完整持续负载、功耗和 ANE 实际执行仍待各自证据。
