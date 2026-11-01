#!/usr/bin/env bash
set -euo pipefail

# Mnemosift ローカルリリース自動化スクリプト
# ローカルの macOS 環境でビルド・パッケージングを行い、GitHub Release にアップロードします
# 使用法: ./scripts/release_local.sh [--version 0.1.0] [--notarize]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION=""
SHOULD_NOTARIZE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --version|-v)
      VERSION="$2"
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

if [ -z "$VERSION" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "Sources/MnemosiftApp/Info.plist" 2>/dev/null || echo "0.1.0")
fi

TAG="v$VERSION"

echo "========================================================"
echo "🚀 Mnemosift ローカルリリース開始: $TAG"
echo "========================================================"

# 1. パッケージングスクリプトを実行 (dist/ 配下に .dmg, .zip, SHA256SUMS.txt を生成)
if [ "$SHOULD_NOTARIZE" = true ]; then
  ./scripts/package_release.sh --version "$VERSION" --notarize
else
  ./scripts/package_release.sh --version "$VERSION"
fi

DIST_DIR="$REPO_ROOT/dist"
ZIP_FILE="$DIST_DIR/Mnemosift-v${VERSION}-macOS-arm64.zip"
LATEST_ZIP_FILE="$DIST_DIR/Mnemosift-macOS-arm64.zip"
DMG_FILE="$DIST_DIR/Mnemosift-v${VERSION}.dmg"
CHECKSUM_FILE="$DIST_DIR/SHA256SUMS.txt"

# 2. Git タグの作成とプッシュ
echo "==> Creating git tag: $TAG..."
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists locally. Updating tag..."
  git tag -d "$TAG" >/dev/null
fi
git tag -a "$TAG" -m "Mnemosift Release $TAG"

echo "==> Pushing tag $TAG to origin..."
git push origin "$TAG" --force

# 3. GitHub Release へのアップロード
echo "==> Uploading release assets to GitHub Release..."

UPLOAD_SUCCESS=false

if command -v gh &> /dev/null; then
  if gh auth status &> /dev/null; then
    echo "==> Using GitHub CLI (gh) to create release and upload assets..."
    # 既存のリリースがあればアセットを上書き、なければ新規作成
    if gh release view "$TAG" &> /dev/null; then
      gh release upload "$TAG" "$ZIP_FILE" "$LATEST_ZIP_FILE" "$DMG_FILE" "$CHECKSUM_FILE" --clobber
    else
      gh release create "$TAG" \
        "$ZIP_FILE" "$LATEST_ZIP_FILE" "$DMG_FILE" "$CHECKSUM_FILE" \
        --title "Mnemosift $TAG" \
        --generate-notes
    fi
    UPLOAD_SUCCESS=true
    echo "✅ GitHub Release にアセットをアップロードしました！"
    echo "URL: https://github.com/hareruya-maro/mnemosift/releases/tag/$TAG"
  fi
fi

if [ "$UPLOAD_SUCCESS" = false ]; then
  echo "--------------------------------------------------------"
  echo "ℹ️  GitHub CLI での直接アップロードをスキップしました。"
  echo "   以下のファイルをブラウザの GitHub Release 画面にドラッグ＆ドロップしてください："
  echo ""
  echo "   1. $DMG_FILE"
  echo "   2. $ZIP_FILE"
  echo "   3. $LATEST_ZIP_FILE"
  echo "   4. $CHECKSUM_FILE"
  echo ""
  echo "==> Finder で dist フォルダを開きます..."
  open "$DIST_DIR"
  echo "==> ブラウザで GitHub Release 編集画面を開きます..."
  open "https://github.com/hareruya-maro/mnemosift/releases/new?tag=$TAG&title=Mnemosift+$TAG"
  echo "--------------------------------------------------------"
fi

echo "========================================================"
echo "🎉 リリース作業が完了しました！"
echo "========================================================"
