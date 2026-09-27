# Native Studio connection fixture

Run `bash scripts/studio-qa/build.sh` on macOS with Xcode/Swift 6. Outputs are `.build/studio-ui-fixture/disconnected.png` and `connected.png`.

This compiles the actual `StudioConnectionView`, theme and core connection sources into a separate NSHostingView renderer. The fixture uses in-memory key/settings stores and a synthetic identity/model. It does not launch the main app, collectors, OAuth, inference or CLI, access real employee keys, or mutate personal settings. No screen capture or computer-use service is needed; AppKit renders the fixture view directly.

Images verify layout for the connection tab only. They do not prove main-window navigation, interactive full-app acceptance, a deployed Studio connection or provider readiness. Swift tests cover real isolated Keychain save/rotation/delete and real loopback redirect refusal separately.
