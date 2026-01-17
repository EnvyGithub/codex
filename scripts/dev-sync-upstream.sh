#!/usr/bin/env bash
set -euo pipefail

# 用途：
# - 在“官方 upstream/main”基础上，快速 rebase 你的功能分支（等价于“自动打补丁”）。
# - 可选：编译 codex-rs 的 codex 二进制（debug/release）。
# - 可选：创建/更新本地符号链接（例如 ~/.local/bin/codex-dev），方便直接运行你编译的版本。
#
# 设计原则：
# - 失败即失败：不吞异常、不悄悄回退默认值；所有关键行为都可见可控。
# - 默认安全：不默认 push、不默认改动用户环境（link）；需要显式确认或参数指定。
# - 既支持交互，也支持参数化非交互（便于自动化/AI 助手调用）。

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
用法：
  scripts/dev-sync-upstream.sh [选项]

默认行为（交互模式）：
  1) git fetch upstream --prune
  2) git rebase upstream/main
  3) 可选：push / build / link / verify（交互询问）

常用示例：
  # 交互式：同步 upstream 并提示你选择是否编译/建链接/推送
  ./scripts/dev-sync-upstream.sh

  # 非交互（适合自动化/AI）：同步 + 编译 release + 建 release 链接
  ./scripts/dev-sync-upstream.sh --non-interactive --build release --link release

  # 非交互：同步 + 推送（rebase 后需要 force-with-lease）+ 快速验证
  ./scripts/dev-sync-upstream.sh --non-interactive --push --verify quick

  # 只预览将要执行的命令（不做任何修改）
  ./scripts/dev-sync-upstream.sh --dry-run --build release --link both --push --verify quick

选项：
  -n, --non-interactive        非交互运行（不提示；未指定的可选步骤默认跳过）
      --dry-run                只打印命令，不执行
      --allow-dirty            允许工作区非干净状态（不推荐；默认要求干净）
      --no-fetch               跳过 fetch upstream（默认会 fetch）
      --no-rebase              跳过 rebase（默认会 rebase）
      --branch <name>          切换到指定分支后再执行（默认当前分支）
      --upstream <ref>         上游基准 ref（默认 upstream/main）
      --push                   rebase 成功后推送到 origin（使用 --force-with-lease）
      --build <mode>           编译模式：none|debug|release|both
      --link <mode>            建立符号链接：none|debug|release|both
      --link-dir <path>        符号链接目录（默认 ~/.local/bin）
      --verify <mode>          验证：none|quick
  -h, --help                   显示帮助

返回码：
  0  成功
  1  失败（例如冲突/缺少 remote/编译失败等）
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

