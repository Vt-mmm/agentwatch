# Company CLI local logs

Agent Watch's Studio tab reads the selected company profile's local sessions independently of the server usage dashboard. The launcher's existing `profile.json` under `~/Library/Application Support/AgentWatch/StudioProfiles/<origin-org-employee-id>/<provider>/` is the registry. No terminal environment or second registration store is required; an app started from Dock uses the same path and active connection settings.

The reader validates the manifest's version, identity, provider and exact managed root, then scans Claude `config/projects` (including nested subagents) and Codex `config/sessions` plus `config/archived_sessions`. Existing personal/default log collectors remain unchanged. Other Studio identities are excluded; local results are cleared on disconnect/profile change and never added to Studio quota, server usage or personal automatic exports.

Existing Claude/Codex parsers and `SessionAccounting`/`UsageLedger` supply local metadata and accounting. Physical hardlinks and logical session copies are deduplicated within the provider/profile. Missing usage stays unknown; malformed records, partial copies, overflow and scan limits remain partial. The view shows the latest 20 sessions in the current local-calendar month with provider, project, session ID, model and local token subtotal. No prompt/event content is returned to this panel or persisted in a new cache.

A utility task bounds each scan to 1,000 files, 20,000 enumerated entries, 256 MiB total and 64 MiB per file. Reads stop at each file's initial size; size/modification changes mark the snapshot incomplete. Symlink components are refused. These checks are accidental-redirection protection, not an adversarial filesystem sandbox against another process running as the same OS user.

Every row currently says **Chưa đối soát**. This is source separation, not server reconciliation: no request/session match is inferred from similar model/time/token totals. P10.6 still requires an employee-scoped authoritative correlation contract. Local estimated cost never overwrites server measurements.

Validation and limitations: [P10 log evidence](../../agent-studio/docs/evidence/P10-local-logs.md). Actual standalone CLI fixtures create and resume logs under isolated company profiles; a separate clean process reads them without `CLAUDE_CONFIG_DIR` or `CODEX_HOME`. Native rendering uses synthetic metadata. This does not replace full installed-app Dock/Keychain acceptance or live provider/CLI acceptance.
