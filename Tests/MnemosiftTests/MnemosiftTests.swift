import Foundation
import Testing
@testable import MnemosiftCore

@Suite("Mnemosift ローカルAIワークスペース 総合テストスイート")
@MainActor
struct MnemosiftTests {

    private func makeIsolatedController(seedDemo: Bool = false) throws -> AppWorkspaceController {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-mnemosift-\(UUID().uuidString).sqlite3").path
        return try AppWorkspaceController(databasePath: tempDB, seedDemoDataIfEmpty: seedDemo)
    }

    @Test("1. AIモデル管理と3段階設定優先順位（実行時指定 > プロジェクト設定 > 全体設定）の検証")
    func testModelManagerAndThreeTierPriorityResolution() throws {
        let ws = try makeIsolatedController()

        // 4分類すべてのモデルがカタログに登録されていること
        #expect(!ws.modelManager.models(for: .stt).isEmpty)
        #expect(!ws.modelManager.models(for: .judge).isEmpty)
        #expect(!ws.modelManager.models(for: .llm).isEmpty)
        #expect(!ws.modelManager.models(for: .embedding).isEmpty)

        // 3. アプリ全体設定
        let globalResolved = ws.modelManager.resolveConfiguration()
        #expect(globalResolved.realtimeSTTModel.id == "stt-qwen3-asr-0.6b")
        #expect(globalResolved.appliedScopeLabel.contains("3. アプリ全体設定"))

        // 2. プロジェクト固有設定
        var customProjSettings = ws.modelManager.globalSettings
        customProjSettings.scope = .project
        customProjSettings.realtimeSTTModelId = "stt-whisper-large-v3-turbo"
        customProjSettings.correctionMode = .highPrecisionAI
        var proj = try ws.projectService.createProject(name: "高精度検証PJ", description: "Whisper優先")
        proj.customAISettings = customProjSettings
        try ws.projectService.updateProject(proj)

        let projectResolved = ws.modelManager.resolveConfiguration(project: proj)
        #expect(projectResolved.realtimeSTTModel.id == "stt-whisper-large-v3-turbo")
        #expect(projectResolved.correctionMode == .highPrecisionAI)
        #expect(projectResolved.appliedScopeLabel.contains("2. プロジェクト固有設定"))

        // 1. 実行時の個別指定
        var runtimeSettings = customProjSettings
        runtimeSettings.scope = .runtimeOverride
        runtimeSettings.realtimeSTTModelId = "stt-apple-speech-ja"
        runtimeSettings.correctionMode = .dictionary

        let runtimeResolved = ws.modelManager.resolveConfiguration(project: proj, runtimeOverride: runtimeSettings)
        #expect(runtimeResolved.realtimeSTTModel.id == "stt-apple-speech-ja")
        #expect(runtimeResolved.correctionMode == .dictionary)
        #expect(runtimeResolved.appliedScopeLabel.contains("1. 実行時の個別指定"))
    }

