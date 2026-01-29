---
mode: plan
task: 最小入侵缩差异并降低后续合并冲突风险
created_at: "2026-01-30T14:18:42+08:00"
complexity: complex
---

# Plan: 最小入侵缩小翻译插件差异面并降低后续合并冲突风险（基于 rust-v0.92.0）

## Goal
- 在不破坏“推理翻译插件（think 翻译）”关键行为的前提下：
  - 显著降低对 upstream 热文件的侵入（优先：`codex-rs/tui/src/chatwidget.rs`、`codex-rs/tui/src/bottom_pane/footer.rs`、`codex-rs/core/src/config/mod.rs`）。
  - 缩小相对 `rust-v0.92.0` 的差异噪声，减少未来同步上游 release tag 时的合并冲突概率与解决成本。
- 维持公开仓库可持续门槛：Ubuntu-only 的 fork CI 继续稳定通过（不扩大 CI 面、不恢复上游重型 workflows）。

## Scope
- In:
  - 以“量化证据”建立 baseline（diffstat、热文件 numstat、merge-tree 冲突探针）。
  - 识别并处理“非翻译核心但高冲突风险/高噪声”的改动点（优先从热文件与依赖/生成物入手）。
  - 将翻译编排/状态机从热文件下沉到新模块/新文件，热文件仅保留薄入口与事件转发。
  - （可选）补丁栈卫生（squash/reword/reorder）以降低“未来 rebase 按提交重放”时的冲突概率；该步骤必须二次确认。
- Out:
  - 不跟随 `upstream/main` 做开发分支同步（仍以 release tags 为基线）。
  - 不引入新的翻译能力（如流式 token 级翻译、多语言策略等）。
  - 不扩大/恢复上游重型 CI workflows（维持最小侵入与最小维护成本）。

## Assumptions / Dependencies
- 当前分支：`feat/agent-reasoning-translation-plugin`，且工作区干净、本地与远程一致。
- 基线策略：以 release tag 为基线（当前稳定 tag 为 `rust-v0.92.0`），同步方式参考 `scripts/dev-sync-upstream.sh`。
- 回归约束：仅跑 `just fmt` + 以下 4 条命令（工作目录 `codex-rs`）：
  - `cargo test -p codex-core translation`
  - `cargo test -p codex-exec`
  - `cargo build -p codex-cli`
  - `cargo test -p codex-tui`

## Phases
1. Baseline 量化与变更分类（只读）
   - 量化差异：
     - `git diff --stat rust-v0.92.0..HEAD`
     - `git diff --numstat rust-v0.92.0..HEAD -- codex-rs/tui/src/chatwidget.rs codex-rs/tui/src/bottom_pane/footer.rs codex-rs/core/src/config/mod.rs codex-rs/core/src/config/types.rs codex-rs/tui/src/history_cell.rs`
   - 冲突探针（不做真正 rebase，只预测趋势）：
     - `git merge-tree --write-tree --messages HEAD rust-v0.93.0-alpha.17 | rg "^CONFLICT"`
   - 输出“变更分层清单”（按文件/提交归因）：
     - 必须保留：翻译核心链路（默认关闭、`command=[]` 显式关闭、异步不阻塞、request/thread 防串台、译文插入策略等）。
     - 可下沉：把复杂逻辑迁移到新模块/新文件，减少热文件侵入。
     - 可移除：与翻译无关且占用差异预算的改动（只在证据充分时执行，避免拍脑袋删）。

2. 缩差异落地（最小入侵优先）
   - 先处理“非翻译核心但高噪声/高冲突风险”的改动点（目标：减少热文件侵入与未来冲突）。候选方向（以 Phase 1 分类结果为准）：
     - `codex-rs/core/Cargo.toml` 中与翻译无关的依赖 feature 偏离（例如 `reqwest` 的额外 feature）。
     - `codex-rs/core/src/shell_snapshot.rs` / `codex-rs/core/src/tools/handlers/shell.rs` 的测试稳定性相关改动（若与翻译无关，优先拆分或回退，避免占用热文件差异预算）。
     - 生成物 `codex-rs/core/config.schema.json`：冲突时优先用流程重建（而非手工合并）。
   - 抽离翻译编排/状态机（保留行为不变）：
     - 建议形态：抽出 `TranslationOrchestrator`（或 Barrier State Machine）到新模块/新文件（例如 `codex-rs/tui/src/chatwidget/agent_reasoning_translation.rs`）。
       - 原则：热文件只保留“薄入口 + 委托”，复杂逻辑/状态机留在新文件里。
       - 若需要进一步解耦 UI：用“effects/command 列表”从 orchestrator 返回（例如 UpdateStatusHeader/SpawnTask/EmitCell/FlushDeferred）。
     - `codex-rs/tui/src/chatwidget.rs` 目标形态：字段持有 + 入口委托 + 事件转发（尽量减少业务逻辑行数）。
     - 测试拆分：把翻译相关测试从 `codex-rs/tui/src/chatwidget/tests.rs` 下沉到更小的子模块（降低同文件冲突概率）。
   - 对齐上游演进方向以消除结构性冲突根因：
     - 对 `codex-rs/tui/src/bottom_pane/footer.rs` 的冲突，优先沿用上游“props 注入（例如 is_wsl）/footer 纯渲染”的结构，避免在 footer 内做环境探测（从根因上降低未来冲突）。
