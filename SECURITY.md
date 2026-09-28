# Security Policy

This repository is a fork of [openai/codex](https://github.com/openai/codex)
with additional downstream developer-tooling changes.

## Reporting

- For issues that reproduce in upstream Codex, use the reporting process
  provided by the upstream project.
- For issues introduced by this fork's downstream translation-plugin work,
  please avoid posting sensitive vulnerability details in a public issue.
  A minimal non-sensitive report can be used to establish contact for a
  private follow-up.

## Downstream scope

The custom code in this fork focuses on the optional AgentReasoning translation
plugin and supporting developer tooling. Security-related testing of this fork
is limited to software and systems that I own or am authorized to analyze.

## Privacy note

The translation hook can pass model output, code snippets, paths, or other
context to an external command. Users should treat the configured translator as
part of their trust boundary and choose a local or approved service when the
content is sensitive.

See [README.fork.md](README.fork.md) for downstream attribution and feature
documentation.
