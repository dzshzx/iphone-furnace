# 项目契约

Furnace 是个人 iPhone 压测 App。使用与构建入口在 [README.md](README.md)，当前交付和待验事项在 [docs/validation.md](docs/validation.md)。

- 改负载选择、会话或指标口径时先读 [GLOSSARY.md](GLOSSARY.md)；热状态只记录，持续负载不因温度主动减载。
- 工程来源为 `project.yml`；模型由 `scripts/generate_models.py` 生成。修改来源文件，生成的 Xcode 工程与模型不入库。
- 交付合同是未签名 `.ipa` 单文件下载；Apple 账号、签名证书和描述文件由用户的签名工具持有。
- 改引擎或构建流程时使用 README 的验证入口；本地 Linux 负责构建工具检查，Swift/Metal 与模拟器证据来自 GitHub macOS runner。
- GitHub 上唯一的触发入口是按需 iOS build，由它先运行 Linux 工具检查，再完成 macOS 原生构建、模拟器测试和 IPA 生成。
- 更新验收结论时核对 `docs/validation.md` 中的构建、提交和回执。手机安装、持续负载及 ANE 实际执行需要各自的真机证据。
