# 故障排查（Fork / WSL 相关）

本文档收集一些在 **Windows 11 + WSL2** 使用 Codex CLI（含本 fork）时更容易遇到的环境问题与排查方法。

> 说明：本 fork 只在“推理输出翻译（外部命令插件）”上做扩展，其余行为尽量保持与上游一致。

## 1) 启动/退出时报错：`The cursor position could not be read within a normal duration`

现象：

- 运行 `codex`（交互 TUI）时立即报错退出，或退出时打印类似错误：
  - `Error: The cursor position could not be read within a normal duration`

结论（通常）：

- 这通常不是本 fork 引入的 bug，而是 **终端环境无法响应“光标位置查询（CPR）”** 导致的。
- Codex 的交互 TUI 在启动/渲染阶段需要读取当前光标位置；如果终端不返回响应（常见于“伪终端/非交互/某些集成终端”），就会触发该错误。

### 排查清单

1. 确认是在“真实交互终端”里运行，而不是：
   - CI / 自动化 runner
   - 输出被重定向/管道（stdout/stderr 被接走）
   - 某些不完整实现 CPR 的伪终端
2. 在 WSL2 下优先使用：
   - Windows Terminal（推荐）
   - 或其它支持完整 VT/CPR 的终端（如 WezTerm 等）
3. 确认 `TERM` 合理（示例）：

```bash
echo "$TERM"
```

常见可用值：`xterm-256color` / `screen-256color`（具体取决于你的终端）。

### 最小自测：终端是否支持 CPR

下面命令会向终端发送 CPR 查询（`ESC [ 6 n`）并等待响应（`... R` 结尾）：

```bash
python3 - <<'PY'
import os
import sys
import termios
import tty
import select

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    sys.stdout.write("\x1b[6n")
    sys.stdout.flush()
    ready, _, _ = select.select([sys.stdin], [], [], 1.0)
    if not ready:
        print("NO_RESPONSE")
        raise SystemExit(2)
    resp = os.read(fd, 64)
    print(resp.decode("ascii", "replace"))
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
PY
```

- 若输出类似 `\x1b[<row>;<col>R`（例如 `\x1b[24;1R`），通常表示 CPR 正常。
- 若输出 `NO_RESPONSE`，说明当前终端/会话不返回 CPR，交互 TUI 很可能无法启动。

### 规避方案

- 需要“非交互”运行时，优先使用子命令（示例）：

```bash
codex exec --help
```

这些模式通常不依赖交互式 TUI 渲染能力。

- 如需进一步定位，可开启回溯（示例）：

```bash
RUST_BACKTRACE=1 codex
```

并将错误输出附到 issue 中（如果你准备提 issue）。

## 2) 翻译插件相关：译文显示 `译文生成失败：...`

翻译插件通过外部命令执行翻译。失败原因最常见的几类：

1. 翻译器路径/argv 配错（`command = [...]`）
2. 翻译器超时（`timeout_ms` 太小，或网络抖动）
3. 翻译器把日志写到了 stdout，导致输出不再是纯 JSON

建议：

- 先用仓库内的 dummy 翻译器验证链路：
  - `scripts/translate_agent_reasoning_dummy.py`
- 确保翻译器 **stdout 只输出 JSON**；日志写 stderr。
- 出网翻译建议把 `timeout_ms` 设大一些（例如 8000ms 或 15000ms），并根据需要调大 `ui_max_wait_ms`（见 `docs/translation.md`）。

## 3) 本地跑全量测试失败：`Unable to find libclang`（bindgen/clang-sys）

现象：

- 运行 `cargo test --all-features`（或某些启用 bindgen 的 crate）时报错：
  - `Unable to find libclang: ... set the LIBCLANG_PATH environment variable ...`

结论（通常）：

- 这是 **系统缺少 clang/libclang**（或没被动态链接器找到）导致的环境问题，不是本 fork 的“推理翻译插件”逻辑本身。
- `--all-features` 会把一些平时不会编译到的依赖也拉进来，其中可能包含需要 bindgen 的 crate，因此更容易触发。

### 解决方案（WSL2 / Ubuntu）

1) 安装 clang + libclang（需要 sudo 权限）：

```bash
sudo apt-get update
sudo apt-get install -y clang libclang-dev
```

2) 验证 clang 可用：

```bash
clang --version
```

3) 若仍提示找不到 `libclang.so`，可以定位并显式设置 `LIBCLANG_PATH`（示例）：

```bash
sudo find /usr -name 'libclang.so*' -print
# 例如你找到的是 /usr/lib/llvm-17/lib/libclang.so.1，则：
export LIBCLANG_PATH=/usr/lib/llvm-17/lib
```

然后重试：

```bash
cd codex-rs
cargo test --all-features
```