    @Test("2. 4つのリアルタイム補正モード・STT原文保護・誤補正ロールバック・否定/数値ガードレールの検証")
    func testRealtimeCorrectionModesAndGuardrails() async throws {
        let ws = try makeIsolatedController()
        let rec = try ws.recordingService.startRecording(
            title: "補正検証セッション",
            source: .microphone,
            projectIds: ws.projectService.projects.map(\.id)
        )
        let tr = try ws.sttService.createTranscriptSession(
            for: rec,
            sttModelId: "stt-qwen3-asr-0.6b",
            correctionMode: .fastAI
        )
        let config = ws.modelManager.resolveConfiguration(project: ws.projectService.projects.first)
        let vocabs = ws.projectService.activeVocabularies(forProjectIds: ws.projectService.projects.map(\.id))

        // モード1: 補正オフ（原文がそのまま保持される）
        let rawInput = "ネモシフトでキュウエン・エーエスアールを動かします。"
        let segOff = try await ws.sttService.processRealtimeUtteranceChunk(
            transcriptId: tr.id,
            rawUtteranceText: rawInput,
            startTimeSeconds: 0,
            endTimeSeconds: 3,
            sttModel: config.realtimeSTTModel,
            correctionMode: .off,
            vocabularies: vocabs,
            judgeModel: config.judgeModel,
            llmModel: config.llmModel
        )
        #expect(segOff.rawText == rawInput)
        #expect(segOff.correctedText == rawInput)
        #expect(!segOff.hasCorrection)

        // モード3: 高速AI補正（System One 判断モデルにより専門用語が補正され、かつ rawText は絶対に変更されない）
        let segFast = try await ws.sttService.processRealtimeUtteranceChunk(
            transcriptId: tr.id,
            rawUtteranceText: rawInput,
            startTimeSeconds: 3,
            endTimeSeconds: 6,
            sttModel: config.realtimeSTTModel,
            correctionMode: .fastAI,
            vocabularies: vocabs,
            judgeModel: config.judgeModel,
            llmModel: config.llmModel
        )
        #expect(segFast.rawText == rawInput)
        #expect(segFast.correctedText.contains("Mnemosift"))
        #expect(segFast.correctedText.contains("Qwen3-ASR"))
        #expect(segFast.hasCorrection)

        // 誤補正の取り消し（ロールバック）で原文に戻ること
        try ws.sttService.revertCorrection(transcriptId: tr.id, segmentId: segFast.id)
        let afterRevert = try #require(ws.sttService.segments(for: tr.id).first(where: { $0.id == segFast.id }))
        #expect(afterRevert.correctedText == rawInput)
        #expect(!afterRevert.hasCorrection)

        // 補正時の制約ガードレール検証：否定表現・数量・日付が変更された場合は棄却して原文を保持する
        let guardrailCheckNegation = CorrectionService.validateCorrectionGuardrails(
            rawText: "このデータは外部へ送信しない方針です。",
            proposedText: "このデータは外部へ送信する方針です。",
            allowedSpans: []
        )
        #expect(!guardrailCheckNegation.isSafe)
        #expect(guardrailCheckNegation.finalText == "このデータは外部へ送信しない方針です。")

        let guardrailCheckNumbers = CorrectionService.validateCorrectionGuardrails(
            rawText: "16GBメモリで3個のモデルを検証します。",
            proposedText: "24GBメモリで5個のモデルを検証します。",
            allowedSpans: []
        )
        #expect(!guardrailCheckNumbers.isSafe)
        #expect(guardrailCheckNumbers.finalText == "16GBメモリで3個のモデルを検証します。")
    }

