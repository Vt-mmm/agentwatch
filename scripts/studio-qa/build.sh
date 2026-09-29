#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
output="$root/.build/studio-ui-fixture"
mkdir -p "$output"
# Link the production Core and compile actual view files into an isolated
# renderer. It never starts the main app/collectors or reads employee keys.
cd "$root"
swift build --jobs 2 --product agentwatch
bin_dir="$(swift build --show-bin-path)"
xcrun swiftc -swift-version 6 -parse-as-library \
    -I "$bin_dir/Modules" "$bin_dir"/AgentWatchCore.build/*.o \
    "$root/App/Theme.swift" "$root/App/StudioConnectionView.swift" "$root/App/StudioDashboardView.swift" \
    "$root/App/StudioBackgroundService.swift" "$root/App/StudioConfigurationView.swift" "$root/App/StudioLauncherView.swift" "$root/App/StudioTerminalOpener.swift" "$root/App/StudioLocalLogsView.swift" \
    "$root/scripts/studio-qa/StudioConnectionQA.swift" -o "$output/render"
"$output/render" "$output/disconnected.png"
"$output/render" "$output/connected.png" connected
"$output/render" "$output/stale.png" connected stale
"$output/render" "$output/launcher.png" connected launcher

"$output/render" "$output/logs.png" connected logs
"$output/render" "$output/disconnect.png" connected disconnect
