use super::*;

use super::super::agent_reasoning_translation::AgentReasoningBodyTranslationResult;

use crate::app_event::AppEvent;
use crate::app_event_sender::AppEventSender;
use crate::history_cell;
use crate::tui::FrameRequester;

use codex_core::config::types::AgentReasoningTranslationConfig;
use codex_protocol::ThreadId;
use pretty_assertions::assert_eq;

#[tokio::test]
async fn reasoning_body_translation_barrier_keeps_translation_adjacent() {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<AppEvent>();
    let app_event_tx = AppEventSender::new(tx);
    let frame_requester = FrameRequester::test_dummy();
    let mut orchestrator = AgentReasoningTranslationOrchestrator::default();

    let thread_id = ThreadId::new();

    // 先插入“原文推理摘要”块（对应真实运行时的 on_agent_reasoning_final）。
    let full_reasoning = "**Thinking**\n\nI will first analyze the request.".to_string();
    app_event_tx.send(AppEvent::InsertHistoryCell(
        history_cell::new_reasoning_summary_block(full_reasoning),
    ));

    // 开启 barrier：在译文生成完成前，缓冲后续历史输出。
    let request_id = orchestrator
        .begin_body_translation_barrier_for_tests(
            std::time::Duration::from_secs(5),
            thread_id,
            Some("Thinking".to_string()),
            frame_requester.clone(),
        )
        .expect("expected barrier to start");

    // 这条输出若不缓冲，会插入到译文之前导致错位。
    orchestrator.emit_history_cell(
        &app_event_tx,
        Box::new(crate::history_cell::PlainHistoryCell::new(vec![
            ratatui::text::Line::from("AFTER_CELL"),
        ])),
    );

    // 模拟译文返回（不依赖真实外部翻译器）。
    let _ = orchestrator.on_body_translated(
        AgentReasoningBodyTranslationResult::new(
            request_id,
            thread_id,
            Some("Thinking".to_string()),
            Some("**思考中**\n\n这里是中文翻译。".to_string()),
            None,
        ),
        Some(thread_id),
        None,
        &app_event_tx,
        frame_requester,
    );

    let cells = drain_insert_history(&mut rx);
    let combined: Vec<String> = cells
        .iter()
        .map(|lines| lines_to_single_string(lines))
        .collect();

    assert!(
        combined
            .first()
            .is_some_and(|s| s.contains("I will first analyze")),
        "missing reasoning block in first cell: {combined:?}"
    );
    assert!(
        combined.get(1).is_some_and(|s| s.contains("└ ")
            && s.contains("这里是中文翻译")
            && !s.contains("└ 译文")),
        "expected translation cell immediately after reasoning: {combined:?}"
    );
    assert!(
        combined.get(2).is_some_and(|s| s.contains("AFTER_CELL")),
        "expected buffered cell to flush after translation: {combined:?}"
    );
}

#[tokio::test]
async fn unified_exec_wait_streak_respects_reasoning_translation_barrier() {
    use std::time::Duration;

    let (mut chat, mut rx, _ops) = make_chatwidget_manual(None).await;
    let frame_requester = chat.frame_requester.clone();

    let thread_id = ThreadId::new();
    chat.thread_id = Some(thread_id);

    // 先落盘推理摘要（对应真实运行时的 on_agent_reasoning_final）。
    chat.app_event_tx.send(AppEvent::InsertHistoryCell(
        history_cell::new_reasoning_summary_block("**Thinking**\n\nFirst reasoning.".to_string()),
    ));

    // 开启 barrier：在译文生成完成前，后续 history insert 必须被缓冲，避免插队。
    let request_id = chat
        .agent_reasoning_translation
        .begin_body_translation_barrier_for_tests(
            Duration::from_secs(5),
            thread_id,
            Some("Thinking".to_string()),
            frame_requester.clone(),
        )
        .expect("expected barrier to start");

    // 该输出来自 unified exec wait streak 的 flush；若绕过 barrier，会插入到译文之前导致错位。
    chat.unified_exec_wait_streak = Some(UnifiedExecWaitStreak::new(
        "proc-1".to_string(),
        Some("sleep 1".to_string()),
    ));
    chat.flush_unified_exec_wait_streak();

    // 模拟译文返回：应当先插入译文，再 flush 掉 barrier 期间缓冲的 unified exec cell。
    let _ = chat.agent_reasoning_translation.on_body_translated(
        AgentReasoningBodyTranslationResult::new(
            request_id,
            thread_id,
            Some("Thinking".to_string()),
            Some("**思考中**\n\n这里是中文翻译。".to_string()),
            None,
        ),
        Some(thread_id),
        None,
        &chat.app_event_tx,
        frame_requester,
    );

    let cells = drain_insert_history(&mut rx);
    let combined = cells
        .iter()
        .map(|lines| lines_to_single_string(lines))
        .collect::<Vec<_>>();

    fn find_idx(haystack: &[String], needle: &str) -> usize {
        haystack
            .iter()
            .position(|s| s.contains(needle))
            .unwrap_or_else(|| panic!("missing {needle:?} in {haystack:?}"))
    }

    let idx_reasoning = find_idx(&combined, "First reasoning");
    let idx_translation = find_idx(&combined, "这里是中文翻译");
    let idx_unified_exec = find_idx(&combined, "Interacted with background terminal");
    assert!(
        idx_reasoning < idx_translation && idx_translation < idx_unified_exec,
        "unexpected insertion order: {combined:?}"
    );
}

