#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
output="$root/.build/studio-ui-fixture"
mkdir -p "$output"
# Compile the production view/core sources into a separate, isolated renderer.
# This executable never starts AgentWatch collectors or reads real app settings.
/usr/bin/python3 - "$root" "$output" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
for name in ['Theme', 'StudioConnectionView']:
    source = root / 'App' / (name + '.swift')
    (output / source.name).write_text(source.read_text().replace('import AgentWatchCore\n', ''))
PY
xcrun swiftc -swift-version 6 -parse-as-library \
    "$root/Sources/AgentWatchCore/StudioClient.swift" \
    "$root/Sources/AgentWatchCore/StudioConnectionStore.swift" \
    "$output/Theme.swift" "$output/StudioConnectionView.swift" \
    "$root/scripts/studio-qa/StudioConnectionQA.swift" -o "$output/render"
"$output/render" "$output/disconnected.png"
"$output/render" "$output/connected.png" connected