3. 回归验证 + 风险回测（严格按约束）
   - 运行：`just fmt` + 4 条 cargo 命令（见 Tests & Verification）。
   - 重新跑 Phase 1 的量化指标，对比“热文件 numstat/冲突探针项”是否下降或至少不增加。

4. （可选，需二次确认）补丁栈卫生（降低未来 rebase 按提交重放的冲突概率）
   - 背景：若仅通过新增提交“搬走逻辑”，历史上早期的大改动提交在未来 rebase 时仍会被重放，冲突仍可能发生。
   - 手段：交互式 rebase（squash/reword/reorder），把翻译功能收敛为少量稳定 commits（例如：core/exec/tui/文档/脚本 分组）。
   - 风险：需要 `--force-with-lease` push。
   - 该 Phase 必须单独获得书面确认后才执行。

## Tests & Verification
- 格式化：`just fmt`（在 `codex-rs` 目录）。
- 功能回归（在 `codex-rs` 目录）：
  - `cargo test -p codex-core translation`
  - `cargo test -p codex-exec`
  - `cargo build -p codex-cli`
  - `cargo test -p codex-tui`
- 量化验收（可复核证据）：
  - 热文件侵入度：`chatwidget.rs` / `footer.rs` / `config/mod.rs` 的 `--numstat` 相比 baseline 明显下降（目标：至少降低 30%，最终阈值以 Phase 1 baseline 决定）。
  - 冲突探针项：`git merge-tree ...` 的 `CONFLICT` 项数不增加，优先消除 `footer.rs` 相关冲突。

## Issue CSV
- Path: issues/2026-01-30_14-10-49-minimize-upstream-diff.csv
- Must share the same timestamp/slug as this plan.

## Execution Strategy（Plan 阶段一次性对齐，避免执行中反复打断）
- Mode: normal-batch
- Entry skill: $issue-batch
- Commit policy: manual
- Plan audit before execution: yes
- Use git worktree: no
- Regression: per-issue quick regression + final regression（仅限本计划约束的命令集合）

## Tools / MCP
- 本地：git、rg、cargo、just。
- 冲突预测：`git merge-tree`。
- 多 agent 审计（本 plan 已完成）：
  - 内置 spawn_agent：`019c0d41-e8a0-7763-b74d-c633fc6db6ef`、`019c0d41-d742-7021-b1d1-0b53916c3b8d`。
  - 外置协作：Claude（Opus）SESSION_ID：`601070f9-8b44-424f-ab4f-7efb0bfaaf60`；Gemini SESSION_ID：`1d46626a-183d-400a-bda8-1d17ba338b78`。

## Acceptance Checklist
- [ ] Phase 1 输出可复核 baseline：diffstat/numstat/冲突探针结果 + 变更分层清单。
- [ ] 在不破坏关键行为（默认关闭/`command=[]` 显式关闭/异步不阻塞/request+thread 防串台/译文紧贴或明确降级决策）的前提下，热文件侵入度显著下降。
- [ ] `just fmt` + 4 条 cargo 命令通过。
- [ ] 冲突探针项不增加；优先消除 `footer.rs` 冲突根因。

## Risks / Blockers
- barrier/deferred 机制是高复杂度点，缩差异重构容易引入顺序错乱/丢消息/卡住。
- 若不做 Phase 4（补丁栈卫生），未来 rebase 仍可能在“历史早期大改动提交”处发生冲突（即便最终 diff 已变小）。
- 生成物（如 `config.schema.json`）的手工合并容易出错，应通过流程而非手改解决。

## Rollback / Recovery
- 执行前创建本地备份分支（不推送）：`backup/2026-01-30-minimize-upstream-diff`。
- 单点回滚：优先 `git revert <commit>`，保持可追溯。
- 运行时止血：通过 config 将 `translation.agent_reasoning.command = []` 显式关闭（不改代码即可关闭功能）。

## Checkpoints
- Commit after: Phase 2 完成且 Phase 3 约束回归通过（COMMIT_POLICY=manual，由人工决定是否提交）。
- Phase 4（可选）开始前：必须二次确认是否允许 `--force-with-lease`。

## References
- `scripts/dev-sync-upstream.sh`（默认对齐最新稳定 tag，并自动推断 patch base）。
- 基线 tag：`rust-v0.92.0`。
- 当前分支：`feat/agent-reasoning-translation-plugin`。
