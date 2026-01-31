#!/usr/bin/env bash
# 翻译功能确定性离线 smoke 测试
# 用途：快速验证翻译插件核心功能（不依赖网络/python）

set -euo pipefail

cd "$(dirname "$0")/../codex-rs"

echo "==> Translation Smoke Test: Starting..."
echo

# 1. Core: 配置/兼容性测试
echo "==> [1/3] codex-core: 配置与兼容性"
cargo test -p codex-core config::plugins_validation -- --test-threads=1
echo "✓ Core config tests passed"
echo

# 2. TUI: Barrier 邻接性与超时测试
echo "==> [2/3] codex-tui: Barrier 邻接性与超时"
cargo test -p codex-tui translation_barrier -- --test-threads=1
echo "✓ TUI barrier tests passed"
echo

# 3. TUI: 完整翻译流程测试（包括外部命令路径）
echo "==> [3/3] codex-tui: 完整翻译流程"
cargo test -p codex-tui agent_reasoning_translation -- --test-threads=1
echo "✓ TUI translation tests passed"
echo

echo "==> Translation Smoke Test: ALL PASSED ✓"
