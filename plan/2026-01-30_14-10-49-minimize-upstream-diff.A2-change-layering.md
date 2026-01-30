---
mode: notes
related_plan: plan/2026-01-30_14-10-49-minimize-upstream-diff.md
related_issues_csv: issues/2026-01-30_14-10-49-minimize-upstream-diff.csv
issue: A2
created_at: "2026-01-30T14:32:00+08:00"
---

# A2：变更分层清单（必须/可下沉/可移除）

本文件是对 `rust-v0.92.0..HEAD` 之间补丁栈的静态审计结果，用于后续 A3~A7 做“最小入侵缩差异/降冲突”的决策依据。

## 事实输入（可复核）

- 分支：`feat/agent-reasoning-translation-plugin`
- 基线 tag：`rust-v0.92.0`
- 当前 HEAD：`302ac354de440968bb627ed0050047aa1702801d`
- `rust-v0.92.0..HEAD` 提交数：28
- A1 baseline 摘要（见 Issue CSV A1 Notes）：
  - diffstat：47 files changed, +4309/-142
  - 热文件 numstat：`chatwidget.rs` +326/-13；`footer.rs` +4/-3；`config/mod.rs` +141；`types.rs` +48；`history_cell.rs` +125
  - 冲突探针（`rust-v0.93.0-alpha.17`）：`codex-rs/Cargo.toml`、`codex-rs/core/src/lib.rs`、`codex-rs/tui/src/bottom_pane/footer.rs`

### 关于“冲突探针”的解释（避免误读）

`git merge-tree HEAD rust-v0.93.0-alpha.17` 的 merge-base 是 `ab99df0694e484f67fcfb8b2765364854f434872`，并非 `rust-v0.92.0`。

因此探针冲突项反映的是“两个不同发布线/分支分叉后”的趋势预测，不等价于“从 `rust-v0.92.0` 快进到 `rust-v0.93.*` 的必然冲突列表”。

## 变更分层

分层目标：

- **必须保留**：删了就会破坏推理翻译插件关键行为（硬约束）。
- **可下沉**：行为必须保留，但实现可以迁移到新文件/新模块以降低热文件侵入与未来冲突面。
- **可移除（候选）**：与翻译无关且占用差异预算/制造冲突风险的改动；仅在证据充分时执行回退/拆分（禁止拍脑袋删）。

---

## 必须保留（翻译核心链路）

### Core：外部命令翻译插件 + 配置语义

对应提交：

- `8343a80c8 feat(core): 推理译文外部命令插件`
- `8c8cec3e9 feat(translation): 增加ui_max_wait_ms并接入TUI`
- `94b95bf2f fix(core): 翻译配置补齐 JsonSchema 以兼容配置 schema`

涉及文件（关键）：

- `codex-rs/core/src/translation/mod.rs`
- `codex-rs/core/src/translation/external_command.rs`
- `codex-rs/core/src/config/mod.rs`
- `codex-rs/core/src/config/types.rs`
- `codex-rs/core/src/config/profile.rs`
- `codex-rs/common/src/config_summary.rs`

保留理由（与硬约束直接相关）：

- 插件默认关闭、未配置不启用（靠 config 语义实现）。
- `command=[]` 表示显式关闭（profile 覆盖语义不能被“简化”为默认值或吞配置）。
- 异步执行与任务编排依赖于可被调用的 core translation 能力（哪怕实现是 external command）。
- `request_id/thread_id` 防串台校验属于业务正确性约束，必须保留在翻译链路上。

风险点（后续改动需特别注意）：

- 配置解析/合并如果做“多路径兜底/默认值静默回退”，会违反“禁止防御性编程掩盖问题”，也会改变 `command=[]` 的语义。

### Exec：推理译文异步输出（不阻塞 UI）

对应提交：

- `cff06418e feat(exec): 推理译文异步输出`

涉及文件（关键）：

- `codex-rs/exec/src/event_processor_with_human_output.rs`

保留理由：

- TUI 主循环不能被翻译阻塞；exec 层异步输出是“不阻塞”的基础设施之一。

### TUI：译文紧贴原文体验（barrier/deferred/flush）

对应提交：

- `43c389d5b feat(tui): 推理译文紧贴展示（含 tui2）`
- `089995809 fix(tui): 成功译文不再显示└ 译文标签`
- `8261ea375 fix(tui,tui2): 推理译文块避免二次换行导致挤压`
- `67e05aea7 fix(tui): 补齐推理翻译字段初始化（修复编译）`

涉及文件（关键）：

- `codex-rs/tui/src/chatwidget.rs`
- `codex-rs/tui/src/history_cell.rs`
- `codex-rs/tui/src/app.rs`
- `codex-rs/tui/src/app_event.rs`

保留理由：

- “译文紧贴原文”的体验依赖 barrier/deferred 机制（顺序、超时释放、flush 逻辑）。此处任何重构都必须“行为等价”。
- request/thread 防串台校验与 UI 插入策略耦合，删改会造成“把别的请求译文贴到当前会话”的严重回归。

