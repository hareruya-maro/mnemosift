import Foundation
import Observation

/// アプリ全体のサービス・ナビゲーション状態・プロジェクト選択文脈を統合管理するコントローラー
@Observable
@MainActor
public final class AppWorkspaceController {
    public let database: LocalDatabase
    public let modelManager: ModelManager
    public let jobManager: JobManager
    public let recordingService: RecordingService
    public let correctionService: CorrectionService
    public let sttService: STTService
    public let projectService: ProjectService
    public let embeddingService: EmbeddingService
    public let llmService: LLMService
    public let documentService: DocumentService
    public let searchService: SearchService
    public let meetingPartnerService: MeetingPartnerService
    public let benchmarkRunner: BenchmarkRunner

    // 1ウィンドウ・タブ切替モード（会議パートナー ⇄ 資料検索・整理）
    public var activeMode: WorkspaceMode = .meetingPartner
    public var isShowingPastSessionsDrawer: Bool = false
    public var isShowingSettingsSheet: Bool = false

    // ナビゲーション状態（録音中も自由に画面遷移可能）
    public var selectedSection: NavigationSection = .home
    public var selectedProjectId: UUID?
    public var activeTranscriptId: UUID?
    public var selectedMeetingId: UUID?
    public var selectedDocumentId: UUID?
    public var highlightedSegmentId: UUID?
    public var statusBannerMessage: String?

    public init(databasePath: String? = nil, seedDemoDataIfEmpty: Bool = true) throws {
        let db = try LocalDatabase(databasePath: databasePath)
        self.database = db

        let modelMgr = ModelManager(database: db)
        self.modelManager = modelMgr

        let jobMgr = JobManager(database: db, modelManager: modelMgr)
        self.jobManager = jobMgr

        let recSvc = RecordingService(database: db)
        self.recordingService = recSvc

        let corrSvc = CorrectionService(database: db, modelManager: modelMgr)
        self.correctionService = corrSvc

        let sttSvc = STTService(
            database: db,
            modelManager: modelMgr,
            jobManager: jobMgr,
            correctionService: corrSvc
        )
        self.sttService = sttSvc

        let projSvc = ProjectService(database: db, modelManager: modelMgr, jobManager: jobMgr)
        self.projectService = projSvc

        let embSvc = EmbeddingService(database: db, modelManager: modelMgr, jobManager: jobMgr)
        self.embeddingService = embSvc

        let llmSvc = LLMService(
            database: db,
            modelManager: modelMgr,
            jobManager: jobMgr,
            embeddingService: embSvc
        )
        self.llmService = llmSvc

        let docSvc = DocumentService(
            database: db,
            modelManager: modelMgr,
            jobManager: jobMgr,
            projectService: projSvc,
            embeddingService: embSvc
        )
        self.documentService = docSvc

        let searchSvc = SearchService(
            database: db,
            modelManager: modelMgr,
            jobManager: jobMgr,
            embeddingService: embSvc,
            projectService: projSvc
        )
        self.searchService = searchSvc

        let partnerSvc = MeetingPartnerService(
            searchService: searchSvc,
            documentService: docSvc,
            llmService: llmSvc,
            projectService: projSvc
        )
        self.meetingPartnerService = partnerSvc

        let bench = BenchmarkRunner(
            database: db,
            modelManager: modelMgr,
            jobManager: jobMgr,
            sttService: sttSvc,
            correctionService: corrSvc,
            projectService: projSvc
        )
        self.benchmarkRunner = bench

        if seedDemoDataIfEmpty && sttSvc.transcripts.isEmpty && docSvc.documents.isEmpty {
            Task { @MainActor in
                try? await self.seedInitialWorkspaceSample()
            }
        } else {
            self.activeTranscriptId = sttSvc.transcripts.first?.id
            self.selectedMeetingId = llmSvc.meetings.first?.id
            self.selectedDocumentId = docSvc.documents.first?.id
            self.refreshMeetingPartnerState()
        }
    }

    public func refreshMeetingPartnerState() {
        let tr = activeTranscriptId.flatMap { id in sttService.transcripts.first { $0.id == id } }
            ?? sttService.transcripts.first
        let segs = tr.map { sttService.segments(for: $0.id) } ?? []
        meetingPartnerService.refreshCopilotContext(
            transcript: tr,
            segments: segs,
            activeProjectId: selectedProjectId
        )
    }

    /// 仕様書 §9.6: プロジェクト詳細画面から操作を開始した際に対象プロジェクトを初期選択して画面遷移する
    public func navigateFromProject(_ projectId: UUID, to section: NavigationSection) {
        self.selectedProjectId = projectId
        self.selectedSection = section
        self.activeMode = section == .recording || section == .meetings ? .meetingPartner : .knowledgeHub
        self.refreshMeetingPartnerState()
    }

