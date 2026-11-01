#!/usr/bin/env bash
set -euo pipefail

# Mnemosift リリースパッケージングスクリプト
# ZIPアーカイブ、DMGイメージ、SHA256ハッシュを生成します
# 使用法: ./scripts/package_release.sh [--version 0.1.0]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --version|-v)
      VERSION="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# バージョンが指定されていない場合は Info.plist から取得
if [ -z "$VERSION" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "Sources/MnemosiftApp/Info.plist" 2>/dev/null || echo "0.1.0")
fi

echo "=========================================="
echo "Packaging Mnemosift v${VERSION}"
echo "=========================================="

# 1. アプリバンドルをビルド
./scripts/build_app.sh --configuration release --version "$VERSION"

APP_BUNDLE="$REPO_ROOT/.build/Mnemosift.app"
DIST_DIR="$REPO_ROOT/dist"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

ZIP_NAME="Mnemosift-v${VERSION}-macOS-arm64.zip"
LATEST_ZIP_NAME="Mnemosift-macOS-arm64.zip"
DMG_NAME="Mnemosift-v${VERSION}.dmg"

# 2. ZIP アーカイブ作成 (ditto を使用してリソースフォークとメタデータを保持)
echo "==> Creating ZIP archive: $ZIP_NAME..."
(
  cd "$REPO_ROOT/.build"
  ditto -c -k --sequesterRsrc --keepParent "Mnemosift.app" "$DIST_DIR/$ZIP_NAME"
  cp "$DIST_DIR/$ZIP_NAME" "$DIST_DIR/$LATEST_ZIP_NAME"
)

# 3. DMG イメージ作成 (hdiutil を使用して /Applications リンク付きのDMGを生成)
echo "==> Creating DMG image: $DMG_NAME..."
DMG_TEMP_DIR="$(mktemp -d /tmp/mnemosift_dmg.XXXXXX)"
cp -R "$APP_BUNDLE" "$DMG_TEMP_DIR/"
ln -s /Applications "$DMG_TEMP_DIR/Applications"

hdiutil create \
  -volname "Mnemosift" \
  -srcfolder "$DMG_TEMP_DIR" \
  -ov \
  -format UDZO \
  "$DIST_DIR/$DMG_NAME"

rm -rf "$DMG_TEMP_DIR"

# 4. SHA256SUMS.txt の作成
echo "==> Generating SHA256 checksums..."
(
  cd "$DIST_DIR"
  shasum -a 256 "$ZIP_NAME" "$LATEST_ZIP_NAME" "$DMG_NAME" > SHA256SUMS.txt
)

echo "=========================================="
echo " Packaging complete!"
echo " Output files in $DIST_DIR:"
ls -lh "$DIST_DIR"
echo "=========================================="
