# 公开仓库说明与发布清单（维护者）

本文档面向**准备把本 fork 公开**的维护者，用于把“对外说明”与“发布前检查”固化为可执行清单，减少遗漏。

## 对外说明（README 建议包含）

建议在仓库首页（`README.md`/`README.zh-CN.md`）明确：

- **这是上游 `openai/codex` 的 fork**，并说明 fork 的动机与目标。
- **本 fork 新增能力**：推理输出翻译插件（外部命令钩子）
  - 可通过 `~/.codex/config.toml` 配置外部命令
  - 把 `AgentReasoning` 以“原文 + 译文”展示在 TUI/TUI2
  - 不内置任何在线翻译 SDK（隐私/合规/依赖解耦）
- **分发说明**：
  - npm / brew 安装的是上游官方发行版
  - 使用本 fork 特性需构建并运行本仓库的 `codex`（或使用本仓库 release，如果维护者提供）
- **非官方声明**：与 OpenAI 官方无隶属关系（避免误解）
- **许可证**：Apache-2.0（`LICENSE`）

翻译插件的对外文档建议以 `docs/translation.md` 为权威入口。

## 使用说明（对外）

面向普通用户，对外文档需要回答三个问题：

1. 怎么获取可运行的 `codex`？
2. 怎么启用推理译文？
3. 怎么自己写/替换翻译器？

建议把“启用推理译文”的最短路径固定为：

- 构建/安装本 fork 的 `codex`
- 配置 `translation.agent_reasoning.command`
- 先用 `scripts/translate_agent_reasoning_dummy.py` 验证链路，再换成真正的翻译器

## 发布前检查（必须做）

### 1) 敏感信息与隐私审计

目标：确认仓库中**不存在**可用于直接访问你账户/资源的敏感信息（API key、token、私钥、内网地址等）。

建议执行一次全仓粗扫（示例，按需增减关键词）：

```bash
rg -n -S "API_KEY|ACCESS_KEY|SECRET_KEY|BEGIN (RSA|OPENSSH) PRIVATE KEY|ssh-rsa|xox[baprs]-|AKIA[0-9A-Z]{16}|ghp_[0-9A-Za-z]{36}" .
```

同时确认示例文件仅包含占位符：

- `scripts/gemini_crs1.env.example`
- `docs/translation.md`

### 2) 文档一致性检查

目标：README 与 docs 中提到的路径/配置项在仓库里真实存在。

建议：

- 检查 `docs/translation.md` 中提到的脚本文件路径都存在
- 检查 `docs/config.md` 中提到的配置键已进入 schema（本 fork 已为翻译配置补齐 JsonSchema）

### 3) 最小可运行性验证

目标：至少能在本地（或 CI）完成一次构建与最小运行，避免“仓库公开但不可用”。

建议最小验证步骤：

```bash
cd codex-rs
cargo build
```

如果你改动了 Rust 代码，建议按仓库约定执行：

```bash
cd codex-rs
just fmt
just fix -p <crate>
```

（注意：本 fork 的翻译功能主要影响 `codex-core` / `codex-exec` / `codex-tui` / `codex-tui2`。）

## 对外支持策略（可选，但建议写清）

仓库公开后，建议明确：

- 你是否接受 PR？（bugfix only / feature discussion first）
- issue 的范围：只处理本 fork 相关问题，还是也协助上游问题定位？
- 对“联网翻译”的支持边界：外部翻译器由用户自行承担 key/服务质量/合规风险

