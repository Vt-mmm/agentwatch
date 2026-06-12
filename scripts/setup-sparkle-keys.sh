#!/usr/bin/env bash
# Chạy MỘT LẦN sau khi clone repo lần đầu trên máy maintainer.
# - Tìm Sparkle generate_keys binary (cần xcodebuild resolve SPM xong trước).
# - Sinh keypair EdDSA → private key vào macOS Keychain, public key in ra stdout.
# - Tự nhét public key vào App/Info.plist (SUPublicEDKey).
#
# Sau bước này: anh CHỈ giữ máy này để build release. Mất Keychain = mất key =
# không sign được update mới (phải bump major + force user reinstall).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJYML="$ROOT/project.yml"

echo "→ Resolving SPM dependencies (cần để fetch Sparkle binaries)…"
cd "$ROOT"
xcodebuild -resolvePackageDependencies \
    -project ClaudeWatchMac.xcodeproj \
    -scheme ClaudeWatchMac >/dev/null

# Sparkle ship binary trong artifactbundle. Path depend vào DerivedData.
DD="$(xcodebuild -project ClaudeWatchMac.xcodeproj -scheme ClaudeWatchMac \
        -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/BUILD_DIR/ {print $2; exit}')"
DD_ROOT="$(dirname "$(dirname "$DD")")"

GEN_KEYS="$(find "$DD_ROOT/SourcePackages/artifacts" -name "generate_keys" -type f 2>/dev/null | head -1)"
if [[ -z "$GEN_KEYS" ]]; then
    echo "✗ Không tìm thấy generate_keys. Hãy build app 1 lần bằng Xcode để fetch artifact bundle, rồi rerun."
    exit 1
fi

echo "→ Sinh keypair (nhập Keychain password nếu macOS prompt)…"
"$GEN_KEYS"

PUBKEY="$("$GEN_KEYS" -p)"
echo "→ Public key: $PUBKEY"

# Inject vào project.yml (xcodegen sẽ regen Info.plist từ đây mỗi lần build).
# sed -E để match đúng dòng SUPublicEDKey hiện tại (placeholder hoặc key cũ).
sed -i '' -E "s|SUPublicEDKey: \".*\"|SUPublicEDKey: \"$PUBKEY\"|" "$PROJYML"
xcodegen generate >/dev/null
echo "✓ Đã ghi SUPublicEDKey vào project.yml + regen Info.plist"
echo
echo "Tiếp theo:"
echo "  1. git diff project.yml App/Info.plist"
echo "  2. git commit -am 'feat: enable sparkle auto-update'"
echo "  3. Build release: ./scripts/release.sh 0.1.0"
