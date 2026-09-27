# Agent Studio integration progress

Studio lives in the separate local repository at `/Users/vtamm/Documents/Claude_management/agent-studio` on `codex/agent-studio`.

Canonical task ledger: [Studio implementation progress](../../agent-studio/docs/implementation-progress.md).

Agent Watch work branch: `codex/agent-studio-integration`; baseline commit `dc6d920e28acfa20aa1c5d78c83755997c228806`. Existing six user documents remain untracked and unchanged. Bundle ID, Sparkle identity, app behavior and default CLI/desktop settings remain unchanged at the P00/P01 checkpoint.

Baseline verified 2026-09-27: Swift 210 tests, 1 skipped, zero failures; Xcode Debug unsigned build succeeded. Evidence is in the Studio repository. P09/P10 app changes have not started.

P01 local OAuth UI is available at http://127.0.0.1:17820 while the harness runs. Owner requested Claude first, maximum five initial live inference requests, and performs OAuth personally through explicit UI buttons. No provider credential belongs in this file or chat. OAuth/CLI/tunnel/pilot remain separate acceptance gates.
