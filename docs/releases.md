# Release maintenance

Each distributed build gets an immutable version, Git tag, downloadable app/CLI, checksums and a signed Sparkle feed entry. Pushing source alone does not update installed apps.

1. Update `MARKETING_VERSION` and the monotonically increasing `CURRENT_PROJECT_VERSION` in `project.yml`; write `docs/release-VERSION.md`. Run the relevant tests, commit and push `main`.
2. On the signing Mac, run `./scripts/release.sh VERSION prepare`. It builds a universal macOS archive with two build workers, checks the bundled CLI, and signs the ZIP using the existing Sparkle Keychain key. Private keys are never exported. The signature must verify against the public key already embedded in installed apps.
3. Run `./scripts/release.sh VERSION publish`. It rechecks source/artifact hashes, pushes the immutable tag, uploads and verifies draft assets, publishes the release, then commits/pushes the feed. The feed never points to an incomplete draft.

Artifacts and build logs are in ignored `Releases/VERSION/`. A failed upload leaves a draft for inspection; do not replace an already published artifact or signing identity. Prepare a new version for changed app contents. A failed feed push can be retried with `git push origin main` after resolving the branch conflict without replacing the release.

Members use **Check for Updates…**; automatic checks run hourly while the app is running. Native Keychain signing keeps publication on the signing Mac rather than exporting its private key to CI.
