# Studio → Agent Watch → coding CLI: one-click synchronization

Status: implemented locally on 2026-09-29. Studio client-config source41d896d is running in Docker; Agent Watch is installed at ~/Applications/AgentWatch.app. Claude/Codex resume and Piagent tool round trips passed live. Current batch38/50 provider starts used,12 remaining; the earlier missing-usage diagnostic remains unresolved. Details and limits: [acceptance evidence](../../agent-studio/docs/evidence/P12-one-click-sync.md).

## Product contract

Member enters Studio API origin and employee key, selects installed target tools, then presses **Kết nối và áp dụng**. Agent Watch resolves identity/team/grants, imports every compatible model granted to that key, selects a valid default, stores the key in Keychain and merges configuration for only the selected tools. No manual model names, provider protocol, context sizes or per-file steps in the normal flow. Display per-tool success and any concrete action needed; failed tools must never be labelled configured.

Studio remains the authority for accounts, team membership, keys, entitlements, routing and accounting. Agent Watch is a local configuration/sync client, not an inference proxy. Coding CLI requests go directly to Studio, then its pinned connector and provider. Closing the visible Watch window must not interrupt configured CLI authentication; headless credential reads use the installed app executable. OAuth credentials remain on Studio.

## Implemented baseline and remaining compatibility limits

Watch retains /capabilities, /me and /models for identity/dashboard discovery and adds /studio/v1/client-config for stable grants. The form connects and applies selected tools in one action; the app-lifetime coordinator refreshes all compatible granted models, conditional on ETag, at startup, network recovery, wake and every300–320seconds. Pi/Piagent share a plan when their configuration directory is the same.

Studio already observes connector account/model inventory periodically and imports account-advertised models. Its native connector and bundled metadata still have separately versioned compatibility requirements. Polling inventory cannot automatically implement a new wire protocol or update an old CLI's native capabilities.

## Bootstrap API

Authenticated GET /studio/v1/client-config is available on the inference origin and reuses existing identity/grant resolution. Read-only discovery neither reserves quota nor dispatches inference. The response includes schema/revision, identity, expiry, granted models and the filtered pinned Codex catalog. Endpoint layout is owned by local adapters; arbitrary remote paths or commands are not accepted.

The coherent snapshot contains schema_version, revision/ETag, org/user/team/key identity (nonsecret IDs), credential expiry, model grants, native model IDs, supported native protocols, context mode, Codex catalog and recommended refresh time. Client compatibility checks/default selection are performed by the local versioned adapter; they are not additional fields currently returned by the manifest. Never return the raw key, OAuth credentials or account-private identifiers. Base URL is derived from the exact origin the user trusted, with validated relative paths; remote metadata is not authority to send the key to another host.

Maintain distinct granted models and current availability. Granted models stay in client config when an account temporarily cools down, runs out of quota, or upstream is offline. Revocation, explicit grant removal or retirement changes the granted catalog. Runtime readiness changes update status, not every config file. The server rechecks authorization and account eligibility on every inference; local config is never enforcement.

/v1/models remains the provider-compatible discovery surface and must reflect the caller's authorized native model IDs with a protocol-appropriate envelope. Watch uses the richer bootstrap contract to avoid confusing transient availability with permission changes. Existing /me/key-models inspection may supply reused grant resolution but is not itself a full bootstrap manifest.

A key can allow many models. It cannot be decoded locally to discover those grants. Authentication resolves key→owner/team→pool/grant in Studio. New catalog models do not silently widen a key with an explicit model selection. If desired, add one clear issuance option, 'Tất cả model tương thích của team, kể cả model mới'; only that explicitly chosen grant mode follows new models automatically.

## Target adapters

| Target | Selected configuration | Catalog behavior |
|---|---|---|
| Claude Code | user settings.json: endpoint, app-owned apiKeyHelper, native default and version-supported discovery settings | only granted Claude/Messages-compatible models; gateway discovery where supported; respect existing managed settings |
| Codex CLI | user config.toml: custom Responses provider, command-backed auth, native default; generated catalog file when the CLI schema supports it | export supported granted Codex models using Codex catalog schema, not a raw /v1/models response |
| Pi | agent directory models.json and relevant settings/session extension | both provider families, explicit anthropic-messages/openai-responses mapping, all compatible granted models |
| Piagent custom | resolve its actual Pi runtime/config directory, retain guard/WebUI extensions and provider-aware routing | share the same generated provider/model records when it shares Pi's directory; never write the same file twice |

API compatibility alone does not mean every coding-client feature works. Version-test streaming, tools, cancellation, reasoning, images and compaction independently. Do not route a Claude session to a Codex model merely because a converter exists. Pi can expose both families explicitly.

