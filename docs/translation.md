# 推理输出翻译插件（外部命令钩子）

本分支为 Codex CLI 增加了一个**可选**的翻译扩展点：通过 `config.toml` 指定一个“外部可执行命令”作为翻译器，把 TUI/TUI2 中的推理相关输出（`AgentReasoning`）从英文翻译成中文，并以“双语”形式显示。

## 设计目标

- **不污染本体依赖**：Codex 不内置任何在线翻译 SDK/服务，避免隐私/合规风险与依赖耦合。
- **可更新同步**：翻译逻辑放在外部脚本/二进制中，你可以独立更新翻译器而不必改 Codex。
- **不拖慢主流程**：Codex 主 UI 先显示原文，翻译在后台执行；完成后再把译文更新到界面。
- **失败可观测**：翻译失败/超时不会影响 Codex 正常工作，但会在译文位置显示失败原因（不吞）。

## 配置方式（`~/.codex/config.toml`）

在配置文件中加入：

```toml
[plugins.translation.agent_reasoning]
# 外部翻译器命令（argv）。示例：python 脚本
command = ["python3", "/path/to/translate_agent_reasoning.py"]

# 调用超时（毫秒）。用于避免外部命令卡死拖慢 UI。
timeout_ms = 2000

# UI 对齐等待上限（毫秒）。用于保证“译文紧跟原文”的短暂缓冲等待；
# 超时后会立刻放行后续输出，并在原文下方显示“译文生成失败：等待超时…”
ui_max_wait_ms = 5000
```

### 旧配置兼容（deprecated）与迁移

本插件已切换为“插件自解析”配置路径：

- 推荐新路径：`[plugins.translation.agent_reasoning]`
- 旧路径仍兼容但已弃用：`[translation.agent_reasoning]`

兼容策略（强消歧，避免隐式优先级）：

- **同一作用域**（global 或某个 profile）新旧配置同时存在：**直接报错**并提示迁移；
- 仅存在旧路径：功能仍生效，但会输出一次 warning（提示迁移到新路径）。

> 说明：“同一作用域”指同一层级：要么是全局（root），要么是同一个 profile（例如 `profiles.dev`）。
> 全局与 profile 属于不同作用域：允许出现“全局新路径 + profile 旧路径”的混用（profile 会覆盖全局；旧路径仍会触发弃用 warning）。

示例（禁止共存）：

```toml
# ❌ 不要这样写：同一作用域新旧共存会报错
[plugins.translation.agent_reasoning]
command = ["python3", "/path/to/translate_agent_reasoning.py"]

[translation.agent_reasoning]
command = ["python3", "/path/to/translate_agent_reasoning.py"]
```

### 配合 profiles 使用

```toml
[plugins.translation.agent_reasoning]
command = ["python3", "/path/to/translate_agent_reasoning.py"]
timeout_ms = 2000

[profiles.no_translate.plugins.translation.agent_reasoning]
# 空数组表示“显式关闭”（用于覆盖全局配置）
command = []
```

## 展示效果（当前实现）

- **TUI / TUI2**
  - 推理标题（状态栏）：
    - 先即时显示原文标题；
    - 标题译文不再单独调用翻译器（避免额外耗时/成本），而是从“正文翻译结果”中解析并缓存；
    - 若缓存中已有该标题的译文，则状态栏显示为 `原文(译文)`（例如 `Thinking(思考中)`）。
  - 推理正文（译文块）：
    - 翻译在后台执行；
    - 译文不再额外展示 `└ 译文` 这类“标签行”，而是把译文正文直接作为子节点输出（第一行带 `└`）；
    - 为了保证**译文紧跟原文**，TUI/TUI2 会在译文生成完成（或超时）前，**短暂缓冲后续的历史输出**，避免其它块插入导致错位。
    - 默认最多等待 5 秒；可在 `config.toml` 中设置 `plugins.translation.agent_reasoning.ui_max_wait_ms` 覆盖；
      也可用环境变量覆盖（单位：毫秒；优先级更高）：
      - `CODEX_TUI_AGENT_REASONING_TRANSLATION_MAX_WAIT_MS=5000`
    - 超时后：会输出 `译文生成失败：等待超时...`，然后立刻放行并输出缓冲内容；晚到的译文将被丢弃（避免破坏“紧跟原文”的阅读顺序）。
    - 注意：`ui_max_wait_ms` 只是 UI 侧“对齐等待上限”，与 `plugins.translation.agent_reasoning.timeout_ms`（外部命令执行超时）是两回事；出网翻译建议把 `timeout_ms` 设得**不小于** `ui_max_wait_ms`，避免 UI 先放行但翻译器还在跑。
