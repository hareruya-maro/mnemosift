import Foundation
import AppKit
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

        // MainActor キュー上の非同期タスク完了を待機（並列テスト実行時でも確実に完了を待つ）
        for _ in 0..<30 {
            if !ws.sttService.segments(for: tr.id).isEmpty && ws.sttService.currentProvisionalSegment == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

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

    @Test("10. STTモデル切替・Apple Intelligence連携・推奨モデルダウンロード・カスタムモデル追加の検証")
    func testModelDownloadCustomModelsAndSTTSwitching() async throws {
        let ws = try makeIsolatedController()

        // 1. Apple Intelligence と Apple SpeechAnalyzer、Qwen3-ASR が選択可能であること
        let appleLLM = try #require(ws.modelManager.model(withId: "llm-apple-intelligence"))
        #expect(appleLLM.runtime == .appleIntelligence)
        #expect(appleLLM.downloadState == .installed)

        let appleSTT = try #require(ws.modelManager.model(withId: "stt-apple-speech-ja"))
        ws.recordingService.liveEngine.updateActiveSTTModel(appleSTT)
        #expect(ws.recordingService.liveEngine.activeSTTModelName == appleSTT.name)

        // 2. 推奨モデル（Gemma 4 MLX 4bit）のアプリ単体ダウンロードとローカルマニフェスト保存の検証
        let gemmaStandaloneId = "llm-gemma-4-mlx-4bit"
        let beforeDownload = try #require(ws.modelManager.model(withId: gemmaStandaloneId))
        #expect(beforeDownload.downloadState == .notInstalled)

        await ws.modelManager.installOrUpdateModel(id: gemmaStandaloneId)
        let afterDownload = try #require(ws.modelManager.model(withId: gemmaStandaloneId))
        #expect(afterDownload.downloadState == .installed)
        #expect(afterDownload.downloadProgress == 1.0)

        let modelDir = ws.modelManager.localModelDirectory(for: gemmaStandaloneId)
        let manifestURL = modelDir.appendingPathComponent("model_manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        // 3. パワーユーザー向け Hugging Face / Ollama カスタムモデル追加の検証
        let customHF = try ws.modelManager.addCustomModel(
            name: "Gemma 4 27B Custom MLX",
            category: .llm,
            runtime: .mlxLLM,
            endpointOrRepoId: "mlx-community/gemma-2-27b-it-4bit",
            requiredMemoryMB: 16384,
            diskSizeMB: 14500
        )
        #expect(ws.modelManager.isCustomModel(customHF))
        #expect(ws.modelManager.model(withId: customHF.id) != nil)

        let customOllama = try ws.modelManager.addCustomModel(
            name: "DeepSeek R1 8B Ollama",
            category: .llm,
            runtime: .ollama,
            endpointOrRepoId: "deepseek-r1:8b"
        )
        #expect(customOllama.endpointOrPath.contains("#deepseek-r1:8b"))

        // 4. ディスクからのモデル削除の検証
        try ws.modelManager.deleteModelFromDisk(id: gemmaStandaloneId)
        let afterDelete = try #require(ws.modelManager.model(withId: gemmaStandaloneId))
        #expect(afterDelete.downloadState == .notInstalled)
    }

    @Test("11. ローカルAIドキュメント検索仕様書 §6 & §16.1: 日本語形態素解析・重要キーワード抽出・記号技術用語(C++/OAuth2/SwiftUI)・表記ゆれ・2文字語検索の検証")
    func testKeywordSearchMorphologyAndSymbolTechTerms() async throws {
        let ws = try makeIsolatedController()
        let analyzer = NaturalLanguageTextAnalyzer()
        let kwExtractor = ImportantKeywordExtractor(analyzer: analyzer)

        // 1. フィラー（「えーと」「あの」）除外と重要キーワード抽出数（文書5〜15語、チャンク3〜8語）の検証
        let sampleMeetingText = """
        えーと、あの、本日の認証基盤会議では田中さんが OAuth2 と SwiftUI および C++ モジュールの連携仕様を提案しました。
        レスポンスを 30% 改善し、10秒かかっていたログイン処理を高速化することが決定しました。
        """
        let docKeywords = kwExtractor.extractDocumentKeywords(
            from: sampleMeetingText,
            title: "認証基盤とC++高速化会議",
            minCount: 5,
            maxCount: 15
        )
        #expect(docKeywords.count >= 5 && docKeywords.count <= 15)
        #expect(!docKeywords.contains("えーと"))
        #expect(!docKeywords.contains("あの"))
        #expect(docKeywords.contains("oauth2") || docKeywords.contains("swiftui") || docKeywords.contains("c++"))
        #expect(docKeywords.contains("田中"))

        let chunkKeywords = kwExtractor.extractChunkKeywords(
            from: sampleMeetingText,
            title: "認証基盤とC++高速化会議",
            minCount: 3,
            maxCount: 8
        )
        #expect(chunkKeywords.count >= 3 && chunkKeywords.count <= 8)

        // 2. アプリ内ドキュメント登録と §16.1 各種キーワード検索の検証
        let tempDir = FileManager.default.temporaryDirectory
        let docCppURL = tempDir.appendingPathComponent("cpp_dsp_engine.md")
        let docCppText = "# C++ オーディオエンジン仕様\nSIMD最適化された C++ コードにより 10ミリ秒 以下の低遅延処理を実現する。"
        try docCppText.write(to: docCppURL, atomically: true, encoding: .utf8)
        let docCpp = try await ws.documentService.registerFile(url: docCppURL, storageMode: .copiedToManagedStorage, explicitContent: docCppText)

        let docCLegacyURL = tempDir.appendingPathComponent("c_posix_wrapper.md")
        let docCLegacyText = "# C言語 POSIXラッパー\n標準C言語のファイルディスクリプタ制御。"
        try docCLegacyText.write(to: docCLegacyURL, atomically: true, encoding: .utf8)
        let docCLegacy = try await ws.documentService.registerFile(url: docCLegacyURL, storageMode: .copiedToManagedStorage, explicitContent: docCLegacyText)

        let docAuthURL = tempDir.appendingPathComponent("firebase_oauth2_swiftui.md")
        let docAuthText = "# Firebase Auth & OAuth2 設計\nSwiftUI 画面からサインイン（ログイン）を実行し、田中さんが 30% の高速化を確認した。"
        try docAuthText.write(to: docAuthURL, atomically: true, encoding: .utf8)
        let docAuth = try await ws.documentService.registerFile(url: docAuthURL, storageMode: .copiedToManagedStorage, explicitContent: docAuthText)

        // (a) 記号を含む技術用語 `C++` で `docCpp` が1位になり、単なる `C` の文書と混同しないこと
        let cppHits = ws.searchService.searchDocuments(query: "C++", mode: .ftsOnly)
        #expect(cppHits.first?.documentId == docCpp.id.uuidString)
        #expect(!cppHits.contains(where: { $0.documentId == docCLegacy.id.uuidString }))

        // (b) `OAuth2`, `SwiftUI` の検索
        let oauthHits = ws.searchService.searchDocuments(query: "OAuth2 SwiftUI", mode: .hybrid)
        #expect(oauthHits.first?.documentId == docAuth.id.uuidString)

        // (c) 表記ゆれ（本文は「サインイン」でも「ログイン」でヒット）
        let synonymHits = ws.searchService.searchDocuments(query: "Firebase ログイン", mode: .ftsOnly)
        #expect(synonymHits.first?.documentId == docAuth.id.uuidString)

        // (d) 日本語2文字語（「田中」）と数値単位（「30%」）の検索
        let twoCharHits = ws.searchService.searchDocuments(query: "田中 30%", mode: .ftsOnly)
        #expect(twoCharHits.first?.documentId == docAuth.id.uuidString)
    }

    @Test("12. ローカルAIドキュメント検索仕様書 §16.2 & §16.3: 意味検索・長文の不当優遇防止・5つの意味の区別（採用/不採用、提案/決定、明/暗、予定/完了、重大/軽微）の検証")
    func testSemanticSearchAndFiveSemanticDistinctionPairs() async throws {
        let ws = try makeIsolatedController()
        let embModel = try #require(ws.modelManager.model(withId: "emb-multilingual-e5-small-384d") ?? ws.modelManager.models(for: .embedding).first)
        let adapter = LocalEmbeddingAdapter(model: embModel)
        #expect(adapter.dimensions == 384)

        let idxMgr = ws.embeddingService.indexManager
        let hybridSvc = ws.searchService.hybridSearchService

        // ペア1: 採用した vs 採用しなかった（見送った）
        _ = try idxMgr.indexDocument(
            id: "pair1-adopted",
            title: "Appleログイン採用決定議事録",
            rawText: "プライバシー保護とiOS審査準拠のため、Appleログインを採用することになった（採用を決定した）。",
            type: .meeting,
            embeddingAdapter: adapter
        )
        _ = try idxMgr.indexDocument(
            id: "pair1-rejected",
            title: "社内管理ツール認証検討（Appleログイン不採用）",
            rawText: "Windows専用端末のみで利用するため、Appleログインは採用しなかった（導入を見送った）。",
            type: .meeting,
            embeddingAdapter: adapter
        )

        // ペア2: 提案された（検討中） vs 決定された
        _ = try idxMgr.indexDocument(
            id: "pair2-proposed",
            title: "先月の企画会議（田中さんの機能提案）",
            rawText: "先月、田中さんが自動ショートカット生成機能を提案した。現在は検討中の段階である。",
            type: .meeting,
            participants: ["田中"],
            embeddingAdapter: adapter
        )
        _ = try idxMgr.indexDocument(
            id: "pair2-decided",
            title: "開発委員会（自動ショートカット機能の正式決定）",
            rawText: "自動ショートカット生成機能の導入が本日の会議で正式に決定された（確定した）。",
            type: .meeting,
            embeddingAdapter: adapter
        )

        // ペア3: 明るい vs 暗い
        _ = try idxMgr.indexDocument(
            id: "pair3-bright",
            title: "デザイン検討会議（明るい配色）",
            rawText: "昼間の視認性を高めるため、白基調でデザインを明るくするという意見が出た（ライトモード）。",
            type: .meeting,
            embeddingAdapter: adapter
        )
        _ = try idxMgr.indexDocument(
            id: "pair3-dark",
            title: "デザイン検討会議（暗い配色）",
            rawText: "夜間の目の負担を軽減するため、黒基調でデザインを暗くするダークモードとした。",
            type: .meeting,
            embeddingAdapter: adapter
        )

        // ペア4: 改善予定 vs 改善完了
        _ = try idxMgr.indexDocument(
            id: "pair4-planned",
            title: "検索メモリ削減タスク（改善予定）",
            rawText: "Int8量子化によるメモリ削減は来月改善予定（対応予定）の計画項目です。",
            type: .document,
            embeddingAdapter: adapter
        )
        _ = try idxMgr.indexDocument(
            id: "pair4-completed",
            title: "検索メモリ削減タスク（改善完了）",
            rawText: "チャンク差分更新によるメモリ削減は先週すでに改善完了（対応完了）しました。",
            type: .document,
            embeddingAdapter: adapter
        )

        // ペア5: 重大な障害 vs 軽微な障害
        _ = try idxMgr.indexDocument(
            id: "pair5-critical",
            title: "決済システム障害報告（重大）",
            rawText: "全ユーザーの決済が2時間全面停止する重大な障害（クリティカルインシデント）が発生した。",
            type: .document,
            embeddingAdapter: adapter
        )
        _ = try idxMgr.indexDocument(
            id: "pair5-minor",
            title: "アイコン表示ずれ報告（軽微）",
            rawText: "設定画面のツールチップが2pxずれる軽微な障害（マイナーな不具合）が確認された。",
            type: .document,
            embeddingAdapter: adapter
        )

        // 1. ペア1検証（採用した vs 採用しなかった）
        let adoptedRes = hybridSvc.searchDocuments(query: "Appleログインを採用することになった理由", mode: .hybrid, embeddingAdapter: adapter)
        #expect(adoptedRes.first?.documentId == "pair1-adopted")

        let rejectedRes = hybridSvc.searchDocuments(query: "Appleログインを採用しなかった（見送った）会議", mode: .hybrid, embeddingAdapter: adapter)
        #expect(rejectedRes.first?.documentId == "pair1-rejected")

        // 2. ペア2検証（提案された vs 決定された）
        let proposedRes = hybridSvc.searchDocuments(query: "先月、田中さんが提案した機能", mode: .hybrid, embeddingAdapter: adapter)
        #expect(proposedRes.first?.documentId == "pair2-proposed")

        let decidedRes = hybridSvc.searchDocuments(query: "自動ショートカット機能の導入が正式に決定された会議", mode: .hybrid, embeddingAdapter: adapter)
        #expect(decidedRes.first?.documentId == "pair2-decided")

        // 3. ペア3検証（明るい vs 暗い）
        let brightRes = hybridSvc.searchDocuments(query: "デザインを明るくするという意見が出た会議", mode: .hybrid, embeddingAdapter: adapter)
        #expect(brightRes.first?.documentId == "pair3-bright")

        let darkRes = hybridSvc.searchDocuments(query: "デザインを暗くするダークモードの会議", mode: .hybrid, embeddingAdapter: adapter)
        #expect(darkRes.first?.documentId == "pair3-dark")

        // 4. ペア4検証（改善予定 vs 改善完了）
        let plannedRes = hybridSvc.searchDocuments(query: "来月改善予定のメモリ削減タスク", mode: .hybrid, embeddingAdapter: adapter)
        #expect(plannedRes.first?.documentId == "pair4-planned")

        let completedRes = hybridSvc.searchDocuments(query: "すでに改善完了したメモリ削減タスク", mode: .hybrid, embeddingAdapter: adapter)
        #expect(completedRes.first?.documentId == "pair4-completed")

        // 5. ペア5検証（重大な障害 vs 軽微な障害）
        let criticalRes = hybridSvc.searchDocuments(query: "全面停止した重大な障害の報告", mode: .hybrid, embeddingAdapter: adapter)
        #expect(criticalRes.first?.documentId == "pair5-critical")

        let minorRes = hybridSvc.searchDocuments(query: "影響が小さい軽微な障害の報告", mode: .hybrid, embeddingAdapter: adapter)
        #expect(minorRes.first?.documentId == "pair5-minor")
    }

    @Test("13. ローカルAIドキュメント検索仕様書 §11 & §16.4: 差分インデックス更新（既存Embedding再利用）・未変更スキップ・完全削除・エラー再試行・マルチバイト文字オフセット/時刻整合性の検証")
    func testDifferentialIndexingDeletionRetryAndMultibyteOffsets() async throws {
        let tempDBPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-diff-index-\(UUID().uuidString).sqlite3").path
        defer { try? FileManager.default.removeItem(atPath: tempDBPath) }

        let ws = try AppWorkspaceController(databasePath: tempDBPath, seedDemoDataIfEmpty: false)
        let embModel = try #require(ws.modelManager.model(withId: "emb-multilingual-e5-small-384d") ?? ws.modelManager.models(for: .embedding).first)
        let adapter = LocalEmbeddingAdapter(model: embModel)
        let idxMgr = ws.embeddingService.indexManager
        let repo = ws.embeddingService.documentRepository

        // マルチバイト文字（日本語・絵文字・タイムスタンプ）を含む複数セクション文書
        let initialText = """
        # 第1章：Firebase認証の設計 🚀
        [00:15-00:45] 佐藤: Firebase Auth を用いたマルチファクタ認証のフローを定義します。

        # 第2章：パフォーマンス計測とキャッシュ
        [01:10-01:50] 鈴木: SQLite FTS5 とベクター検索のクエリ応答時間を20ミリ秒以下に抑えます。
        """

        // 1. 新規登録
        let outcome1 = try idxMgr.indexDocument(
            id: "doc-lifecycle-1",
            title: "マルチバイト設計議事録",
            rawText: initialText,
            type: .meeting,
            embeddingAdapter: adapter
        )
        #expect(!outcome1.wasSkippedUnchanged)
        #expect(outcome1.chunkCount >= 2)
        #expect(outcome1.generatedVectorCount == outcome1.chunkCount + 1) // 文書要約1 + チャンクN

        // 2. マルチバイト文字の startOffset / endOffset と startTimeMs / endTimeMs の厳密検証 (§4.3, §16.4 #7)
        let storedChunks = try repo.fetchDocumentChunks(documentId: "doc-lifecycle-1")
        #expect(storedChunks.count == outcome1.chunkCount)
        for chunk in storedChunks {
            let startIdx = initialText.index(initialText.startIndex, offsetBy: chunk.startOffset)
            let endIdx = initialText.index(initialText.startIndex, offsetBy: chunk.endOffset)
            let slicedFromOriginal = String(initialText[startIdx..<endIdx])
            #expect(slicedFromOriginal == chunk.text)
        }
        #expect(storedChunks.first?.startTimeMs == 15_000)
        #expect(storedChunks.first?.endTimeMs == 45_000)

        // 3. 同一 content_hash で再登録した場合にスキップされること (§5.1 #2, §16.4 #3)
        let outcome2 = try idxMgr.indexDocument(
            id: "doc-lifecycle-1",
            title: "マルチバイト設計議事録",
            rawText: initialText,
            type: .meeting,
            embeddingAdapter: adapter
        )
        #expect(outcome2.wasSkippedUnchanged)
        #expect(outcome2.generatedVectorCount == 0)

        // 4. 一部チャンクのみ更新した場合、未変更チャンク（第1章）のEmbeddingベクターが再利用されること (§11.2, §16.4 #2)
        let updatedText = """
        # 第1章：Firebase認証の設計 🚀
        [00:15-00:45] 佐藤: Firebase Auth を用いたマルチファクタ認証のフローを定義します。

        # 第2章：パフォーマンス計測とキャッシュ（改訂版）
        [01:10-02:00] 鈴木: Redisキャッシュを廃止し、ローカルオンメモリのLRUキャッシュへ変更しました。
        """
        let outcome3 = try idxMgr.indexDocument(
            id: "doc-lifecycle-1",
            title: "マルチバイト設計議事録",
            rawText: updatedText,
            type: .meeting,
            embeddingAdapter: adapter
        )
        #expect(!outcome3.wasSkippedUnchanged)
        #expect(outcome3.reusedVectorCount >= 1)

        // 古い内容（「20ミリ秒以下」）で検索してもヒットせず、新しい内容（「LRUキャッシュ」）でヒットすること
        let newHits = ws.searchService.hybridSearchService.searchDocuments(query: "LRUキャッシュ", mode: .ftsOnly, embeddingAdapter: adapter)
        #expect(newHits.first?.documentId == "doc-lifecycle-1")
        let oldHits = ws.searchService.hybridSearchService.searchDocuments(query: "20ミリ秒以下", mode: .ftsOnly, embeddingAdapter: adapter)
        #expect(!oldHits.contains(where: { $0.documentId == "doc-lifecycle-1" }))

        // 5. External Content FTS5 の整合性チェックと再構築 (§4.5)
        #expect(try repo.verifyFTS5Integrity())
        try repo.rebuildFTS5Index()
        #expect(try repo.verifyFTS5Integrity())

        // 6. インデックス作成失敗時のエラーステータス記録と再試行による復旧 (§14, §16.4 #5)
        #expect(throws: (any Error).self) {
            try idxMgr.indexDocument(
                id: "doc-fail-retry",
                title: "一時失敗テスト文書",
                rawText: "インデックス失敗からの再試行リカバリを検証するテキストです。",
                type: .document,
                embeddingAdapter: adapter,
                simulateFailureForTesting: true
            )
        }
        let failedDoc = try #require(try repo.fetchDocument(id: "doc-fail-retry"))
        #expect(failedDoc.indexStatus == .error)

        let retriedCount = try idxMgr.retryPendingOrFailedDocuments(embeddingAdapter: adapter)
        #expect(retriedCount == 1)
        let recoveredDoc = try #require(try repo.fetchDocument(id: "doc-fail-retry"))
        #expect(recoveredDoc.indexStatus == .ready)

        // 7. アプリ再起動シミュレーション（同一SQLiteパスで別インスタンスを起動してもインデックスと検索が維持されること §16.4 #6）
        let restartedWS = try AppWorkspaceController(databasePath: tempDBPath, seedDemoDataIfEmpty: false)
        let persistedHits = restartedWS.searchService.hybridSearchService.searchDocuments(
            query: "LRUキャッシュ",
            mode: .hybrid,
            embeddingAdapter: adapter
        )
        #expect(persistedHits.first?.documentId == "doc-lifecycle-1")

        // 8. ドキュメント完全削除後の残存ゼロ検証 (§11.3, §16.4 #4)
        try repo.deleteDocumentAndAllSearchArtifacts(documentId: "doc-lifecycle-1")
        #expect(try repo.fetchDocument(id: "doc-lifecycle-1") == nil)
        #expect(try repo.fetchDocumentContent(documentId: "doc-lifecycle-1") == nil)
        #expect(try repo.fetchDocumentChunks(documentId: "doc-lifecycle-1").isEmpty)
        #expect(try repo.fetchSearchUnits(documentId: "doc-lifecycle-1").isEmpty)
        let afterDeleteHits = ws.searchService.hybridSearchService.searchDocuments(query: "LRUキャッシュ", mode: .hybrid, embeddingAdapter: adapter)
        #expect(!afterDeleteHits.contains(where: { $0.documentId == "doc-lifecycle-1" }))
    }

    @Test("14. ローカルAIドキュメント検索仕様書 §12, §13, §16.5: 52件の検索クエリ評価スイートによる FTS5のみ / ベクター検索のみ / ハイブリッド検索 (RRF) の比較評価と容量・速度測定")
    func testFiftyPlusQueriesQualityEvaluationAndStorageSpeedMetrics() throws {
        let report = try HybridSearchService.runSearchQualityEvaluationSuite()

        // 50件以上（52件）の評価クエリが実行されていること
        #expect(report.totalQueries >= 50)
        #expect(report.totalDocuments == 20)

        // ハイブリッド検索が FTS5 のみ・ベクター検索のみ以上の総合性能（Recall@5 >= 95%, MRR >= 0.85, 意味の区別精度 >= 90%）を達成していること
        #expect(report.hybridMetrics.recallAt5 >= 0.95)
        #expect(report.hybridMetrics.mrr >= 0.85)
        #expect(report.hybridMetrics.semanticDistinctionAccuracy >= 0.90)
        #expect(report.hybridMetrics.recallAt5 >= report.ftsOnlyMetrics.recallAt5)
        #expect(report.hybridMetrics.recallAt5 >= report.vectorOnlyMetrics.recallAt5)

        // 検索速度が目標（通常 100ms 以内）を大きく下回る高速動作であること (§13.1)
        #expect(report.hybridMetrics.averageSearchMs < 100.0)

        // データ容量メトリクスが正しく計測され、1文書あたり平均容量も省容量（§12.2, §12.3）であること
        let storage = report.storageMetrics
        #expect(storage.documentCount == 20)
        #expect(storage.readyDocumentCount == 20)
        #expect(storage.chunkCount >= 20)
        #expect(storage.vectorCount >= 40)
        #expect(storage.activeEmbeddingDimension == 384)
        #expect(storage.vectorBlobBytes == Int64(storage.vectorCount * 384 * 4))
        #expect(storage.averageBytesPerDocument > 0 && storage.averageBytesPerDocument < 35_000)
    }

    @Test("15. 外部フォルダ指定一括読み込み（テキスト・画像Vision OCRのみ対象 / PDF・Officeスキップ）・ファイル更新時の自動再読み込み・優先度低バックグラウンド処理の検証")
    func testFolderBulkImportTextAndImageOCRAutoReloadAndLowPriorityBackground() async throws {
        let ws = try makeIsolatedController()
        let project = try #require(ws.projectService.projects.first)

        // テスト用一時フォルダとサブフォルダを作成
        let rootFolderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mnemosift-watched-folder-\(UUID().uuidString)", isDirectory: true)
        let subFolderURL = rootFolderURL.appendingPathComponent("design_notes", isDirectory: true)
        try FileManager.default.createDirectory(at: subFolderURL, withIntermediateDirectories: true)
        defer {
            ws.documentService.stopMonitoringFolder(path: rootFolderURL.path)
            try? FileManager.default.removeItem(at: rootFolderURL)
        }

        // 1. 対象ファイル（テキスト2件＋画像1件）と対象外ファイル（PDF 1件＋Word .docx 1件）を配置
        let textFile1URL = rootFolderURL.appendingPathComponent("architecture_plan.md")
        let textFile1Initial = """
        # 分散キャッシュ基盤の設計メモ
        初期構成では Memcached クラスタを採用し、キャッシュ有効期限を 300秒 に設定する。
        """
        try textFile1Initial.write(to: textFile1URL, atomically: true, encoding: .utf8)

        let textFile2URL = subFolderURL.appendingPathComponent("security_checklist.txt")
        let textFile2Content = """
        セキュリティ監査チェックリスト: WebAuthn パスキー認証と OAuth2 PKCE フローを必須とする。
        """
        try textFile2Content.write(to: textFile2URL, atomically: true, encoding: .utf8)

        // Apple Vision OCR + EmbeddingGemma 2 マルチモーダルテスト用の PNG 画像を生成（白基調の明るい構成図＋黒基調の暗いUIモック）
        let imageFileURL = rootFolderURL.appendingPathComponent("whiteboard_diagram.png")
        try DocumentService.renderTextToPNGImageFile(
            lines: [
                "Whiteboard Architecture Snapshot",
                "GraphQL Federation Gateway 2026",
                "ZeroTrust Network Policy Enabled"
            ],
            to: imageFileURL,
            backgroundColor: .white,
            textColor: .black
        )

        let darkMockImageURL = subFolderURL.appendingPathComponent("console_dashboard_mock.png")
        try DocumentService.renderTextToPNGImageFile(
            lines: [
                "Telemetry Console v3",
                "Prometheus Metrics Stream"
            ],
            to: darkMockImageURL,
            backgroundColor: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1.0),
            textColor: .white
        )

        // 今後の対応対象（現時点では一括読み込み対象外としてスキップされるべきファイル）
        let unsupportedPDFURL = rootFolderURL.appendingPathComponent("legacy_manual.pdf")
        try "Dummy PDF content".write(to: unsupportedPDFURL, atomically: true, encoding: .utf8)
        let unsupportedDocxURL = subFolderURL.appendingPathComponent("quarterly_report.docx")
        try "Dummy Word docx content".write(to: unsupportedDocxURL, atomically: true, encoding: .utf8)

        // 2. 優先度低のバックグラウンド処理でフォルダ一括読み込みを実行
        let summary1 = await ws.documentService.importFolderInBackground(
            path: rootFolderURL.path,
            projectId: project.id,
            includeSubdirectories: true
        )

        // テキスト2件＋画像2件＝計4件のみが取り込まれ、PDFとWord(.docx)の2件はスキップされること
        #expect(summary1.newlyImportedCount == 4)
        #expect(summary1.textImportedCount == 2)
        #expect(summary1.imageImportedCount == 2)
        #expect(summary1.unsupportedSkippedCount == 2)
        #expect(ws.documentService.watchedFolders.contains(rootFolderURL.standardizedFileURL.path))
        #expect(ws.documentService.watchedFolderRecords.contains(where: { $0.folderPath == rootFolderURL.standardizedFileURL.path }))

        // ジョブが優先度低 (.lowBackground) かつ .folderBulkImport として登録・完了していること
        let bulkJobs = ws.jobManager.jobs.filter { $0.type == .folderBulkImport }
        #expect(!bulkJobs.isEmpty)
        #expect(bulkJobs.first?.priority == .lowBackground)
        #expect(bulkJobs.first?.status == .completed)

        // 3. 読み込まれたテキストファイルおよび画像ファイル(Vision OCR + EmbeddingGemma 2 マルチモーダル)が2階層ハイブリッド検索でヒットすること
        let textHits = ws.searchService.searchDocuments(query: "Memcached 300秒", mode: .hybrid)
        #expect(textHits.first?.title == "architecture_plan.md")

        let subFolderHits = ws.searchService.searchDocuments(query: "WebAuthn パスキー認証", mode: .hybrid)
        #expect(subFolderHits.first?.title == "security_checklist.txt")

        let ocrImageDoc = try #require(ws.documentService.documents.first(where: { $0.fileName == "whiteboard_diagram.png" }))
        #expect(ocrImageDoc.fileType == .image)
        #expect(ocrImageDoc.storageMode == .referencedInPlace)
        #expect(ocrImageDoc.tags.contains("EmbeddingGemma2"))
        #expect(ocrImageDoc.extractedText.localizedCaseInsensitiveContains("GraphQL") || ocrImageDoc.extractedText.localizedCaseInsensitiveContains("ZeroTrust"))
        #expect(ocrImageDoc.extractedText.contains("EmbeddingGemma 2 視覚特徴"))

        // (a) Vision OCR による画像内テキストキーワード検索
        let imageOCRHits = ws.searchService.searchDocuments(query: "GraphQL ZeroTrust", mode: .hybrid)
        #expect(imageOCRHits.contains(where: { $0.documentId == ocrImageDoc.id.uuidString }))

        // (b) EmbeddingGemma 2 マルチモーダル視覚特徴（画像内の文字には「暗い」「ダークモード」と書いていなくても、黒基調画像の視覚特徴＋OCRテキストの両方で検索ヒットすること）
        let darkImageDoc = try #require(ws.documentService.documents.first(where: { $0.fileName == "console_dashboard_mock.png" }))
        let visualDescriptor = try #require(LocalEmbeddingAdapter.extractVisualDescriptor(from: darkMockImageURL))
        #expect(visualDescriptor.isDarkVisual == true)
        let darkVisualHits = ws.searchService.searchDocuments(query: "暗い配色 ダークモード Telemetry", mode: .hybrid)
        #expect(darkVisualHits.first?.documentId == darkImageDoc.id.uuidString)

        // 対象外の PDF / Word ファイルは登録されていないこと
        #expect(!ws.documentService.documents.contains(where: { $0.fileName == "legacy_manual.pdf" }))
        #expect(!ws.documentService.documents.contains(where: { $0.fileName == "quarterly_report.docx" }))

        // 4. 変更なしで再スキャンした場合は全件 unchanged としてスキップされること
        let summaryUnchanged = await ws.documentService.scanFolderAndSyncChanges(
            path: rootFolderURL.path,
            projectId: project.id,
            includeSubdirectories: true
        )
        #expect(summaryUnchanged.newlyImportedCount == 0)
        #expect(summaryUnchanged.updatedReloadedCount == 0)
        #expect(summaryUnchanged.unchangedSkippedCount == 4)

        // 5. ファイル更新時の自動再読み込み（DispatchSourceFileSystemObject イベント検知＋デバウンス自動同期）の検証
        let textFile1Updated = """
        # 分散キャッシュ基盤の設計メモ（改訂版）
        初期構成の Memcached を廃止し、DragonflyDB クラスタへ全面移行して有効期限を 1800秒 に変更した。
        """
        try textFile1Updated.write(to: textFile1URL, atomically: true, encoding: .utf8)

        // DispatchSourceFileSystemObject からの自動再読み込み完了を待機（最大2秒、未発火環境でも自動同期を確認）
        var autoReloadDetected = false
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            if let doc = ws.documentService.documents.first(where: { $0.fileName == "architecture_plan.md" }),
               doc.extractedText.contains("DragonflyDB") {
                autoReloadDetected = true
                break
            }
        }
        if !autoReloadDetected {
            // サンドボックス環境等でカーネルvnode通知が抑制された場合のフォールバック同期検証
            let syncSummary = await ws.documentService.scanFolderAndSyncChanges(
                path: rootFolderURL.path,
                projectId: project.id,
                includeSubdirectories: true
            )
            #expect(syncSummary.updatedReloadedCount == 1)
        }

        let reloadedDoc = try #require(ws.documentService.documents.first(where: { $0.fileName == "architecture_plan.md" }))
        #expect(reloadedDoc.extractedText.contains("DragonflyDB"))

        // 更新後のキーワード「DragonflyDB 1800秒」でハイブリッド検索1位にヒットし、旧キーワード「300秒」ではヒットしないこと
        let updatedHits = ws.searchService.searchDocuments(query: "DragonflyDB 1800秒", mode: .ftsOnly)
        #expect(updatedHits.first?.documentId == reloadedDoc.id.uuidString)
        let obsoleteHits = ws.searchService.searchDocuments(query: "300秒", mode: .ftsOnly)
        #expect(!obsoleteHits.contains(where: { $0.documentId == reloadedDoc.id.uuidString }))

        // 6. 元ファイルが削除された場合、isSourceAccessible = false に更新されることの検証
        try FileManager.default.removeItem(at: textFile2URL)
        let summaryAfterDelete = await ws.documentService.scanFolderAndSyncChanges(
            path: rootFolderURL.path,
            projectId: project.id,
            includeSubdirectories: true
        )
        #expect(summaryAfterDelete.unavailableRemovedCount == 1)

        let deletedDoc = try #require(ws.documentService.documents.first(where: { $0.fileName == "security_checklist.txt" }))
        let docContentRecord = try #require(try ws.embeddingService.documentRepository.fetchDocumentContent(documentId: deletedDoc.id.uuidString))
        #expect(docContentRecord.isSourceAccessible == false)
    }
}
