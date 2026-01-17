use codex_core::WireApi;
use codex_core::config::Config;

use std::path::Path;

use crate::sandbox_summary::summarize_sandbox_policy;

/// Build a list of key/value pairs summarizing the effective configuration.
pub fn create_config_summary_entries(config: &Config, model: &str) -> Vec<(&'static str, String)> {
    let mut entries = vec![
        ("workdir", config.cwd.display().to_string()),
        ("model", model.to_string()),
        ("provider", config.model_provider_id.clone()),
        ("approval", config.approval_policy.value().to_string()),
        (
            "sandbox",
            summarize_sandbox_policy(config.sandbox_policy.get()),
        ),
    ];
    if config.model_provider.wire_api == WireApi::Responses {
        let reasoning_effort = config
            .model_reasoning_effort
            .map(|effort| effort.to_string());
        entries.push((
            "reasoning effort",
            reasoning_effort.unwrap_or_else(|| "none".to_string()),
        ));
        entries.push((
            "reasoning summaries",
            config.model_reasoning_summary.to_string(),
        ));
    }

    if let Some(translation) = &config.agent_reasoning_translation {
        let mut label = translation
            .command
            .first()
            .cloned()
            .and_then(|arg| {
                Path::new(&arg)
                    .file_name()
                    .and_then(|s| s.to_str())
                    .map(std::string::ToString::to_string)
            })
            .unwrap_or_else(|| "enabled".to_string());
        // 常见场景：`python3 /path/to/script.py`，用脚本文件名提示当前启用的插件。
        if translation.command.len() > 1 {
            let arg = &translation.command[1];
            let arg_display = Path::new(arg)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or(arg)
                .to_string();
            label = format!("{label} {arg_display}");
        }
        if translation.command.len() > 2 {
            label = format!("{label} (+{} 参数)", translation.command.len() - 2);
        }
        entries.push(("reasoning translation", label));
    }

    entries
}
