#!/usr/bin/env bash
set -euo pipefail

# Apple 公証 (Notarization) & ステープル (Staple) 自動化スクリプト
# 使用法: ./scripts/notarize.sh <path-to-dmg-or-app>

TARGET_FILE="${1:-}"

if [ -z "$TARGET_FILE" ] || [ ! -e "$TARGET_FILE" ]; then
  echo "Usage: $0 <path-to-dmg-or-app>"
  exit 1
fi

echo "=========================================="
echo "Submitting to Apple Notary Service: $TARGET_FILE"
echo "=========================================="

NOTARY_ARGS=()

# 認証方式 1: App Store Connect API Key (推奨・CI最適)
if [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_KEY_ISSUER:-}" ]; then
  echo "==> Using App Store Connect API Key authentication (Key ID: $APPLE_API_KEY_ID)"
  NOTARY_ARGS+=(
    "--key" "$APPLE_API_KEY_PATH"
    "--key-id" "$APPLE_API_KEY_ID"
    "--issuer" "$APPLE_API_KEY_ISSUER"
  )
# 認証方式 2: Apple ID + App用パスワード + Team ID
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  echo "==> Using Apple ID authentication (Apple ID: $APPLE_ID, Team ID: $APPLE_TEAM_ID)"
  NOTARY_ARGS+=(
    "--apple-id" "$APPLE_ID"
    "--password" "$APPLE_APP_SPECIFIC_PASSWORD"
    "--team-id" "$APPLE_TEAM_ID"
  )
# 認証方式 3: キーチェーンプロファイル (ローカル環境向け)
elif [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Using Keychain Profile: $NOTARY_PROFILE"
  NOTARY_ARGS+=(
    "--keychain-profile" "$NOTARY_PROFILE"
  )
else
  echo "Error: Apple Notary credentials not found!"
  echo "Please set either:"
  echo "  A) APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_KEY_ISSUER"
  echo "  B) APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID"
  echo "  C) NOTARY_PROFILE"
  exit 1
fi

# 1. Apple 公証サービスへ送信して結果を待機 (--wait)
echo "==> Uploading and waiting for notary approval..."
xcrun notarytool submit "$TARGET_FILE" "${NOTARY_ARGS[@]}" --wait

# 2. 公証チケットをホッチキス留め (Staple)
# ※ ZIPはステープル不可のため、DMG または .app に対してのみ実行
if [[ "$TARGET_FILE" == *.dmg ]] || [[ "$TARGET_FILE" == *.app ]]; then
  echo "==> Stapling notarization ticket to $TARGET_FILE..."
  xcrun stapler staple "$TARGET_FILE"
  echo "==> Validating staple..."
  xcrun stapler validate "$TARGET_FILE"
fi

echo "✅ Successfully notarized and stapled: $TARGET_FILE"
