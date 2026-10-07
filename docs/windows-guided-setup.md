# Windows: guided setup and macOS UI mapping

Date: 2026-10-07.

## Approach

The Windows setup is a classic manual wizard: explicit choices with explanations, existing configuration retained unless changed, a Back path, credentials validated before proceeding, prerequisites checked separately, and an explicit final apply. Studio keeps its company-managed credential model and continues to own model choice, permissions and quotas.

## Mapping

| macOS source / behavior | Windows implementation |
| --- | --- |
| `App/Theme.swift`: linen surfaces, espresso text, warm orange, cards | WPF resources, sidebar, cards, progress and keyboard focus/disabled states |
| `StudioConnectForm`: connection code or origin + secure key | Step 2 with explicit input mode and masked fields |
| Saved Studio profiles and status strip | Existing-key reuse, active connection card and live verification |
| `StudioConfigurationView`: tools with individual status | Piagent card; direct Claude Code/Codex explicitly described as unavailable on Windows |
| Apply selected configuration | Step 4 review: identity, origin, WSL, models, startup choice; explicit apply |
| Diagnostics/support copy | Native diagnostics with version, public origin, key-presence state and latest check; no key or transcript |
| Keychain | Per-user Windows DPAPI |
| macOS managed runtime | WSL2, non-root account, bubblewrap, Windows interop and recorded Piagent runtime |

## State and failure handling

1. Start: choose a fresh setup or reuse the saved key. Reuse still checks Studio.
2. Credentials: check compatibility, identity and key without saving. Only managed company keys proceed. Changing inputs invalidates both credential and runtime verification.
3. Runtime: choose installed WSL or enter a distro; verify WSL2, normal user, interop, runtime paths/digests, pinned Pi version and bubblewrap. Changing distro invalidates runtime verification. Preparation remains an explicit interactive PowerShell action.
4. Review/apply: save credential, fetch/validate manifest, write hash-pinned binding, save distro and login-start preference. If a later step fails, state remains available for retry and the UI does not claim completion.

All async actions share one busy gate. WSL stdout/stderr drain together with a two-minute deadline. A second app launch activates the existing window. Closing an idle setup clears its unsaved key.

## Installation changes

Synchronized onto upstream `6f2682e`: the GUI remains `AgentWatchApp.exe` and the CLI remains `agentwatch.exe` in the same application directory. The installer's version-feed lookup with API fallback, PowerShell 5.1 compatibility and scoped process-stop/wait/retry behavior are retained. Staging checks both executables before swapping; bad downloads preserve the installed app, a per-user lock excludes concurrent installers, CLI startup failure restores `app.previous`, and an interrupted swap recovers on rerun. Profiles live outside the swapped app directory.

The existing `setup-ubuntu.sh`, restart recovery, Ubuntu user/default-user creation, clock/network handling, UTF-8 and LF handling, existing-model preservation and unattended CI mode are retained. Interactive company credentials move into the native wizard; explicit `AGENTWATCH_CODE` automation remains supported through stdin. Startup preference is chosen at final Apply.

The guided script offers full setup or app-only update, offers selection among existing Ubuntu distributions and retains the reboot/Ubuntu user-creation checkpoints. [Microsoft WSL installation guidance](https://learn.microsoft.com/en-us/windows/wsl/install) and [command reference](https://learn.microsoft.com/en-us/windows/wsl/basic-commands) informed the prerequisite checkpoints. It does not enter keys via process arguments.

Piagent's shared macOS/Linux updater now installs a durable helper when invoked from an npm exec cache even if its version already matches. `--no-host` with an incompatible Pi host fails before mutating either global package.

## Verification boundary

Local: WPF/CLI/core build; core behavior tests; mocked PowerShell installer tests; updater fixtures; Studio TypeScript and browser checks. No native Windows desktop, UAC, reboot, real WSL2 install, ARM64 execution or live Studio-provider inference was exercised on this macOS host. Windows CI includes a native wizard smoke and screenshot artifact; it has not been dispatched from this task. Release binaries and public bootstrap URLs still require a coordinated release before users receive these changes.

Sync validation: 27 core tests passed; WPF/core/CLI Release build completed with zero warnings or errors; installer fixtures passed, including direct version feed, API fallback, checksum rejection, rollback, data preservation and locking. Old `.cache/windows-review` packages predate this integration and must not be shipped. Native Windows checks require CI; the source is not a release.
