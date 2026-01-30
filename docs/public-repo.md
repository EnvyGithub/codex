# 公开仓库说明与发布清单（维护者）

本文档面向**准备把本 fork 公开**的维护者，用于把“对外说明”与“发布前检查”固化为可执行清单，减少遗漏。

## 对外说明（README 建议包含）

建议在仓库首页（`README.md`/`README.en.md`）明确：

- **这是上游 `openai/codex` 的 fork**，并说明 fork 的动机与目标。
- **本 fork 新增能力**：推理输出翻译插件（外部命令钩子）
  - 可通过 `~/.codex/config.toml` 配置外部命令
  - 把 `AgentReasoning` 以“原文 + 译文”展示在 TUI/TUI2
  - 不内置任何在线翻译 SDK（隐私/合规/依赖解耦）
- **分发说明**：
  - npm / brew 安装的是上游官方发行版
  - 使用本 fork 特性需构建并运行本仓库的 `codex`（或使用本仓库 release，如果维护者提供）
- **非官方声明**：与 OpenAI 官方无隶属关系（避免误解）
- **许可证**：Apache-2.0（`LICENSE`）

翻译插件的对外文档建议以 `docs/translation.md` 为权威入口。

## 使用说明（对外）

面向普通用户，对外文档需要回答三个问题：

1. 怎么获取可运行的 `codex`？
2. 怎么启用推理译文？
3. 怎么自己写/替换翻译器？

建议把“启用推理译文”的最短路径固定为：

- 构建/安装本 fork 的 `codex`
- 配置 `plugins.translation.agent_reasoning.command`
- 先用 `scripts/translate_agent_reasoning_dummy.py` 验证链路，再换成真正的翻译器

## 上游同步策略（强烈建议）

目标：让公开仓库的基线尽量贴近“官方可用版本”，减少“跟着 main 跑但遇到开发中变更”的不可控风险。

建议约定两条规则：

1. **日常开发可以跟随 `upstream/main`**（新特性/修复更快进入）。
2. **对外公开/发版时优先对齐上游发布 tag**（更接近上游发布包的真实基线）。

在 `openai/codex` 里，Rust CLI 的发布通常会打 tag，例如：

- `rust-v0.87.0`（稳定版）
- `rust-v0.88.0-alpha.1`（预发布）

同步脚本默认会对齐“最新稳定发布 tag（rust-vX.Y.Z）”，并把本 fork 的补丁栈重新打上去，示例：

```bash
./scripts/dev-sync-upstream.sh --non-interactive --build both --link both --verify quick
```

如果你希望锁定到某个具体发布版本（例如 `rust-v0.87.0`），可显式指定：

```bash
./scripts/dev-sync-upstream.sh --non-interactive --upstream rust-v0.87.0 --build both --link both --verify quick
```

如需跟随上游开发分支（`upstream/main`）：

```bash
./scripts/dev-sync-upstream.sh --non-interactive --upstream upstream/main --build release
```

如果你想找“最新稳定版 tag”，可在 fetch tags 后用版本排序筛选（示例）：

```bash
git fetch upstream --tags --prune
git tag --list 'rust-v*' | rg '^rust-v\\d+\\.\\d+\\.\\d+$' | sort -V | tail -n 1
```

## 发布前检查（必须做）

### 1) 敏感信息与隐私审计

目标：确认仓库中**不存在**可用于直接访问你账户/资源的敏感信息（API key、token、私钥、内网地址等）。

建议执行一次全仓粗扫（示例，按需增减关键词）：

```bash
rg -n -S "API_KEY|ACCESS_KEY|SECRET_KEY|BEGIN (RSA|OPENSSH) PRIVATE KEY|ssh-rsa|xox[baprs]-|AKIA[0-9A-Z]{16}|ghp_[0-9A-Za-z]{36}" .
```

同时确认示例文件仅包含占位符：

- `scripts/gemini_crs1.env.example`
- `docs/translation.md`

### 2) 文档一致性检查

目标：README 与 docs 中提到的路径/配置项在仓库里真实存在。

建议：

- 检查 `docs/translation.md` 中提到的脚本文件路径都存在
- 检查 `docs/config.md` 中提到的 `plugins` 命名空间已进入 schema（schema 只描述通用 `plugins`，不会校验 `plugins.*` 下的插件字段；翻译插件会在运行时严格解析并在未知字段时报错；细节以 `docs/translation.md` 为准）

### 3) 最小可运行性验证

目标：至少能在本地（或 CI）完成一次构建与最小运行，避免“仓库公开但不可用”。

建议最小验证步骤：

```bash
cd codex-rs
cargo build
```

如果你改动了 Rust 代码，建议按仓库约定执行：

```bash
cd codex-rs
just fmt
just fix -p <crate>
```

（注意：本 fork 的翻译功能主要影响 `codex-core` / `codex-exec` / `codex-tui`；上游 `rust-v0.92.0` 起已移除 `codex-tui2`。）

## 对外支持策略（可选，但建议写清）

仓库公开后，建议明确：

- 你是否接受 PR？（bugfix only / feature discussion first）
- issue 的范围：只处理本 fork 相关问题，还是也协助上游问题定位？
- 对“联网翻译”的支持边界：外部翻译器由用户自行承担 key/服务质量/合规风险
