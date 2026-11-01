#!/usr/bin/env bash
set -euo pipefail

# Mnemosift macOS アプリケーションバンドルビルドスクリプト
# 使用法: ./scripts/build_app.sh [--configuration release|debug] [--version 0.1.0] [--identity "Developer ID Application: ..."]

CONFIGURATION="release"
CUSTOM_VERSION=""
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:--}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --configuration|-c)
      CONFIGURATION="$2"
      shift 2
      ;;
    --version|-v)
      CUSTOM_VERSION="$2"
      shift 2
      ;;
    --identity|-i)
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Building Mnemosift ($CONFIGURATION)..."
swift build -c "$CONFIGURATION" --arch arm64

BUILD_DIR="$REPO_ROOT/.build/arm64-apple-macosx/$CONFIGURATION"
if [ ! -d "$BUILD_DIR" ]; then
  BUILD_DIR="$REPO_ROOT/.build/$CONFIGURATION"
fi

EXECUTABLE="$BUILD_DIR/Mnemosift"
if [ ! -f "$EXECUTABLE" ]; then
  echo "Error: Executable not found at $EXECUTABLE"
  exit 1
fi

APP_BUNDLE="$REPO_ROOT/.build/Mnemosift.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Creating .app bundle structure at $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 1. 実行可能バイナリを配置
cp "$EXECUTABLE" "$MACOS_DIR/Mnemosift"
chmod +x "$MACOS_DIR/Mnemosift"

# 2. リソース (AppIcon, SwiftPM Bundle) を配置
if [ -f "Sources/MnemosiftApp/Resources/AppIcon.icns" ]; then
  cp "Sources/MnemosiftApp/Resources/AppIcon.icns" "$RESOURCES_DIR/"
fi
if [ -f "Sources/MnemosiftApp/Resources/AppIcon.png" ]; then
  cp "Sources/MnemosiftApp/Resources/AppIcon.png" "$RESOURCES_DIR/"
fi

# SwiftPMリソースバンドルが存在する場合はコピー
RESOURCE_BUNDLE=$(find "$BUILD_DIR" -maxdepth 2 -name "Mnemosift_MnemosiftApp.bundle" | head -n 1)
if [ -n "$RESOURCE_BUNDLE" ] && [ -d "$RESOURCE_BUNDLE" ]; then
  echo "==> Copying resource bundle: $RESOURCE_BUNDLE"
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

# 3. Info.plist を配置（バージョン指定があれば置換）
INFO_PLIST_SRC="Sources/MnemosiftApp/Info.plist"
INFO_PLIST_DST="$CONTENTS_DIR/Info.plist"

if [ -n "$CUSTOM_VERSION" ]; then
  echo "==> Setting CFBundleShortVersionString to $CUSTOM_VERSION"
  sed "s/<string>0.1.0<\/string>/<string>$CUSTOM_VERSION<\/string>/g" "$INFO_PLIST_SRC" > "$INFO_PLIST_DST"
else
  cp "$INFO_PLIST_SRC" "$INFO_PLIST_DST"
fi

# 4. コード署名 (Ad-hoc または Apple Developer ID + Hardened Runtime)
ENTITLEMENTS="$REPO_ROOT/Sources/MnemosiftApp/Mnemosift.entitlements"

if [ "$SIGNING_IDENTITY" != "-" ]; then
  echo "==> Signing with Developer ID: $SIGNING_IDENTITY (Hardened Runtime + Timestamp)"
  codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE"
else
  echo "==> Signing with Ad-hoc signature (local development mode)..."
  codesign --force --deep --sign - \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE"
fi

# 署名の検証
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "✅ Successfully built and signed: $APP_BUNDLE"
