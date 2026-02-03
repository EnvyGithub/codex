#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
OpenAI 兼容翻译器脚本的最小单元测试（仅标准库）。

目标：
- 429（限流）触发后可重试并成功，不产生 Traceback；
- 401（鉴权失败）不重试，stderr 为结构化短错误（便于 Codex 截断展示）。
"""

from __future__ import annotations

import io
import os
import unittest
import urllib.error
from unittest import mock

import translate_agent_reasoning_openai_compatible as translator


class _FakeResponse:
    def __init__(self, body: bytes) -> None:
        self._body = body

    def read(self) -> bytes:
        return self._body

    def __enter__(self) -> "_FakeResponse":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        return False


class TestOpenAiCompatibleTranslator(unittest.TestCase):
    def test_429_then_success_should_retry_without_traceback(self) -> None:
        http_429 = urllib.error.HTTPError(
            url="https://api.example.test/v1/chat/completions",
            code=429,
            msg="Too Many Requests",
            hdrs={"Retry-After": "0"},
            fp=io.BytesIO(b'{"error":"rate_limit"}'),
        )

        ok = _FakeResponse(b'{"choices":[{"message":{"content":"OK"}}]}')

        with mock.patch.object(
            translator.urllib.request,
            "urlopen",
            side_effect=[http_429, ok],
        ) as mock_urlopen:
            with mock.patch.object(translator.time, "sleep") as sleep:
                with mock.patch.dict(
                    os.environ,
                    {
                        "CODEX_TRANSLATION_ENV_FILE": "/this/file/should/not/exist.env",
                        "CODEX_TRANSLATION_API_KEY": "test-key",
                        "CODEX_TRANSLATION_BASE_URL": "https://api.example.test/v1",
                        "CODEX_TRANSLATION_RETRY_ATTEMPTS": "1",
                    },
                    clear=True,
                ):
                    stdin = io.StringIO(
                        '{"schema_version":1,"kind":"agent_reasoning_body","format":"markdown","source_language":"en","target_language":"zh-CN","text":"Hello"}'
                    )
                    stdout = io.StringIO()
                    stderr = io.StringIO()
                    with mock.patch("sys.stdin", stdin), mock.patch("sys.stdout", stdout), mock.patch(
                        "sys.stderr", stderr
                    ):
                        exit_code = translator.main()

        self.assertEqual(exit_code, 0)
        self.assertEqual(mock_urlopen.call_count, 2)
        self.assertIn('"text": "OK"', stdout.getvalue())
        self.assertEqual("", stderr.getvalue())
        sleep.assert_called_once_with(0.2)

    def test_401_should_fail_without_retry_and_without_traceback(self) -> None:
        http_401 = urllib.error.HTTPError(
            url="https://api.example.test/v1/chat/completions",
            code=401,
            msg="Unauthorized",
            hdrs={},
            fp=io.BytesIO(b'{"error":"invalid_api_key"}'),
        )

        with mock.patch.object(
            translator.urllib.request,
            "urlopen",
            side_effect=[http_401],
        ) as mock_urlopen:
            with mock.patch.object(translator.time, "sleep") as sleep:
                with mock.patch.dict(
                    os.environ,
                    {
                        "CODEX_TRANSLATION_ENV_FILE": "/this/file/should/not/exist.env",
                        "CODEX_TRANSLATION_API_KEY": "test-key",
                        "CODEX_TRANSLATION_BASE_URL": "https://api.example.test/v1",
                    },
                    clear=True,
                ):
                    stdin = io.StringIO(
                        '{"schema_version":1,"kind":"agent_reasoning_body","format":"markdown","source_language":"en","target_language":"zh-CN","text":"Hello"}'
                    )
                    stdout = io.StringIO()
                    stderr = io.StringIO()
                    with mock.patch("sys.stdin", stdin), mock.patch("sys.stdout", stdout), mock.patch(
                        "sys.stderr", stderr
                    ):
                        exit_code = translator.main()

        self.assertEqual(exit_code, 2)
        self.assertEqual(mock_urlopen.call_count, 1)
        self.assertEqual("", stdout.getvalue())
        err = stderr.getvalue()
        self.assertIn("translation_failed:http_401", err)
        self.assertIn("hint:", err)
        self.assertNotIn("Traceback", err)
        sleep.assert_not_called()

    def test_429_exhausted_should_fail_with_attempts_count(self) -> None:
        http_429_a = urllib.error.HTTPError(
            url="https://api.example.test/v1/chat/completions",
            code=429,
            msg="Too Many Requests",
            hdrs={"Retry-After": "0"},
            fp=io.BytesIO(b'{"error":"rate_limit"}'),
        )
        http_429_b = urllib.error.HTTPError(
            url="https://api.example.test/v1/chat/completions",
            code=429,
            msg="Too Many Requests",
            hdrs={"Retry-After": "0"},
            fp=io.BytesIO(b'{"error":"rate_limit"}'),
        )

        with mock.patch.object(
            translator.urllib.request,
            "urlopen",
            side_effect=[http_429_a, http_429_b],
        ) as mock_urlopen:
            with mock.patch.object(translator.time, "sleep") as sleep:
                with mock.patch.dict(
                    os.environ,
                    {
                        "CODEX_TRANSLATION_ENV_FILE": "/this/file/should/not/exist.env",
                        "CODEX_TRANSLATION_API_KEY": "test-key",
                        "CODEX_TRANSLATION_BASE_URL": "https://api.example.test/v1",
                        "CODEX_TRANSLATION_RETRY_ATTEMPTS": "1",
                    },
                    clear=True,
                ):
                    stdin = io.StringIO(
                        '{"schema_version":1,"kind":"agent_reasoning_body","format":"markdown","source_language":"en","target_language":"zh-CN","text":"Hello"}'
                    )
                    stdout = io.StringIO()
                    stderr = io.StringIO()
                    with mock.patch("sys.stdin", stdin), mock.patch("sys.stdout", stdout), mock.patch(
                        "sys.stderr", stderr
                    ):
                        exit_code = translator.main()

        self.assertEqual(exit_code, 2)
        self.assertEqual(mock_urlopen.call_count, 2)
        self.assertEqual("", stdout.getvalue())
        err = stderr.getvalue()
        self.assertIn("translation_failed:http_429", err)
        self.assertIn("attempts=2", err)
        self.assertNotIn("Traceback", err)
        sleep.assert_called_once_with(0.2)


if __name__ == "__main__":
    unittest.main()