trim() {
  # 去除首尾空白（不依赖外部命令，避免在精简环境里缺少 xargs）。
  local s="$1"
  # shellcheck disable=SC2001
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

warn() {
  echo "警告：$*" >&2
}

info() {
  echo "==> $*" >&2
}

require_arg() {
  local flag="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "参数 ${flag} 需要一个值（用 --help 查看用法）"
}

is_enum() {
  local value="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if [[ "$value" == "$candidate" ]]; then
      return 0
    fi
  done
  return 1
}

require_enum() {
  local flag="$1"
  local value="$2"
  shift 2
  is_enum "$value" "$@" || die "参数 ${flag} 的值无效：${value}（允许值：$*）"
}

run_cmd() {
  # 用数组传参，避免 eval/拼接导致的转义问题
  local -a cmd=("$@")
  printf '➜' >&2
  local part
  for part in "${cmd[@]}"; do
    printf ' %q' "$part" >&2
  done
  printf '\n' >&2

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  "${cmd[@]}"
}

run_git() {
  run_cmd git -C "$REPO_ROOT" "$@"
}

prompt_yes_no() {
  local question="$1"
  local default="$2" # y 或 n

  if [[ "$INTERACTIVE" -ne 1 ]]; then
    die "内部错误：在非交互模式下调用了 prompt（请使用参数指定行为）"
  fi
  if [[ ! -t 0 ]]; then
    die "当前不是交互终端（stdin 非 TTY），请使用 --non-interactive 并显式传参"
  fi

  local hint
  if [[ "$default" == "y" ]]; then
    hint="[Y/n]"
  else
    hint="[y/N]"
  fi

  while true; do
    read -r -p "${question} ${hint} " answer || true
    answer="$(trim "${answer:-}")"
    answer="${answer,,}"
    if [[ -z "$answer" ]]; then
      answer="$default"
    fi
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "请输入 y 或 n。" >&2 ;;
    esac
  done
}

prompt_enum() {
  local question="$1"
  local default="$2"
  shift 2
  local -a allowed=("$@")

  if [[ "$INTERACTIVE" -ne 1 ]]; then
    die "内部错误：在非交互模式下调用了 prompt（请使用参数指定行为）"
  fi
  if [[ ! -t 0 ]]; then
    die "当前不是交互终端（stdin 非 TTY），请使用 --non-interactive 并显式传参"
  fi

  local allowed_joined
  allowed_joined="$(IFS='|'; echo "${allowed[*]}")"

  while true; do
    read -r -p "${question}（${allowed_joined}，默认 ${default}）： " answer || true
    answer="$(trim "${answer:-}")"
    answer="${answer,,}"
    if [[ -z "$answer" ]]; then
      answer="$default"
    fi
    if is_enum "$answer" "${allowed[@]}"; then
      echo "$answer"
      return 0
    fi
    echo "无效输入：${answer}（允许值：${allowed_joined}）" >&2
  done
}

# ===== 参数解析 =====

INTERACTIVE=1
DRY_RUN=0
ALLOW_DIRTY=0
DO_FETCH=1
DO_REBASE=1
DO_PUSH=0
PUSH_EXPLICIT=0

TARGET_BRANCH=""
UPSTREAM_REF="upstream/main"
BUILD_MODE=""
LINK_MODE=""
VERIFY_MODE=""
LINK_DIR="${HOME}/.local/bin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -n|--non-interactive)
      INTERACTIVE=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --no-fetch)
      DO_FETCH=0
      shift
      ;;
    --no-rebase)
      DO_REBASE=0
      shift
      ;;
    --push)
      DO_PUSH=1
      PUSH_EXPLICIT=1
      shift
      ;;
    --no-push)
      DO_PUSH=0
      PUSH_EXPLICIT=1
      shift
      ;;
    --branch)
      require_arg "--branch" "${2:-}"
      TARGET_BRANCH="$2"
      shift 2
      ;;
    --upstream)
      require_arg "--upstream" "${2:-}"
      UPSTREAM_REF="$2"
      shift 2
      ;;
    --build)
      require_arg "--build" "${2:-}"
      BUILD_MODE="$2"
      shift 2
      ;;
    --link)
      require_arg "--link" "${2:-}"
      LINK_MODE="$2"
      shift 2
      ;;
    --link-dir)
      require_arg "--link-dir" "${2:-}"
      LINK_DIR="$2"
      shift 2
      ;;
    --verify)
      require_arg "--verify" "${2:-}"
      VERIFY_MODE="$2"
      shift 2
      ;;
    *)
      die "未知参数：$1（用 --help 查看用法）"
      ;;
  esac
done

# ===== 定位仓库根目录 =====

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  die "无法定位 git 仓库根目录：请在仓库内运行该脚本"
fi

# ===== 基础校验 =====

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "当前目录不是 git 仓库：${REPO_ROOT}"
fi

if ! git -C "$REPO_ROOT" remote get-url upstream >/dev/null 2>&1; then
  die "缺少 remote 'upstream'（期望指向官方仓库）；可用：git remote add upstream https://github.com/openai/codex"
fi
if ! git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
  die "缺少 remote 'origin'（期望指向你的 fork）；可用：gh repo fork --remote"
fi

# 若存在进行中的 rebase，直接失败并提示；避免脚本把状态越弄越乱。
GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)"
if [[ -e "${GIT_DIR}/rebase-apply" || -e "${GIT_DIR}/rebase-merge" ]]; then
  die "检测到进行中的 rebase（${GIT_DIR}/rebase-* 存在）。请先执行 git rebase --continue 或 git rebase --abort 再重试。"
