#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build --jobs 2 --product agentwatch
bin_dir="$(swift build --show-bin-path)"
xcrun swiftc -swift-version 6 -parse-as-library -I "$bin_dir/Modules" "$bin_dir"/AgentWatchCore.build/*.o scripts/studio-qa/StudioManagedBrokerFixture.swift -o "$bin_dir/studio-managed-broker-fixture"
