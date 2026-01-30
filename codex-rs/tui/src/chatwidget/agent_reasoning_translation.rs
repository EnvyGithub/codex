use std::collections::HashMap;
use std::collections::VecDeque;
use std::time::Duration;
use std::time::Instant;

use codex_core::config::types::AgentReasoningTranslationConfig;
use codex_core::config::types::DEFAULT_AGENT_REASONING_TRANSLATION_UI_MAX_WAIT_MS;
use codex_protocol::ThreadId;

use crate::app_event::AppEvent;
use crate::app_event_sender::AppEventSender;
use crate::history_cell;
use crate::history_cell::HistoryCell;
use crate::tui::FrameRequester;

/// 覆盖推理译文对齐等待上限的环境变量（单位：毫秒）。
///
/// 示例：`CODEX_TUI_AGENT_REASONING_TRANSLATION_MAX_WAIT_MS=5000`
const AGENT_REASONING_TRANSLATION_MAX_WAIT_ENV: &str =
    "CODEX_TUI_AGENT_REASONING_TRANSLATION_MAX_WAIT_MS";

#[derive(Debug)]
struct AgentReasoningBodyTranslationBarrier {
    request_id: u64,
    thread_id: ThreadId,
    title: Option<String>,
    max_wait: Duration,
    deadline: Instant,
}

#[derive(Debug)]
pub(super) struct AgentReasoningBodyTranslationResult {
    request_id: u64,
    thread_id: ThreadId,
    title: Option<String>,
    translated: Option<String>,
    error: Option<String>,
}

impl AgentReasoningBodyTranslationResult {
    pub(super) fn new(
        request_id: u64,
        thread_id: ThreadId,
        title: Option<String>,
        translated: Option<String>,
        error: Option<String>,
    ) -> Self {
        Self {
            request_id,
            thread_id,
            title,
            translated,
            error,
        }
    }
}

#[derive(Debug)]
pub(crate) struct AgentReasoningTranslationOrchestrator {
    /// “主题标题原文 -> 主题标题译文”的缓存。
    ///
    /// 这里缓存来自“正文翻译结果”中提取的标题译文，用于实时 status header 显示双语标题。
    title_translation_cache: HashMap<String, String>,
    /// 当前 UI 中展示的推理标题原文（来自 reasoning delta 的 `**...**` 提取）。
    ///
    /// 用于在译文返回时做“防串台”校验：只有仍在展示同一个标题时才更新 status header。
    current_reasoning_title_raw: Option<String>,
    /// 正文译文对齐用的 barrier：在译文生成完成（或超时）前，暂存后续 history cell。
    body_translation_barrier: Option<AgentReasoningBodyTranslationBarrier>,
    /// barrier 期间暂存的 history cells（用于“译文紧贴原文”）。
    deferred_history_cells: VecDeque<Box<dyn HistoryCell>>,
    /// 单调-ish 序列号，用于把异步回传与当前 barrier 绑定（防串台/防乱序）。
    body_translation_seq: u64,
    /// 异步翻译结果回传（去 AppEvent 化）。
    body_translation_results_tx:
        tokio::sync::mpsc::UnboundedSender<AgentReasoningBodyTranslationResult>,
    body_translation_results_rx:
        tokio::sync::mpsc::UnboundedReceiver<AgentReasoningBodyTranslationResult>,
}

pub(crate) struct OnBodyTranslatedResult {
    pub(crate) status_header_update: Option<String>,
    pub(crate) needs_redraw: bool,
}

impl Default for AgentReasoningTranslationOrchestrator {
    fn default() -> Self {
        let (body_translation_results_tx, body_translation_results_rx) =
            tokio::sync::mpsc::unbounded_channel();
        Self {
            title_translation_cache: HashMap::new(),
            current_reasoning_title_raw: None,
            body_translation_barrier: None,
            deferred_history_cells: VecDeque::new(),
            body_translation_seq: 0,
            body_translation_results_tx,
            body_translation_results_rx,
        }
    }
}

impl AgentReasoningTranslationOrchestrator {
    pub(crate) fn on_task_started(&mut self) {
        self.current_reasoning_title_raw = None;
    }

