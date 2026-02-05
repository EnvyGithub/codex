#!/usr/bin/env bash
set -euo pipefail

# 用途：
# - 默认以“上游最新稳定发布 tag（rust-vX.Y.Z）”为基线，把本 fork 的补丁栈重新打上去（等价于“自动打补丁”）。
# - 如需跟随上游开发分支，可显式指定：--upstream upstream/main
# - 可选：编译 codex-rs 的 codex 二进制（debug/release）。
# - 可选：创建/更新本地符号链接（例如 ~/.local/bin/codex-dev），方便直接运行你编译的版本。
# - 可选：清理 codex-rs/target（只保留二进制可执行文件），防止磁盘占用过大。
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
  1) git fetch upstream --prune --tags
  2) git rebase --onto <latest stable rust tag> <patch-base>
  3) 可选：push / build / link / verify / prune-target（交互询问）
  4) 若基线为 rust-v* tag 且你启用了 build/verify：脚本会临时把 codex-rs/Cargo.toml 的
     workspace.package.version 写成该 tag 的版本号，并备份/恢复 codex-rs/Cargo.lock，
     确保本次编译产物的 `codex --version` 对齐该 tag；脚本退出会自动恢复，避免把版本号改动带进补丁栈。

常用示例：
  # 交互式：默认对齐“最新稳定 tag”，并提示你选择是否编译/建链接/推送
  ./scripts/dev-sync-upstream.sh

  # 非交互（适合自动化/AI）：对齐最新稳定 tag + 编译 release + 建 release 链接
  ./scripts/dev-sync-upstream.sh --non-interactive --build release --link release --prune-target keep-executables

  # 非交互：对齐最新稳定 tag + 推送（rebase 后需要 force-with-lease）+ 快速验证
  ./scripts/dev-sync-upstream.sh --non-interactive --push --verify quick

  # 只预览将要执行的命令（不做任何修改）
  ./scripts/dev-sync-upstream.sh --dry-run --build release --link both --push --verify quick

  # 显式对齐到某个“发布 tag”（推荐：对外公开仓库/对齐上游 release 时使用）
  # 说明：上游会为 Rust CLI 的发布打 tag，例如 rust-v0.87.0 / rust-v0.88.0-alpha.1（预发布）
  ./scripts/dev-sync-upstream.sh --non-interactive --upstream rust-v0.87.0 --build both --link both --verify quick --prune-target keep-executables

  # 跟随上游开发分支（会得到 0.0.0 这类开发版本号属正常现象）
  ./scripts/dev-sync-upstream.sh --non-interactive --upstream upstream/main --build release

选项：
  -n, --non-interactive        非交互运行（不提示；未指定的可选步骤默认跳过）
      --dry-run                只打印命令，不执行
      --allow-dirty            允许工作区非干净状态（不推荐；默认要求干净）
      --no-fetch               跳过 fetch upstream（默认会 fetch）
      --no-rebase              跳过 rebase（默认会 rebase）
      --branch <name>          切换到指定分支后再执行（默认当前分支）
      --upstream <ref>         上游基准 ref（默认 latest-stable，即最新 rust 稳定 tag）
      --patch-base <ref>       补丁基线 ref（默认优先用当前分支已包含的最新稳定 rust tag；否则用 marker 启发式；若历史变更/文件迁移请手动指定）
      --push                   rebase 成功后推送到 origin（使用 --force-with-lease）
      --build <mode>           编译模式：none|debug|release|both
      --link <mode>            建立符号链接：none|debug|release|both
      --link-dir <path>        符号链接目录（默认 ~/.local/bin）
      --verify <mode>          验证：none|quick
      --prune-target <mode>    清理 codex-rs/target：none|keep-executables|keep-codex
                               - keep-executables：仅保留目标 profile 顶层可执行文件（推荐：避免磁盘爆炸）
                               - keep-codex：仅保留目标 profile 的 codex 可执行文件（更省空间，但更激进）
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

