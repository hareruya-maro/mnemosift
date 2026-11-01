# Apple 公証（Notarization）セットアップガイド

Mnemosift を macOS のセキュリティ警告（Gatekeeper）なしで誰でもダブルクリック一発で起動・インストールできるようにするための、**Apple Developer ID 署名 ＆ Apple 公証** の設定手順です。

---

## 1. 必要なもの

1. **Apple Developer Program アカウント**（有料: 年間 $99 / 約15,000円）
2. **Developer ID Application 証明書**（.p12 ファイル）
3. **App Store Connect API Key**（推奨）または **Apple ID ＋ App用パスワード**

---

## 2. 手順詳細

### ステップ 1: Developer ID Application 証明書の発行とエクスポート

1. [Apple Developer ポータル (Certificates)](https://developer.apple.com/account/resources/certificates/list) にアクセスします。
2. 「＋」ボタンを押し、**「Developer ID Application」** を選択して画面の指示に従い証明書を発行します。
3. 発行された証明書（`.cer`）をダウンロードし、ダブルクリックして Mac の「キーチェーンアクセス」アプリに登録します。
4. 「キーチェーンアクセス」を開き、サイドバーの「ログイン」>「自分の証明書」から `Developer ID Application: ...` を探します。
5. 証明書を右クリックして **「"Developer ID Application: ..." を書き出す...」** を選択し、`.p12` 形式で保存します（パスワードを設定してください）。

### ステップ 2: 証明書を Base64 文字列に変換

ターミナルで以下のコマンドを実行し、エクスポートした `.p12` ファイルを Base64 文字列に変換してクリップボードにコピーします：

```bash
base64 -i /path/to/your/certificate.p12 | pbcopy
```

### ステップ 3: App Store Connect API Key の発行（推奨）

1. [App Store Connect (ユーザーとアクセス > 統合 > APIキー)](https://appstoreconnect.apple.com/access/integrations/api) にアクセスします。
2. 「キーを追加（＋）」をクリックし、以下を設定します：
   - **名前**: 例「GitHub Actions Notarization」
   - **アクセス権**: **「Developer」**（開発者）
3. 生成された **Key ID**（キーID）と **Issuer ID**（発行者ID）をメモします。
4. **「APIキーをダウンロード（.p8）」** をクリックして保存します（※1度しかダウンロードできません）。
5. ターミナルで `.p8` ファイルを Base64 変換してコピーします：
   ```bash
   base64 -i /path/to/AuthKey_XXXXXX.p8 | pbcopy
   ```

---

## 3. GitHub Secrets への登録

GitHub リポジトリの **Settings > Secrets and variables > Actions** に移動し、**「New repository secret」** で以下の変数を登録します：

| Secret 名 | 設定する値 |
| :--- | :--- |
| `MACOS_CERTIFICATE` | ステップ 2 でコピーした `.p12` の Base64 文字列 |
| `MACOS_CERTIFICATE_PWD` | `.p12` を書き出したときに設定したパスワード |
| `APPLE_API_KEY_BASE64` | ステップ 3 でコピーした `.p8` の Base64 文字列 |
| `APPLE_API_KEY_ID` | App Store Connect の Key ID（例: `ABC1234XYZ`） |
| `APPLE_API_KEY_ISSUER` | App Store Connect の Issuer ID（UUID形式） |

> **代替方式（Apple ID + App用パスワードを使う場合）:**
> API Key の代わりに以下を登録することも可能です：
> - `APPLE_ID`: あなたの Apple ID（メールアドレス）
> - `APPLE_APP_SPECIFIC_PASSWORD`: [appleid.apple.com](https://appleid.apple.com) で生成した App 用パスワード
> - `APPLE_TEAM_ID`: Apple Developer の 10 桁の Team ID（組織ID）

---

## 4. リリース実行

設定完了後、バージョンタグをプッシュするだけで、GitHub Actions が自動的に **署名 ➔ Apple 公証（Notarization） ➔ チケットのステープル（Staple） ➔ Release 公開** を完了します：

```bash
git tag v0.1.0
git push origin v0.1.0
```

公証された DMG または ZIP からインストールしたユーザーは、警告ダイアログが出ることなく初回からスムーズに起動できます。