#[tokio::test]
async fn reasoning_body_translation_barrier_uses_config_ui_max_wait() {
    use std::time::Duration;

    let frame_requester = FrameRequester::test_dummy();
    let mut orchestrator = AgentReasoningTranslationOrchestrator::default();

    // 这里不需要真实可执行的 command：该测试仅验证 barrier 的等待时间取值逻辑。
    let config = AgentReasoningTranslationConfig {
        command: Vec::new(),
        timeout: Duration::from_millis(2_000),
        ui_max_wait: Duration::from_millis(12_345),
    };

    let expected = std::env::var("CODEX_TUI_AGENT_REASONING_TRANSLATION_MAX_WAIT_MS")
        .ok()
        .and_then(|raw| raw.trim().parse::<u64>().ok())
        .map(Duration::from_millis)
        .unwrap_or(Duration::from_millis(12_345));

    let thread_id = ThreadId::new();
    let _request_id = orchestrator
        .begin_body_translation_barrier_for_tests(
            config.ui_max_wait,
            thread_id,
            Some("Thinking".to_string()),
            frame_requester,
        )
        .expect("expected barrier to start");

    assert_eq!(orchestrator.barrier_max_wait_for_tests(), Some(expected));
}

#[tokio::test]
async fn reasoning_body_translation_barrier_times_out_and_flushes_buffer() {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<AppEvent>();
    let app_event_tx = AppEventSender::new(tx);
    let frame_requester = FrameRequester::test_dummy();
    let mut orchestrator = AgentReasoningTranslationOrchestrator::default();

    let thread_id = ThreadId::new();

    let full_reasoning = "**Thinking**\n\nI will first analyze the request.".to_string();
    app_event_tx.send(AppEvent::InsertHistoryCell(
        history_cell::new_reasoning_summary_block(full_reasoning),
    ));

    let _request_id = orchestrator
        .begin_body_translation_barrier_for_tests(
            std::time::Duration::from_secs(5),
            thread_id,
            Some("Thinking".to_string()),
            frame_requester.clone(),
        )
        .expect("expected barrier to start");

    orchestrator.emit_history_cell(
        &app_event_tx,
        Box::new(crate::history_cell::PlainHistoryCell::new(vec![
            ratatui::text::Line::from("AFTER_CELL"),
        ])),
    );

    // 人为把 deadline 设到过去，触发一次超时释放。
    orchestrator.set_barrier_deadline_for_tests(
        std::time::Instant::now() - std::time::Duration::from_millis(1),
    );
    assert!(
        orchestrator.maybe_flush_timeout(None, Some(thread_id), &app_event_tx, frame_requester),
        "expected timeout flush to trigger"
    );

    let cells = drain_insert_history(&mut rx);
    let combined: Vec<String> = cells
        .iter()
        .map(|lines| lines_to_single_string(lines))
        .collect();

    assert!(
        combined
            .get(1)
            .is_some_and(|s| s.contains("译文生成失败") && s.contains("等待超时")),
        "expected timeout error cell after reasoning: {combined:?}"
    );
    assert!(
        combined.get(2).is_some_and(|s| s.contains("AFTER_CELL")),
        "expected buffered cell to flush after timeout: {combined:?}"
    );
}

