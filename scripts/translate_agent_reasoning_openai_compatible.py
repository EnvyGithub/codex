#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
OpenAI 兼容翻译器示例（用于 Codex “推理输出翻译插件”）。

特点：
- 不依赖第三方包（仅标准库）。
- 通过环境变量配置 base_url / api_key / model（也支持从 env 文件读取：`$CODEX_TRANSLATION_ENV_FILE` 或默认 `~/.codex/translation.env`）。
- 从 stdin 读取 JSON 请求，向 stdout 输出 JSON 响应（协议见 docs/translation.md）。

使用方式（示例）：

  [plugins.translation.agent_reasoning]
  command = ["python3", "/path/to/translate_agent_reasoning_openai_compatible.py"]
  timeout_ms = 8000
  ui_max_wait_ms = 5000

环境变量：
- CODEX_TRANSLATION_BASE_URL：OpenAI 兼容 API Base URL（默认：$OPENAI_BASE_URL 或 https://api.openai.com/v1）
- CODEX_TRANSLATION_API_KEY：API Key（默认：$OPENAI_API_KEY）
- CODEX_TRANSLATION_MODEL：模型 ID（默认：gpt-4.1-mini；按需替换为你可用的模型）
- CODEX_TRANSLATION_RETRY_ATTEMPTS：额外重试次数（默认：1；仅对 429/5xx/网络错误重试）
- CODEX_TRANSLATION_RETRY_BASE_SLEEP_MS：重试基础退避（毫秒，默认：200）
- CODEX_TRANSLATION_RETRY_MAX_SLEEP_MS：单次等待上限（毫秒，默认：1000；也用于限制 Retry-After）
- CODEX_TRANSLATION_HTTP_TIMEOUT_SECONDS：单次 HTTP 请求超时（秒，默认：30）

注意：
- 推理内容可能包含敏感信息。是否出网、发送到哪里，取决于你配置的 base_url。
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request


DEFAULT_ENV_FILE = os.path.expanduser("~/.codex/translation.env")
ENV_FILE_OVERRIDE_ENV = "CODEX_TRANSLATION_ENV_FILE"

# 说明：
# - 该脚本是“示例翻译器”，默认目标是：可用、可调、失败可观测；
# - 在线翻译常见偶发限流(429)/上游 5xx/网络抖动；
# - 若异常未被捕获，会导致脚本输出 Traceback（噪声大、且 Codex 仅展示 stderr 前 300 字符）；
# - 因此这里实现“有限次重试 + 统一错误输出”，避免把问题伪装成其它阶段失败。
RETRYABLE_HTTP_STATUS_CODES = {408, 429, 500, 502, 503, 504}
MAX_ERROR_DETAIL_CHARS = 200

# 默认值选择依据：
# - Codex 默认外部命令超时为 2000ms（见 core 配置默认值），因此默认只做 1 次快速重试；
# - 若你明确启用“出网翻译”，通常需要把 timeout_ms 调大（例如 8000ms 或更高），
#   并按需提高重试次数/等待上限（下面这些都可用 env 覆盖）。
DEFAULT_RETRY_ATTEMPTS = 1  # 额外重试次数（不含首次请求）
DEFAULT_RETRY_BASE_SLEEP_MS = 200
DEFAULT_RETRY_MAX_SLEEP_MS = 1_000
DEFAULT_HTTP_TIMEOUT_SECONDS = 30


def _env_file_path() -> str:
    override = os.environ.get(ENV_FILE_OVERRIDE_ENV, "").strip()
    if override:
        return os.path.expanduser(override)
    return DEFAULT_ENV_FILE


def _maybe_load_env_file(path: str) -> None:
    """
    从 `KEY=VALUE` 文本文件加载环境变量（仅当当前进程未设置同名 env 时才写入）。

    设计目标：
    - 让翻译脚本在被 Codex 作为外部命令调用时也能自动拿到 KEY/URL 等配置；
    - 避免用户每次打开终端都手动 export；
    - 环境变量仍可覆盖文件（优先级：进程 env > 文件）。

    文件格式（最小约定）：
    - 允许空行与以 `#` 开头的注释
    - 允许 `export KEY=VALUE`
    - 值可用单/双引号包裹（仅去掉首尾同类引号，不做复杂转义）
    """
    try:
        with open(path, encoding="utf-8") as f:
            lines = list(f)
    except FileNotFoundError:
        return
    except Exception as e:  # noqa: BLE001 - 示例脚本直接返回可读错误
        sys.stderr.write(f"cannot_read_translation_env:{path}:{e}\n")
        return

    for line_no, raw in enumerate(lines, start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            sys.stderr.write(f"invalid_translation_env_line:{path}:{line_no}:{raw.strip()}\n")
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            sys.stderr.write(f"invalid_translation_env_key:{path}:{line_no}\n")
            continue

        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]

        if key not in os.environ:
            os.environ[key] = value


def _get_env(name: str) -> str | None:
    value = os.environ.get(name)
    if value is None:
        return None
    value = value.strip()
    return value or None


