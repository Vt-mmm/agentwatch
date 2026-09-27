# Native Studio connection fixture

Run `bash scripts/studio-qa/build.sh` on macOS with Xcode/Swift 6. Outputs are `.build/studio-ui-fixture/disconnected.png`, `connected.png`, `stale.png` and `launcher.png`. Connected/stale views include the personal ledger dashboard, quota and recent requests with synthetic data; the launcher view is rendered without executing it.

This compiles the actual `StudioConnectionView`, theme and core connection sources into a separate NSHostingView renderer. The fixture uses in-memory key/settings stores and a synthetic identity/model. It does not launch the main app, collectors, OAuth, inference or CLI, access real employee keys, or mutate personal settings. No screen capture or computer-use service is needed; AppKit renders the fixture view directly.

Images verify layout for the Studio tab only. They do not prove main-window navigation, interactive full-app acceptance, a deployed Studio connection or provider readiness. Swift tests cover real isolated Keychain save/rotation/delete, private scoped file cache and real loopback redirect refusal separately.

The native client can also be run against Studio's actual employee HTTP API and PostgreSQL fixture. Build its probe from this repository:

```sh
xcrun swiftc -swift-version 6 -parse-as-library \
  Sources/AgentWatchCore/StudioClient.swift Sources/AgentWatchCore/StudioDashboard.swift \
  scripts/studio-qa/StudioDashboardProbe.swift -o .build/studio-dashboard-probe
```

In the Studio repo, provide the existing `STUDIO_TEST_DATABASE_URL` for the dedicated test database and set `STUDIO_MAC_DASHBOARD_PROBE` to the absolute probe path, then run `go test -race -count=1 ./internal/httpapi -run TestMacDashboardNativeClient -v`. The Go fixture creates an isolated schema and loopback gateway/connector, passes its temporary employee key through the child environment, and proves a confirmed 15-token fixture request plus an unknown request retain the correct shared quota counters. A second native probe checks revocation. Only fixed assertions are printed. No real provider account or owner runtime is used, and the probe does not use Keychain or app settings.

For the actual CLI command workflow, run `bash scripts/studio-qa/build-cli-probe.sh`, then set Studio's `STUDIO_MAC_CLI_PROBE` to the absolute `.build/studio-cli-probe` path and run `go test -race -count=1 ./internal/httpapi -run '^TestMacCLILauncher$' -v`. The probe injects only test settings/key storage into the production `StudioRunCommand`; native preflight and execution remain unchanged. This does not access the real app's defaults or employee Keychain namespace.

`bash scripts/studio-qa/build-terminal-probe.sh` builds a separate Launch Services smoke. Explicitly run `.build/studio-terminal-probe --open-terminal` to open one real Terminal window in the background. It uses the production command-file generator/opener and an inert helper that records literal arguments under a temporary directory. It verifies the pinned profile/arguments and one-use command removal; no provider request or Keychain access occurs. The fixture cleans its own files and does not close the user's Terminal windows. This is handoff evidence, not full app/Keychain/native-interactive acceptance.