fi

if [[ -n "$TARGET_BRANCH" ]]; then
  info "切换到分支：${TARGET_BRANCH}"
  run_git switch "$TARGET_BRANCH"
fi

CURRENT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" == "HEAD" ]]; then
  die "当前处于 detached HEAD。请用 --branch <name> 指定要操作的分支。"
fi

if [[ "${ALLOW_DIRTY}" -ne 1 ]]; then
  DIRTY="$(git -C "$REPO_ROOT" status --porcelain)"
  if [[ -n "$DIRTY" ]]; then
    die "工作区不干净（存在未提交改动/未跟踪文件）。请先提交或 stash，或显式传 --allow-dirty（不推荐）。"
  fi
else
  warn "已启用 --allow-dirty：rebase/切换分支可能失败，且可能导致你更难回滚；请确认你了解风险。"
fi

# ===== 交互补齐参数 =====

if [[ -z "${BUILD_MODE}" ]]; then
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    BUILD_MODE="$(prompt_enum "是否编译 codex（cargo build -p codex-cli）" "release" none debug release both)"
  else
    BUILD_MODE="none"
  fi
else
  BUILD_MODE="$(trim "$BUILD_MODE")"
  BUILD_MODE="${BUILD_MODE,,}"
fi
require_enum "--build" "$BUILD_MODE" none debug release both

if [[ -z "${LINK_MODE}" ]]; then
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    LINK_MODE="$(prompt_enum "是否创建/更新本地符号链接（codex-dev*）" "none" none debug release both)"
  else
    LINK_MODE="none"
  fi
else
  LINK_MODE="$(trim "$LINK_MODE")"
  LINK_MODE="${LINK_MODE,,}"
fi
require_enum "--link" "$LINK_MODE" none debug release both

if [[ -z "${VERIFY_MODE}" ]]; then
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    VERIFY_MODE="$(prompt_enum "是否运行快速验证（fmt + 相关 crate tests）" "none" none quick)"
  else
    VERIFY_MODE="none"
  fi
else
  VERIFY_MODE="$(trim "$VERIFY_MODE")"
  VERIFY_MODE="${VERIFY_MODE,,}"
fi
require_enum "--verify" "$VERIFY_MODE" none quick

if [[ "$PUSH_EXPLICIT" -ne 1 && "$INTERACTIVE" -eq 1 ]]; then
  if prompt_yes_no "是否在 rebase 成功后推送到 origin？（将使用 --force-with-lease）" "n"; then
    DO_PUSH=1
  else
    DO_PUSH=0
  fi
fi

CODEX_RS_DIR="${REPO_ROOT}/codex-rs"
if [[ ! -d "$CODEX_RS_DIR" ]]; then
  die "未找到 codex-rs 目录：${CODEX_RS_DIR}"
fi

info "仓库：${REPO_ROOT}"
info "分支：${CURRENT_BRANCH}"
info "上游：${UPSTREAM_REF}"
info "模式：fetch=${DO_FETCH} rebase=${DO_REBASE} push=${DO_PUSH} build=${BUILD_MODE} link=${LINK_MODE} verify=${VERIFY_MODE} dry-run=${DRY_RUN}"

# ===== 执行：fetch / rebase / push =====

if [[ "$DO_FETCH" -eq 1 ]]; then
  info "同步 upstream..."
  run_git fetch upstream --prune
else
  info "跳过 fetch upstream（--no-fetch）"
fi

if [[ "$DO_REBASE" -eq 1 ]]; then
  info "rebase 到 ${UPSTREAM_REF}..."
  if ! run_git rebase "$UPSTREAM_REF"; then
    cat >&2 <<EOF

rebase 失败（通常是冲突）。
下一步：
  1) 用 git status 查看冲突文件
  2) 解决冲突后：git add <文件...>
  3) 继续：git rebase --continue
  4) 放弃本次 rebase：git rebase --abort

提示：
  - 你已启用 rerere 的话，下一次遇到同类冲突会自动复用解决方案。
