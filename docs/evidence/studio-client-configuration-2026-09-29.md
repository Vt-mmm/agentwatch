# Studio → Agent Watch → standalone CLI acceptance

Status: implementation built and tested locally; real-provider basic flows and Claude resume passed. Full app UI / ordinary-terminal acceptance remains open.

## Delivered implementation

Agent Watch's Studio screen prepares and applies saved configuration for Claude Code, Codex CLI and Pi, with tool/model selectors and guarded restore. Files contain a credential command, not the employee key. The credential command checks the active profile and reads its Keychain item. The final design invokes the main app executable in a headless credential mode before SwiftUI/collectors initialize, keeping Keychain ownership with the application. This final app-owned path is built, but has not yet passed live acceptance.

Backups are private and preserve the original contents across repeated applies. An external edit prevents overwrite/restore. Failed writes that fully roll back also restore the previous backup receipt. Symlinks, unsafe files and ambiguous TOML layouts are rejected. The optional old launcher is collapsed below the main setup flow.

## Context contract

Studio exposes native `provider_model_id`, explicitly resolved `client_model_id`, `context_mode=provider_default`, effective output allowance and output-accounting mode. Historical IDs such as `claude-local` keep their grants; account sync creates the native-name alias only when that name is unclaimed. Clients require a verified native mapping.

Claude/Codex use native model names with no generated context-window or compaction-size override. Applying configuration removes known saved context overrides, which remain in the restore backup. Pi copies context metadata from its installed 0.87.1 native provider catalog; unknown layouts/models fail instead of guessing. Output limits remain separate: Claude's wire output cap respects Studio's allowance; Codex settles observed usage and Pi's Responses adapter omits unsupported `max_output_tokens`.

Observed live: Claude Haiku 4.5 reported a 200,000-token context during resume. Its native output metadata reported 32,000, while the generated request cap is 16,384; these are different quantities. Pi's installed Codex catalog reports a 272,000 context and 128,000 native output maximum. This is not a full-window or compaction performance benchmark, nor qualification of every model.

