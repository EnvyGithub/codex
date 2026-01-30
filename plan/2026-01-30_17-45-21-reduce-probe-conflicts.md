---
mode: plan
task: 消除 probe 冲突热点（Cargo.toml + core/lib.rs）
created_at: "2026-01-30T17:50:31+08:00"
complexity: complex
---

# Plan: 消除 probe 冲突热点（Cargo.toml + core/lib.rs）

## Goal
- 在不破坏“推理翻译插件”关键行为的前提下，进一步降低未来同步上游 release tag 的合并冲突成本。
- 以 `rust-v0.92.0` 为稳定基线（patch base 思路不变），对齐上游演进方向，目标是让冲突探针（`rust-v0.93.0-alpha.17`）中：
  - `codex-rs/Cargo.toml` 不再出现 content conflict
  - `codex-rs/core/src/lib.rs` 不再出现 content conflict
- 约束：不做无意义格式化/重排；测试严格限制为白名单 5 条命令。

## Scope
- In:
  - 以“冲突探针（merge-tree）证据”为驱动，定位并消除 `codex-rs/Cargo.toml` 与 `codex-rs/core/src/lib.rs` 的结构性冲突根因。
  - 对齐策略：优先“顺上游结构”（模块拆分/声明顺序/成员组织/feature gate 结构），把 fork 专有差异放到更稳定区域，避免与上游活跃变更区域重叠。
  - 每次调整后立即复跑 probe，确保冲突项不反弹、不扩散。
- Out:
  - 不做真实 rebase（本 Plan 只做准备性对齐，降低未来 rebase 冲突概率）。
  - 不执行 B1（补丁栈卫生/改历史）；B1 将放入独立 Plan。
  - 不引入新功能，不扩大/修改测试白名单。

## Assumptions / Dependencies
- 稳定基线 tag：`rust-v0.92.0`。
- 冲突探针 target：`rust-v0.93.0-alpha.17`（仅趋势预测，不等同于 rebase 目标）。
- 当前 probe 冲突项：2 个（`codex-rs/Cargo.toml`、`codex-rs/core/src/lib.rs`）。
- 执行纪律：
  - 任何改动必须能解释“为什么能降低冲突根因”。
  - 不允许吞异常/默认值兜底掩盖问题。

## Phases
1. Phase 1：只读定位（先证据后动作）
   - 记录当前 probe baseline 输出（含时间戳、HEAD SHA、tag SHA、冲突列表）。
   - 分析上游从 `rust-v0.92.0` 到 `rust-v0.93.0-alpha.17` 在这两个文件的结构演进（哪些段落是上游热点）。
2. Phase 2：治理 `codex-rs/Cargo.toml`
   - 目标：probe 输出中不再包含 `codex-rs/Cargo.toml`。
   - 策略：按上游演进方式调整 workspace/依赖/feature 的结构与位置；尽量避免在上游频繁改动段落堆叠 fork 差异。
3. Phase 3：治理 `codex-rs/core/src/lib.rs`
   - 目标：probe 输出中不再包含 `codex-rs/core/src/lib.rs`。
   - 策略：对齐上游 `mod`/`pub use`/feature gate 组织；将翻译相关入口放到“安全插入位置”。
4. Phase 4：门禁回归 + 复测 probe
   - 跑白名单回归（见 Tests & Verification）。
   - 复跑 probe 并写入对比结论（与 Phase 1 baseline 对比）。

## Tests & Verification
- 冲突探针（固定命令，保证可复现；每个 phase 后至少记录一次）：

```bash
cd "/home/admin2/tmp/openai-codex"
git merge-tree --write-tree --messages HEAD rust-v0.93.0-alpha.17 | rg "^CONFLICT"
```

- 白名单回归（严格限制；失败即停止）：

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
- Path: issues/2026-01-30_17-45-21-reduce-probe-conflicts.csv
- Must share the same timestamp/slug as this plan.

## Execution Strategy（Plan 阶段一次性对齐，避免执行中反复打断）
- Mode: normal-batch
- Entry skill: $issue-batch
- Commit policy: manual
- Plan audit before execution: yes
- Use git worktree: no
- Regression: per-issue quick regression + final regression（均限制为白名单命令集合）

## Tools / MCP
- 本地：git（merge-tree）、rg、cargo、just。
- 外置协作（审计）：Claude/Gemini（本 plan 草稿已审计，SESSION_ID 见 References）。

## Acceptance Checklist
- [ ] probe 冲突项不增加。
- [ ] probe 输出不再包含 `codex-rs/Cargo.toml`。
- [ ] probe 输出不再包含 `codex-rs/core/src/lib.rs`。
- [ ] 白名单回归 5 条命令全部 exit=0。

## Risks / Blockers
- 测试白名单限制：无法扩大到 workspace 全量验证，可能遗漏非翻译路径回归（需接受风险或后续单独申请扩大测试授权）。
- 若上游在 alpha 阶段仍频繁改动热点段落，可能需要多轮对齐才能稳定消除冲突。

## Rollback / Recovery
- 本 Plan 不改历史；回滚以 `git revert <sha>` 为主，保持可追溯。

## Checkpoints
- Checkpoint P1：记录 baseline probe 输出（作为后续对比基线）。
- Checkpoint P2：`Cargo.toml` 从 probe 冲突列表消失。
- Checkpoint P3：`core/src/lib.rs` 从 probe 冲突列表消失。
- Checkpoint P4：白名单回归通过 + 最终 probe 通过（冲突项为 0）。

## References
- 既有合约：plan/2026-01-30_14-10-49-minimize-upstream-diff.md
- 当前分支：feat/agent-reasoning-translation-plugin
- 冲突探针目标：rust-v0.93.0-alpha.17
- Plan 审计（Claude opus）：SESSION_ID=dac7da61-8f93-450e-aab7-91df4cff2a73
- Plan 审计（Gemini）：SESSION_ID=5979ec14-3e9f-4260-94a6-673f66f4a0b2
- Plan 审计（spawn_agent）：id=019c0e47-82a4-7130-a9ef-03b404d8cd44