Use native model IDs and provider/client defaults for context and compaction. Output allowance is a separate field. Where a generated catalog requires numeric model metadata, use verified, versioned native metadata; an unknown model must be marked as awaiting client compatibility instead of receiving guessed context limits. Do not install a stale complete catalog that replaces newly shipped native behavior without version checking.

## Apply and ongoing sync

Detect tool version and actual user/config directory before preparing changes. Select no tool by default on first connect; remember the user's previous selections. Existing CLI profile/environment/project overrides are reported as conflicts, not silently replaced. Pick the administrator-provided default only if permitted and compatible; otherwise preserve the member's valid selection or use a stable compatible default. Import all models independently of choosing one default.

Generate all selected changes first, validate schemas and paths, back up original affected values, then apply atomically per file with durable receipts and compensation if a later write fails. Repeated application is idempotent. Merge owned keys only; preserve hooks, MCP, projects, personal providers and unrelated settings. Coalesce Pi/Piagent targets sharing a path. Conflicts require one specific resolution, not repeated normal-flow confirmation.

After initial one-button setup, enable lightweight selected-target sync while the app/background helper is running: at login/app start, network recovery, key change, and a bounded periodic interval (5minutes with jitter and ETag). Do not scan every home directory or rewrite unchanged files. Sync still works with the visible window closed only if the background component is enabled; never promise synchronization while the machine is asleep or the component is stopped.

Active sessions keep their model/context until the CLI supports a safe reload; new catalog/default changes normally apply to new sessions or the native model-picker reload. Key revocation is effective on the server immediately, even before local sync. On offline/5xx keep the last good configuration and show stale status. On401/expiry disable Studio credential retrieval and ask for a replacement key without deleting unrelated CLI credentials. A rotated key is revalidated against its identity/team before reusing settings.

App installation/update must provide a stable executable path and signing identity for Keychain helper access. OS permission prompts cannot be silently bypassed. Agent Watch does not import executable commands or arbitrary destination file paths from the server: local versioned adapters own those decisions.

## Upstream update lifecycle

Separate three updates: account inventory/entitlement discovery, model metadata/catalog refresh, and executable provider/client compatibility releases. Inventory and validated catalog data can refresh automatically. Engine/client code changes go through pinned versions, regression checks and rollback-capable release. Merely tracking upstream main or adding a model name is not evidence that new tools, streaming or context semantics work.

## Acceptance gates

1. Fresh member supplies URL/key, checks one or more tools and applies once; files and model pickers match the grant, with no inference needed to configure.
2. A mixed Claude/Codex grant yields correct per-tool catalogs; Piagent/Pi shared paths are handled once.
3. New explicitly granted model syncs; an ungranted new model stays absent. Account cooldown does not delete model config.
4. Wrong/revoked/expired key, empty grant, protocol/version mismatch and offline sync produce clear, truthful states without corrupting prior files.
5. Existing personal config, symlinks, managed config, active profiles, write failures and user edits have safe conflict/restore behavior.
6. Real CLI tests cover both providers, model switch, tool/result continuation, session resume, streaming/cancel and ledger/team attribution. The corrected durable-completion path passed a clean Codex tool round trip; Piagent Claude also passed. These cover the installed versions and selected models, not every provider feature.
7. Cold start, closed visible Watch window, app update, key rotation and multiple selected tools retain a working credential helper. Large context/compaction is a separate acceptance gate, not implied by a two-turn test.

## Source checks

- OpenAI configuration reference: https://developers.openai.com/codex/config-reference (custom Responses provider, command-backed auth, model_catalog_json loaded at startup).
- Claude environment reference: https://code.claude.com/docs/en/env-vars (CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY; feature/version support must be tested against the installed CLI).
- Claude gateway guidance: https://code.claude.com/docs/en/llm-gateway (gateway protocols and compatibility maintenance).
- Installed Pi0.87.1 docs/models.md: models.json supports compatible endpoints, model lists, credential commands and native model-picker reload. Installed Piagent1.8.0 was inspected separately from the owner's dirty1.6.1 source checkout.

## Using the installed local build

Open ~/Applications/AgentWatch.app → Studio. API origin is http://127.0.0.1:17922; the dashboard at17920 is not the inference origin. Paste the employee API key, select installed tools, then **Kết nối và áp dụng**. All selected tool results must be green before opening a fresh CLI session. Tool directories and restore are under **Thư mục và khôi phục**. No personal tool is selected automatically.

The real installed app reports Login Items enabled and remains running after its main window closes. Signing/distribution, actual logout/login recovery, large-context compaction and additional CLI/model versions remain separate acceptance gates. Owner update, 2026-09-29: machine enrollment/unlock keys and quit restrictions have been removed. Studio API authentication remains. Existing report IDs and folder bindings are retained without key entry; closing the window keeps the app running, while Quit exits normally. See studio-ui-background-update.md.