    @Test("3. プロジェクト辞書の4経路作成・承認ワークフロー・適用優先順位・同音異義語の文脈評価")
    func testVocabularyCreationApprovalAndContextualDisambiguation() async throws {
        let ws = try makeIsolatedController()
        let project = try #require(ws.projectService.projects.first)

        // 経路2: 文書からAI抽出 → 初期状態は candidate（未承認）であること
        let extracted = try await ws.projectService.extractVocabularyCandidatesWithAI(
            fromText: "新しい音声認識エンジンとして WhisperTurboCore と AppleSiliconNeural を検証する。",
            source: .extractedFromDocument,
            projectId: project.id
        )
        #expect(!extracted.isEmpty)
        let candidate = extracted[0]
        #expect(candidate.approvalStatus == .candidate)

        // 未承認の段階では activeVocabularies に含まれないこと
        let activeBefore = ws.projectService.activeVocabularies(forProjectIds: [project.id])
        #expect(!activeBefore.contains(where: { $0.id == candidate.id }))

        // ユーザーが承認すると activeVocabularies に含まれること
        try ws.projectService.approveVocabulary(id: candidate.id)
        let activeAfter = ws.projectService.activeVocabularies(forProjectIds: [project.id])
        #expect(activeAfter.contains(where: { $0.id == candidate.id }))

        // 同一誤認識表現に対する複数候補の文脈評価テスト
        let termAudio = try ws.projectService.addVocabularyManually(
            projectId: project.id,
            canonicalForm: "SCStream (音声キャプチャ)",
            reading: "エスシーストリーム",
            aliases: [],
            commonMisrecognitions: ["エスシーストリーム"],
            definition: "macOS システム音声 録音 オーディオ キャプチャ ストリーム",
            domainTags: ["録音", "システム音声", "オーディオ"]
        )
        _ = try ws.projectService.addVocabularyManually(
            projectId: nil,
            canonicalForm: "SCStream (半導体製造)",
            reading: "エスシーストリーム",
            aliases: [],
            commonMisrecognitions: ["エスシーストリーム"],
            definition: "シリコン ウェハー 製造 ライン",
            domainTags: ["半導体", "工場"]
        )

        let judge = SystemOneJudgeAdapter(model: ws.modelManager.models(for: .judge).first!)
        let evalResult = try #require(judge.evaluateCorrectionCandidates(
            utterance: "エスシーストリームを使ってシステム音声を録音する",
            surroundingContext: "macOS オーディオ キャプチャ",
            matchedFragment: "エスシーストリーム",
            candidates: ws.projectService.activeVocabularies(forProjectIds: [project.id])
        ))
        #expect(evalResult.vocabulary.id == termAudio.id)
    }

    @Test("4. 議事録生成・担当者/期限の推測禁止ルール・一部項目のみの再生成・プロジェクト未所属の単発処理")
    func testMeetingMinutesGenerationAndPartialRegeneration() async throws {
        let ws = try makeIsolatedController()

        // プロジェクト未所属（projectIds = []）での単発録音・文字起こし・議事録生成
        let rec = try ws.recordingService.startRecording(title: "単発ミーティング", source: .microphone, projectIds: [])
        _ = try ws.recordingService.stopRecording()

        let tr = try ws.sttService.createTranscriptSession(
            for: rec,
            sttModelId: "stt-qwen3-asr-0.6b",
            correctionMode: .dictionary
        )
        let config = ws.modelManager.resolveConfiguration()
        let vocabs = ws.projectService.activeVocabularies(forProjectIds: [])

        // 担当者・期限が明示された発話と、明示されていない発話の両方を投入
        _ = try await ws.sttService.processRealtimeUtteranceChunk(
            transcriptId: tr.id,
            rawUtteranceText: "決定事項として、ローカルデータベースにはSQLiteを採用することとします。",
            speakerLabel: "山田",
            startTimeSeconds: 0,
            endTimeSeconds: 4,
            sttModel: config.realtimeSTTModel,
            correctionMode: .dictionary,
            vocabularies: vocabs,
            judgeModel: config.judgeModel,
            llmModel: config.llmModel
        )
        _ = try await ws.sttService.processRealtimeUtteranceChunk(
            transcriptId: tr.id,
            rawUtteranceText: "TODOとして、来週水曜日までに田中さんがFTS5インデックスの性能測定を実施します。",
            speakerLabel: "山田",
            startTimeSeconds: 4,
            endTimeSeconds: 9,
            sttModel: config.realtimeSTTModel,
            correctionMode: .dictionary,
            vocabularies: vocabs,
            judgeModel: config.judgeModel,
            llmModel: config.llmModel
        )
        _ = try await ws.sttService.processRealtimeUtteranceChunk(
            transcriptId: tr.id,
            rawUtteranceText: "もう一つのアクションアイテムとして、UIデザインのレビューを実施します。",
            speakerLabel: "鈴木",
            startTimeSeconds: 9,
            endTimeSeconds: 13,
            sttModel: config.realtimeSTTModel,
            correctionMode: .dictionary,
            vocabularies: vocabs,
            judgeModel: config.judgeModel,
            llmModel: config.llmModel
        )

        let segments = ws.sttService.segments(for: tr.id)
        let meeting = try await ws.llmService.generateMeetingMinutes(
            from: tr,
            segments: segments,
            templateId: "template-standard",
            project: nil,
            vocabularies: vocabs,
            relatedDocuments: []
        )

        #expect(meeting.projectIds.isEmpty)
        #expect(!meeting.decisions.isEmpty)
        #expect(meeting.actionItems.count == 2)

        // 1つ目のTODOは「田中」「来週水曜日」が抽出されること
        let explicitTodo = try #require(meeting.actionItems.first(where: { $0.title.contains("FTS5") }))
        #expect(explicitTodo.assignee == "田中")
        #expect(explicitTodo.dueDateText == "来週水曜日")

        // 2つ目のTODOは担当者・期限が不明なため推測せず nil（Markdown上は未定表記）になること
        let ambiguousTodo = try #require(meeting.actionItems.first(where: { $0.title.contains("UIデザイン") }))
        #expect(ambiguousTodo.assignee == nil)
        #expect(ambiguousTodo.dueDateText == nil)

        // 一部項目（概要セクション）のみの再生成
        let regenerated = try await ws.llmService.regenerateSection(
            meetingId: meeting.id,
            section: .overview,
            segments: segments,
            vocabularies: vocabs
        )
        #expect(regenerated.overview.contains("セクション再生成済み"))
    }

    @Test("5. ファイルの段階的分類（大型LLM起動省略）・承認制ファイル整理提案・ロールバックの検証")
    func testDocumentTieredClassificationAndUndoableFileOperations() async throws {
        let ws = try makeIsolatedController()
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("design_spec_v1.md")
        let content = "# Mnemosift 設計仕様書\n本ドキュメントは音声認識と議事録生成の要件を定義する仕様書です。"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let doc = try await ws.documentService.registerFile(
            url: fileURL,
            storageMode: .copiedToManagedStorage,
            explicitContent: content,
            initialProjectIds: []
        )

        // ルールまたは小型判断モデルで分類され、大型LLMを起動せずに完了していること
        #expect(doc.category == .specification)
        #expect(doc.classificationStage.contains("LLM未起動") || doc.classificationStage.contains("大型LLM起動省略"))

        // 初期状態では整理提案は「承認待ち (pendingApproval)」であり、自動リネームされていないこと
        let proposal = try #require(ws.documentService.operationHistories.first(where: { $0.documentId == doc.id }))
        #expect(proposal.status == .pendingApproval)
        #expect(proposal.proposedFileName.hasPrefix("spec_"))

        // ユーザーが承認するとファイル名・パスが変更されること
        try ws.documentService.approveAndApplyFileOperation(historyId: proposal.id)
        let appliedDoc = try #require(ws.documentService.documents.first(where: { $0.id == doc.id }))
        #expect(appliedDoc.fileName == proposal.proposedFileName)

        // ロールバック（取り消し）を実行すると元のファイル名・パスに復元されること
        try ws.documentService.undoFileOperation(historyId: proposal.id)
        let undoneDoc = try #require(ws.documentService.documents.first(where: { $0.id == doc.id }))
        #expect(undoneDoc.fileName == proposal.previousFileName)
        #expect(undoneDoc.filePath == proposal.previousFilePath)
    }

    @Test("6. AI検索・RAG：3つの検索範囲モード（全体 / プロジェクト優先 / プロジェクト限定）と古い資料の不当優先防止の検証")
    func testSearchScopeModesAndRecencyRanking() async throws {
        let ws = try makeIsolatedController()
        let projA = try ws.projectService.createProject(name: "Project Alpha", description: "Alpha")
        let projB = try ws.projectService.createProject(name: "Project Beta", description: "Beta")

        // Project Alpha の非常に古いチャンク（1年前）
        let oldDate = Date().addingTimeInterval(-365 * 86400)
        let oldAlphaChunk = KnowledgeChunk(
            sourceType: .document,
            sourceId: UUID(),
            projectIds: [projA.id],
            title: "Alpha 古い設計メモ",
            content: "ローカルSTT音声認識では量子化モデルを使用して遅延を削減する。",
            sourceUpdatedAt: oldDate
        )
        try ws.database.saveKnowledgeChunk(oldAlphaChunk)

        // Project Beta の最新チャンク（今日更新・重要決定事項）
        let freshBetaChunk = KnowledgeChunk(
            sourceType: .meetingMinutes,
            sourceId: UUID(),
            projectIds: [projB.id],
            title: "Beta 最新アーキテクチャ決定事項",
            content: "ローカルSTT音声認識では量子化モデルを使用して遅延を削減することが決定事項として合意された。",
            isDecisionOrImportant: true,
            sourceUpdatedAt: Date()
        )
        try ws.database.saveKnowledgeChunk(freshBetaChunk)

        // EmbeddingService を再ロードしてチャンクを反映
        let refreshedEmb = EmbeddingService(database: ws.database, modelManager: ws.modelManager, jobManager: ws.jobManager)
        let searchSvc = SearchService(
            database: ws.database,
            modelManager: ws.modelManager,
            jobManager: ws.jobManager,
            embeddingService: refreshedEmb,
            projectService: ws.projectService
        )

        // 1. プロジェクト限定検索 (Project Alpha のみ返り、Beta は一切含まれない)
        let exclusiveResults = searchSvc.search(
            query: "ローカルSTT音声認識 量子化モデル",
            scopeMode: .projectExclusive,
            targetProjectId: projA.id
        )
        #expect(exclusiveResults.count == 1)
        #expect(exclusiveResults.first?.chunk.id == oldAlphaChunk.id)

        // 2. プロジェクト優先検索 (Project Alpha を指定しても、1年前の古い資料より今日の最新重要決定事項の方が高スコアになる)
        let priorityResults = searchSvc.search(
            query: "ローカルSTT音声認識 量子化モデル",
            scopeMode: .projectPriority,
            targetProjectId: projA.id
        )
        #expect(priorityResults.count == 2)
        #expect(priorityResults.first?.chunk.id == freshBetaChunk.id)

        // 3. 根拠が存在しない質問に対するRAG回答では推測せず根拠なしと明示すること
        let noEvidenceReply = try await searchSvc.askQuestion(
            question: "火星探査ローバーのバッテリー仕様は何ですか？",
            scopeMode: .global
        )
        #expect(!noEvidenceReply.hasSufficientEvidence)
        #expect(noEvidenceReply.citations.isEmpty)
        #expect(noEvidenceReply.content.contains("明確な根拠"))
    }

    @Test("7. 録音中の画面遷移・異常終了復旧・メモリ不足時の優先度制御・Phase 0 ベンチマークの検証")
    func testRecordingContinuityCrashRecoveryMemoryThrottlingAndPhase0() async throws {
        let ws = try makeIsolatedController()

        // 録音開始後に画面を「議事録」「ファイル」「設定」へ遷移しても録音が中断されないこと
        let rec = try ws.recordingService.startRecording(title: "画面遷移テスト録音", source: .microphoneAndSystem, projectIds: [])
        #expect(ws.recordingService.state == .recording)

        ws.selectedSection = .meetings
        #expect(ws.recordingService.state == .recording)
        ws.selectedSection = .files
        #expect(ws.recordingService.state == .recording)
        ws.selectedSection = .settings
        #expect(ws.recordingService.state == .recording)

        let stopped = try #require(try ws.recordingService.stopRecording())
        #expect(stopped.id == rec.id)
        #expect(FileManager.default.fileExists(atPath: stopped.filePath))

        // メモリ制限シミュレーション時の低優先度ジョブ制御確認
        ws.jobManager.setSimulatedAvailableMemoryMB(800)
        let jobOutput = try await ws.jobManager.enqueueAndRun(
            type: .embeddingGeneration,
            title: "低メモリ時のバックグラウンドジョブ検証",
            priority: .lowBackground,
            modelId: "emb-embedding-gemma-2",
            requiredMemoryMB: 650
        ) {
            ("OK", "待機後に正常完了")
        }
        #expect(jobOutput == "OK")
        ws.jobManager.setSimulatedAvailableMemoryMB(nil)

        // Phase 0 技術検証ベンチマークスイートの実行確認
        let benchResults = try await ws.benchmarkRunner.runPhase0VerificationSuite()
        #expect(benchResults.count == 4)
        #expect(benchResults.allSatisfy { $0.passedGuardrails })
    }

    @Test("8. 会議パートナーのライブ議論要約・関連資料の自動提案・CLI/MCP外部LLM連携ブリッジの検証")
    func testMeetingPartnerCopilotAndExternalToolBridge() async throws {
        let ws = try makeIsolatedController()
        let project = try #require(ws.projectService.projects.first)

        // 1. 関連資料を登録
        let tempDir = FileManager.default.temporaryDirectory
        let specURL = tempDir.appendingPathComponent("audio_architecture.md")
        let specText = "# システム音声録音設計書\nScreenCaptureKit と Qwen3-ASR を組み合わせてリアルタイム文字起こしを実現する。"
        try specText.write(to: specURL, atomically: true, encoding: .utf8)

        let doc = try await ws.documentService.registerFile(
            url: specURL,
            storageMode: .copiedToManagedStorage,
            explicitContent: specText,
            initialProjectIds: [project.id]
        )

        // 2. 会議を開始して発話を追加
        let rec = try ws.recordingService.startRecording(
            title: "AIパートナー検証会議",
            source: .microphoneAndSystem,
            projectIds: [project.id]
        )
        let tr = try ws.sttService.createTranscriptSession(
            for: rec,
            sttModelId: "stt-qwen3-asr-0.6b",
            correctionMode: .fastAI
        )
        ws.activeTranscriptId = tr.id
        let config = ws.modelManager.resolveConfiguration(project: project)
        let vocabs = ws.projectService.activeVocabularies(forProjectIds: [project.id])

        _ = try await ws.sttService.processRealtimeUtteranceChunk(
            transcriptId: tr.id,
            rawUtteranceText: "本日の議題として、スクリーンキャプチャーキットとキュウエン・エーエスアールの連携仕様を確認します。",
            speakerLabel: "佐藤",
            startTimeSeconds: 0,
            endTimeSeconds: 5,
            sttModel: config.realtimeSTTModel,
            correctionMode: .fastAI,
            vocabularies: vocabs,
            judgeModel: config.judgeModel,
            llmModel: config.llmModel
        )
        _ = try await ws.sttService.processRealtimeUtteranceChunk(
            transcriptId: tr.id,
            rawUtteranceText: "決定事項として、来週月曜日までに鈴木さんが録音テストを実施することとします。",
            speakerLabel: "佐藤",
            startTimeSeconds: 5,
            endTimeSeconds: 10,
            sttModel: config.realtimeSTTModel,
            correctionMode: .fastAI,
            vocabularies: vocabs,
            judgeModel: config.judgeModel,
            llmModel: config.llmModel
        )

        // 3. 会議パートナーの状態を更新し、ライブ要約と関連資料が自動提案されていることを確認
        ws.refreshMeetingPartnerState()
        let digest = ws.meetingPartnerService.liveDigest
        #expect(digest.utteranceCount == 2)
        #expect(!digest.decisions.isEmpty)

        let suggestions = ws.meetingPartnerService.relatedSuggestions
        #expect(!suggestions.isEmpty)
        #expect(suggestions.contains(where: { $0.kind == .document && $0.sourceId == doc.id }))

        // 4. CLI & MCP ブリッジの動作確認
        let bridge = ExternalToolBridge(workspace: ws)
        let cliSearchOut = bridge.runSearchCommand(query: "ScreenCaptureKit Qwen3-ASR", asJSON: false)
        #expect(cliSearchOut.contains("audio_architecture.md"))

        let mcpInitReply = try #require(bridge.handleMCPJSONRPCRequest(
            jsonLine: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        ))
        #expect(mcpInitReply.contains("mnemosift-local-workspace"))

        let mcpToolsReply = try #require(bridge.handleMCPJSONRPCRequest(
            jsonLine: #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
        ))
        #expect(mcpToolsReply.contains("mnemosift_search"))

        let mcpCallReply = try #require(bridge.handleMCPJSONRPCRequest(
            jsonLine: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"mnemosift_search","arguments":{"query":"ScreenCaptureKit"}}}"#
        ))
        #expect(mcpCallReply.contains("audio_architecture.md"))
    }

    @Test("9. リアルタイム音声キャプチャエンジン（LiveAudioStreamEngine）と文字起こしパイプラインの結合検証")
    func testLiveAudioStreamEnginePipeline() async throws {
        let ws = try makeIsolatedController()

        // 1. 権限状態の取得確認
        let permStatus = ws.recordingService.checkPermissionsStatus()
        #expect(permStatus.contains("マイク権限"))
        #expect(permStatus.contains("システム音声"))

        // 2. 録音セッションの開始
        let rec = try ws.recordingService.startRecording(
            title: "リアルタイムストリーミングテスト",
            source: .microphoneAndSystem,
            projectIds: ws.projectService.projects.map(\.id),
            hotwords: ["Mnemosift", "Qwen3-ASR"]
        )
        let tr = try ws.sttService.createTranscriptSession(
            for: rec,
            sttModelId: "stt-qwen3-asr-0.6b",
            correctionMode: .fastAI
        )
        ws.activeTranscriptId = tr.id

        // 3. 暫定テキスト (Provisional) の受信シミュレーション
        ws.recordingService.onProvisionalText?("認識中のテキスト...")
        #expect(ws.sttService.currentProvisionalSegment != nil)
        #expect(ws.sttService.currentProvisionalSegment?.rawText == "認識中のテキスト...")
        #expect(ws.sttService.currentProvisionalSegment?.isProvisional == true)

        // 4. 発話確定 (Finalized Utterance) の受信シミュレーション ＆ 重複防止・要約圧縮の検証
        let youtubeSample = "こんにちはAIスクール太田のビジネス変革スイッチへようこそAIスクールの太田ですこのチャンネルではAIのビジネス活用を考えの方に役立つ情報をお届けしています概要欄のリンクもぜひご覧くださいそれでは早速見ていきましょう"
        let formattedSample = LiveAudioStreamEngine.formatJapanesePunctuation(youtubeSample)
        #expect(formattedSample.contains("。"))

        ws.recordingService.onFinalizedUtterance?(formattedSample, 0.0, 27.0)
        // 同一内容が重複して飛んできた場合でも1件に抑えられることを検証
        ws.recordingService.onFinalizedUtterance?(formattedSample, 27.0, 28.0)

        // 少し待機して非同期タスク完了を待つ
        try await Task.sleep(for: .milliseconds(350))

        let segments = ws.sttService.segments(for: tr.id)
        #expect(segments.count == 1)
        #expect(ws.sttService.currentProvisionalSegment == nil)

        // リアルタイム議論要約が原文の丸写しではなく、挨拶を除去して要点に圧縮されていることを確認
        let digest = ws.meetingPartnerService.liveDigest
        #expect(digest.currentTopic.count < youtubeSample.count)
        #expect(!digest.currentTopic.contains("概要欄のリンク"))
        #expect(digest.keyPoints.first?.contains("AIのビジネス活用") == true)

        // 5. 録音停止とファイルサイズの確定確認
        let stopped = try #require(try ws.recordingService.stopRecording())
        #expect(stopped.completedAt != nil)
        #expect(stopped.fileSizeBytes > 0)
    }
}