latest_stable_rust_tag() {
  # 选择最新“稳定发布”tag：
  # - 稳定 tag 定义为：严格匹配 `rust-vX.Y.Z`（末尾不带任何后缀）
  # - 预发布通常形如：rust-v0.88.0-alpha.1 / rust-v0.11.0-beta.1 / rust-v0.12.0-rc.1
  #
  # 这样做的目的：避免仅靠排除某些后缀（alpha/beta/rc）导致未来出现新命名（preview/dev 等）时误判“稳定”。
  local tag
  tag="$(
    git -C "$REPO_ROOT" tag --list 'rust-v*' --sort=-v:refname \
      | while read -r candidate; do
          if [[ "$candidate" =~ ^rust-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$candidate"
            break
          fi
        done
  )"
  [[ -n "$tag" ]] || die "未找到可用的上游稳定 tag（期望形如 rust-v0.87.0）。请先执行 git fetch upstream --tags --prune。"
  echo "$tag"
}

latest_stable_rust_tag_merged_into_head() {
  # 选择当前 HEAD 已经包含的最新“稳定发布”tag（strict rust-vX.Y.Z）。
  #
  # 当你的分支始终是“基于某个 rust-v* tag + 仅叠加 fork 提交（补丁栈）”时，
  # 这个 tag 基本等价于“当前补丁栈的基线”。用它作为 patch-base 可以避免重放
  # 上游在 tag 之间的提交（其中经常包含 Cargo.lock churn），从而显著减少 rebase 冲突。
  local tag
  tag="$(
    git -C "$REPO_ROOT" tag --merged HEAD --list 'rust-v*' --sort=-v:refname \
      | while read -r candidate; do
          if [[ "$candidate" =~ ^rust-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$candidate"
            break
          fi
        done
  )"

  if [[ -z "$tag" ]]; then
    return 1
  fi
  echo "$tag"
}

auto_patch_base() {
  # 自动推断“补丁基线”（即：本 fork 的自定义提交栈从哪里开始）。
  #
  # 约定：
  # - 若当前分支已经基于某个上游稳定 tag（rust-vX.Y.Z）并仅叠加 fork 提交：
  #   优先把“当前 HEAD 已经包含的最新稳定 tag”作为补丁基线。
  # - 否则（例如跟随 upstream/main 或历史不含 tag）：回退到 marker 文件启发式。
  #
  # 这样做的目的：
  # - 减少 lockfile/依赖更新带来的 rebase 冲突
  # - 确保“重新打补丁”尽可能只搬运本 fork 自己的改动
  local stable_tag
  if stable_tag="$(latest_stable_rust_tag_merged_into_head)"; then
    echo "$stable_tag"
    return 0
  fi

  local marker_file="codex-rs/core/src/translation/external_command.rs"
  local first_commit
  first_commit="$(git -C "$REPO_ROOT" log --reverse --format=%H -- "$marker_file" | head -n 1 || true)"
  [[ -n "$first_commit" ]] || die "无法自动推断补丁基线：在历史中找不到 ${marker_file}。请用 --patch-base 显式指定。"
  git -C "$REPO_ROOT" rev-parse "${first_commit}^"
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

VERSION_OVERRIDE_DIR=""
VERSION_OVERRIDE_APPLIED=0

restore_workspace_version_override() {
  if [[ "${VERSION_OVERRIDE_APPLIED}" -ne 1 ]]; then
    return 0
  fi

  if [[ -z "${VERSION_OVERRIDE_DIR}" || ! -d "${VERSION_OVERRIDE_DIR}" ]]; then
    warn "未找到版本备份目录（VERSION_OVERRIDE_DIR=${VERSION_OVERRIDE_DIR}），跳过恢复。"
    return 0
  fi

  local cargo_toml="${CODEX_RS_DIR}/Cargo.toml"
  local cargo_lock="${CODEX_RS_DIR}/Cargo.lock"

  info "恢复 workspace 版本文件（Cargo.toml/Cargo.lock）..."
  if [[ -f "${VERSION_OVERRIDE_DIR}/Cargo.toml" ]]; then
    run_cmd cp "${VERSION_OVERRIDE_DIR}/Cargo.toml" "$cargo_toml"
  fi
  if [[ -f "${VERSION_OVERRIDE_DIR}/Cargo.lock" ]]; then
    run_cmd cp "${VERSION_OVERRIDE_DIR}/Cargo.lock" "$cargo_lock"
  fi

  if [[ "${DRY_RUN}" -ne 1 ]]; then
    run_cmd rm -rf "${VERSION_OVERRIDE_DIR}"
  fi

  VERSION_OVERRIDE_DIR=""
  VERSION_OVERRIDE_APPLIED=0
}

should_override_workspace_version() {
  # 仅当：
  # - 上游 ref 是 rust-v* tag（因此 UPSTREAM_VERSION 非空）
  # - 且本次确实会 build/verify（否则没必要改写）
  if [[ -z "${UPSTREAM_VERSION}" ]]; then
    return 1
  fi
  if [[ "${BUILD_MODE}" == "none" && "${VERIFY_MODE}" == "none" ]]; then
    return 1
  fi
  return 0
}

apply_workspace_version_override() {
  if ! should_override_workspace_version; then
    return 0
  fi

  # 交互/非交互都一致：仅影响本次 build/verify 的产物版本号；
  # 脚本退出时自动恢复，避免把 “version 变化” 带进补丁栈。
  local cargo_toml="${CODEX_RS_DIR}/Cargo.toml"
  local cargo_lock="${CODEX_RS_DIR}/Cargo.lock"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run：将临时写入 workspace version=${UPSTREAM_VERSION} 到 ${cargo_toml}（并在脚本退出时恢复）"
    return 0
  fi

  VERSION_OVERRIDE_DIR="$(mktemp -d)"
  VERSION_OVERRIDE_APPLIED=1
  trap restore_workspace_version_override EXIT

  run_cmd cp "$cargo_toml" "${VERSION_OVERRIDE_DIR}/Cargo.toml"
  if [[ -f "$cargo_lock" ]]; then
    run_cmd cp "$cargo_lock" "${VERSION_OVERRIDE_DIR}/Cargo.lock"
  fi

  info "临时写入 workspace version=${UPSTREAM_VERSION}（仅用于本次 build/verify；脚本退出自动恢复）"
  run_cmd python3 - "$cargo_toml" "$UPSTREAM_VERSION" <<'PY'
import re
import sys
from pathlib import Path

cargo_toml_path = Path(sys.argv[1])
new_version = sys.argv[2]

raw = cargo_toml_path.read_text(encoding="utf-8")
lines = raw.splitlines(keepends=True)

in_workspace_package = False
replaced = False
out = []

for line in lines:
    if re.match(r"^\[.*\]\s*$", line):
        in_workspace_package = line.strip() == "[workspace.package]"
        out.append(line)
        continue

    if in_workspace_package and not replaced:
        match = re.match(r'^version\s*=\s*"[^"]*"\s*(#.*)?\n?$', line)
        if match:
            suffix = match.group(1) or ""
            newline = "\n" if line.endswith("\n") else ""
            out.append(f'version = "{new_version}"{suffix}{newline}')
            replaced = True
            continue

    out.append(line)

if not replaced:
    raise SystemExit("failed to update [workspace.package] version in Cargo.toml")

cargo_toml_path.write_text("".join(out), encoding="utf-8")
PY
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
UPSTREAM_REF="latest-stable"
PATCH_BASE_REF=""
BUILD_MODE=""
LINK_MODE=""
VERIFY_MODE=""
PRUNE_TARGET_MODE=""
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
    --patch-base)
      require_arg "--patch-base" "${2:-}"
      PATCH_BASE_REF="$2"
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
    --prune-target)
      require_arg "--prune-target" "${2:-}"
      PRUNE_TARGET_MODE="$2"
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
  warn "已启用 --allow-dirty：rebase 将使用 --autostash 临时收起本地改动；若存在冲突，仍需手工处理。"
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

if [[ -z "${PRUNE_TARGET_MODE}" ]]; then
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    if [[ "$BUILD_MODE" == "none" && "$LINK_MODE" == "none" ]]; then
      # 既不编译也不建链接时，“保留哪个 profile”无法推断；默认不清理，避免误删用户已有产物。
      PRUNE_TARGET_MODE="none"
    else
      PRUNE_TARGET_MODE="$(prompt_enum "是否在结束时清理 codex-rs/target（只保留二进制，防止占用过大）" "keep-executables" none keep-executables keep-codex)"
    fi
  else
    PRUNE_TARGET_MODE="none"
  fi
else
  PRUNE_TARGET_MODE="$(trim "$PRUNE_TARGET_MODE")"
  PRUNE_TARGET_MODE="${PRUNE_TARGET_MODE,,}"
fi
require_enum "--prune-target" "$PRUNE_TARGET_MODE" none keep-executables keep-codex

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

PATCH_BASE=""

# ===== 执行：fetch / rebase / push =====

if [[ "$DO_FETCH" -eq 1 ]]; then
  info "同步 upstream..."
  run_git fetch upstream --prune --tags
else
  info "跳过 fetch upstream（--no-fetch）"
fi

if [[ "$UPSTREAM_REF" == "latest-stable" ]]; then
  UPSTREAM_REF="$(latest_stable_rust_tag)"
fi

if [[ -n "$PATCH_BASE_REF" ]]; then
  PATCH_BASE="$PATCH_BASE_REF"
else
  PATCH_BASE="$(auto_patch_base)"
fi

UPSTREAM_VERSION=""
if [[ "$UPSTREAM_REF" == rust-v* ]]; then
  UPSTREAM_VERSION="${UPSTREAM_REF#rust-v}"
fi

PATCH_BASE_SHORT="$(git -C "$REPO_ROOT" rev-parse --short "$PATCH_BASE")"

info "仓库：${REPO_ROOT}"
info "分支：${CURRENT_BRANCH}"
info "补丁基线：${PATCH_BASE_SHORT}"
if [[ -n "$UPSTREAM_VERSION" ]]; then
  info "目标基线：${UPSTREAM_REF}（version=${UPSTREAM_VERSION}）"
else
  info "目标基线：${UPSTREAM_REF}"
fi
info "模式：fetch=${DO_FETCH} rebase=${DO_REBASE} push=${DO_PUSH} build=${BUILD_MODE} link=${LINK_MODE} verify=${VERIFY_MODE} prune-target=${PRUNE_TARGET_MODE} dry-run=${DRY_RUN}"

if [[ "$DO_REBASE" -eq 1 ]]; then
  info "重新打补丁：把 ${PATCH_BASE_SHORT} 之后的本地提交栈应用到 ${UPSTREAM_REF}..."
  SKIP_REBASE=0
  if [[ "${DRY_RUN}" -ne 1 ]]; then
    if ! run_git rev-parse --verify "${PATCH_BASE}^{commit}" >/dev/null 2>&1; then
      die "补丁基线 ref 不存在或不可解析：${PATCH_BASE}（请确认 remote upstream 存在且已 fetch）"
    fi
    if ! run_git rev-parse --verify "${UPSTREAM_REF}^{commit}" >/dev/null 2>&1; then
      die "上游 ref 不存在或不可解析：${UPSTREAM_REF}（如果是 tag，请确保已 fetch tags；脚本默认会 fetch --tags）"
    fi

    # 若补丁基线与目标基线一致，rebase 将无意义地重放补丁栈并改写提交 hash。
    if [[ "$(git -C "$REPO_ROOT" rev-parse "${PATCH_BASE}^{commit}")" == "$(git -C "$REPO_ROOT" rev-parse "${UPSTREAM_REF}^{commit}")" ]]; then
      info "补丁基线与目标基线相同（${UPSTREAM_REF}），跳过 rebase。"
      SKIP_REBASE=1
    fi
  fi
  if [[ "$SKIP_REBASE" -eq 1 ]]; then
    :
  elif [[ "$ALLOW_DIRTY" -eq 1 ]]; then
    if ! run_git rebase --autostash --onto "$UPSTREAM_REF" "$PATCH_BASE"; then
      die "rebase 失败（已启用 --autostash）。请根据 git 输出解决冲突后执行 git rebase --continue，或执行 git rebase --abort 放弃本次 rebase。"
    fi
  elif ! run_git rebase --onto "$UPSTREAM_REF" "$PATCH_BASE"; then
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

# ===== 执行：临时版本对齐（仅影响 build/verify 产物）=====
#
# 目标：让编译出的二进制（`codex --version`）与上游 rust-v* tag 一致，
# 但不把 version 变化带进补丁栈（脚本退出自动恢复）。
apply_workspace_version_override

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
  # codex-tui（以及旧版本的 codex-tui2）集成测试会 spawn `codex` 二进制。
  # 但该二进制不一定会被 `cargo test -p codex-tui` 自动重新构建（容易误用旧产物）。
  # 因此这里显式 build 一次，保证测试用到的是“当前 HEAD”对应的 `codex`。
  (cd "$CODEX_RS_DIR" && run_cmd cargo build -p codex-cli)
  (cd "$CODEX_RS_DIR" && run_cmd cargo test -p codex-tui)
  # 上游 rust-v0.92.0 起已移除 codex-tui2；若你的基线仍包含该 crate，则继续跑。
  #
  # 这里不做“多路径回退默认值”，而是做一个可观测的一致性判断：
  # - manifest 存在 && workspace 也包含该包：跑测试
  # - manifest 存在但 workspace 不包含：告警并跳过（通常是遗留目录，跑会失败）
  # - manifest 不存在：跳过（上游已移除）
  local tui2_manifest="${CODEX_RS_DIR}/tui2/Cargo.toml"
  if [[ -f "$tui2_manifest" ]]; then
    local metadata_json
    metadata_json="$(cd "$CODEX_RS_DIR" && cargo metadata --format-version 1 --no-deps)"
    if python3 -c 'import json,sys; data=json.load(sys.stdin); sys.exit(0 if any(p.get("name")=="codex-tui2" for p in data.get("packages", [])) else 1)' <<<"$metadata_json"; then
      (cd "$CODEX_RS_DIR" && run_cmd cargo test -p codex-tui2)
    else
      warn "发现 ${tui2_manifest}，但 workspace 未包含 codex-tui2；跳过对应测试（可能是遗留目录）"
    fi
  else
    info "跳过 codex-tui2：未发现 ${tui2_manifest}（该 crate 可能已被上游移除）"
  fi

  if [[ "$LINK_MODE" != "none" ]]; then
    info "验证软链接可用性：运行 codex-dev* --version"
    local dev="${LINK_DIR}/codex-dev"
    if [[ "${DRY_RUN}" -ne 1 ]]; then
      [[ -x "$dev" ]] || die "找不到可执行链接：${dev}（请先 --link ...）"
    fi
    run_cmd "$dev" --version
    if [[ "$LINK_MODE" == "debug" || "$LINK_MODE" == "both" ]]; then
      run_cmd "${LINK_DIR}/codex-dev-debug" --version
    fi
    if [[ "$LINK_MODE" == "release" || "$LINK_MODE" == "both" ]]; then
      run_cmd "${LINK_DIR}/codex-dev-release" --version
    fi
  fi
}

case "$VERIFY_MODE" in
  none) ;;
  quick) verify_quick ;;