- **codex exec（human output）**
  - 在输出推理原文后，后台翻译完成会打印一段 `译文`（不阻塞主事件处理；尽力在退出前输出已完成结果）。

> 注意：未配置 `plugins.translation.agent_reasoning.command`（或 legacy 的 `translation.agent_reasoning.command`）时，行为与上游保持一致（完全不翻译、不改变输出）。

## 外部翻译器协议（stdin / stdout JSON）

Codex 会把翻译请求以 **JSON** 写入翻译器的 `stdin`，翻译器需要把响应 JSON 写到 `stdout`。

### 请求（stdin）

字段：

- `schema_version`: 当前协议版本（固定为 `1`）
- `kind`: 请求类型
  - `agent_reasoning_body`：推理正文（可能包含 Markdown；**默认会包含开头的 `**标题**`**，用于一次翻译同时得到主题与正文）
  - `agent_reasoning_title`：推理标题（通常很短，例如 `Thinking`，**预留/可选**；当前 UI 默认不再单独调用以减少一次翻译成本）
- `format`: `plain` 或 `markdown`
- `source_language`: 当前固定为 `en`
- `target_language`: 当前固定为 `zh-CN`
- `text`: 待翻译文本

示例：

```json
{
  "schema_version": 1,
  "kind": "agent_reasoning_body",
  "format": "markdown",
  "source_language": "en",
  "target_language": "zh-CN",
  "text": "…"
}
```

实现细节（建议遵守）：

- UI 会在 `agent_reasoning_body` 的译文中解析首个 `**...**` 来提取“主题译文”。
- 如果翻译器丢失/破坏了 `**...**` 结构，Codex 仍会展示正文译文，但无法单独展示主题（会退化为通用的“译文”标题）。

### 响应（stdout）

字段：

- `schema_version`: 必须为 `1`
- `text`: 翻译后的文本（只输出译文本体，不要加额外解释）

示例：

```json
{ "schema_version": 1, "text": "这里是译文…" }
```

### 错误处理约定

- 如果翻译器返回非 0 退出码、输出非 JSON、或超时：Codex 会在界面显示 `译文生成失败：...`。
- Codex **不会**因为翻译失败而中止任务执行。

## 示例翻译器（离线 dummy）

仓库内提供了一个最小示例脚本（仅用于验证链路，不做真实翻译）：

- `scripts/translate_agent_reasoning_dummy.py`

你可以先用 dummy 脚本确认 UI/日志的“追加译文”流程正常，再替换为你自己的翻译实现（例如调用私有翻译服务、企业代理、或本地模型）。

## 示例翻译器（OpenAI 兼容在线）

仓库内还提供了一个**不依赖第三方包**的在线翻译脚本示例（适用于 OpenAI 官方 API、以及大多数 OpenAI 兼容代理/路由服务）：

- `scripts/translate_agent_reasoning_openai_compatible.py`

使用前请配置环境变量（避免把密钥写入脚本）。为减少每次启动终端手动 `export` 的成本，
示例脚本会尝试读取 env 文件并加载其中的 `KEY=VALUE`：

> env 文件路径：`$CODEX_TRANSLATION_ENV_FILE`（若设置） > `~/.codex/translation.env`（默认）  
> 值优先级：**进程环境变量** > env 文件（仅当当前进程未设置同名 env 时才从文件注入）。

示例（`~/.codex/translation.env`）：

```bash
# OpenAI 兼容
CODEX_TRANSLATION_BASE_URL=https://api.openai.com/v1
CODEX_TRANSLATION_API_KEY=<your_api_key>
CODEX_TRANSLATION_MODEL=gpt-4.1-mini

# Gemini（可选）
CODEX_GEMINI_BASE_URL=https://generativelanguage.googleapis.com/v1beta
CODEX_GEMINI_API_KEY=<your_api_key>
CODEX_GEMINI_MODEL=gemini-3-flash
CODEX_GEMINI_MAX_OUTPUT_TOKENS=4096
```