    pub(crate) fn maybe_status_header_from_reasoning_buffer(
        &mut self,
        reasoning_buffer: &str,
    ) -> Option<String> {
        let header = super::extract_first_bold(reasoning_buffer)?;
        self.current_reasoning_title_raw = Some(header.clone());

        if let Some(translated) = self.title_translation_cache.get(&header) {
            Some(codex_core::translation::format_bilingual_title(
                &header, translated,
            ))
        } else {
            Some(header)
        }
    }

    pub(crate) fn maybe_translate_reasoning_body(
        &mut self,
        config: Option<&AgentReasoningTranslationConfig>,
        thread_id: Option<ThreadId>,
        full_reasoning: String,
        frame_requester: FrameRequester,
    ) {
        let Some(config) = config.cloned() else {
            return;
        };
        let Some(thread_id) = thread_id else {
            return;
        };

        let title = super::extract_first_bold(&full_reasoning);
        let Some(body) = extract_reasoning_body_for_translation(&full_reasoning) else {
            return;
        };
        if body.trim().is_empty() {
            return;
        }

        // 方案 A：为保证译文紧跟原文，在译文生成完成（或超时）前，缓冲后续历史输出。
        let Some(request_id) = self.begin_body_translation_barrier(
            config.ui_max_wait,
            thread_id,
            title.clone(),
            frame_requester.clone(),
        ) else {
            return;
        };

        let result_tx = self.body_translation_results_tx.clone();
        // 仅调用一次翻译：把 “**标题** + 正文” 一起交给外部翻译器。
        // 这样可以在同一次返回中拿到“主题译文 + 正文译文”，避免标题/正文分别调用带来的成本与延迟。
        tokio::spawn(async move {
            let result = codex_core::translation::translate_text(
                &config,
                codex_core::translation::TranslationKind::AgentReasoningBody,
                &full_reasoning,
            )
            .await;

            let msg = match result {
                Ok(translated) => AgentReasoningBodyTranslationResult::new(
                    request_id,
                    thread_id,
                    title,
                    Some(translated),
                    None,
                ),
                Err(err) => AgentReasoningBodyTranslationResult::new(
                    request_id,
                    thread_id,
                    title,
                    None,
                    Some(err.to_string()),
                ),
            };

            let _ = result_tx.send(msg);
            frame_requester.schedule_frame();
        });
    }

    pub(crate) fn drain_body_translation_results(
        &mut self,
        active_thread_id: Option<ThreadId>,
        config: Option<&AgentReasoningTranslationConfig>,
        app_event_tx: &AppEventSender,
        frame_requester: FrameRequester,
    ) -> OnBodyTranslatedResult {
        let mut out = OnBodyTranslatedResult {
            status_header_update: None,
            needs_redraw: false,
        };

        loop {
            match self.body_translation_results_rx.try_recv() {
                Ok(msg) => {
                    let result = self.on_body_translated(
                        msg,
                        active_thread_id,
                        config,
                        app_event_tx,
                        frame_requester.clone(),
                    );
                    if result.status_header_update.is_some() {
                        out.status_header_update = result.status_header_update;
                    }
                    out.needs_redraw |= result.needs_redraw;
                }
                Err(tokio::sync::mpsc::error::TryRecvError::Empty) => break,
                Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => break,
            }
        }

        out
    }

