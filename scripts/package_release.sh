#!/usr/bin/env bash
set -euo pipefail

# Mnemosift リリースパッケージングスクリプト
# ZIPアーカイブ、DMGイメージ、SHA256ハッシュを生成し、オプションでApple公証を実施します
# 使用法: ./scripts/package_release.sh [--version 0.1.0] [--identity "Developer ID Application: ..."] [--notarize]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION=""
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:--}"
SHOULD_NOTARIZE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --version|-v)
      VERSION="$2"
      shift 2
      ;;
    --identity|-i)
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --notarize)
      SHOULD_NOTARIZE=true
      shift
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
echo "Signing Identity: $SIGNING_IDENTITY"
echo "Notarization: $SHOULD_NOTARIZE"
echo "=========================================="

# 1. アプリバンドルをビルド & 署名
./scripts/build_app.sh --configuration release --version "$VERSION" --identity "$SIGNING_IDENTITY"

APP_BUNDLE="$REPO_ROOT/.build/Mnemosift.app"
DIST_DIR="$REPO_ROOT/dist"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

ZIP_NAME="Mnemosift-v${VERSION}-macOS-arm64.zip"
LATEST_ZIP_NAME="Mnemosift-macOS-arm64.zip"
DMG_NAME="Mnemosift-v${VERSION}.dmg"

# 2. 公証が要求されている場合: 先に .app を公証＆ステープル
if [ "$SHOULD_NOTARIZE" = true ] && [ "$SIGNING_IDENTITY" != "-" ]; then
  echo "==> Creating temporary ZIP for app notarization..."
  TEMP_APP_ZIP="$(mktemp /tmp/mnemosift_app.XXXXXX.zip)"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$TEMP_APP_ZIP"

  echo "==> Notarizing .app bundle..."
  ./scripts/notarize.sh "$TEMP_APP_ZIP"
  rm -f "$TEMP_APP_ZIP"

  echo "==> Stapling ticket to .app..."
  xcrun stapler staple "$APP_BUNDLE"
fi

# 3. ZIP アーカイブ作成 (ステープル済み .app を元に作成)
echo "==> Creating ZIP archive: $ZIP_NAME..."
(
  cd "$REPO_ROOT/.build"
  ditto -c -k --sequesterRsrc --keepParent "Mnemosift.app" "$DIST_DIR/$ZIP_NAME"
  cp "$DIST_DIR/$ZIP_NAME" "$DIST_DIR/$LATEST_ZIP_NAME"
)

# 4. DMG イメージ作成 (hdiutil を使用して /Applications リンク付きのDMGを生成)
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

# 5. 公証が要求されている場合: DMG も署名＆公証＆ステープル
if [ "$SHOULD_NOTARIZE" = true ] && [ "$SIGNING_IDENTITY" != "-" ]; then
  echo "==> Signing DMG with Developer ID..."
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DIST_DIR/$DMG_NAME"

  echo "==> Notarizing DMG..."
  ./scripts/notarize.sh "$DIST_DIR/$DMG_NAME"
fi

# 6. SHA256SUMS.txt の作成
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
