---
mode: plan
task: B1 补丁栈卫生（交互式 rebase + 可能 force-with-lease）
created_at: "2026-01-30T17:51:09+08:00"
complexity: complex
---

# Plan: B1 补丁栈卫生（交互式 rebase + 可能 force-with-lease）

## Goal
- 在不改变功能的前提下，通过交互式 rebase（squash/reword/reorder）把翻译插件相关补丁栈收敛为少量稳定 commits，降低未来 rebase “按提交重放” 的冲突概率。
- 在明确风险控制与可回滚的前提下，必要时对 `origin/feat/agent-reasoning-translation-plugin` 执行 `git push --force-with-lease`。

## Scope
- In:
  - 仅做 git 历史整理：squash/reword/reorder（原则上不改内容）。
  - B1 前建立可审计、可回滚的 backup refs（本地 + 远端）。
  - B1 前后必须跑白名单回归集合，并记录证据。
- Out:
  - 不引入新功能。
  - 不扩大测试白名单。
  - 不在 B1 阶段夹带“内容修复”；若确需修复，必须回到 Plan A 或新 plan 处理。

## Assumptions / Dependencies
- 前置条件（必须满足，否则不得进入 B1）：
  - Plan A（reduce-probe-conflicts）已完成，并且白名单回归通过。
  - 当前分支工作区干净（无未提交改动）。
- 协作约束：
  - 若该远端分支存在协作者基于开发，必须先通知并确认冻结窗口。

## Phases
1. Phase 0（门禁）：协作者通知 + 冻结窗口确认
   - 明确通知渠道与确认方式（例如：在 PR/群里公告 + 24h 冻结窗口）。
   - 若无法确认无人基于该分支开发，则默认走“推新分支”的低风险方案（不 force 覆盖旧分支）。
2. Phase 1（门禁）：创建并推送 backup refs（强制）
   - 创建 tag / backup 分支指向 B1 前 HEAD。
   - 推送 backup refs 到 origin，确保可在任何机器上恢复。
   - 把 backup ref 名称与 SHA 写入 issue Notes。
3. Phase 2：交互式 rebase（仅整理历史）
   - 目标形态：将翻译插件相关提交收敛为少量主题 commits（建议 3~6 个，按 core/exec/tui/tests/docs 分组）。
   - 要求：reword 的 commit message 必须是中文，包含“做了什么 + 为什么”。
4. Phase 3（门禁）：等价性审计（证明“只改历史”）
   - 输出并审计 `git range-diff`（或等价工具）的摘要。
   - 若承诺“内容不变”，则新旧 tree diff 应为空；如非空，必须说明原因并回到 Phase 2 修正。
5. Phase 4（门禁）：白名单回归再跑一遍
6. Phase 5（门禁）：满足准入条件后才允许 force-with-lease
   - 准入条件（必须同时满足）：
     - 冻结窗口确认完成
     - backup refs 已推送到 origin
     - Phase 3 等价性审计通过
     - Phase 4 白名单回归通过
   - 若任一条件不满足：禁止 force，改为推送到新分支并通知协作者切换。

## Tests & Verification
- 白名单回归（B1 前后都必须跑；失败即停止）：

```bash
cd "/home/admin2/tmp/openai-codex/codex-rs"
just fmt
```

```bash
cd "/home/admin2/tmp/openai-codex/codex-rs"
cargo test -p codex-core translation
```

```bash
cd "/home/admin2/tmp/openai-codex/codex-rs"
cargo test -p codex-exec
```

```bash
cd "/home/admin2/tmp/openai-codex/codex-rs"
cargo build -p codex-cli
```

```bash
cd "/home/admin2/tmp/openai-codex/codex-rs"
cargo test -p codex-tui
```

## Issue CSV
- Path: issues/2026-01-30_17-45-21-b1-patchstack-hygiene.csv
- Must share the same timestamp/slug as this plan.

## Execution Strategy（Plan 阶段一次性对齐，避免执行中反复打断）
- Mode: normal-batch
- Entry skill: $issue-batch
- Commit policy: manual
- Plan audit before execution: yes
- Use git worktree: no
- Regression: per-issue quick regression + final regression（均限制为白名单命令集合）

## Tools / MCP
- 本地：git（rebase/range-diff/push）、rg、cargo、just。
- 外置协作（审计）：Claude/Gemini（本 plan 草稿已审计，SESSION_ID 见 References）。

## Acceptance Checklist
- [ ] Plan A 已完成且白名单回归通过。
- [ ] B1 前 backup refs 已创建并推送到 origin，且记录到 issue Notes。
- [ ] B1 后 `git range-diff` 审计通过（若承诺“内容不变”，tree diff 为空）。
- [ ] B1 后白名单回归通过。
- [ ] 若执行 force-with-lease：满足准入条件且协作者已知晓恢复步骤。

## Risks / Blockers
- 该 Plan 是高风险“改历史”操作；即使使用 `--force-with-lease`，仍可能对协作者造成影响。
- 测试白名单限制：无法扩大验证范围，存在漏检风险；B1 只能降低冲突风险，不等于零风险。

## Rollback / Recovery
- 通过 backup ref 一键回滚（写入 issue Notes，作为执行门禁的一部分）：

```bash
cd "/home/admin2/tmp/openai-codex"
# 例：把 <BACKUP_REF> 替换为 Phase 1 创建并已推送到 origin 的 tag/分支
# git reset --hard <BACKUP_REF>
# git push --force-with-lease origin feat/agent-reasoning-translation-plugin
```

## Checkpoints
- Checkpoint B0：协作者冻结窗口确认完成。
- Checkpoint B1：backup refs 已推送到 origin。
- Checkpoint B2：rebase 完成且等价性审计通过。
- Checkpoint B3：白名单回归通过。
- Checkpoint B4：满足准入条件后才允许 force-with-lease。

## References
- 前置 plan：plan/2026-01-30_17-45-21-reduce-probe-conflicts.md
- 既有合约：plan/2026-01-30_14-10-49-minimize-upstream-diff.md
- 当前分支：feat/agent-reasoning-translation-plugin
- Plan 审计（Claude opus）：SESSION_ID=dac7da61-8f93-450e-aab7-91df4cff2a73
- Plan 审计（Gemini）：SESSION_ID=5979ec14-3e9f-4260-94a6-673f66f4a0b2
- Plan 审计（spawn_agent）：id=019c0e47-82a4-7130-a9ef-03b404d8cd44
