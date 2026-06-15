#!/usr/bin/env bash
# Build + sign + push release. 1 lệnh: ./scripts/release.sh 0.2.0
#
# Workflow:
#  1. Bump MARKETING_VERSION + CFBundleShortVersionString → $1.
#  2. xcodebuild archive (Release config).
#  3. Export .app từ archive → Releases/ClaudeWatchMac-$1.zip.
#  4. sign_update → EdDSA signature.
#  5. Tạo GitHub Release + upload zip qua gh CLI.
#  6. Generate entry vào appcast.xml (prepend mới nhất lên top).
#  7. Commit appcast.xml + push.
#
# Sau bước này: mọi user đã install bản cũ → Sparkle auto-check 1h/lần → popup
# update → 1 click là xong.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>   (vd: $0 0.2.0)"; exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD="${VERSION//./}"   # 0.2.0 → 020 (CFBundleVersion phải tăng đơn điệu)
ZIP="ClaudeWatchMac-$VERSION.zip"
APPCAST="$ROOT/appcast.xml"
REL_DIR="$ROOT/Releases"
mkdir -p "$REL_DIR"

echo "→ [1/7] Bump version → $VERSION (build $BUILD)"
sed -i '' "s|MARKETING_VERSION: \".*\"|MARKETING_VERSION: \"$VERSION\"|" project.yml
sed -i '' "s|CURRENT_PROJECT_VERSION: \".*\"|CURRENT_PROJECT_VERSION: \"$BUILD\"|" project.yml
# Info.plist dùng $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION) template —
# xcodebuild substitute lúc build. Không cần PlistBuddy nữa.
xcodegen generate >/dev/null

echo "→ [2/7] Archive"
ARCHIVE="$REL_DIR/ClaudeWatchMac-$VERSION.xcarchive"
rm -rf "$ARCHIVE"
xcodebuild -project ClaudeWatchMac.xcodeproj -scheme ClaudeWatchMac \
    -configuration Release -destination 'platform=macOS' \
    -archivePath "$ARCHIVE" archive >/tmp/archive.log 2>&1 || {
        tail -40 /tmp/archive.log; exit 1; }

APP_SRC="$ARCHIVE/Products/Applications/ClaudeWatchMac.app"
APP_DST="$REL_DIR/ClaudeWatchMac.app"
rm -rf "$APP_DST" "$REL_DIR/$ZIP"
cp -R "$APP_SRC" "$APP_DST"

# Sparkle.framework ship pre-signed với Team ID của Sparkle. Khi main app
# ad-hoc (Team ID rỗng) → dyld báo "different Team IDs" → app crash launch.
# Fix: deep re-sign toàn bộ bundle bằng ad-hoc. --deep ký tất cả XPC services,
# Updater.app, Autoupdate, Downloader, Installer trong Sparkle.framework.
echo "→ [3/7] Re-sign frameworks bằng ad-hoc"
# KHÔNG dùng --options runtime: hardened runtime → Library Validation enforce
# Team ID match cực nghiêm. Ngay cả 2 ad-hoc binary cũng bị reject. Tắt
# hardened runtime cho ad-hoc distribution (chỉ matter khi notarize).
codesign --force --deep --sign - --timestamp=none "$APP_DST" 2>&1 | tail -5
codesign --verify --deep --strict "$APP_DST" || { echo "✗ Signature verify failed"; exit 1; }

echo "→ [4/7] Zip → $ZIP"
# ditto giữ extended attributes + symlinks, Sparkle expect format này.
(cd "$REL_DIR" && ditto -c -k --keepParent ClaudeWatchMac.app "$ZIP")

echo "→ [5/7] Sign update (EdDSA)"
DD="$(xcodebuild -project ClaudeWatchMac.xcodeproj -scheme ClaudeWatchMac \
        -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/BUILD_DIR/ {print $2; exit}')"
DD_ROOT="$(dirname "$(dirname "$DD")")"
SIGN="$(find "$DD_ROOT/SourcePackages/artifacts" -name "sign_update" -type f 2>/dev/null | head -1)"
[[ -z "$SIGN" ]] && { echo "✗ sign_update missing — open Xcode build once."; exit 1; }

SIG_LINE="$("$SIGN" "$REL_DIR/$ZIP")"
SIG="$(echo "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LEN="$(echo "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
echo "   sig=${SIG:0:16}… len=$LEN"

echo "→ [6/7] GitHub release + upload"
TAG="v$VERSION"
git add project.yml App/Info.plist
git commit -m "chore: release $VERSION" || true
git tag "$TAG"
git push origin main "$TAG"

# Build CLI release binary cùng release — user có thể download standalone.
echo "   building CLI binary…"
swift build -c release --product claudewatch >/tmp/cli-build.log 2>&1 || {
    tail -20 /tmp/cli-build.log; exit 1; }
cp .build/release/claudewatch "$REL_DIR/claudewatch"
# Strip debug symbols để giảm size binary (~30-50%). -S strip debug symbols
# nhưng giữ symbol table cho crash report. -x strip local symbols thêm.
strip -S -x "$REL_DIR/claudewatch" 2>/dev/null || true
echo "   CLI size: $(du -h "$REL_DIR/claudewatch" | awk '{print $1}')"

gh release create "$TAG" "$REL_DIR/$ZIP" "$REL_DIR/claudewatch" \
    --title "Claude Watch $VERSION" \
    --notes "Built from $TAG. Auto-update sẽ tự tải qua Sparkle. CLI binary có sẵn — chmod +x rồi copy vào /usr/local/bin/." \
    --latest

URL="https://github.com/Vt-mmm/claudewatch/releases/download/$TAG/$ZIP"
DATE="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"

echo "→ [7/7] Cập nhật appcast.xml"
ITEM=$(cat <<EOF
        <item>
            <title>Version $VERSION</title>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <pubDate>$DATE</pubDate>
            <enclosure url="$URL" sparkle:edSignature="$SIG" length="$LEN" type="application/octet-stream"/>
        </item>
EOF
)
# Insert ngay sau <language>en</language> (item mới nhất ở top).
python3 - "$APPCAST" "$ITEM" <<'PY'
import sys, re
path, item = sys.argv[1], sys.argv[2]
with open(path) as f: src = f.read()
new = re.sub(r"(<language>en</language>\s*\n)", r"\1" + item + "\n", src, count=1)
with open(path, "w") as f: f.write(new)
PY

git add appcast.xml
git commit -m "chore: appcast $VERSION"
git push

echo "✓ Done. User chạy bản cũ sẽ nhận update trong 1h, hoặc dùng menu Check for Updates."