esac

prune_target_keep_executables() {
  local target_dir="${CODEX_RS_DIR}/target"
  local -a profiles_to_keep=("$@")

  if [[ ! -d "$target_dir" ]]; then
    info "未发现 ${target_dir}，无需清理。"
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run：将清理 ${target_dir}，仅保留 profile=${profiles_to_keep[*]} 顶层可执行文件。"
    return 0
  fi

  local backup_dir
  backup_dir="$(mktemp -d)"
  run_cmd mkdir -p "${backup_dir}/debug" "${backup_dir}/release"

  local profile
  for profile in "${profiles_to_keep[@]}"; do
    local profile_dir="${target_dir}/${profile}"
    if [[ ! -d "$profile_dir" ]]; then
      run_cmd rm -rf "$backup_dir"
      die "找不到目录：${profile_dir}（请先 --build 对应模式，或关闭 --prune-target）"
    fi

    local -a kept_names=()
    while IFS= read -r -d '' exe; do
      kept_names+=("$(basename "$exe")")
      run_cmd cp -a "$exe" "${backup_dir}/${profile}/"
    done < <(find "$profile_dir" -maxdepth 1 \( -type f -o -type l \) -executable -print0)

    if [[ "${#kept_names[@]}" -eq 0 ]]; then
      run_cmd rm -rf "$backup_dir"
      die "在 ${profile_dir} 未找到任何顶层可执行文件，无法执行 --prune-target keep-executables"
    fi

    info "将保留（${profile}）：${kept_names[*]}"
  done

  info "清理前 target 大小："
  run_cmd du -sh "$target_dir"
  info "清理编译产物：删除 ${target_dir} 并仅恢复可执行文件..."
  run_cmd rm -rf "$target_dir"

  local restore_profile
  for restore_profile in "${profiles_to_keep[@]}"; do
    run_cmd mkdir -p "${target_dir}/${restore_profile}"
    shopt -s nullglob
    local file
    for file in "${backup_dir}/${restore_profile}/"*; do
      run_cmd cp -a "$file" "${target_dir}/${restore_profile}/"
    done
    shopt -u nullglob
  done

  run_cmd rm -rf "$backup_dir"
  info "target 清理完成：${target_dir}"
  run_cmd du -sh "$target_dir"
}

