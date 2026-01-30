---
mode: plan
task: 插件命名空间 + 翻译插件自解析 + TUI 内部回传（降冲突/降维护成本）
created_at: "2026-01-30T22:50:02+08:00"
complexity: complex
---

# Plan: 插件化 translation 配置 + TUI 内部回传，进一步缩小翻译功能侵入面

## Goal
- 长期可维护：把翻译配置从 core config 热区与巨大 schema 生成物中解耦出去，减少未来同步 upstream 时的冲突概率与人工合并成本。
- 最小入侵：不改变既有翻译功能行为（默认关闭、显式关闭、异步不阻塞、barrier 邻接/超时降级、晚到丢弃、防串台）。
- 强可观测：不引入“悄悄回退/吞错/默认值掩盖失败”的多路径行为；所有兼容行为必须有清晰错误/警告。

## Scope
- In:
  - Core 配置：引入 `plugins` 命名空间；translation 插件在该命名空间下自解析配置。
  - 兼容旧配置：继续支持旧 `[translation.agent_reasoning]`（以及 profile 内的旧路径），但作为 deprecated：
    - 同一作用域（global 或 profile）同时存在新旧配置 -> 直接报错并提示迁移（强消歧，避免隐式优先级）。
    - 仅存在旧配置 -> 功能仍生效，但输出一次 warning（可观测、不静默）。
  - JSON Schema：主 schema 仅包含通用 `plugins`（不再包含 translation 细节），降低 future churn。
  - TUI：翻译结果回传从 `AppEvent` 移除，改为 `ChatWidget/Orchestrator` 内部 channel + draw tick drain；同时覆盖 overlay 场景。
  - 文档：更新 `docs/translation.md` 与 `docs/config.md`（公开仓库必须同步说明迁移与兼容策略）。
- Out:
  - 不改变翻译器协议（stdin/stdout JSON）与仓库内示例翻译脚本能力（只更新文档片段）。
  - 不引入新特性（多语言、流式翻译、额外 UI 模式等）。

## Assumptions / Dependencies
- 新配置路径：`[plugins.translation.agent_reasoning]`。
- 旧配置路径（兼容但弃用）：`[translation.agent_reasoning]`。
- 作用域：global + profile（`[profiles.<name>.plugins.translation.agent_reasoning]` / `[profiles.<name>.translation.agent_reasoning]`）。

## Phases
1. Core：引入 plugins 命名空间 + 插件名校验
   - `ConfigToml` / `ConfigProfile` 增加 `plugins` 字段（map<string, toml::Value>），并实现 schema_with：`plugins_schema`。
   - 增加运行时校验：`plugins` 内出现未知插件名 -> 报错（列出允许值，当前至少包含 `translation`）。

2. Core：translation 插件自解析 + 旧配置兼容
   - 翻译模块内部实现严格解析（`deny_unknown_fields`）：
     - 从新路径（plugins.translation）解析
     - 从旧路径（translation）解析（deprecated，发 warning）
   - 解析与合并策略：
     - profile 优先于 global（保持现有语义）
     - 同一作用域同时出现新旧配置 -> 直接报错（防止多路径掩盖/歧义）

3. TUI：翻译结果回传去 AppEvent 化
   - 在 orchestrator 内部增加 `mpsc` channel，翻译任务完成后写入 channel 并 `schedule_frame()`。
   - 在 draw tick（含 overlay）中 drain channel，调用既有处理逻辑插入 history cell，并驱动 barrier flush。
   - 删除 `AppEvent::AgentReasoningBodyTranslated` 变体及 `app.rs` 对应 match arm（降低热文件侵入）。

4. TUI：确保 barrier 的“邻接性”前提成立
   - 收口已知绕过点：避免 barrier 期间直接 `InsertHistoryCell` 绕过 orchestrator 造成译文插队。

5. 文档与生成物
   - 更新 `docs/translation.md`：新配置路径 + profile 示例 + 迁移指南（含旧配置弃用说明与冲突规则）。
   - 更新 `docs/config.md`：新增 plugins 说明，并把翻译配置示例切换为新路径（同时注明旧路径兼容但弃用）。
   - 运行 `just write-config-schema` 更新 `codex-rs/core/config.schema.json`。

## Tests & Verification
- Core：
  - `cd codex-rs && cargo test -p codex-core translation`
  - 覆盖：默认关闭、profile 覆盖、command=[] 显式关闭、新旧配置解析一致性、同作用域新旧共存报错、未知插件名报错。
- TUI：
  - `cd codex-rs && cargo test -p codex-tui agent_reasoning_translation`
  - 覆盖：barrier 邻接/超时/晚到丢弃；并补测 overlay 场景下仍能 drain/tick。
- 回归（按仓库约束，避免跑全量）：
  - `cd codex-rs && just fmt`
  - `cd codex-rs && cargo test -p codex-exec`
  - `cd codex-rs && cargo build -p codex-cli`

## Issue CSV
- Path: issues/2026-01-30_22-31-05-plugins-translation-decouple.csv
- Must share the same timestamp/slug as this plan.

## Execution Strategy（Plan 阶段一次性对齐，避免执行中反复打断）
- Mode: tdd-issue-loop
- Entry skill: $issue-loop-tdd
- Commit policy: manual
- Plan audit before execution: no
- Use git worktree: no
- Regression: per-issue quick regression + final regression

## Tools / MCP
- 本地：git/rg/cargo/just。
- 冲突趋势：git merge-tree（只读预测）。

## Acceptance Checklist
- [ ] 新路径 `plugins.translation.agent_reasoning` 可用；旧路径 `translation.agent_reasoning` 仍可用但会 warning。
- [ ] 同一作用域新旧同时存在会报错，并给出迁移提示（避免歧义）。
- [ ] 未知插件名会报错（不静默）。
- [ ] TUI 不再依赖 AppEvent 回传翻译结果；`app_event.rs`/`app.rs` 因翻译功能的 diff 显著下降。
- [ ] 翻译链路行为不回归：异步不阻塞、barrier 邻接/超时降级、晚到丢弃、防串台。
- [ ] just fmt + 核心测试/最小回归通过；schema 生成物更新完成。

## Risks / Blockers
- 兼容旧配置必然引入“双路径”，必须用“强消歧 + 明确 warning”控制维护成本。
- overlay 场景 tick 路径必须覆盖，否则 barrier 可能在 overlay 打开期间不释放，造成 deferred 队列堆积。

## Rollback / Recovery
- 用户侧：删除或置空 `plugins.translation.agent_reasoning.command` 可关闭翻译。
- 代码侧：按 issue 粒度 revert（commit policy=manual，不自动提交）。

## Checkpoints
- Commit after: Phase 2（core 配置与兼容策略稳定 + core tests 通过）；Phase 3（TUI 去 AppEvent 化 + tui tests 通过）。

## References
- docs/translation.md
- docs/config.md
- codex-rs/core/src/config/schema.rs
- codex-rs/tui/src/chatwidget/agent_reasoning_translation.rs
