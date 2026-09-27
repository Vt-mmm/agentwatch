# Studio CLI launcher

The local `agentwatch` executable now supports a company-profile launcher. Connect the Mac app to Studio first using an employee key with `me` and `inference` scopes. The launcher reads the app's active profile and its dedicated Keychain entry, verifies the current employee identity and allowed model list, then checks the standalone CLI before starting it.

```sh
agentwatch run claude --model MODEL_ID --project /path/to/project --binary /path/to/claude --check
agentwatch run claude --model MODEL_ID --project /path/to/project --binary /path/to/claude
agentwatch run codex --model MODEL_ID --project /path/to/project --binary /path/to/codex
agentwatch run codex --model MODEL_ID --project /path/to/project --resume SESSION_UUID
```

Use an actual model ID returned by Studio. `--check` reads identity/models and verifies local configuration without inference. `--print TEXT` runs a noninteractive turn; text supplied on the command line can appear in shell history/process arguments. Never put credentials there. No arbitrary CLI flags, endpoint override, key argument or permission-bypass option is accepted.

Binary discovery checks `~/.local/bin`, `/opt/homebrew/bin`, then `/usr/local/bin`. An explicit `--binary` takes precedence. Paths inside a desktop `.app`, including symlink targets, are rejected. The npm Codex wrapper is resolved to its packaged native binary so the launcher does not depend on a global Node installation. No package is installed or updated. The selected binary must report **Claude Code 2.1.181** or **Codex CLI 0.155.1**, the versions currently qualified; other versions fail before receiving the employee key. If a newer personal install is found first, select a qualified standalone binary explicitly or qualify the new version before changing this gate.

Profiles live under `~/Library/Application Support/AgentWatch/StudioProfiles/<origin-org-employee-digest>/<provider>/`. Each has private HOME/config/tmp directories, a versioned manifest and provider config. Directories are 0700 and managed files 0600; redirected paths are refused. Changed manifests/Claude settings are preserved and rejected. Codex may save trust/preferences, so its existing config is preserved and the merged native configuration is checked on every launch. Key rotation for the same identity retains profile history; a different origin/org/employee gets a different directory.

Claude uses `--bare`, empty settings sources, a fixed settings file, strict empty MCP configuration, disabled slash commands/Chrome integration and normal permission mode. The adapter refuses detected system/managed Claude settings until those layers are qualified. Codex uses command-line overrides plus its own `app-server config/read` API to verify the effective model, provider endpoint/env key, Responses wire format, retry settings, sandbox/approval policy and environment policy. Conflicting project endpoint/model/auth fields are overridden by the verified launch settings; unexpected hooks/MCP/plugins/notification/auth/permission configuration is rejected. Preflight has a 10-second deadline and a 1 MiB output ceiling, and receives no employee key.

The launched process gets a clean environment, company HOME/config paths and only the selected provider's employee-key variable. The launcher replaces itself with the native CLI, retaining terminal input/output and signals. It does not write keys to config, argv, URLs, shell commands or diagnostics. Child process environments and local transcript files still belong to the macOS user's trust boundary; this is not isolation from hostile code running as that user. CLI tools can access files allowed by their normal permissions. Project contents/instructions are still available to the native CLI.

The adapters follow the [official Codex configuration reference](https://developers.openai.com/codex/config-reference/) and [Claude environment/settings documentation](https://code.claude.com/docs/en/env-vars); exact installed-binary tests are the compatibility evidence, since current documentation can describe newer releases.

Validation: 243 Swift tests, one existing skip, no failures; unsigned Xcode Debug build; actual production launch-plan text/resume/revoke through real Studio HTTP/PostgreSQL and a synthetic connector. Both CLI profiles retain one SDK session across two invocations, settle 30 synthetic tokens and contain no full employee key. An outer test sandbox permits only the fixture gateway and temporary writes; personal config/auth fingerprints stay unchanged. No live provider request was used.

Still open: app button/bundled helper and cross-binary Keychain interaction, interactive terminal acceptance, company log-root registration, reconciliation with the server ledger, explicit running-session choices on disconnect, managed-Mac qualification, compact/fork and live CLI acceptance. The current fixture supplies a synthetic key through a test-only entry point; it does not claim the full GUI/Keychain-to-Terminal workflow has passed. Codex native upstream output-cap qualification remains a separate server gate. [Evidence](../../agent-studio/docs/evidence/P10-cli-launcher.md).