def _get_int_env(name: str, default: int, *, min_value: int) -> int:
    raw = _get_env(name)
    if not raw:
        return default
    raw_preview = raw if len(raw) <= 64 else f"{raw[:64]}…"
    try:
        value = int(raw)
    except Exception as e:  # noqa: BLE001
        raise ValueError(f"invalid_{name}:{raw_preview}:{e}") from e
    if value < min_value:
        raise ValueError(f"invalid_{name}:{raw_preview}:must_be_>={min_value}")
    return value


def _join_url(base_url: str, path: str) -> str:
    base = base_url.rstrip("/")
    return f"{base}{path}"


def _system_prompt(kind: str, fmt: str, source_language: str, target_language: str) -> str:
    # 只要求“输出译文”，避免模型附带解释。
    if kind == "agent_reasoning_title":
        return (
            f"你是一个翻译器。将以下 {source_language} 的短标题翻译为 {target_language}。\n"
            "要求：尽量短；不要添加解释；不要加引号；只输出译文文本。"
        )
    if fmt == "markdown":
        return (
            f"你是一个翻译器。将以下 {source_language} 文本翻译为 {target_language}。\n"
            "要求：只输出译文文本；不要添加解释或标签；不要省略或总结任何内容；保留换行；保留原有 Markdown 结构（包含开头的 `**...**` 粗体标题标记、标题/列表/代码块/内联代码）。"
        )
    return (
        f"你是一个翻译器。将以下 {source_language} 文本翻译为 {target_language}。\n"
        "要求：不要添加解释；只输出译文文本。"
    )


def _call_chat_completions(
    *,
    base_url: str,
    api_key: str,
    model: str,
    system_prompt: str,
    user_text: str,
    retry_attempts: int,
    retry_base_sleep_ms: int,
    retry_max_sleep_ms: int,
    http_timeout_seconds: int,
) -> str:
    url = _join_url(base_url, "/chat/completions")

    payload = {
        "model": model,
        "temperature": 0.2,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_text},
        ],
    }

    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )

    def parse_retry_after_ms(headers: object) -> int | None:
        # Retry-After 既可能是秒数，也可能是日期字符串；这里只支持最常见的“秒数”形式。
        get_header = getattr(headers, "get", None)
        if not callable(get_header):
            return None
        retry_after_raw = get_header("Retry-After", None)
        if not retry_after_raw:
            return None
        try:
            seconds = int(str(retry_after_raw).strip())
        except Exception:  # noqa: BLE001 - 解析失败直接忽略
            return None
        if seconds < 0:
            return None
        return seconds * 1000

    def compute_sleep_ms(*, retry_index: int, retry_after_ms: int | None) -> int:
        # retry_index 从 1 开始（第一次重试为 1）。
        backoff_ms = retry_base_sleep_ms * (2 ** (retry_index - 1))
        backoff_ms = min(backoff_ms, retry_max_sleep_ms)
        if retry_after_ms is not None:
            # 尊重服务端提示，但设置上限：长等待应由用户显式调参，而不是默认拖慢 UI。
            backoff_ms = max(backoff_ms, min(retry_after_ms, retry_max_sleep_ms))
        return int(backoff_ms)

    attempts_total = 1 + retry_attempts
    for attempt_index in range(attempts_total):
        try:
            with urllib.request.urlopen(req, timeout=http_timeout_seconds) as resp:
                data = resp.read().decode("utf-8", errors="replace")
                break
        except urllib.error.HTTPError as e:
            msg = e.read().decode("utf-8", errors="replace")
            err = f"http_{e.code}:{msg[:MAX_ERROR_DETAIL_CHARS]}"
            should_retry = (
                e.code in RETRYABLE_HTTP_STATUS_CODES and attempt_index < attempts_total - 1
            )
            if not should_retry:
                raise RuntimeError(f"{err}; attempts={attempt_index + 1}") from e
            sleep_ms = compute_sleep_ms(
                retry_index=attempt_index + 1,
                retry_after_ms=parse_retry_after_ms(e.headers),
            )
            time.sleep(sleep_ms / 1000.0)
            continue
        except urllib.error.URLError as e:
            err = f"network_error:{str(e)[:MAX_ERROR_DETAIL_CHARS]}"
            if attempt_index >= attempts_total - 1:
                raise RuntimeError(f"{err}; attempts={attempt_index + 1}") from e
            sleep_ms = compute_sleep_ms(retry_index=attempt_index + 1, retry_after_ms=None)
            time.sleep(sleep_ms / 1000.0)
            continue
        except TimeoutError as e:
            err = f"timeout:{str(e)[:MAX_ERROR_DETAIL_CHARS]}"
            if attempt_index >= attempts_total - 1:
                raise RuntimeError(f"{err}; attempts={attempt_index + 1}") from e
            sleep_ms = compute_sleep_ms(retry_index=attempt_index + 1, retry_after_ms=None)
            time.sleep(sleep_ms / 1000.0)
            continue
        except Exception as e:  # noqa: BLE001 - 示例脚本直接返回可读错误
            raise RuntimeError(str(e)) from e

    try:
        obj = json.loads(data)
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"invalid_json_response:{data[:300]}") from e

    choices = obj.get("choices") or []
    if not choices:
        raise RuntimeError("empty_choices")

    message = (choices[0] or {}).get("message") or {}
    content = message.get("content")
    if not isinstance(content, str) or not content.strip():
        raise RuntimeError("empty_content")
    return content.strip()


