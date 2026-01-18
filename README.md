# Codex CLI（Fork：推理输出翻译插件）

本仓库基于上游 `openai/codex`，在官方 Codex CLI 的基础上新增了一个**可选**扩展：**推理输出翻译插件（外部命令钩子）**。

该扩展的目标是：允许你用**自定义外部命令**（脚本/二进制均可）把 TUI / TUI2 中的 `AgentReasoning`（例如 `Thinking` / `Analyzing` 这类推理/思考块）翻译为中文，并以“原文 + 译文”形式展示。

## 效果预览

![推理译文效果预览](./.github/agent-reasoning-translation-preview.png)

（SVG 版：`./.github/agent-reasoning-translation-preview.svg`）

## 这是什么（对外说明建议）

- 这是一个上游 `openai/codex` 的 fork，用于探索/维护额外能力。
- 这是一个**非官方**仓库，与 OpenAI 官方无隶属关系。
- 本 fork **不内置任何在线翻译 SDK/服务**，翻译逻辑完全由你配置的外部命令实现（便于替换、便于合规、便于私有化）。
- 未启用翻译配置时，行为与上游保持一致（不改变默认输出）。
- 常见终端/WSL 相关问题排查：`docs/troubleshooting.md`。
- 目前主要在 **Windows 11 + WSL2** 环境开发/测试；其他环境尚未系统验证（欢迎反馈与 PR）。

## 快速开始：启用“推理译文”（TUI/TUI2）

### 1) 安装/构建本 fork 的 `codex`

如果你只是想使用官方 Codex CLI，请直接使用上游在 README 中提供的 npm / brew 安装方式。

如果你想使用本 fork 的“推理输出翻译插件”，需要运行**本 fork 构建出来的** `codex` 可执行文件（因为该能力尚不在上游发行版里）。

从源码构建（示例）：

```bash
git clone https://github.com/EnvyGithub/codex.git
cd codex/codex-rs
cargo build
```

运行（示例）：

```bash
cargo run --bin codex -- "explain this codebase to me"
```

更完整的构建依赖与命令说明见：

- `docs/install.md`（上游通用构建说明）

### 2) 配置翻译器（`~/.codex/config.toml`）

> **⚠️ 隐私提示**：推理内容可能包含代码片段、文件路径、命令等敏感信息。
>
> 使用联网翻译服务前，请确保：
>
> - 翻译服务提供商符合你的合规与隐私要求
> - 或使用本地翻译器（离线模型/内网服务）避免数据出网

在你的 `~/.codex/config.toml` 中加入（示例）：

```toml
[translation.agent_reasoning]
command = ["python3", "/path/to/translate_agent_reasoning_dummy.py"]
timeout_ms = 2000
ui_max_wait_ms = 5000
```

- `command`：外部翻译器命令（argv 数组）
- `timeout_ms`：外部命令执行超时（毫秒）
- `ui_max_wait_ms`：UI 对齐等待上限（毫秒），用于尽量保证“译文紧跟原文”

详细说明见：`docs/translation.md`。

## 编写你自己的翻译器（外部命令插件）

你需要实现一个“从 stdin 读 JSON、向 stdout 写 JSON”的可执行程序即可：

- **输入（stdin）**：翻译请求 JSON（包含 `text`、`format`、`kind` 等字段）
- **输出（stdout）**：翻译结果 JSON（只输出译文本体，不要额外解释）

协议与字段定义见：`docs/translation.md` 的 “外部翻译器协议（stdin / stdout JSON）” 章节。

建议直接从最小示例开始：

- `scripts/translate_agent_reasoning_dummy.py`：离线 dummy（不做真实翻译，只验证链路）

如果你要做联网翻译：

- `scripts/translate_agent_reasoning_openai_compatible.py`：OpenAI / OpenAI 兼容服务示例（无第三方依赖）
- `scripts/translate_agent_reasoning_gemini.py`：Gemini 示例（无第三方依赖）

## 安全与隐私

推理内容可能包含路径、代码片段、命令等信息。是否“出网翻译”由你的外部翻译器决定：

- 需要联网：请确保翻译服务/代理满足你的合规与隐私要求。
- 不希望出网：请使用本地翻译器（例如本地模型、离线词典、内网服务等）。

## 与上游同步（维护者）

本仓库包含一个用于同步上游并 rebase 的脚本：

- `scripts/dev-sync-upstream.sh`

它的定位是“帮助维护者把本 fork 的改动持续搬运到**上游稳定发布基线**上”，默认会对齐最新稳定 tag（`rust-vX.Y.Z`），并提供可选的 build/link/verify 能力。若你需要跟随上游开发分支，可显式使用 `--upstream upstream/main`。具体用法见脚本内置 `--help`。

推荐的一键命令（对齐最新稳定 tag + 构建 debug/release + 建软链 + 快速验证）：

```bash
./scripts/dev-sync-upstream.sh --non-interactive --build both --link both --verify quick
```

如果你准备把仓库公开，建议先按发布清单自检：

- `docs/public-repo.md`

## 许可证

本仓库使用 Apache-2.0 许可证，见 `LICENSE`。