#[tokio::test]
async fn reasoning_body_translation_ignores_late_results_from_previous_barrier() {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<AppEvent>();
    let app_event_tx = AppEventSender::new(tx);
    let frame_requester = FrameRequester::test_dummy();
    let mut orchestrator = AgentReasoningTranslationOrchestrator::default();

    let thread_id = ThreadId::new();

    app_event_tx.send(AppEvent::InsertHistoryCell(
        history_cell::new_reasoning_summary_block("**Thinking**\n\nFirst reasoning.".to_string()),
    ));

    let request_id_1 = orchestrator
        .begin_body_translation_barrier_for_tests(
            std::time::Duration::from_secs(5),
            thread_id,
            Some("Thinking".to_string()),
            frame_requester.clone(),
        )
        .expect("expected barrier to start");

    // 超时释放 barrier 1（模拟翻译器卡住/很慢，译文晚到）。
    orchestrator.set_barrier_deadline_for_tests(
        std::time::Instant::now() - std::time::Duration::from_millis(1),
    );
    assert!(orchestrator.maybe_flush_timeout(
        None,
        Some(thread_id),
        &app_event_tx,
        frame_requester.clone()
    ));

    let request_id_2 = orchestrator
        .begin_body_translation_barrier_for_tests(
            std::time::Duration::from_secs(5),
            thread_id,
            Some("Thinking".to_string()),
            frame_requester.clone(),
        )
        .expect("expected barrier to start");

    // 旧译文晚到：不应当打断当前 barrier，也不应插入到历史中。
    let late = orchestrator.on_body_translated(
        AgentReasoningBodyTranslationResult::new(
            request_id_1,
            thread_id,
            Some("Thinking".to_string()),
            Some("**旧**\n\n旧译文".to_string()),
            None,
        ),
        Some(thread_id),
        None,
        &app_event_tx,
        frame_requester.clone(),
    );
    assert!(!late.needs_redraw, "late result should be ignored");
    assert_eq!(
        orchestrator.barrier_request_id_for_tests(),
        Some(request_id_2),
        "late result should not affect the current barrier"
    );

    // 当前译文到达：应当正常结束 barrier 并落盘。
    let current = orchestrator.on_body_translated(
        AgentReasoningBodyTranslationResult::new(
            request_id_2,
            thread_id,
            Some("Thinking".to_string()),
            Some("**新**\n\n新译文".to_string()),
            None,
        ),
        Some(thread_id),
        None,
        &app_event_tx,
        frame_requester,
    );
    assert!(
        current.needs_redraw,
        "expected current translation to be handled"
    );
    assert_eq!(
        orchestrator.barrier_request_id_for_tests(),
        None,
        "expected barrier to clear after matching translation result"
    );

    let cells = drain_insert_history(&mut rx);
    let combined = cells
        .iter()
        .map(|lines| lines_to_single_string(lines))
        .collect::<Vec<_>>();

    assert!(
        combined.iter().all(|s| !s.contains("旧译文")),
        "did not expect late translation to be inserted: {combined:?}"
    );
    assert!(
        combined.iter().any(|s| s.contains("新译文")),
        "expected current translation to be inserted: {combined:?}"
    );
}