- `CODEX_TRANSLATION_BASE_URL`（可选，默认使用 `$OPENAI_BASE_URL` 或 `https://api.openai.com/v1`）
- `CODEX_TRANSLATION_API_KEY`（或直接复用 `$OPENAI_API_KEY`）
- `CODEX_TRANSLATION_MODEL`（默认 `gpt-4.1-mini`，按你账号可用模型自行替换）

建议把 `timeout_ms` 设得稍大一些（例如 8000ms），避免网络抖动导致频繁超时。

## 示例翻译器（Gemini 在线）

你提供的 opencode 插件示例使用了 Gemini（例如 `gemini-3-flash`）。为了便于对齐用法，本分支也提供了一个 Gemini 示例脚本：

- `scripts/translate_agent_reasoning_gemini.py`

使用前请配置环境变量。为减少每次启动终端手动 `export` 的成本，
示例脚本会尝试读取 env 文件并加载其中的 `KEY=VALUE`：

> env 文件路径：`$CODEX_TRANSLATION_ENV_FILE`（若设置） > `~/.codex/translation.env`（默认）  
> 值优先级：**进程环境变量** > env 文件（仅当当前进程未设置同名 env 时才从文件注入）。

- `CODEX_GEMINI_BASE_URL`（可选，默认 `https://generativelanguage.googleapis.com/v1beta`）
- `CODEX_GEMINI_API_KEY`
- `CODEX_GEMINI_MODEL`（默认 `gemini-3-flash`，按你账号可用模型自行替换）
- `CODEX_GEMINI_MAX_OUTPUT_TOKENS`（可选，默认 `4096`）：单次翻译允许的最大输出 token 上限

同样建议把 `timeout_ms` 设得稍大一些（例如 8000ms 或 15000ms），因为出网翻译的延迟往往不稳定。

> 备注：在部分 Gemini 代理/网关中，中文输出的 token 计数可能偏“紧”。如果你发现译文被截断（例如结尾突然断句），请把 `CODEX_GEMINI_MAX_OUTPUT_TOKENS` 调大（并同步增大 `plugins.translation.agent_reasoning.timeout_ms`）。

### 使用自建/代理 Gemini 网关（示例：crs1）

如果你的 Gemini 服务是通过代理网关暴露的（例如你给出的 URL 形如：
`https://<host>/gemini/v1beta/models/<model>:generateContent`），推荐的配置方式是：

1. **把 Base URL / 模型 / API Key 写入私有 env 文件**（避免每次手敲；同时不要把 key 提交到 git）  
   推荐放在：`~/.codex/translation.env`（示例脚本会自动读取），或通过 `CODEX_TRANSLATION_ENV_FILE` 指定路径  
   参考：`scripts/gemini_crs1.env.example`（可直接复制并按需改名/路径）

2. （可选）确保文件权限仅当前用户可读：

   ```bash
   chmod 700 ~/.codex
   chmod 600 ~/.codex/translation.env
   ```

3. 确保你设置的是：
   - `CODEX_GEMINI_BASE_URL=https://<host>/gemini/v1beta`（**不要**包含 `/models/...:generateContent`）
   - `CODEX_GEMINI_MODEL=gemini-3-flash-preview`（或你的实际模型 ID）
   - `CODEX_GEMINI_API_KEY=...`（仅放在私有文件中）

4. 然后在 `~/.codex/config.toml`（或 `codex -c ...`）中启用翻译脚本：
   - `command = ["python3", "/path/to/translate_agent_reasoning_gemini.py"]`

## 与 Codex 原生 “reasoning” 开关的关系

Codex 自身已经有两个与推理显示有关的配置键（见官方配置文档）：

- `hide_agent_reasoning = true`：抑制推理输出（你就不会看到英文推理，也不会触发翻译）
- `show_raw_agent_reasoning = true`：在模型支持时额外显示更“原始”的推理内容（此时也会触发翻译）

你可以按需组合：

- 只想要最终答案，不想要推理：`hide_agent_reasoning = true`
- 想保留推理但看中文：保持 `hide_agent_reasoning = false`，并启用本翻译插件
- 想看更完整的推理（模型支持时）：再加上 `show_raw_agent_reasoning = true`

## 安全与隐私提示

推理内容可能包含路径、代码、命令、甚至敏感信息。是否“出网翻译”由你的外部翻译器决定：

- 如果你需要联网翻译：请确保你的翻译服务/代理满足你的合规要求。
- 如果你不希望出网：请使用本地翻译器（例如本地模型或离线词典）。