    pub(crate) fn on_body_translated(
        &mut self,
        msg: AgentReasoningBodyTranslationResult,
        active_thread_id: Option<ThreadId>,
        config: Option<&AgentReasoningTranslationConfig>,
        app_event_tx: &AppEventSender,
        frame_requester: FrameRequester,
    ) -> OnBodyTranslatedResult {
        let AgentReasoningBodyTranslationResult {
            request_id,
            thread_id,
            title,
            translated,
            error,
        } = msg;

        let Some(barrier) = self.body_translation_barrier.as_ref() else {
            // 已超时释放，或会话已切换；为保证“译文紧跟原文”，这里不再追加晚到的译文。
            return OnBodyTranslatedResult {
                status_header_update: None,
                needs_redraw: false,
            };
        };
        if barrier.request_id != request_id {
            return OnBodyTranslatedResult {
                status_header_update: None,
                needs_redraw: false,
            };
        }
        if barrier.thread_id != thread_id {
            return OnBodyTranslatedResult {
                status_header_update: None,
                needs_redraw: false,
            };
        }
        if active_thread_id.as_ref() != Some(&thread_id) {
            return OnBodyTranslatedResult {
                status_header_update: None,
                needs_redraw: false,
            };
        }

        // 先结束 barrier，确保译文与后续缓冲内容按顺序落盘。
        self.body_translation_barrier = None;

        let mut status_header_update = None;

        if let Some(translated) = translated {
            // 译文返回的是完整块（包含 `**标题**`），这里再拆分出：
            // - 主题译文：用于译文块标题 & 状态栏缓存
            // - 正文译文：用于译文块内容（避免重复显示标题）
            let translated_title = super::extract_first_bold(&translated);
            let translated_body = extract_reasoning_body_for_translation(&translated)
                .unwrap_or_else(|| translated.clone())
                .trim()
                .to_string();

            // 尽力缓存标题译文（用于后续实时 status 显示），但不强行兜底二次翻译。
            if let (Some(original), Some(translated_title)) =
                (title.as_deref(), translated_title.as_deref())
            {
                self.title_translation_cache
                    .insert(original.to_string(), translated_title.to_string());

                // 仅当当前 UI 仍在展示同一个推理标题时，才更新状态行，避免“串台”。
                if self.current_reasoning_title_raw.as_deref() == Some(original) {
                    status_header_update = Some(codex_core::translation::format_bilingual_title(
                        original,
                        translated_title,
                    ));
                }
            }

            self.emit_history_cell(
                app_event_tx,
                history_cell::new_agent_reasoning_translation_block(
                    None,
                    if translated_body.is_empty() {
                        translated
                    } else {
                        translated_body
                    },
                ),
            );
        } else {
            let reason = error.unwrap_or_else(|| "unknown error".to_string());
            self.emit_history_cell(
                app_event_tx,
                history_cell::new_agent_reasoning_translation_error_block(title, reason),
            );
        }

        self.flush_deferred_history_cells(config, active_thread_id, app_event_tx, frame_requester);

        OnBodyTranslatedResult {
            status_header_update,
            needs_redraw: true,
        }
    }

    pub(crate) fn maybe_flush_timeout(
        &mut self,
        config: Option<&AgentReasoningTranslationConfig>,
        active_thread_id: Option<ThreadId>,
        app_event_tx: &AppEventSender,
        frame_requester: FrameRequester,
    ) -> bool {
        let Some(barrier) = self.body_translation_barrier.as_ref() else {
            return false;
        };
        if Instant::now() < barrier.deadline {
            return false;
        }

        let title = barrier.title.clone();
        let max_wait = barrier.max_wait;
        let max_wait_ms = max_wait.as_millis();

        // 先结束 barrier，再输出失败块与缓冲内容，确保它们按顺序落盘。
        self.body_translation_barrier = None;
        self.emit_history_cell(
            app_event_tx,
            history_cell::new_agent_reasoning_translation_error_block(
                title,
                format!("等待超时（{max_wait_ms}ms），已跳过译文输出"),
            ),
        );
        self.flush_deferred_history_cells(config, active_thread_id, app_event_tx, frame_requester);
        true
    }

    pub(crate) fn emit_history_cell(
        &mut self,
        app_event_tx: &AppEventSender,
        cell: Box<dyn HistoryCell>,
    ) {
        if self.body_translation_barrier.is_some() {
            self.deferred_history_cells.push_back(cell);
        } else {
            app_event_tx.send(AppEvent::InsertHistoryCell(cell));
        }
    }

    fn flush_deferred_history_cells(
        &mut self,
        config: Option<&AgentReasoningTranslationConfig>,
        active_thread_id: Option<ThreadId>,
        app_event_tx: &AppEventSender,
        frame_requester: FrameRequester,
    ) {
        while let Some(cell) = self.deferred_history_cells.pop_front() {
            let maybe_reasoning_for_translation = cell
                .as_any()
                .downcast_ref::<history_cell::ReasoningSummaryCell>()
                .and_then(history_cell::ReasoningSummaryCell::full_markdown_for_translation);

            app_event_tx.send(AppEvent::InsertHistoryCell(cell));

            if let Some(full_reasoning) = maybe_reasoning_for_translation {
                // 关键：barrier 期间可能积压了新的推理块（ReasoningSummaryCell）。
                // 若直接一次性 flush 完所有缓冲内容，会导致这些推理块“没触发翻译”。
                // 这里在 flush 时遇到推理块就尝试启动下一次翻译，并立即停止继续 flush，
                // 以保证其译文仍然紧跟在对应原文下面。
                if self.body_translation_barrier.is_none() {
                    self.maybe_translate_reasoning_body(
                        config,
                        active_thread_id,
                        full_reasoning,
                        frame_requester.clone(),
                    );
                    if self.body_translation_barrier.is_some() {
                        break;
                    }
                }
            }
        }
    }

