# Studio layout and keyless Agent Watch lifecycle

Implemented locally on 2026-09-29, following the owner's request to simplify Studio and subsequent explicit removal of Agent Watch's old enrollment/unlock mechanism.

## Studio UI

- Persistent compact account header: verified member, team, origin, refresh and connection menu.
- Three sections: **Công cụ**, **Usage**, **Chẩn đoán**. Four CLI cards in a consistent 2×2 grid; one apply action. No tools are preselected on a real fresh installation.
- Selected tool state is separate from account authentication. Changed selection/directory invalidates prior results; offline sync cannot keep a current success badge. Background responses from a previous selection/disconnect cannot repopulate the UI.
- Model list, paths/restore, quota windows and request IDs are disclosures. Restore remains accessible for deselected tools. Deselecting stops synchronization; it does not silently undo installed configuration.
- Local CLI log reading and the optional isolated launcher are under Diagnostics, not mounted on the normal Tools screen. Native provider context/catalog handling is unchanged.

## No app-open or quit key

The enrollment sheet, lock/menu buttons, bundled enrollment/unlock verifier table and key-gated startup/termination code were removed. Normal Cmd+Q records a clean exit and terminates. Closing the window leaves app/background synchronization running. Existing SMAppService registration is reused; the Settings menu links to macOS Login Items. A login launch is recognized using Apple's launch-event property and starts hidden without taking focus.

Studio employee API keys remain in Keychain and are still checked by Studio. Removing a local supervisor key does not broaden model/team/API permissions. Previously stored local report IDs/names are retained, preserving existing report history and Google folder bindings. A fresh machine receives a stable opaque local report ID without authentication or key entry. This local report ID is not a Studio employee identity. Report delivery still requires its existing review/Google authorization; this update sends no reports.

Legacy audit event names, heartbeat fields, and the historical `SupervisorLockStore` type/file remain for decoding old records. They do not control access. Coverage reports now describe missing observation, not a failure to enter a key. The old lock preferences are removed when the new app starts; activity/audit/report data is preserved.

## Regression found during actual app acceptance

The URLSession transport rejected every 3xx response, including **304 Not Modified**. The conditional-manifest client expected 304, but its test transport bypassed that production rejection. After the first background synchronization the real app therefore showed a false redirect error. The transport now passes 304 to the manifest client, which requires a valid cached manifest; real redirects remain blocked and credentials are never forwarded. A real loopback HTTP test covers initial 200, conditional 304 and authorization failure after caching.

A subsequent local app replacement exposed a second startup issue: the connection-store initializer synchronously requested interactive Keychain access on the main thread. Sampling confirmed it was blocked inside SecItemCopyMatching before the app finished opening. Initialization and automatic view refresh now read noninteractively using LAContext plus a scoped legacy macOS Keychain UI guard (the legacy login-keychain backend ignored the former per-query flag); macOS approval can be requested by the explicit connection-refresh action. The app and background services can start even while credential access needs approval. No Keychain ACL or macOS security requirement was bypassed.

## Validation

- Xcode Debug build passed; installed GUI and credential helper match the built files; deep signature verification passed.
- `swift test --jobs 2 --filter 'Studio|Report|DailyActivity'`: **155 executed, 153 passed, 2 opt-in skips, 0 failures**. Skips are installed standalone-CLI qualification and real-day report export; no report was uploaded.
- Native lifecycle probe passed with temporary preferences/audit storage. Tests also preserve legacy report identity/folder binding, generate stable new local identity, reject corrupt IDs, isolate reconnect preferences, cancel stale synchronization and handle 304 through the actual URLSession transport.
- 14 native rendered fixtures generated. Narrow (620px), short (460px content), long-name, dark, stale usage, error and diagnostics layouts inspected; representative synthetic screenshots are in `evidence/studio-layout/`.
- Installed app opened Studio with the existing account/team and no supervisor-key sheet. Actual Usage UI displayed its existing 3 requests / 27,191 confirmed tokens. Closing the main window retained the same process; Cmd+Q produced a clean-quit audit event followed by the UI inspection tool reopening the app, without a key prompt.
- Installed app query returned `login_item_enabled`. Login launch-event handling is exercised synthetically; an actual logout/login or reboot was not performed.
- Trial journal stayed **53/62, 9 remaining**. No inference, Docker Desktop restart, external deployment or report delivery was performed.

Installed location: `~/Applications/AgentWatch.app`. Previous bundles remain under `.build/installed-app-backups/`. Build/test logs are `.build/watch-unlocked-xcode.log`, `.build/watch-unlocked-tests.log`, `.build/studio-ui-refresh-render.log`.

[Focused upstream management review](../../agent-studio/docs/management-upstream-review-2026-09-29.md).

Apple reference: [Launch Apple Event Constants](https://developer.apple.com/documentation/coreservices/apple_events/1556410-launch_apple_event_constants) describes the login-item launch event used by the native delegate.

Keychain implementation references: [Apple UI authentication context](https://developer.apple.com/documentation/security/ksecuseauthenticationuifail), [macOS Keychain interaction controls](https://developer.apple.com/documentation/security/keychains). The prior interaction setting is restored after each background read and covered by a regression test; no item ACL is modified.

## Final installed state

The final installed build starts successfully with the existing Keychain item still protected. Actual AX/screenshot inspection shows the new Studio tab and **Cho phép Keychain** action; no enrollment sheet is present and the app continues emitting background heartbeats. Login Items remains enabled. macOS requires the owner to authorize this locally rebuilt app to read the existing Studio key. Final real-server reconnection/sync therefore remains pending that OS approval; it is not claimed successful from the loopback 304 test. The owner was directed to the explicit button; no password, key, ACL or provider credentials were extracted or changed.

## Source update — 2026-09-29

Version 0.12.0 adds reviewed Sonnet 5.5 metadata for Pi 0.87.1, preferring an installed native catalog entry when available. Unknown IDs remain unsupported. Claude/Codex context defaults remain native. Added explicit Sonnet 5.5 and Opus 5.5 reference prices. Verification: 170 passed, two opt-in live checks skipped; macOS Release build passed. No paid provider requests were made for this update.