### 自动验证（翻译链路的回归锚点）

对应提交：

- `43c389d5b` / `089995809` / `8c8cec3e9` 等对测试的增补

涉及文件（关键）：

- `codex-rs/tui/src/chatwidget/tests.rs`

保留理由：

- 后续 A4/A5 会移动实现位置；测试是“保持行为不回归”的唯一可自动化证据载体之一。

---

## 可下沉（保留行为，降低热文件侵入/未来冲突）

### 1) `codex-rs/tui/src/chatwidget.rs`：翻译编排/状态机下沉

现状证据：

- A1 热文件 numstat：`chatwidget.rs` +326/-13（侵入度最高）
- 相关提交：`43c389d5b`、`8c8cec3e9`、`67e05aea7`

建议下沉方向（与 plan A4 对齐）：

- 新增 chatwidget 子模块承载 orchestrator + barrier/deferred 状态机；`chatwidget.rs` 仅保留薄入口/委托/事件转发。
- 若需要解耦 UI：用 “effects 列表” 作为输出（例如 AppendCell/SpawnTask/FlushDeferred），避免状态机直接操作 UI 数据结构。

下沉的收益：

- 减少对上游热文件的长期侵入，降低未来 rebase/合并时的冲突概率。

### 2) `codex-rs/tui/src/chatwidget/tests.rs`：翻译相关测试下沉

现状证据：

- diffstat：`chatwidget/tests.rs` +356（同样是高冲突面）

建议：

- 把翻译相关大块测试拆到更小的 tests 子模块/文件（A5），降低同文件冲突概率，并便于聚焦 barrier/deferred 行为回归。

### 3) `codex-rs/tui/src/bottom_pane/footer.rs`：向“props 注入 + 纯渲染”靠拢

现状证据：

- 冲突探针命中：`codex-rs/tui/src/bottom_pane/footer.rs`
- 当前 footer 内包含 WSL 检测的 cfg/test 分支（为快照测试稳定性做的妥协）

建议：

- 逐步把 `is_wsl` 的判定从 footer 内移到更上层（owner widget/app），footer 接收 props 并纯渲染。
- 这样既能保留“测试稳定性”，也能避免 footer 在上游结构调整时反复冲突（根因治理）。

---

## 可移除（候选，需要证据与回归；禁止拍脑袋删）

### 1) WSL 下跳过 PowerShell 安全断言（疑似与翻译无关）

对应提交：

- `249c5e318 test(core): WSL 下跳过 PowerShell 安全断言`

涉及文件：

- `codex-rs/core/src/tools/handlers/shell.rs`

初步判断：

- 从提交信息与文件归属看，是 shell 工具/测试稳定性相关；与翻译核心链路无直接关系。

后续决策所需证据（A3 再执行）：

- 该改动是否只是测试规避（例如 WSL 环境差异），以及是否会影响计划允许的测试集合。

### 2) `reqwest` 启用 `native-tls-vendored`（依赖 feature 偏离）

对应提交：

- `7193629ae chore(core): reqwest 启用 native-tls-vendored`

涉及文件：

- `codex-rs/core/Cargo.toml`

初步判断：

- 与翻译核心链路（external command）无直接关系，但可能是为构建环境可移植性（OpenSSL 依赖）做的工程化调整。

后续决策所需证据（A3 再执行）：

- 在目标环境（WSL2）与允许的回归命令下，此 feature 是否必要；若非必要可回退以缩差异面。

### 3) shell_snapshot 超时/ETXTBSY 相关修复（测试稳定性噪声）

对应提交：

- `f19178566 fix(core): 更新配置 schema 并修复 shell_snapshot 超时测试（避免 Linux ETXTBSY）`
- `286125a06 chore: 更新 Cargo.lock 与格式（对齐 v0.92.0）`（包含对 `shell_snapshot.rs` 的再修改）

涉及文件：

- `codex-rs/core/src/shell_snapshot.rs`
- `codex-rs/core/config.schema.json`（生成物）

初步判断：

- 与翻译核心链路无直接关系，属于测试稳定性/生成物同步类噪声，可能占用差异预算。

后续决策所需证据（A3 再执行）：

- 是否能在不影响允许回归集合的前提下回退；以及生成物是否可以通过流程重建而非长期保留手工合并结果。

---

## 需要用户二次确认的事项

- B1：补丁栈卫生（interactive rebase + `--force-with-lease` push）是高风险操作，未获得明确书面确认前不得执行。

## 下一步（A3 聚焦点）

优先处理“与翻译无关但占用差异预算/制造冲突根因”的改动点：

1. footer：推进 props 注入/纯渲染，优先消除探针冲突根因。
2. 依赖 feature 偏离（`reqwest native-tls-vendored`）：评估必要性后决定回退/保留。
3. shell_snapshot / shell handler：识别与翻译无关的测试稳定性改动，能拆则拆、能退则退。

