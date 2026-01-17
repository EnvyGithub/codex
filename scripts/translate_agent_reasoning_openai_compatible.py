#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
OpenAI 兼容翻译器示例（用于 Codex “推理输出翻译插件”）。

特点：
- 不依赖第三方包（仅标准库）。
- 通过环境变量配置 base_url / api_key / model（也支持从 env 文件读取：`$CODEX_TRANSLATION_ENV_FILE` 或默认 `~/.codex/translation.env`）。
- 从 stdin 读取 JSON 请求，向 stdout 输出 JSON 响应（协议见 docs/translation.md）。

使用方式（示例）：

  [translation.agent_reasoning]
  command = ["python3", "/path/to/translate_agent_reasoning_openai_compatible.py"]
  timeout_ms = 8000

环境变量：
- CODEX_TRANSLATION_BASE_URL：OpenAI 兼容 API Base URL（默认：$OPENAI_BASE_URL 或 https://api.openai.com/v1）
- CODEX_TRANSLATION_API_KEY：API Key（默认：$OPENAI_API_KEY）
- CODEX_TRANSLATION_MODEL：模型 ID（默认：gpt-4.1-mini；按需替换为你可用的模型）

注意：
- 推理内容可能包含敏感信息。是否出网、发送到哪里，取决于你配置的 base_url。
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request


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

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"http_{e.code}:{msg[:300]}") from e
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
    translated = _call_chat_completions(
        base_url=base_url,
        api_key=api_key,
        model=model,
        system_prompt=system_prompt,
        user_text=text,
    )

    resp = {"schema_version": 1, "text": translated}
    sys.stdout.write(json.dumps(resp, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