Reference: [Claude model/context configuration](https://code.claude.com/docs/en/model-config). Project/environment overrides outside the selected files can still take precedence and require effective-runtime verification.

## Real provider evidence

The initial successful runs used the production config writer, real Studio APIs, Keychain storage and real installed CLIs, with an acceptance binary as credential reader. They do not establish that the final app-owned credential entry point or UI clicks have passed.

| Flow | Provider starts | Confirmed tokens | Result |
|---|---:|---:|---|
| Claude Code / Haiku | 1 | 6,239 | Response, team/model/session accounting passed |
| Codex / GPT-6-luna, diagnostic | 1 | unknown | Response succeeded; usage seal missing; remains unresolved |
| Codex / GPT-6-luna, after fix | 1 | 12,002 | Response and accounting passed |
| Pi / Claude | 1 | 685 | Response and accounting passed |
| Pi / Codex | 1 | 423 | Response and accounting passed |
| Claude Code reopen/resume | 2 | 12,772 | Marker remembered; same session digest; both usages confirmed |

Total: **7/20 newly authorized starts**, 32,121 confirmed tokens across six requests and one unresolved diagnostic request. Persistent trial journal: 19 starts including 12 historical; ceiling 32; 13 remain. Failed credential/setup checks consumed no provider starts. All temporary Studio members were disabled and issued keys revoked; successful test profile cleanup restored its predecessor.

Studio request IDs: `0f159cba-cbbb-4ce1-9de4-cbc70202c792`, diagnostic `27616800-1091-4fbb-b6f9-a565fecab168`, `6840c51a-dcc3-49d6-9aac-2268969ad753`, `3c562cfb-1cfc-4dd8-a414-5c8c9965c308`, `dc2be822-f8c7-4672-acd8-7c006593edec`, resume `4bd9c80c-3378-4f36-97c1-1d279c2cdf1b` and `89768e2d-a057-4877-9536-1e88807f519d`.

## Bugs found by actual clients

1. Claude apiKeyHelper sends the identical key in Authorization and x-api-key. Studio now accepts exact agreement and rejects conflicting/repeated credentials.
2. Codex closes on `response.completed`, which raced connector usage sealing. The connector now persists the usage seal before exposing the terminal frame. Intermediate frames still stream. Cancellation-on-terminal and execution/events race tests pass. The previous unknown request is not retroactively fabricated or forced to zero.
3. Separate ad-hoc app/helper binaries do not automatically share macOS Keychain signing partitions. The attempted ACL approach was discarded. Final implementation uses the application's own executable for headless credential reads and refuses hidden interactive prompts.

## Validation and remaining gates

- PostgreSQL-backed account/ledger/HTTP API race suites passed.
- Connector execution/events race tests passed, including terminal disconnect.
- Swift Studio suite: 71 tests, 70 passed, one opt-in native test skipped; Xcode Debug build passed. Native preflight had separately passed earlier in the slice.
- Native UI fixture rendered and inspected. This is layout evidence, not interactive app acceptance.
- Both Studio and connector clean-context Docker builds/upgrades passed health and ingress isolation. Docker Desktop itself was not restarted.
- A **synthetic Keychain ACL diagnostic** (`keychain-helper-qa`) is waiting in a macOS authorization dialog. User was asked to cancel it so its deferred cleanup restores the original profile and deletes its synthetic item. No password or permission grant is needed. Do not kill/recompile that binary or overwrite the active profile before cleanup is confirmed.
- Final app-owned credential flow, Codex/Pi resume, tool execution, actual custom Pi platform extensions, key rotation/revocation through configured clients, and interactive UI acceptance remain pending.
- Custom Pi source and installed platform have different versions; no owner changes or global installation were overwritten. The successful Pi runs qualify base Pi 0.87.1 plus the generated session extension, not the full custom platform.

## Reproduction after the pending diagnostic is cancelled

Build the Debug app with Xcode. The local-only Debug acceptance entry point creates/restores a temporary profile and uses the production client/configuration code; it is excluded from Release. From the sibling Agent Studio repository run `node scripts/live-client-config-e2e.mjs <flow> [basic|resume]`, where flow is `claude-claude`, `codex-codex`, `pi-claude` or `pi-codex`. The driver uses the existing persistent allowance and never increases it. Reports contain selected metadata only, under Studio `.cache/client-config-live-*.json`; raw keys are supplied on stdin and not logged.


## App-owned credential acceptance after Cancel (2026-09-29)

The synthetic Keychain diagnostic exited after the user cancelled. Its deferred cleanup ran. The first final-app prepare still failed before inference because the test replaced HOME, redirecting macOS Keychain resolution. The driver now retains the login HOME and isolates each CLI through CLAUDE_CONFIG_DIR, CODEX_HOME and PI_CODING_AGENT_DIR. No Keychain ACL override is used.

Real final-app credential checks passed, followed by two-turn memory/session/usage checks for Claude Code, Codex, Pi→Claude and Pi→Codex. All eight new requests confirmed the expected team and model; each profile was restored and temporary member disabled. Native observed context: Claude Haiku 200,000; Codex CLI effective 258,400; Pi Codex native catalog 272,000. These reflect different native client accounting, not an imposed shared context limit. No full-window/compaction acceptance claim.

Installed Piagent 1.8.0 core guard and WebUI extensions were explicitly loaded for one real basic request per provider, both successful, with no extension-load errors observed. This qualifies basic CLI coexistence; it does not qualify every guard workflow or WebUI interaction, and does not change the owner's dirty Pi source tree.

Tool probe: Pi with both platform extensions completed a real read-tool round trip against Codex, with two confirmed requests (1,262 tokens). However, two intervening 503 session_account_busy_retry_later responses occurred before Pi recovered. The final answer contained the file marker but added text. The original driver's pass flag was too weak; this result is **recovered tool execution, not clean tool acceptance**. The driver now requires no intermediate error events and an exact final assistant reply. Revoking the test member made the former key return 401 on /v1/models without another provider start.

The gateway now refreshes durable connector completion evidence once (bounded to two seconds) when an existing session's account appears busy, then rechecks normal admission. It neither replays inference nor releases capacity from transport success. A real PostgreSQL regression covers completed evidence, seal-only evidence, no evidence and unavailable connector; unresolved usage retains its budget holds. Focused and full HTTP API race suites passed. Local image rollout and a post-fix live two-call tool rerun are not yet evidenced at this checkpoint.

Budget: **19/20 newly authorized provider starts**, persistent journal31/32, one remaining. Across this batch, 18 requests have confirmed usage totaling74,040 tokens; the earlier Codex diagnostic remains unresolved. Do not use the one remaining start for a two-call tool test or silently extend the budget.

New request IDs by flow:
- Codex resume:654d94ac-8b73-4a0e-a651-6f133eebbc39,8cd27534-ca6a-4cf0-85bc-1c122f1d7e87.
- Claude resume:9afbb439-e70f-4f6b-a95b-b0112d8b7c42,3620cd23-d329-4687-beee-b632c56401a6.
- Pi Claude resume:879d4462-4256-407e-ba00-ef879b97c75e,3275c848-afde-415d-9b3d-e6c290c0fa03.
- Pi Codex resume:bbdc9b99-5b52-4bfb-9d49-2c0422eaae19,d46fd05a-29d1-44c1-a22a-b95557dbd591.
- Pi platform Codex:41317422-56d4-4ef7-990d-bec798441eab; Claude:d2cf8ada-465e-41b3-9394-25fead920d3e.
- Pi tool:4b656e35-dc43-4973-8440-07f3db22e424,e3bb9a13-8b13-4706-9ac6-be3695007f83.
