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
