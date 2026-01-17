#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
离线 dummy 翻译器（仅用于验证 Codex “外部命令翻译插件”链路）。

使用方式（示例）：

  [translation.agent_reasoning]
  command = ["python3", "/path/to/translate_agent_reasoning_dummy.py"]
  timeout_ms = 2000
  ui_max_wait_ms = 5000

协议：从 stdin 读取 JSON 请求，向 stdout 输出 JSON 响应。
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    try:
        req = json.load(sys.stdin)
    except Exception as e:  # noqa: BLE001 - 工具脚本，直接给出可读错误即可
        sys.stderr.write(f"invalid_json:{e}\n")
        return 2

    schema_version = req.get("schema_version", 1)
    if schema_version != 1:
        sys.stderr.write(f"unsupported_schema_version:{schema_version}\n")
        return 2

    kind = req.get("kind", "")
    text = req.get("text", "")
    if not isinstance(text, str):
        text = str(text)

    if kind == "agent_reasoning_title":
        title = text.strip()
        mapping = {
            "Thinking": "思考中",
            "Analyzing": "分析中",
            "Planning": "规划中",
            "Working": "处理中",
        }
        out_text = mapping.get(title, f"译:{title}")
    else:
        # 仅占位：不做真实翻译，便于验证 UI 是否会把“译文块”追加并异步更新。
        out_text = "（示例译文，占位，不是真实翻译）\n" + text

    resp = {"schema_version": 1, "text": out_text}
    sys.stdout.write(json.dumps(resp, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
