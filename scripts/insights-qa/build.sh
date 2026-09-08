#!/bin/bash
set -euo pipefail
qa_repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$qa_repo_root"
swift build -c debug --product agentwatch
qa_build_dir="$(swift build -c debug --show-bin-path)"
qa_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentwatch-ui-build.XXXXXX")"
qa_app_dir="$qa_output_dir/AgentWatchInsightsReview.app"
mkdir -p "$qa_app_dir/Contents/MacOS"
cat > "$qa_app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.agentwatch.insights-review</string><key>CFBundleName</key><string>AgentWatch Insights Review</string><key>CFBundleExecutable</key><string>AgentWatchInsightsReview</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" -I "$qa_build_dir/Modules" \
  App/Views/TaskInsightsView.swift App/Views/InsightHistoryView.swift \
  App/Views/TaskBindingEditor.swift App/Views/TaskOutcomeView.swift \
  App/Views/SessionLineageView.swift App/Views/TeamReportOverviewView.swift \
  scripts/insights-qa/InsightsQA.swift "$qa_build_dir"/AgentWatchCore.build/*.o \
  -lsqlite3 -o "$qa_app_dir/Contents/MacOS/AgentWatchInsightsReview"
mkdir -p "$qa_app_dir/Contents/Resources"
ditto "$qa_build_dir/AgentWatchCore_AgentWatchCore.bundle" "$qa_app_dir/Contents/Resources/AgentWatchCore_AgentWatchCore.bundle"
codesign --force --sign - "$qa_app_dir"
codesign --verify --deep --strict "$qa_app_dir"
printf '%s\n' "$qa_app_dir"
