# Mnemosift — 会議のAIパートナー & ローカルAIワークスペース (macOS / Apple Silicon)

**「会議も、ファイルも、メモも。すべて自分のPC内でAIが整理する。」**

Mnemosift は、会議中にリアルタイム文字起こしと議論の要約を行いながら、会話内容に関連しそうなローカル資料・過去の議事録を自動で提案してその場ですぐに見られる**「会議のAIパートナー」**であり、普段の業務や外部LLM（MCP / CLI）からもローカル資料を簡単に探せるデスクトップアプリです。

---

## 画面構成（サイドバーなし・1ウィンドウ2モード切替）

上部ヘッダーバーのセグメントスイッチで、2つのメインモードをワンクリックで切り替えられます（プロジェクト文脈フィルタも上部に常駐）：

1. **🎙️ 会議パートナー画面（2カラム集中型）** ([`MeetingPartnerView`](file:///Users/haruya/dev/Mnemosift/Sources/MnemosiftApp/Views/MeetingPartnerView.swift))
   - **左カラム**: 録音コントロール ＋ **リアルタイム文字起こし**（会議後は同じカラム内で **📝 議事録・Markdown** タブへ切り替え・編集・出力可能。過去の会議リストは開閉式ドロワーで必要な時だけ表示）
   - **右カラム上段**: **🧠 リアルタイム議論要約**（進行中の論点・決定事項・TODO・議論のポイントを発話ごとに自動更新）
   - **右カラム下段**: **📎 関連資料・過去議事録・用語の自動提案**（今話している内容から関連資料をリアルタイム検索・提案し、クリックすると画面移動なしで**その場でインラインプレビュー**）
2. **📚 資料検索・整理画面** ([`KnowledgeWorkspaceView`](file:///Users/haruya/dev/Mnemosift/Sources/MnemosiftApp/Views/KnowledgeWorkspaceView.swift))
   - FTS5全文検索＋Embedding意味検索による横断検索、ドラッグ＆ドロップ資料登録、AIによるファイル整理提案（承認制リネーム・移動＆ロールバック）、専門用語辞書管理、参照元リンク付きAIチャット（RAG）を1画面に集約。
3. **⚙️ 設定・AIモデル・外部LLM連携シート** ([`SettingsAndToolsSheet`](file:///Users/haruya/dev/Mnemosift/Sources/MnemosiftApp/Views/SettingsAndToolsSheet.swift))
   - 4分類AIモデル管理、MCPサーバー設定JSON / CLIコマンドのワンクリックコピー、ジョブ・メモリ監視、Phase 0 技術検証ベンチマークを格納。

---

## 🚀 インストール & 自動アップデート

### 1. GitHub Releases からダウンロード
[GitHub Releases](https://github.com/hareruya-maro/mnemosift/releases) から最新のリリースアセット（`.dmg` または `.zip`）をダウンロードしてください：
- **`Mnemosift-vX.Y.Z.dmg`**: ダブルクリックして開いたウィンドウから `Mnemosift.app` を `/Applications` へドラッグ＆ドロップ。
- **`Mnemosift-macOS-arm64.zip`**: 解凍して `/Applications` へ配置。

> [!NOTE]
> 初回起動時に「開発元を検証できないため開けません」と表示された場合は、Finder で `Mnemosift.app` を右クリック（Controlクリック）して「開く」を選択してください。

### 2. アプリ内自動更新
- **起動時自動チェック**: アプリ起動時に最新の GitHub Release をバックグラウンドで自動確認します（「⚙️ 設定 > 🚀 アプリ更新」から ON/OFF 切り替え可能）。
- **手動確認**: メニューバーの「Mnemosift > アップデートを確認...」または設定シートの「🚀 アプリ更新」タブからいつでも最新リリースを確認可能。
- **ワンクリック更新**: 新バージョンが利用可能な場合、リリースノートの確認と「今すぐアップデートして再起動」ボタンをクリックするだけで、最新版のダウンロード・置換・再起動が自動で行われます。

---

## 🛠️ 開発・ビルド・リリースワークフロー

### 1. ローカルでの開発起動・CLI / MCP 連携・テスト
```bash
# GUI デスクトップアプリの起動
swift run Mnemosift

# CLI 検索・議事録取得
swift run Mnemosift search "Qwen3-ASR 決定事項"
swift run Mnemosift meetings --json

# MCP サーバー起動
swift run Mnemosift mcp

# テストスイート実行
swift test
```

### 2. ローカルでのリリースパッケージング
```bash
# .build/Mnemosift.app のビルド
./scripts/build_app.sh --configuration release

# dist/ 配下に .zip, .dmg, SHA256SUMS.txt を生成
./scripts/package_release.sh --version 0.1.0
```

### 3. GitHub Actions による自動リリース
バージョンタグを push すると、GitHub Actions (`.github/workflows/release.yml`) が自動的に macOS ランナー上でビルド＆パッケージングを行い、GitHub Release を公開します：
```bash
git tag v0.1.0
git push origin v0.1.0
```
また、GitHub リポジトリの **Actions > Release Mnemosift > Run workflow** から手動でトリガーすることも可能です。
