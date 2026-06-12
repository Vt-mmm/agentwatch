# Claude Watch Mac

Native macOS menu bar + window app theo dõi Claude Code sessions. Auto-detect session đang chạy (hoặc pin 1 folder cụ thể), live tokens / cost / subagent tree, refresh mỗi 1s.

App chạy **local only** — không có hosted distribution, mỗi dev tự clone về build trên máy mình.

## Yêu cầu

- macOS 14+ (MenuBarExtra requirement)
- Xcode 16+ với Command Line Tools (`xcode-select --install`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Setup lần đầu

```bash
git clone <repo-url> claude-watch-mac
cd claude-watch-mac

# 1. (Optional) Verify core library + unit tests
swift build
swift test

# 2. Generate Xcode project from project.yml
xcodegen generate

# 3. Build the .app
xcodebuild -project ClaudeWatchMac.xcodeproj \
           -scheme ClaudeWatchMac \
           -configuration Debug build

# 4. Copy built bundle vào Releases/ rồi mở
SRC=$(find ~/Library/Developer/Xcode/DerivedData \
       -name ClaudeWatchMac.app -path "*Debug*" | head -1)
mkdir -p Releases && rm -rf Releases/ClaudeWatchMac.app
ditto "$SRC" Releases/ClaudeWatchMac.app
open Releases/ClaudeWatchMac.app
```

Build ad-hoc signed (không cần Apple Developer account). Gatekeeper có thể prompt lần đầu → right-click `Open`.

## Hoặc dùng Xcode trực tiếp

```bash
xcodegen generate
open ClaudeWatchMac.xcodeproj
# ⌘R để run từ Xcode
```

## Cách dùng

1. Mở app → icon Claude sparkle xuất hiện trên menu bar (top right) + cửa sổ chính.
2. **Default**: app tự follow session JSONL mới nhất từ `~/.claude/projects/` — không cần làm gì, mở 1 phiên Claude Code lên rồi check app.
3. Hoặc bấm **Pin folder…** để khoá theo 1 project folder cụ thể; bấm **Follow active** để quay lại auto-follow.
4. Click menu bar icon → dropdown summary cost + tokens.
5. Full window: session header, token / cost card kèm sparkline, live activity feed (tool call hiện tại), agent tree với LIVE / DONE badge. Click 1 row để mở detail sheet (full prompt / result).

## Iteration loop khi sửa code

```bash
# Sau khi sửa Swift code
swift test                                              # core logic only
xcodebuild -project ClaudeWatchMac.xcodeproj -scheme ClaudeWatchMac build
# Hoặc Xcode ⌘R

# Sau khi sửa project.yml
xcodegen generate
```

## Đổi icon (nếu muốn)

```bash
# 1. Sửa scripts/app-icon.svg
# 2. Render PNG 1024
qlmanage -t -s 1024 -o /tmp/icon-render scripts/app-icon.svg
# 3. Resize sang 7 size + ghi đè asset
for s in 16 32 64 128 256 512 1024; do
  sips -z $s $s /tmp/icon-render/app-icon.svg.png \
       --out App/Assets.xcassets/AppIcon.appiconset/icon_${s}.png
done
# 4. Rebuild
xcodebuild -project ClaudeWatchMac.xcodeproj -scheme ClaudeWatchMac build
```

## Architecture

```
claude-watch-mac/
├── Package.swift              # Swift package: ClaudeWatchCore (logic) + claude-watch-demo (CLI)
├── project.yml                # XcodeGen config for the .app
├── scripts/app-icon.svg       # source SVG cho app icon
├── Sources/
│   └── ClaudeWatchCore/        # Pure logic, no AppKit
│       ├── Pricing.swift        # USD/Mtok lookup (opus/sonnet/haiku/fable)
│       ├── SessionStats.swift   # aggregate model + live activity
│       ├── SessionEvent.swift   # one timeline entry
│       ├── AgentSpawn.swift     # subagent tracking
│       ├── ProjectPath.swift    # cwd ↔ slug, latest-session lookup
│       ├── JsonlParser.swift    # parse one transcript
│       └── SessionWatcher.swift # @Observable poll 1s + token history
├── App/                        # SwiftUI app target
│   ├── ClaudeWatchMacApp.swift # @main, MenuBarExtra + WindowGroup
│   ├── ProjectStore.swift      # persists pinned / follow-latest mode
│   ├── NotificationService.swift # subagent + cost threshold alerts
│   ├── Theme.swift             # Claude palette + ClaudeFont + cards
│   ├── TokenFormatter.swift    # compact + USD + UTC→local clock
│   ├── ToolIcon.swift / AgentIcon.swift
│   ├── MainWindowView.swift / MenuBarSummaryView.swift
│   └── Views/
│       ├── ProjectPickerView.swift
│       ├── SessionHeaderView.swift
│       ├── TokenStatsCard.swift
│       ├── TokenRateSparkline.swift
│       ├── LiveActivityCard.swift
│       ├── EventDetailView.swift
│       ├── AgentTreeList.swift
│       └── AgentDetailView.swift
└── Tests/ClaudeWatchCoreTests/   # parser + watcher tests
```

## Auto-update qua Sparkle

App tích Sparkle 2 → user install xong sẽ tự pull update mỗi 1h, hoặc bấm **Menu Bar → Claude Watch → Check for Updates…**.

### Setup MỘT LẦN (maintainer)

```bash
# 1. Sinh keypair EdDSA — private key vào Keychain, public key vào project.yml
./scripts/setup-sparkle-keys.sh
```

**Quan trọng:** private key sống trong Keychain máy này. Backup Keychain hoặc lưu key string ra Bitwarden — mất key = không sign được update mới, phải force user reinstall.

### Phát hành version mới

```bash
./scripts/release.sh 0.2.0
```

Script tự làm:
1. Bump version (`project.yml` + `Info.plist`).
2. `xcodebuild archive` → export `.app`.
3. `ditto -c -k --keepParent` → `ClaudeWatchMac-0.2.0.zip`.
4. Sign EdDSA bằng key trong Keychain.
5. Tag + push + tạo GitHub Release + upload zip qua `gh`.
6. Prepend entry vào `appcast.xml`, commit + push.

User chạy bản cũ sẽ thấy popup update trong ≤1h, hoặc dùng menu Check for Updates ngay.

### User install bản đầu (chia cho team)

1. Tải `.zip` từ https://github.com/Vt-mmm/claudewatch/releases/latest → unzip → kéo `ClaudeWatchMac.app` vô `/Applications`.
2. **Bypass Gatekeeper lần đầu** (app ad-hoc signed, không có Developer ID):
   ```bash
   xattr -dr com.apple.quarantine /Applications/ClaudeWatchMac.app
   ```
   Hoặc qua UI: **System Settings → Privacy & Security** → kéo xuống cuối → **Open Anyway** cho ClaudeWatchMac.
3. Mở app bình thường.

Từ version 2 trở đi, Sparkle tự update không cần bypass nữa vì update binary không bị macOS gắn quarantine.

## Known limits

- Cost = ước tính theo Anthropic list price; 5m vs 1h cache prompt không phân biệt riêng.
- Subagent token cost gộp vào parent session (Claude Code không tách JSONL riêng).
- macOS 14+ (MenuBarExtra requirement, Observation framework).
- Polling 1s — trễ tối đa 1 giây so với JSONL append.
- Ad-hoc signed → user mở lần đầu thấy Gatekeeper warning, right-click Open để bypass.