    fn begin_body_translation_barrier(
        &mut self,
        config_max_wait: Duration,
        thread_id: ThreadId,
        title: Option<String>,
        frame_requester: FrameRequester,
    ) -> Option<u64> {
        if self.body_translation_barrier.is_some() {
            // 同一时刻只允许一个 barrier；避免多段推理并发时造成输出死锁。
            return None;
        }

        let request_id = self.body_translation_seq;
        self.body_translation_seq = self.body_translation_seq.saturating_add(1);

        let max_wait = self.max_wait_with_env_override(config_max_wait);
        let deadline = Instant::now()
            .checked_add(max_wait)
            .unwrap_or_else(Instant::now);
        self.body_translation_barrier = Some(AgentReasoningBodyTranslationBarrier {
            request_id,
            thread_id,
            title,
            max_wait,
            deadline,
        });

        // 触发一个未来的 Draw tick，用于在没有其它事件到来时也能按时超时释放。
        frame_requester.schedule_frame_in(max_wait);
        Some(request_id)
    }

    fn max_wait_with_env_override(&self, config_max_wait: Duration) -> Duration {
        match std::env::var(AGENT_REASONING_TRANSLATION_MAX_WAIT_ENV) {
            Ok(raw) => match raw.trim().parse::<u64>() {
                Ok(ms) => Duration::from_millis(ms),
                Err(err) => {
                    tracing::warn!(
                        "无法解析环境变量 {AGENT_REASONING_TRANSLATION_MAX_WAIT_ENV}={raw:?}：{err}；将使用配置值 {}ms（未配置则默认 {}ms）",
                        config_max_wait.as_millis(),
                        DEFAULT_AGENT_REASONING_TRANSLATION_UI_MAX_WAIT_MS
                    );
                    config_max_wait
                }
            },
            Err(_) => config_max_wait,
        }
    }
}

/// 从推理 Markdown 中提取“正文”部分（去掉首个 `**标题**`）。
///
/// 约定：推理块通常以 `**Thinking**` 之类的粗体标题开头，后续为正文。
/// 若未找到完整的 `**...**`，或标题后没有正文，则返回 `None`。
pub(super) fn extract_reasoning_body_for_translation(
    full_reasoning_markdown: &str,
) -> Option<String> {
    let full_reasoning_markdown = full_reasoning_markdown.trim();
    let open = full_reasoning_markdown.find("**")?;
    let after_open = &full_reasoning_markdown[(open + 2)..];
    let close = after_open.find("**")?;

    let after_close_idx = open + 2 + close + 2;
    if after_close_idx >= full_reasoning_markdown.len() {
        return None;
    }
    let body = full_reasoning_markdown[after_close_idx..].trim_start();
    if body.is_empty() {
        None
    } else {
        Some(body.to_string())
    }
}

#[cfg(test)]
impl AgentReasoningTranslationOrchestrator {
    pub(super) fn begin_body_translation_barrier_for_tests(
        &mut self,
        config_max_wait: Duration,
        thread_id: ThreadId,
        title: Option<String>,
        frame_requester: FrameRequester,
    ) -> Option<u64> {
        self.begin_body_translation_barrier(config_max_wait, thread_id, title, frame_requester)
    }

    pub(super) fn barrier_max_wait_for_tests(&self) -> Option<Duration> {
        self.body_translation_barrier.as_ref().map(|b| b.max_wait)
    }

    pub(super) fn barrier_request_id_for_tests(&self) -> Option<u64> {
        self.body_translation_barrier.as_ref().map(|b| b.request_id)
    }

    pub(super) fn set_barrier_deadline_for_tests(&mut self, deadline: Instant) {
        if let Some(barrier) = self.body_translation_barrier.as_mut() {
            barrier.deadline = deadline;
        }
    }
}
