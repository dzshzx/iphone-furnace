# 项目契约

使用与构建入口在 [README.md](README.md)，当前交付和待验事项在 [docs/validation.md](docs/validation.md)。

- 改负载选择、会话或指标口径时先读 [GLOSSARY.md](GLOSSARY.md)；热状态只记录，持续负载不因温度主动减载。
- 工程来源为 `project.yml`；模型由 `scripts/generate_models.py` 生成。修改来源文件，生成的 Xcode 工程与模型不入库。
- 交付约定是未签名 `.ipa` 单文件下载；Apple 账号、签名证书和描述文件由用户的签名工具保管。
- 门禁：`bash scripts/check.sh`；验证入口见 README；Linux 工具检查在本机，Swift/Metal 与模拟器证据来自按需触发的 `release.yml`（`-f dry_run=true` 只验证，任意分支可跑）。
- 发版：`gh workflow run release.yml --ref master -f bump=patch`；版本号由 CI 按最高纯 `vX.Y.Z` tag 算出，build 号按版本公式算出，仓里 `project.yml` 只放占位值，不手改。minor、major 须维护者先确认；失败不留 tag，修好后同一 `bump` 重跑。细节见 README「发版」。
- 更新验收结论时按 `docs/validation.md`「同提交完整验收清单」记录构建、提交和证据。手机安装、持续负载及 ANE 实际执行需要各自的真机证据。