#[tokio::test]
async fn reasoning_body_translation_barrier_does_not_skip_deferred_reasoning_blocks() {
    if cfg!(target_os = "windows") {
        // 该测试依赖 `sh`（用于最小化外部翻译器实现），Windows 上默认不可用。
        return;
    }

    use std::time::Duration;

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<AppEvent>();
    let app_event_tx = AppEventSender::new(tx);
    let frame_requester = FrameRequester::test_dummy();
    let mut orchestrator = AgentReasoningTranslationOrchestrator::default();

    let config = AgentReasoningTranslationConfig {
        command: vec![
            "sh".to_string(),
            "-c".to_string(),
            r#"cat >/dev/null; printf '%s' '{"schema_version":1,"text":"**思考中**\\n\\n这里是中文翻译。"}'"#
                .to_string(),
        ],
        timeout: Duration::from_millis(2_000),
        ui_max_wait: Duration::from_millis(5_000),
    };

    let thread_id = ThreadId::new();

    // 推理块 1：先落盘原文推理摘要（对应真实运行时的 on_agent_reasoning_final）。
    let reasoning_1 = "**Thinking**\n\nFirst reasoning.".to_string();
    app_event_tx.send(AppEvent::InsertHistoryCell(
        history_cell::new_reasoning_summary_block(reasoning_1.clone()),
    ));
    orchestrator.maybe_translate_reasoning_body(
        Some(&config),
        Some(thread_id),
        reasoning_1,
        frame_requester.clone(),
    );

    // barrier 期间追加推理块 2（会进入 deferred 队列）。
    orchestrator.emit_history_cell(
        &app_event_tx,
        Box::new(crate::history_cell::PlainHistoryCell::new(vec![
            ratatui::text::Line::from("AFTER_1"),
        ])),
    );
    orchestrator.emit_history_cell(
        &app_event_tx,
        history_cell::new_reasoning_summary_block("**Thinking**\n\nSecond reasoning.".to_string()),
    );
    orchestrator.emit_history_cell(
        &app_event_tx,
        Box::new(crate::history_cell::PlainHistoryCell::new(vec![
            ratatui::text::Line::from("AFTER_2"),
        ])),
    );

    let mut combined: Vec<String> = Vec::new();
    let mut translation_cells_seen = 0usize;
    let mut saw_after_2 = false;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    while tokio::time::Instant::now() < deadline && (translation_cells_seen < 2 || !saw_after_2) {
        let tick = Duration::from_millis(25);
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        // 模拟 Draw tick：在任何 overlay 场景下也会发生 drain（见 App::handle_tui_event）。
        let _ = orchestrator.drain_body_translation_results(
            Some(thread_id),
            Some(&config),
            &app_event_tx,
            frame_requester.clone(),
        );

        let Ok(Some(ev)) = tokio::time::timeout(std::cmp::min(remaining, tick), rx.recv()).await
        else {
            continue;
        };

        if let AppEvent::InsertHistoryCell(cell) = ev {
            let s = lines_to_single_string(&cell.display_lines(80));
            if s.contains("这里是中文翻译") {
                translation_cells_seen += 1;
            }
            if s.contains("AFTER_2") {
                saw_after_2 = true;
            }
            combined.push(s);
        }
    }

    fn find_idx(haystack: &[String], needle: &str) -> usize {
        haystack
            .iter()
            .position(|s| s.contains(needle))
            .unwrap_or_else(|| panic!("missing {needle:?} in {haystack:?}"))
    }

    let idx_r1 = find_idx(&combined, "First reasoning");
    let idx_after_1 = find_idx(&combined, "AFTER_1");
    let idx_r2 = find_idx(&combined, "Second reasoning");
    let idx_after_2 = find_idx(&combined, "AFTER_2");

    let translation_indices: Vec<usize> = combined
        .iter()
        .enumerate()
        .filter_map(|(idx, s)| s.contains("这里是中文翻译").then_some(idx))
        .collect();
    assert_eq!(
        translation_indices.len(),
        2,
        "expected 2 translation cells: {combined:?}"
    );

    let idx_t1 = translation_indices[0];
    let idx_t2 = translation_indices[1];
    assert!(
        idx_r1 < idx_t1
            && idx_t1 < idx_after_1
            && idx_after_1 < idx_r2
            && idx_r2 < idx_t2
            && idx_t2 < idx_after_2,
        "unexpected insertion order: {combined:?}"
    );
}

#[test]
fn extract_reasoning_body_for_translation_requires_header_and_body() {
    use super::super::agent_reasoning_translation::extract_reasoning_body_for_translation;

    assert_eq!(extract_reasoning_body_for_translation("no header"), None);
    assert_eq!(extract_reasoning_body_for_translation("**Thinking**"), None);
    assert_eq!(
        extract_reasoning_body_for_translation("**Thinking**  hello"),
        Some("hello".to_string())
    );
    assert_eq!(
        extract_reasoning_body_for_translation("**Thinking**\n\nhello"),
        Some("hello".to_string())
    );
}