    /// 仕様書 §8.4 & §6.4: AIチャットの参照元や議事録から該当ファイル・議事録・文字起こし箇所へ直接移動する
    public func jumpToSource(citation: ChatCitation) {
        switch citation.sourceType {
        case .document:
            selectedDocumentId = citation.sourceId
            selectedSection = .files
            activeMode = .knowledgeHub
        case .meetingMinutes:
            selectedMeetingId = citation.sourceId
            selectedSection = .meetings
            activeMode = .knowledgeHub
        case .transcriptSegment:
            activeTranscriptId = citation.sourceId
            selectedSection = .recording
            activeMode = .meetingPartner
            refreshMeetingPartnerState()
        }
        statusBannerMessage = "参照元『\(citation.title)』(\(citation.locationHint)) を表示しています"
    }

    public func jumpToTranscript(from meeting: Meeting, highlightSegmentId: UUID? = nil) {
        if let tid = meeting.transcriptId {
            activeTranscriptId = tid
            highlightedSegmentId = highlightSegmentId
            selectedSection = .recording
        }
    }

    /// 初回起動時にすぐ動作確認できるようサンプル録音・文字起こし・議事録・仕様書データを投入する
    public func seedInitialWorkspaceSample() async throws {
        let defaultProject = projectService.projects.first
        let projectIds = defaultProject.map { [$0.id] } ?? []
        let config = modelManager.resolveConfiguration(project: defaultProject)
        let vocabs = projectService.activeVocabularies(forProjectIds: projectIds)

        // 1. サンプル仕様書ドキュメント登録
        let sampleSpecText = """
        # Mnemosift ローカルAIワークスペース アーキテクチャ仕様書
        本アプリは macOS Apple Silicon (M1以降) 上ですべてのAI推論とデータ保存をローカル完結させる。
        STTモデルには Qwen3-ASR 0.6B / 1.7B、WhisperKit (Whisper Large v3 Turbo)、Apple SpeechAnalyzer をサポートする。
        判断モデル (System One) には Japanese ModernBERT Classifier を用い、リアルタイム文字起こし中の専門用語補正を低遅延で行う。
        議事録生成には Gemma 4 を標準採用し、EmbeddingGemma 2 による意味検索と SQLite FTS5 全文検索を組み合わせたハイブリッドRAGを提供する。
        """
        let tempDir = FileManager.default.temporaryDirectory
        let specURL = tempDir.appendingPathComponent("Mnemosift_Architecture_Spec.md")
        try? sampleSpecText.write(to: specURL, atomically: true, encoding: .utf8)

        let doc = try await documentService.registerFile(
            url: specURL,
            storageMode: .copiedToManagedStorage,
            explicitContent: sampleSpecText,
            initialProjectIds: projectIds
        )
        self.selectedDocumentId = doc.id

        // 2. サンプル録音と文字起こしセッション（誤認識→AI補正の履歴を含む）
        let rec = try recordingService.startRecording(
            title: "アーキテクチャ設計・モデル選定キックオフ会議",
            source: .microphoneAndSystem,
            projectIds: projectIds
        )
        _ = try recordingService.stopRecording()

        let transcript = try sttService.createTranscriptSession(
            for: rec,
            sttModelId: config.realtimeSTTModel.id,
            correctionMode: .fastAI
        )

        let sampleUtterances: [(speaker: String, text: String, start: Double, end: Double)] = [
            ("佐藤", "本日の議題として、ネモシフトのローカルSTTと議事録生成アーキテクチャを確認します。", 0.0, 5.2),
            ("鈴木", "リアルタイム文字起こしにはキュウエン・エーエスアールとウィスパーキットを切り替え可能にする方針で合意しました。", 5.2, 11.5),
            ("佐藤", "決定事項として、議事録生成の標準LLMにはジェマフォーを採用し、音声や文書は外部APIへ一切送信しないこととします。", 11.5, 18.0),
            ("高橋", "アクションアイテムとして、来週金曜日までに鈴木さんがスクリーンキャプチャーキットによるシステム音声録音の長時間テストを実施します。", 18.0, 25.0),
            ("佐藤", "未解決事項として、8GBメモリ環境での大型モデル同時実行時の待機閾値チューニングは引き続き検討中とします。", 25.0, 31.0)
        ]

        for item in sampleUtterances {
            _ = try await sttService.processRealtimeUtteranceChunk(
                transcriptId: transcript.id,
                rawUtteranceText: item.text,
                speakerLabel: item.speaker,
                startTimeSeconds: item.start,
                endTimeSeconds: item.end,
                sttModel: config.realtimeSTTModel,
                correctionMode: .fastAI,
                vocabularies: vocabs,
                projectContextSnippets: [sampleSpecText],
                judgeModel: config.judgeModel,
                llmModel: config.llmModel,
                confidenceThreshold: config.judgeConfidenceThreshold
            )
        }

        let segments = sttService.segments(for: transcript.id)
        try embeddingService.indexTranscript(transcript, segments: segments)

        // 3. サンプル議事録生成
        let meeting = try await llmService.generateMeetingMinutes(
            from: transcript,
            segments: segments,
            templateId: "template-technical",
            project: defaultProject,
            vocabularies: vocabs,
            relatedDocuments: [doc]
        )

        self.activeTranscriptId = transcript.id
        self.selectedMeetingId = meeting.id
        self.refreshMeetingPartnerState()
    }
}
