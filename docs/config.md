# Configuration

For basic configuration instructions, see [this documentation](https://developers.openai.com/codex/config-basic).

For advanced configuration instructions, see [this documentation](https://developers.openai.com/codex/config-advanced).

For a full configuration reference, see [this documentation](https://developers.openai.com/codex/config-reference).

## Connecting to MCP servers

Codex can connect to MCP servers configured in `~/.codex/config.toml`. See the configuration reference for the latest MCP server options:

- https://developers.openai.com/codex/config-reference

## Apps (Connectors)

Use `$` in the composer to insert a ChatGPT connector; the popover lists accessible
apps. The `/apps` command lists available and installed apps. Connected apps appear first
and are labeled as connected; others are marked as can be installed.

## Notify

Codex can run a notification hook when the agent finishes a turn. See the configuration reference for the latest notification settings:

- https://developers.openai.com/codex/config-reference

## JSON Schema

The generated JSON Schema for `config.toml` lives at `codex-rs/core/config.schema.json`.

## Notices

Codex stores "do not show again" flags for some UI prompts under the `[notice]` table.

Ctrl+C/Ctrl+D quitting uses a ~1 second double-press hint (`ctrl + c again to quit`).

## 推理输出翻译（外部命令插件）

本分支新增了一个**可选**的外部翻译命令钩子，用于把 `AgentReasoning`（TUI 里的 “Thinking/Analyzing…” 推理摘要）从英文翻译为中文，并以“原文 + 译文”方式展示。

- 详细说明与插件协议：`docs/translation.md`
- 关键配置项（`~/.codex/config.toml`）：
  - `[translation.agent_reasoning] command = [...]`：外部翻译器命令（argv）
  - `timeout_ms`：外部命令执行超时（毫秒）
  - `ui_max_wait_ms`：TUI 对齐等待上限（毫秒；控制“译文紧跟原文”的缓冲等待时间）
  - 环境变量 `CODEX_TUI_AGENT_REASONING_TRANSLATION_MAX_WAIT_MS` 可覆盖 `ui_max_wait_ms`
