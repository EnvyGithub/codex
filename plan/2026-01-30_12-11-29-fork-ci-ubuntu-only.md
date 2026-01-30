---
mode: plan
task: fork-ci ubuntu-only + 最小侵入发布门槛
created_at: "2026-01-30T12:12:54+08:00"
complexity: medium
---

# Plan: Fork 轻量 CI（Ubuntu-only）+ 隔离上游重型 Workflows（策略 A）

## Goal
- 让默认分支 `feat/agent-reasoning-translation-plugin` 在公开仓库中具备**稳定、可持续**的 CI 信号：
  - 仅使用 GitHub-hosted Ubuntu runner。
  - CI **只运行**以下 4 条命令（工作目录 `codex-rs`）：
    1) `cargo test -p codex-core translation`
    2) `cargo test -p codex-exec`
    3) `cargo build -p codex-cli`
    4) `cargo test -p codex-tui`
- 避免触发上游继承来的重型 CI（例如依赖自建 runner group `codex-runners` 的 `rust-ci`），防止默认分支长期红。
- 在不改动“推理翻译功能”源代码行为的前提下，完成最小侵入的 CI/发布门槛调整，降低未来 rebase 冲突风险。

## Scope
- In:
  - 新增一个 fork 专用 workflow：`.github/workflows/fork-ci.yml`（Ubuntu-only，且只跑 4 条命令）。
  - 撤回为触发 Actions 而引入的默认分支 push 触发扩展（revert `2fc5f2ccf`）。
  - 通过 GitHub repo 配置（`gh workflow disable`）禁用非目标 workflows，确保 PR/push 只触发 `fork-ci`。
- Out:
  - 不把上游完整 CI（多 OS、多 target、bazel、release、Node 全量检查）迁移到本仓库。
  - 不对翻译功能相关源代码做重构/行为调整（本次仅 CI/发布门槛）。
  - 不处理任何业务 issue（仅做发布稳定性/可持续维护相关的基础设施调整）。

## Assumptions / Dependencies
- GitHub Actions 已启用，且可以使用 GitHub-hosted runner（Ubuntu）。
- 当前分支工作区干净，且本地与远程一致（基线证据：`HEAD == origin/feat/agent-reasoning-translation-plugin == 2fc5f2ccf11fb72b3a6bd27d6760c9e296d41ae3`）。
- 具备仓库管理员权限（至少能执行 `gh workflow disable`）。若权限不足，则回退到“代码层隔离触发条件（策略 B）”。

## Phases
1. 基线确认（只读）
   - 记录：当前分支、HEAD、工作区状态、本地/远程一致性。
   - 盘点：`.github/workflows` 中会在 `push`/`pull_request` 触发的 workflows 清单（用于验收“只剩 fork-ci”）。
2. 落地 fork-ci（代码改动）
   - 新增 `.github/workflows/fork-ci.yml`：
     - `push`/`pull_request`/`workflow_dispatch` 均针对 `feat/agent-reasoning-translation-plugin`。
     - `runs-on` 仅 Ubuntu。
     - 严格 4 个 `run:` step，每个 step 仅单行命令（审计口径：命令数=4）。
3. 撤回触发扩展（代码改动，最小侵入）
   - 以 `git revert` 形式撤回提交 `2fc5f2ccf` 对上游 workflows 的触发扩展（目标：减少与 upstream 的 YAML 偏离）。
4. 禁用非目标 workflows（配置改动，策略 A）
   - 使用 `gh workflow list` 识别 push/PR 相关 workflow。
   - 禁用清单（已执行）：`rust-ci`、`Bazel (experimental)`、`ci`、`sdk`、`cargo-deny`、`Codespell`。
     - 备注：本仓库当前 `gh workflow list` 未显示 `shell-tool-mcp CI`（对应文件为 `.github/workflows/shell-tool-mcp-ci.yml`）。若后续在列表中出现，则补充禁用以保持默认分支仅 `fork-ci` 提供 CI 信号。
   - 记录证据：禁用前/后的 `gh workflow list` 输出（可贴在 issue Notes 中）。
