#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Google Gemini 翻译器示例（用于 Codex “推理输出翻译插件”）。

特点：
- 不依赖第三方包（仅标准库）。
- 通过环境变量配置 base_url / api_key / model（也支持从 env 文件读取：`$CODEX_TRANSLATION_ENV_FILE` 或默认 `~/.codex/translation.env`）。
- 从 stdin 读取 JSON 请求，向 stdout 输出 JSON 响应（协议见 docs/translation.md）。

使用方式（示例）：

  [translation.agent_reasoning]
  command = ["python3", "/path/to/translate_agent_reasoning_gemini.py"]
  timeout_ms = 8000

环境变量：
- CODEX_GEMINI_BASE_URL：Gemini API Base URL
  - 默认：https://generativelanguage.googleapis.com/v1beta
- CODEX_GEMINI_API_KEY：API Key（不要写进脚本）
- CODEX_GEMINI_MODEL：模型 ID（默认：gemini-3-flash）
- CODEX_GEMINI_MAX_OUTPUT_TOKENS：单次生成的最大输出 token 上限（默认：4096）

注意：
- 推理内容可能包含敏感信息。是否出网、发送到哪里，取决于你配置的 base_url。
- 本脚本使用 `:generateContent`（非 SSE 流式），以保持实现简单且稳定。
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request


DEFAULT_MAX_OUTPUT_TOKENS = 4096
DEFAULT_ENV_FILE = os.path.expanduser("~/.codex/translation.env")
ENV_FILE_OVERRIDE_ENV = "CODEX_TRANSLATION_ENV_FILE"


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


def _join_url(base_url: str, path: str) -> str:
    base = base_url.rstrip("/")
    return f"{base}{path}"


def _system_prompt(kind: str, fmt: str, source_language: str, target_language: str) -> str:
    # 统一用 user prompt，避免依赖 Gemini 的 systemInstruction 兼容性差异。
    if kind == "agent_reasoning_title":
        return (
            f"You are a translation engine. Translate the {source_language} short title into"
            f" {target_language}.\n"
            "Rules (STRICT):\n"
            "- Output ONLY the translation.\n"
            "- Keep it short.\n"
            "- No quotes, no labels, no commentary.\n"
        )

    if fmt == "markdown":
        return (
            f"You are a translation engine. Translate the {source_language} text into"
            f" {target_language}.\n"
            "Rules (STRICT):\n"
            "- Output ONLY the translation.\n"
            "- Preserve Markdown structure (headings, bullets, code blocks, inline code).\n"
            "- Keep the `**` delimiters, but translate the text inside them.\n"
            "- Do NOT translate the contents of code blocks or inline code.\n"
            "- Preserve line breaks.\n"
            "- Do NOT omit or summarize any content.\n"
            "- No labels, no commentary.\n"
        )

    return (
        f"You are a translation engine. Translate the {source_language} text into"
        f" {target_language}.\n"
        "Rules (STRICT):\n"
        "- Output ONLY the translation.\n"
        "- Preserve line breaks.\n"
        "- Do NOT omit or summarize any content.\n"
        "- No labels, no commentary.\n"
    )


def _extract_candidate_text_and_finish_reason(data: str) -> tuple[str, str | None]:
    try:
        obj = json.loads(data)
    except Exception as e:  # noqa: BLE001 - 示例脚本直接返回可读错误
        raise RuntimeError(f"invalid_json_response:{data[:300]}") from e

    candidates = obj.get("candidates") or []
    if not candidates:
        # 有些代理会以 {"error": ...} 形式返回，这里直接把关键字段露出来便于排障。
        err = obj.get("error")
        if err:
            raise RuntimeError(f"no_candidates_error:{str(err)[:300]}")
        raise RuntimeError("empty_candidates")

    cand0 = candidates[0] or {}
    finish_reason = cand0.get("finishReason")
    content = cand0.get("content") or {}
    parts = content.get("parts") or []

    out = ""
    for part in parts:
        text = (part or {}).get("text")
        if isinstance(text, str):
            out += text

    if not out.strip():
        raise RuntimeError("empty_content")
    return out.strip(), str(finish_reason) if finish_reason is not None else None


def _call_generate_content(
    *,
    base_url: str,
    api_key: str,
    model: str,
    prompt: str,
    max_output_tokens: int,
) -> str:
    url = _join_url(base_url, f"/models/{model}:generateContent")
    payload = {
        "generationConfig": {
            "temperature": 0,
            "maxOutputTokens": int(max_output_tokens),
        },
        "contents": [
            {
                "role": "user",
                "parts": [{"text": prompt}],
            }
        ],
    }

    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "x-goog-api-key": api_key,
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"http_{e.code}:{msg[:300]}") from e
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(str(e)) from e

    translated, finish_reason = _extract_candidate_text_and_finish_reason(data)
    if finish_reason and finish_reason.upper() in {"MAX_TOKENS", "MAX_OUTPUT_TOKENS", "LENGTH"}:
        raise RuntimeError(f"truncated_by_max_tokens:{finish_reason}")
    return translated


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

    base_url = _get_env("CODEX_GEMINI_BASE_URL") or "https://generativelanguage.googleapis.com/v1beta"
    api_key = _get_env("CODEX_GEMINI_API_KEY")
    if not api_key:
        sys.stderr.write("missing_api_key: set CODEX_GEMINI_API_KEY\n")
        return 2

    model = _get_env("CODEX_GEMINI_MODEL") or "gemini-3-flash"
    max_output_tokens_raw = _get_env("CODEX_GEMINI_MAX_OUTPUT_TOKENS")
    max_output_tokens = DEFAULT_MAX_OUTPUT_TOKENS
    if max_output_tokens_raw:
        try:
            max_output_tokens = int(max_output_tokens_raw)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(
                f"invalid_CODEX_GEMINI_MAX_OUTPUT_TOKENS:{max_output_tokens_raw}:{e}\n"
            )
            return 2

    system_prompt = _system_prompt(kind, fmt, source_language, target_language)
    prompt = f"{system_prompt}\n\nEnglish:\n{text}"

    translated = None
    last_err = None
    # 说明：
    # - 一些 Gemini 代理（尤其是中文输出）在 `maxOutputTokens=1024` 时可能被截断；
    #   默认提高到 4096 以避免长推理内容被截断。
    # - 若仍然被截断，可通过 `CODEX_GEMINI_MAX_OUTPUT_TOKENS` 显式调大。
    # - 这里只做有限次数重试，避免无止境等待，保持可观测性。
    for _attempt in range(2):
        try:
            translated = _call_generate_content(
                base_url=base_url,
                api_key=api_key,
                model=model,
                prompt=prompt,
                max_output_tokens=max_output_tokens,
            )
            last_err = None
            break
        except Exception as e:  # noqa: BLE001
            last_err = e
            msg = str(e)
            if "truncated_by_max_tokens" in msg:
                # 第一次截断：把上限翻倍再试一次（除非用户已显式指定上限）。
                if max_output_tokens_raw:
                    break
                max_output_tokens = max_output_tokens * 2
                continue
            break

    if translated is None:
        sys.stderr.write(f"translation_failed:{last_err}\n")
        sys.stderr.write(
            "hint: try increasing CODEX_GEMINI_MAX_OUTPUT_TOKENS and/or translation.agent_reasoning.timeout_ms\n"
        )
        return 2

    resp = {"schema_version": 1, "text": translated}
    sys.stdout.write(json.dumps(resp, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
