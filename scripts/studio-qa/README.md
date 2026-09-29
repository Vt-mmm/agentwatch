## Studio layout and background lifecycle · 2026-09-29

The renderer now covers 14 views at 620/860px, including a 460px content height, long member/team labels, light/dark, onboarding, empty-grant tool errors, stale usage and diagnostics. These are production SwiftUI views with synthetic identities, isolated preferences, fake key storage and temporary tool/log roots. It never applies configuration to the owner’s directories. The connected Studio sections are Tools / Usage / Diagnostics; log reading is mounted only in Diagnostics.

Run the built Debug app executable with `--studio-local-acceptance lifecycle` for an isolated native check of retired enrollment preferences, unconditional normal termination, last-window background behavior and macOS login launch-event detection. The probe writes only a temporary audit directory and preferences suite and removes them. `--studio-local-acceptance background-status` is a read-only query of the installed app’s actual Login Items registration. Neither probe sends inference or uploads reports.

[Implementation and acceptance](../../docs/studio-ui-background-update.md). No synthetic screenshot proves an actual logout/login cycle.

# Native Studio connection fixture

Run `bash scripts/studio-qa/build.sh` on macOS with Xcode/Swift 6. Outputs are `.build/studio-ui-fixture/disconnected.png`, `connected.png`, `stale.png` `launcher.png` and `logs.png`. Connected/stale views include the personal ledger dashboard, quota and recent requests with synthetic data; the launcher view is rendered without executing it.

This links the production Swift-package Core and compiles the actual Studio views/theme into a separate NSHostingView renderer. The logs view reads temporary synthetic managed profiles with matched, incomplete and absent-server-evidence cases; those files are removed afterward. The fixture uses in-memory key/settings stores and a synthetic identity/model. It does not launch the main app, collectors, OAuth, inference or CLI, access real employee keys, or mutate personal settings. No screen capture or computer-use service is needed; AppKit renders the fixture view directly.

Images verify layout for the Studio tab only. They do not prove main-window navigation, interactive full-app acceptance, a deployed Studio connection or provider readiness. Swift tests cover real isolated Keychain save/rotation/delete, private scoped file cache and real loopback redirect refusal separately.

The native client can also be run against Studio's actual employee HTTP API and PostgreSQL fixture. Build its probe from this repository:

```sh
xcrun swiftc -swift-version 6 -parse-as-library \
  Sources/AgentWatchCore/StudioClient.swift Sources/AgentWatchCore/StudioDashboard.swift \
  scripts/studio-qa/StudioDashboardProbe.swift -o .build/studio-dashboard-probe
```

In the Studio repo, provide the existing `STUDIO_TEST_DATABASE_URL` for the dedicated test database and set `STUDIO_MAC_DASHBOARD_PROBE` to the absolute probe path, then run `go test -race -count=1 ./internal/httpapi -run TestMacDashboardNativeClient -v`. The Go fixture creates an isolated schema and loopback gateway/connector, passes its temporary employee key through the child environment, and proves a confirmed 15-token fixture request plus an unknown request retain the correct shared quota counters. A second native probe checks revocation. Only fixed assertions are printed. No real provider account or owner runtime is used, and the probe does not use Keychain or app settings.

For the actual CLI command workflow, run `bash scripts/studio-qa/build-cli-probe.sh`, then set Studio's `STUDIO_MAC_CLI_PROBE` to the absolute `.build/studio-cli-probe` path and run `go test -race -count=1 ./internal/httpapi -run '^TestMacCLILauncher$' -v`. The probe injects only test settings/key storage into the production `StudioRunCommand`; native preflight and execution remain unchanged. After both CLI turns it starts a separate `--logs` probe without provider config environment variables, verifies the persisted native session and 30 synthetic local tokens, queries the actual employee session report, and requires a matched comparison to two confirmed requests/30 server tokens. It checks that reading caused no inference. This does not access the real app's defaults or employee Keychain namespace.

`bash scripts/studio-qa/build-terminal-probe.sh` builds a separate Launch Services smoke. Explicitly run `.build/studio-terminal-probe --open-terminal` to open one real Terminal window in the background. It uses the production command-file generator/opener and an inert helper that records literal arguments under a temporary directory. It verifies the pinned profile/arguments and one-use command removal; no provider request or Keychain access occurs. The fixture cleans its own files and does not close the user's Terminal windows. This is handoff evidence, not full app/Keychain/native-interactive acceptance.


Claude compaction regression: the companion Studio test `TestStandaloneCLIStartup/claude/compact` can use this probe's `--launch-plan` mode through `STUDIO_MAC_CLI_PROBE`. That test-only mode returns the production `StudioCLILaunchPlan` arguments and credential-free environment after normal employee metadata/model reads; it never emits the supplied key or executes inference itself. The Go fixture runs that plan in its outer sandbox, adapts print output to a continuous JSON input/output stream, sends two user turns, `/compact`, and another turn, then launches a second CLI process with the saved session. It requires both emitted/persisted compact boundaries, summary-bearing continuation before/after restart, stable SDK account/session binding and five separate synthetic usage settlements. `STUDIO_TEST_NATIVE_POSTGRES=1` starts and cleans an isolated socket-only PostgreSQL instance for these tests. This is not interactive Terminal/full-app or live-provider acceptance.

The Claude launcher intentionally retains built-in commands. Its old `--disable-slash-commands` flag suppressed compaction in pinned Claude Code 2.1.181. Bare mode, empty setting sources, the explicit company settings/MCP configuration and isolated profile remain; default personal CLI configuration is unchanged in regression tests.