prune_target_keep_codex() {
  local target_dir="${CODEX_RS_DIR}/target"
  local -a profiles_to_keep=("$@")

  if [[ ! -d "$target_dir" ]]; then
    info "未发现 ${target_dir}，无需清理。"
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "dry-run：将清理 ${target_dir}，仅保留 profile=${profiles_to_keep[*]} 的 codex 可执行文件。"
    return 0
  fi

  local backup_dir
  backup_dir="$(mktemp -d)"

  local profile
  for profile in "${profiles_to_keep[@]}"; do
    local codex_path="${target_dir}/${profile}/codex"
    if [[ ! -x "$codex_path" ]]; then
      run_cmd rm -rf "$backup_dir"
      die "找不到可执行文件：${codex_path}（请先 --build 对应模式，或使用 --prune-target keep-executables）"
    fi
    run_cmd mkdir -p "${backup_dir}/${profile}"
    run_cmd cp -a "$codex_path" "${backup_dir}/${profile}/"
    info "将保留（${profile}）：codex"
  done

  info "清理前 target 大小："
  run_cmd du -sh "$target_dir"
  info "清理编译产物：删除 ${target_dir} 并仅恢复 codex..."
  run_cmd rm -rf "$target_dir"

  local restore_profile
  for restore_profile in "${profiles_to_keep[@]}"; do
    run_cmd mkdir -p "${target_dir}/${restore_profile}"
    run_cmd cp -a "${backup_dir}/${restore_profile}/codex" "${target_dir}/${restore_profile}/codex"
  done

  run_cmd rm -rf "$backup_dir"
  info "target 清理完成：${target_dir}"
  run_cmd du -sh "$target_dir"
}

