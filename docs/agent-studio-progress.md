# Agent Studio integration progress

Studio lives in the separate local repository at `/Users/vtamm/Documents/Claude_management/agent-studio` on `codex/agent-studio`.

Canonical task ledger: [Studio implementation progress](../../agent-studio/docs/implementation-progress.md).

Agent Watch work branch: `codex/agent-studio-integration`; baseline commit `dc6d920e28acfa20aa1c5d78c83755997c228806`. Existing seven user documents remain untracked and unchanged. Bundle ID, Sparkle identity and default CLI/desktop settings are preserved.

Baseline verified 2026-09-27: Swift 210 tests, 1 skipped, zero failures; Xcode Debug unsigned build succeeded. Evidence is in the Studio repository.

P09 connection checkpoint, 2026-09-28: native Studio tab (⌘4), typed read-only client, public API-version check before credentials, employee identity/models, isolated device-only Keychain storage, URL/profile-only preferences, refresh/rotation/disconnect and explicit stale memory snapshot. A single active profile is supported; disconnect before changing origin/identity. Invalid credentials or changed identity clear the previous snapshot. Late responses cannot restore a disconnected key/profile.

Validation: Swift **226 tests, 1 existing skip, 0 failures** (16 Studio tests); Xcode 26.5 / Swift 6.3.2 arm64 unsigned Debug build passed. Real fixture Keychain save/rotation/isolation/delete and real loopback HTTP redirect refusal passed. The actual native connection view was rendered and inspected with synthetic data via `bash scripts/studio-qa/build.sh`. [Evidence and limits](../../agent-studio/docs/evidence/P09-mac-connection.md).

P09 usage/quota/request dashboard, persistent scoped usage cache, full-app/deployed connection acceptance and P10 company CLI launcher remain open. Existing Sessions/Tasks/coaching/pets/reporting code is preserved; Studio metadata is separate from local token/cost totals and supervisor enrollment.

P01 local OAuth UI is available at http://127.0.0.1:17820 while the harness runs. Owner requested Claude first, maximum five initial live inference requests, and performs OAuth personally through explicit UI buttons. One live request has been used; this Mac checkpoint sends no inference. No provider credential belongs in this file or chat. OAuth/CLI/tunnel/pilot remain separate acceptance gates.
