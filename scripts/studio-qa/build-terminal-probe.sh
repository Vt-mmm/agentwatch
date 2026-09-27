#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build --product agentwatch
bin_dir="$(swift build --show-bin-path)"
xcrun swiftc -swift-version 6 -parse-as-library \
  -I "$bin_dir/Modules" "$bin_dir"/AgentWatchCore.build/*.o \
  App/StudioTerminalOpener.swift scripts/studio-qa/StudioTerminalProbe.swift \
  -o .build/studio-terminal-probe
