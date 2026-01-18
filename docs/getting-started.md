# Getting started with Codex CLI

For an overview of Codex CLI features, see [this documentation](https://developers.openai.com/codex/cli/features#running-in-interactive-mode).

## 推理输出翻译插件（本 fork 扩展）

本仓库在上游基础上新增了一个**可选**扩展点：通过 `~/.codex/config.toml` 配置外部命令，把 TUI/TUI2 的 `AgentReasoning` 以“原文 + 译文”形式展示。

- 详细说明与插件协议：`docs/translation.md`
- 快速入口（中文）：`README.zh-CN.md`
