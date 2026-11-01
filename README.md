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

## 起動・CLI / MCP 連携・テスト方法

### 1. Mac デスクトップアプリ (GUI) の起動
```bash
swift run Mnemosift
```

### 2. CLI コマンドとして検索・議事録取得（Claude Code / Codex / Raycast 等から利用）
```bash
# ローカル資料・議事録・発言をハイブリッド検索
swift run Mnemosift search "Qwen3-ASR 決定事項"
swift run Mnemosift search "システム音声" --json

# 議事録・決定事項・TODO一覧の取得
swift run Mnemosift meetings --json

# 登録資料一覧の取得
swift run Mnemosift documents --json
```

### 3. MCP (Model Context Protocol) サーバーとして起動（Claude Desktop / Cursor 等から利用）
```bash
swift run Mnemosift mcp
```
提供ツール: `mnemosift_search`, `mnemosift_list_meetings`, `mnemosift_list_documents`, `mnemosift_lookup_vocabulary`

### 4. 総合テストスイートの実行
```bash
swift test
```