5. 验证与交付
   - 本地执行 4 条命令，确保“推理翻译功能”与 TUI 相关测试仍通过。
   - 推送后验证 GitHub Actions：默认分支 push/PR 仅触发 `fork-ci` 且通过。

## Tests & Verification
- “只跑 4 条命令” ->
  - 静态：审计 `fork-ci.yml` 只有 4 个 `run:` step 且每个单行命令。
  - 动态：Actions run log 的 steps 与命令一致。
- “仅 Ubuntu” ->
  - 静态：`runs-on` 仅 `ubuntu-*`。
  - 动态：Actions run 显示 runner OS 为 Ubuntu。
- “默认分支不触发其它 workflows” ->
  - 动态：push/PR 后 Actions runs/Checks 列表只有 `fork-ci`（其余被禁用，不产生 runs）。
- “功能不回归（最小侵入）” ->
  - 本地执行以下命令全部通过：
    - `cargo test -p codex-core translation`
    - `cargo test -p codex-exec`
    - `cargo build -p codex-cli`
    - `cargo test -p codex-tui`

## Issue CSV
- Path: issues/2026-01-30_12-11-29-fork-ci-ubuntu-only.csv
- Must share the same timestamp/slug as this plan.

## Execution Strategy（Plan 阶段一次性对齐，避免执行中反复打断）
- Mode: normal-batch
- Entry skill: $issue-batch
- Commit policy: manual
- Plan audit before execution: yes
- Use git worktree: no
- Regression: per-issue quick regression + final regression（仅限本计划 4 条命令）

## Tools / MCP
- 本地：git、gh、cargo
- 多 agent 审计：
  - 内置子代理 `spawn_agent` id：`019c0d07-c1bc-7bd2-bf08-1266e7863eb7`
  - 外置协作（Claude）SESSION_ID：`b15ebadb-ab7a-4d58-b72e-9324797257e2`

## Acceptance Checklist
- [ ] 新增 `.github/workflows/fork-ci.yml`，且仅 Ubuntu、仅 4 条命令。
- [ ] 撤回 `2fc5f2ccf` 对上游 workflows 的触发扩展，降低 future rebase 冲突风险。
- [ ] 通过 `gh workflow disable` 禁用非目标 workflows，默认分支 push/PR 只触发 `fork-ci`。
- [ ] 本地执行 4 条命令全部通过。
- [ ] 推送后 GitHub Actions：`fork-ci` 通过，且无额外 workflow runs。

## Risks / Blockers
- 缺少仓库管理员权限导致无法禁用 workflows -> 回退到策略 B（代码化隔离触发条件）。
- 禁用 workflows 属于“配置层变更”，不体现在 git diff -> 需要在 Notes/验证步骤里留存证据。
- Ubuntu runner 可能缺少系统依赖导致某条测试失败 -> 仅按失败信息最小补齐依赖，禁止吞错/默认值掩盖。

## Rollback / Recovery
- 若 `fork-ci.yml` 引入问题：revert 新增文件的提交。
- 若禁用 workflow 过多：使用 `gh workflow enable <name>` 恢复。
- 若需要回到策略 B：恢复 workflows 并改 `on.*.branches` 触发条件（但会增加未来 rebase 冲突风险）。

## Checkpoints
- Commit after: `fork-ci` 落地 + revert 触发扩展 + workflows 禁用完成 + 本地 4 条命令通过。

## References
- `.github/workflows/rust-ci.yml`（存在 `runs-on: { group: codex-runners, ... }` 依赖，fork 无此 runner group）。
- `.github/workflows/bazel.yml`（包含非 Ubuntu runner/架构矩阵）。
- `.github/workflows/ci.yml` / `.github/workflows/sdk.yml` / `.github/workflows/cargo-deny.yml` / `.github/workflows/codespell.yml` / `.github/workflows/shell-tool-mcp-ci.yml`