def main() -> int:
    _maybe_load_env_file(_env_file_path())
    try:
        req = json.load(sys.stdin)
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"invalid_json:{e}\n")
        return 2

    schema_version = req.get("schema_version", 1)
    if schema_version != 1:
        sys.stderr.write(f"unsupported_schema_version:{schema_version}\n")
        return 2

    kind = str(req.get("kind", "") or "")
    fmt = str(req.get("format", "") or "")
    source_language = str(req.get("source_language", "en") or "en")
    target_language = str(req.get("target_language", "zh-CN") or "zh-CN")
    text = req.get("text", "")
    if not isinstance(text, str):
        text = str(text)

    if not text.strip():
        sys.stderr.write("empty_text\n")
        return 2

    base_url = (
        _get_env("CODEX_TRANSLATION_BASE_URL")
        or _get_env("OPENAI_BASE_URL")
        or "https://api.openai.com/v1"
    )
    api_key = _get_env("CODEX_TRANSLATION_API_KEY") or _get_env("OPENAI_API_KEY")
    if not api_key:
        sys.stderr.write("missing_api_key: set CODEX_TRANSLATION_API_KEY or OPENAI_API_KEY\n")
        return 2

    model = _get_env("CODEX_TRANSLATION_MODEL") or "gpt-4.1-mini"

    system_prompt = _system_prompt(kind, fmt, source_language, target_language)
    try:
        retry_attempts = _get_int_env(
            "CODEX_TRANSLATION_RETRY_ATTEMPTS",
            DEFAULT_RETRY_ATTEMPTS,
            min_value=0,
        )
        retry_base_sleep_ms = _get_int_env(
            "CODEX_TRANSLATION_RETRY_BASE_SLEEP_MS",
            DEFAULT_RETRY_BASE_SLEEP_MS,
            min_value=0,
        )
        retry_max_sleep_ms = _get_int_env(
            "CODEX_TRANSLATION_RETRY_MAX_SLEEP_MS",
            DEFAULT_RETRY_MAX_SLEEP_MS,
            min_value=0,
        )
        http_timeout_seconds = _get_int_env(
            "CODEX_TRANSLATION_HTTP_TIMEOUT_SECONDS",
            DEFAULT_HTTP_TIMEOUT_SECONDS,
            min_value=1,
        )
    except Exception as e:  # noqa: BLE001 - 配置错误要对用户可见
        sys.stderr.write(f"invalid_config:{e}\n")
        return 2

    if retry_max_sleep_ms < retry_base_sleep_ms:
        sys.stderr.write(
            "invalid_config: CODEX_TRANSLATION_RETRY_MAX_SLEEP_MS must be >= CODEX_TRANSLATION_RETRY_BASE_SLEEP_MS\n"
        )
        return 2

    try:
        translated = _call_chat_completions(
            base_url=base_url,
            api_key=api_key,
            model=model,
            system_prompt=system_prompt,
            user_text=text,
            retry_attempts=retry_attempts,
            retry_base_sleep_ms=retry_base_sleep_ms,
            retry_max_sleep_ms=retry_max_sleep_ms,
            http_timeout_seconds=http_timeout_seconds,
        )
    except Exception as e:  # noqa: BLE001 - 必须捕获，避免输出 Traceback
        msg_raw = str(e).strip() or type(e).__name__
        msg = msg_raw
        attempts_suffix = ""
        if "; attempts=" in msg_raw:
            prefix, suffix = msg_raw.rsplit("; attempts=", 1)
            attempts_suffix = f"; attempts={suffix}"
            msg = prefix

        max_prefix_len = 220 - len(attempts_suffix)
        if max_prefix_len < 0:
            max_prefix_len = 0
        if len(msg) > max_prefix_len:
            msg = f"{msg[:max_prefix_len]}…"
        msg = f"{msg}{attempts_suffix}"
        sys.stderr.write(f"translation_failed:{msg}\n")
        if msg.startswith("http_429"):
            sys.stderr.write(
                "hint: 429 通常是限流/配额触发；可尝试调大 plugins.translation.agent_reasoning.timeout_ms，并提高 CODEX_TRANSLATION_RETRY_ATTEMPTS\n"
            )
        elif msg.startswith("http_401"):
            sys.stderr.write(
                "hint: 401 通常是 API Key 无效；请检查 CODEX_TRANSLATION_API_KEY / OPENAI_API_KEY\n"
            )
        elif msg.startswith("network_error:"):
            sys.stderr.write(
                "hint: 网络错误可检查 CODEX_TRANSLATION_BASE_URL / 代理 / DNS；必要时调大 timeout_ms\n"
            )
        return 2

    resp = {"schema_version": 1, "text": translated}
    sys.stdout.write(json.dumps(resp, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