EOF
    exit 1
  fi
else
  info "跳过 rebase（--no-rebase）"
fi

info "当前分支状态："
run_git status -sb

if [[ "$DO_PUSH" -eq 1 ]]; then
  info "推送到 origin（rebase 后使用 --force-with-lease）..."
  run_git push --force-with-lease origin "$CURRENT_BRANCH"
fi

# ===== 执行：build =====

build_debug() {
  info "编译 debug：cargo build -p codex-cli"
  (cd "$CODEX_RS_DIR" && run_cmd cargo build -p codex-cli)
}

build_release() {
  info "编译 release：cargo build -p codex-cli --release"
  (cd "$CODEX_RS_DIR" && run_cmd cargo build -p codex-cli --release)
}

case "$BUILD_MODE" in
  none) ;;
  debug) build_debug ;;
  release) build_release ;;
  both)
    build_debug
    build_release
    ;;
esac

# ===== 执行：link =====

ensure_link_dir() {
  if [[ -d "$LINK_DIR" ]]; then
    return 0
  fi

  if [[ "$INTERACTIVE" -eq 1 ]]; then
    if prompt_yes_no "链接目录不存在，是否创建：${LINK_DIR} ?" "y"; then
      run_cmd mkdir -p "$LINK_DIR"
      return 0
    fi
    die "链接目录不存在：${LINK_DIR}"
  fi

  # 非交互：既然用户显式要求 link，就必须创建目录，否则无法完成任务。
  run_cmd mkdir -p "$LINK_DIR"
}

link_one() {
  local target="$1"
  local link_path="$2"

  if [[ "$DRY_RUN" -ne 1 ]]; then
    [[ -x "$target" ]] || die "找不到可执行文件：${target}（请先 --build 对应模式）"
  fi

  run_cmd ln -sf "$target" "$link_path"
}

maybe_link() {
  local want_debug=0
  local want_release=0
  case "$LINK_MODE" in
    none) return 0 ;;
    debug) want_debug=1 ;;
    release) want_release=1 ;;
    both)
      want_debug=1
      want_release=1
      ;;
  esac

  ensure_link_dir

  local debug_bin="${CODEX_RS_DIR}/target/debug/codex"
  local release_bin="${CODEX_RS_DIR}/target/release/codex"

  # 规则：
  # - codex-dev 指向“你选的默认版本”：both 时优先 release；仅 debug 时指向 debug；仅 release 时指向 release。
  # - 同时创建明确命名的 codex-dev-debug / codex-dev-release（若对应模式被选中）。
  if [[ "$want_release" -eq 1 ]]; then
    link_one "$release_bin" "${LINK_DIR}/codex-dev-release"
  fi
  if [[ "$want_debug" -eq 1 ]]; then
    link_one "$debug_bin" "${LINK_DIR}/codex-dev-debug"
  fi

  if [[ "$want_release" -eq 1 ]]; then
    link_one "$release_bin" "${LINK_DIR}/codex-dev"
  elif [[ "$want_debug" -eq 1 ]]; then
    link_one "$debug_bin" "${LINK_DIR}/codex-dev"
  fi

  info "已更新符号链接：${LINK_DIR}/codex-dev*"
  if [[ "$DRY_RUN" -ne 1 ]]; then
    info "提示：确保 ${LINK_DIR} 在 PATH 中，然后可直接运行：codex-dev --version"
  fi
}

maybe_link

# ===== 执行：verify =====

verify_quick() {
  info "快速验证：fmt + 相关 crate tests"
  (cd "$REPO_ROOT" && run_cmd just fmt)
  (cd "$CODEX_RS_DIR" && run_cmd cargo test -p codex-core translation)
  (cd "$CODEX_RS_DIR" && run_cmd cargo test -p codex-exec)
  (cd "$CODEX_RS_DIR" && run_cmd cargo test -p codex-tui)
  (cd "$CODEX_RS_DIR" && run_cmd cargo test -p codex-tui2)
}

case "$VERIFY_MODE" in
  none) ;;
  quick) verify_quick ;;
esac

info "完成。"