maybe_prune_target() {
  if [[ "$PRUNE_TARGET_MODE" == "none" ]]; then
    return 0
  fi

  local want_debug=0
  local want_release=0

  case "$BUILD_MODE" in
    debug|both) want_debug=1 ;;
  esac
  case "$BUILD_MODE" in
    release|both) want_release=1 ;;
  esac
  case "$LINK_MODE" in
    debug|both) want_debug=1 ;;
  esac
  case "$LINK_MODE" in
    release|both) want_release=1 ;;
  esac

  local -a profiles_to_keep=()
  if [[ "$want_debug" -eq 1 ]]; then
    profiles_to_keep+=("debug")
  fi
  if [[ "$want_release" -eq 1 ]]; then
    profiles_to_keep+=("release")
  fi

  if [[ "${#profiles_to_keep[@]}" -eq 0 ]]; then
    die "--prune-target ${PRUNE_TARGET_MODE} 需要配合 --build/--link 指定要保留的 profile（例如：--build release）"
  fi

  case "$PRUNE_TARGET_MODE" in
    keep-executables) prune_target_keep_executables "${profiles_to_keep[@]}" ;;
    keep-codex) prune_target_keep_codex "${profiles_to_keep[@]}" ;;
    *) die "内部错误：未知 PRUNE_TARGET_MODE=${PRUNE_TARGET_MODE}" ;;
  esac
}

maybe_prune_target

if [[ "$PRUNE_TARGET_MODE" == "none" && -d "${CODEX_RS_DIR}/target" ]]; then
  if [[ "$BUILD_MODE" != "none" || "$LINK_MODE" != "none" || "$VERIFY_MODE" != "none" ]]; then
    info "提示：本次未清理 codex-rs/target（编译缓存可能增长很快）。如只需要二进制产物，建议下次加：--prune-target keep-executables（或 keep-codex）。"
  fi
fi

info "完成。"
