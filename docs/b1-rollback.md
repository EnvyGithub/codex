# B1 回滚与恢复 SOP

## 目的
- 给 B1（交互式 rebase + force-with-lease）准备一套可复现、可审计的回滚流程。
- 覆盖两类场景：
  - 仅本地回滚（不影响远端）
  - 远端分支回滚（会再次改历史，需要明确冻结窗口）

## 适用范围
- 分支：`feat/agent-reasoning-translation-plugin`
- 本次 B1 的证据与合约：
  - 执行合约：`@issues/2026-01-30_17-45-21-b1-patchstack-hygiene.csv`
  - range-diff 归档：`@issues/b1-range-diff-20260130.txt`

## 可用回滚点（backup refs，origin 可见）
> 说明：backup refs 的目标是“任何机器都能恢复”。优先使用 tag（不可变、容易 fetch）；分支作为冗余入口。

- `backup-b1-pre-20260130-1441d05b025c`
  - 指向：`1441d05b025cd234b2e3981b7064df7d01eaac29`
  - 含义：更早的 B1 门禁阶段的快照（用于“回到最初备份点”）。
- `backup-b1-pre-20260130-3cd0af54d2ac`
  - 指向：`3cd0af54d2acfaa08f4420ae5e35f5d2a27825c4`
  - 含义：**pre-rebase 的 HEAD**（已用于 tree 等价性审计的基准点之一，推荐作为主要回滚点）。
- `backup/b1-pre-20260130-1441d05b025c`（分支）
  - 指向：`1441d05b025cd234b2e3981b7064df7d01eaac29`

## 回滚前检查（必须）
1) 确认冻结窗口
- 远端回滚会“再次改历史”，必须确保无人基于当前远端新历史开发/未合并本地工作。

2) 记录当前远端 SHA（审计/回滚前后对比用）

```bash
git fetch origin --prune --tags
git rev-parse origin/feat/agent-reasoning-translation-plugin
```

3) 确认 backup tag 可用

```bash
git show -s --oneline backup-b1-pre-20260130-3cd0af54d2ac
```

## 本地回滚（不推送远端）
> 适用：你想先在本地验证“回滚后是否恢复了预期行为”，或者只是临时回到旧版本做排查。

```bash
git fetch origin --prune --tags
git checkout feat/agent-reasoning-translation-plugin
git reset --hard backup-b1-pre-20260130-3cd0af54d2ac
git status -sb
git rev-parse HEAD
```

（可选）按白名单跑一次回归（与 Plan B 保持一致）：

```bash
cd codex-rs
just fmt
cargo test -p codex-core translation
cargo test -p codex-exec
cargo build -p codex-cli
cargo test -p codex-tui
```

## 远端回滚（会改历史，谨慎）
> 适用：你已经确认需要把 `origin/feat/agent-reasoning-translation-plugin` 恢复到某个 backup 点。

步骤：
1) 本地先回滚到目标 backup tag（同“本地回滚”）。
2) 再用 `--force-with-lease` 推送（确保你不会覆盖掉“你没见过”的远端更新）。

```bash
git fetch origin --prune --tags
git checkout feat/agent-reasoning-translation-plugin
git reset --hard backup-b1-pre-20260130-3cd0af54d2ac
git push --force-with-lease origin feat/agent-reasoning-translation-plugin
```

## 协作者同步指引（回滚后）
> 适用：协作者之前已经拉取过“新历史”，需要把本地分支同步到回滚后的远端状态。

无本地工作（推荐最快路径）：

```bash
git fetch origin --prune --tags
git checkout feat/agent-reasoning-translation-plugin
git reset --hard origin/feat/agent-reasoning-translation-plugin
```

如果协作者在旧历史上有本地提交：不要直接 `reset --hard`，建议把其提交先 `git format-patch` 备份，或联系维护者确定迁移策略。

