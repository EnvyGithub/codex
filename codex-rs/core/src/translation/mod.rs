//! 外部翻译插件（命令钩子）。
//!
//! 目标：
//! - Codex 本体不内置任何在线翻译服务，避免隐私/合规风险与依赖耦合。
//! - 通过 `config.toml` 指定外部命令（argv）作为翻译器。
//! - 调用方式为 stdin/stdout JSON，便于传输长文本并保持协议可扩展。

mod external_command;

use serde::Deserialize;
use serde::Serialize;

use crate::config::types::AgentReasoningTranslationConfig;

/// 当前翻译协议版本。
pub const TRANSLATION_SCHEMA_VERSION: u32 = 1;

/// 翻译请求类型（用于让插件决定提示词/策略）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranslationKind {
    /// 推理标题（通常很短，例如 “Thinking”）。
    AgentReasoningTitle,
    /// 推理正文（可能包含 Markdown）。
    AgentReasoningBody,
}

impl TranslationKind {
    fn as_wire_value(self) -> &'static str {
        match self {
            TranslationKind::AgentReasoningTitle => "agent_reasoning_title",
            TranslationKind::AgentReasoningBody => "agent_reasoning_body",
        }
    }

    fn format(self) -> TranslationFormat {
        match self {
            TranslationKind::AgentReasoningTitle => TranslationFormat::Plain,
            TranslationKind::AgentReasoningBody => TranslationFormat::Markdown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum TranslationFormat {
    Plain,
    Markdown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct TranslationRequest<'a> {
    schema_version: u32,
    kind: &'static str,
    format: TranslationFormat,
    source_language: &'a str,
    target_language: &'a str,
    text: &'a str,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct TranslationResponse {
    schema_version: u32,
    text: String,
}

/// 翻译失败（外部命令插件）。
#[derive(Debug, thiserror::Error)]
pub enum TranslationError {
    #[error("翻译器命令为空")]
    EmptyCommand,

    #[error("序列化翻译请求失败: {0}")]
    SerializeRequest(#[from] serde_json::Error),

    #[error("启动翻译器进程失败: {0}")]
    Spawn(std::io::Error),

    #[error("写入翻译器 stdin 失败: {0}")]
    WriteStdin(std::io::Error),

    #[error("读取翻译器输出失败: {0}")]
    ReadOutput(std::io::Error),

    #[error("翻译器输出过大（{stream} 超过 {limit_bytes} bytes）")]
    OutputTooLarge {
        stream: &'static str,
        limit_bytes: usize,
    },

    #[error("翻译器超时（{timeout_ms}ms）")]
    Timeout { timeout_ms: u128 },

    #[error("翻译器退出码非 0（code={code:?}）：stderr={stderr_preview} stdout={stdout_preview}")]
    NonZeroExit {
        code: Option<i32>,
        stderr_preview: String,
        stdout_preview: String,
    },

    #[error("翻译器输出不是合法 JSON: {stdout_preview}")]
    InvalidJson { stdout_preview: String },

    #[error("翻译器返回 schema_version 不匹配: expected={expected} actual={actual}")]
    SchemaVersionMismatch { expected: u32, actual: u32 },

    #[error("翻译器返回空译文")]
    EmptyTranslation,
}

fn preview_bytes(bytes: &[u8]) -> String {
    const MAX_CHARS: usize = 300;
    let s = String::from_utf8_lossy(bytes);
    let trimmed = s.trim();

    let mut out = String::new();
    let mut chars = trimmed.chars();
    for _ in 0..MAX_CHARS {
        let Some(c) = chars.next() else {
            return out;
        };
        out.push(c);
    }

    if chars.next().is_some() {
        out.push('…');
    }

    out
}

/// 通过外部命令翻译文本（异步）。
///
/// - `kind` 决定 `format`（plain/markdown）以及 `kind` 字段的 wire 值。
/// - 该函数只做协议调用与错误包装；不负责 UI 格式化（例如 `原文(译文)`）。
pub async fn translate_text(
    config: &AgentReasoningTranslationConfig,
    kind: TranslationKind,
    text: &str,
) -> Result<String, TranslationError> {
    if config.command.is_empty() {
        return Err(TranslationError::EmptyCommand);
    }

    // 当前需求固定翻译为中文；如未来需要多语言，可把 target_language 变成配置项。
    let request = TranslationRequest {
        schema_version: TRANSLATION_SCHEMA_VERSION,
        kind: kind.as_wire_value(),
        format: kind.format(),
        source_language: "en",
        target_language: "zh-CN",
        text,
    };

    let request_json = serde_json::to_vec(&request)?;
    let output = external_command::run_translation_command(config, request_json).await?;

    let response: TranslationResponse =
        serde_json::from_slice(&output.stdout).map_err(|_| TranslationError::InvalidJson {
            stdout_preview: preview_bytes(&output.stdout),
        })?;

    if response.schema_version != TRANSLATION_SCHEMA_VERSION {
        return Err(TranslationError::SchemaVersionMismatch {
            expected: TRANSLATION_SCHEMA_VERSION,
            actual: response.schema_version,
        });
    }

    let translated = response.text.trim().to_string();
    if translated.is_empty() {
        return Err(TranslationError::EmptyTranslation);
    }

    Ok(translated)
}

/// 生成 `原文(译文)` 的双语标题展示文本。
pub fn format_bilingual_title(original: &str, translated: &str) -> String {
    // 用户侧常见期望格式：`Thinking(思考中)`，便于在等宽终端中对齐显示。
    format!("{original}({translated})")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io;
    use std::path::PathBuf;
    use std::time::Duration;
    use tempfile::TempDir;

    fn find_python() -> Option<PathBuf> {
        which::which("python3")
            .ok()
            .or_else(|| which::which("python").ok())
    }

    fn write_script(dir: &TempDir, name: &str, content: &str) -> io::Result<PathBuf> {
        let path = dir.path().join(name);
        std::fs::write(&path, content)?;
        Ok(path)
    }

    #[tokio::test]
    async fn translate_text_success() -> io::Result<()> {
        let Some(python) = find_python() else {
            return Ok(());
        };

        let dir = TempDir::new()?;
        let script = write_script(
            &dir,
            "translator_ok.py",
            r#"
import json, sys
req = json.load(sys.stdin)
out = {"schema_version": 1, "text": "译:" + req.get("text","")}
sys.stdout.write(json.dumps(out))
"#,
        )?;

        let config = AgentReasoningTranslationConfig {
            command: vec![
                python.to_string_lossy().to_string(),
                script.to_string_lossy().to_string(),
            ],
            timeout: Duration::from_millis(2_000),
            ui_max_wait: Duration::from_millis(5_000),
        };

        let translated = translate_text(&config, TranslationKind::AgentReasoningTitle, "Thinking")
            .await
            .expect("translation should succeed");
        assert_eq!(translated, "译:Thinking");
        Ok(())
    }

    #[tokio::test]
    async fn translate_text_non_zero_exit_is_error() -> io::Result<()> {
        let Some(python) = find_python() else {
            return Ok(());
        };

        let dir = TempDir::new()?;
        let script = write_script(
            &dir,
            "translator_fail.py",
            r#"
import sys
sys.stderr.write("boom")
sys.exit(2)
"#,
        )?;

        let config = AgentReasoningTranslationConfig {
            command: vec![
                python.to_string_lossy().to_string(),
                script.to_string_lossy().to_string(),
            ],
            timeout: Duration::from_millis(2_000),
            ui_max_wait: Duration::from_millis(5_000),
        };

        let err = translate_text(&config, TranslationKind::AgentReasoningTitle, "Thinking")
            .await
            .expect_err("should fail");
        let msg = err.to_string();
        assert!(msg.contains("退出码非 0"));
        assert!(msg.contains("boom"));
        Ok(())
    }

    #[tokio::test]
    async fn translate_text_timeout_is_error() -> io::Result<()> {
        let Some(python) = find_python() else {
            return Ok(());
        };

        let dir = TempDir::new()?;
        let script = write_script(
            &dir,
            "translator_sleep.py",
            r#"
import time
time.sleep(5)
"#,
        )?;

        let config = AgentReasoningTranslationConfig {
            command: vec![
                python.to_string_lossy().to_string(),
                script.to_string_lossy().to_string(),
            ],
            timeout: Duration::from_millis(50),
            ui_max_wait: Duration::from_millis(5_000),
        };

        let err = translate_text(&config, TranslationKind::AgentReasoningTitle, "Thinking")
            .await
            .expect_err("should time out");
        let msg = err.to_string();
        assert!(msg.contains("超时"));
        Ok(())
    }
}
