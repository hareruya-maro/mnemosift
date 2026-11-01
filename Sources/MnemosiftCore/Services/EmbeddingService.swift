import Foundation
import Observation

/// 仕様書 §3.5 & §11.3 & ローカルAIドキュメント検索機能 実装仕様書 v1.0 (§4, §5, §11):
/// Embedding・2階層検索インデックス管理サービス
/// - アプリ内で登録・変更されたファイル、文字起こし、議事録に対して2階層（文書要約＋チャンク）のインデックスと差分更新を実行
/// - 不要な全件再生成を避け、Embeddingモデル変更時・インデックス仕様バージョン更新時に再インデックスを実行する
@Observable
@MainActor
public final class EmbeddingService {
    private let database: LocalDatabase
    private let modelManager: ModelManager
    private let jobManager: JobManager

    public let documentRepository: DocumentRepository
    public let indexManager: IndexManager

    public private(set) var chunks: [KnowledgeChunk] = []
    public private(set) var embeddingsByChunkId: [UUID: EmbeddingRecord] = [:]
    public private(set) var activeEmbeddingModelId: String

    public init(database: LocalDatabase, modelManager: ModelManager, jobManager: JobManager) {
        self.database = database
        self.modelManager = modelManager
        self.jobManager = jobManager
        self.activeEmbeddingModelId = modelManager.globalSettings.embeddingModelId

        let repo = DocumentRepository(database: database)
        self.documentRepository = repo
        self.indexManager = IndexManager(repository: repo)

        let loadedChunks = (try? database.loadKnowledgeChunks()) ?? []
        let loadedEmbeddings = (try? database.loadEmbeddingRecords()) ?? []
        self.chunks = loadedChunks
        var map: [UUID: EmbeddingRecord] = [:]
        for record in loadedEmbeddings {
            map[record.chunkId] = record
        }
        self.embeddingsByChunkId = map
    }

    /// ファイル登録・更新時の差分インデックス更新（2階層 SQLite + FTS5 External Content + Vector Store 連携）
    @discardableResult
    public func indexDocument(_ document: Document, projectIds: [UUID]) throws -> DocumentIndexingOutcome {
        try database.deleteKnowledgeChunks(sourceId: document.id)
        chunks.removeAll { $0.sourceId == document.id }

        let embModel = modelManager.model(withId: modelManager.globalSettings.embeddingModelId)
            ?? modelManager.models(for: .embedding).first!
        let adapter = LocalEmbeddingAdapter(model: embModel)
        let imageURL: URL? = document.fileType.isImageFile ? URL(fileURLWithPath: document.filePath) : nil

        let paragraphs = Self.splitIntoChunks(text: document.extractedText, maxLength: 360)
        for (idx, paragraph) in paragraphs.enumerated() {
            let isImportant = paragraph.contains("決定") || paragraph.contains("仕様") || paragraph.contains("重要") || paragraph.contains("必須")
            let chunk = KnowledgeChunk(
                sourceType: .document,
                sourceId: document.id,
                projectIds: projectIds,
                title: document.fileName,
                content: paragraph,
                chunkIndex: idx,
                locationHint: "\(document.fileName) (セクション #\(idx + 1))",
                isDecisionOrImportant: isImportant,
                sourceUpdatedAt: document.updatedAt
            )
            let vector = adapter.generateMultimodalEmbedding(
                forText: "\(document.fileName) \(document.tags.joined(separator: " ")) \(paragraph)",
                imageURL: imageURL
            )
            let record = EmbeddingRecord(
                chunkId: chunk.id,
                modelId: embModel.id,
                dimensions: adapter.dimensions,
                vector: vector
            )
            try database.saveKnowledgeChunk(chunk)
            try database.saveEmbeddingRecord(record)
            chunks.append(chunk)
            embeddingsByChunkId[chunk.id] = record
        }

        // ローカルAIドキュメント検索仕様書 v1.0 の2階層インデックス（documents / document_contents / document_chunks / search_units / search_units_fts / embeddings）へ登録・差分更新
        let docType: IndexedDocumentType = document.category == .meetingMinutes ? .meeting : .document
        let sourceType: IndexedDocumentSourceType = document.storageMode == .copiedToManagedStorage ? .local : .external
        return try indexManager.indexDocument(
            id: document.id.uuidString,
            title: document.fileName,
            rawText: document.extractedText,
            type: docType,
            sourceType: sourceType,
            sourceURI: document.filePath,
            occurredAt: document.createdAt,
            createdAt: document.createdAt,
            projectIds: projectIds,
            participants: [],
            embeddingAdapter: adapter
        )
    }

    /// ドキュメント削除時の完全インデックス削除（§11.3）
    public func deleteDocumentIndex(documentId: UUID) throws {
        try database.deleteKnowledgeChunks(sourceId: documentId)
        chunks.removeAll { $0.sourceId == documentId }
        try documentRepository.deleteDocumentAndAllSearchArtifacts(documentId: documentId.uuidString)
    }

    /// 文字起こし完了・更新時の差分インデックス更新
    public func indexTranscript(_ transcript: Transcript, segments: [TranscriptSegment]) throws {
        try database.deleteKnowledgeChunks(sourceId: transcript.id)
        chunks.removeAll { $0.sourceId == transcript.id }

        let embModel = modelManager.model(withId: modelManager.globalSettings.embeddingModelId)
            ?? modelManager.models(for: .embedding).first!
        let adapter = LocalEmbeddingAdapter(model: embModel)

        var formattedLines: [String] = []
        var speakerSet: Set<String> = []

        for segment in segments where !segment.isProvisional {
            let timeLabel = LocalLLMAdapter.formatTimestamp(segment.startTimeSeconds)
            let endLabel = LocalLLMAdapter.formatTimestamp(segment.endTimeSeconds)
            speakerSet.insert(segment.speakerLabel)
            formattedLines.append("[\(timeLabel)-\(endLabel)] \(segment.speakerLabel): \(segment.correctedText)")

            let isImportant = segment.correctedText.contains("決定") || segment.correctedText.contains("合意") || segment.correctedText.contains("アクション")
            let chunk = KnowledgeChunk(
                sourceType: .transcriptSegment,
                sourceId: transcript.id,
                projectIds: transcript.projectIds,
                title: transcript.title,
                content: segment.correctedText,
                chunkIndex: segment.sequenceIndex,
                locationHint: "発話 [\(timeLabel)] (\(segment.speakerLabel))",
                isDecisionOrImportant: isImportant,
                sourceUpdatedAt: segment.updatedAt
            )
            let vector = adapter.generateEmbedding(for: "\(transcript.title) \(segment.correctedText)")
            let record = EmbeddingRecord(
                chunkId: chunk.id,
                modelId: embModel.id,
                dimensions: adapter.dimensions,
                vector: vector
            )
            try database.saveKnowledgeChunk(chunk)
            try database.saveEmbeddingRecord(record)
            chunks.append(chunk)
            embeddingsByChunkId[chunk.id] = record
        }

        if !formattedLines.isEmpty {
            let fullTranscriptText = formattedLines.joined(separator: "\n")
            _ = try indexManager.indexDocument(
                id: transcript.id.uuidString,
                title: transcript.title,
                rawText: fullTranscriptText,
                type: .meeting,
                sourceType: .local,
                sourceURI: "transcript://\(transcript.id.uuidString)",
                occurredAt: transcript.createdAt,
                createdAt: transcript.createdAt,
                projectIds: transcript.projectIds,
                participants: Array(speakerSet).sorted(),
                embeddingAdapter: adapter
            )
        }
    }

    /// 議事録生成・更新時の差分インデックス更新
    public func indexMeeting(_ meeting: Meeting) throws {
        try database.deleteKnowledgeChunks(sourceId: meeting.id)
        chunks.removeAll { $0.sourceId == meeting.id }

        let embModel = modelManager.model(withId: modelManager.globalSettings.embeddingModelId)
            ?? modelManager.models(for: .embedding).first!
        let adapter = LocalEmbeddingAdapter(model: embModel)

        var sectionsToIndex: [(text: String, hint: String, important: Bool)] = []
        if !meeting.overview.isEmpty {
            sectionsToIndex.append((meeting.overview, "会議の概要", false))
        }
        for decision in meeting.decisions {
            sectionsToIndex.append((decision, "決定事項", true))
        }
        for item in meeting.actionItems {
            let assignee = item.assignee ?? "未定"
            let due = item.dueDateText ?? "未定"
            sectionsToIndex.append(("\(item.title) (担当: \(assignee), 期限: \(due))", "TODO・アクションアイテム", true))
        }
        for issue in meeting.unresolvedIssues {
            sectionsToIndex.append((issue, "未解決事項", false))
        }

        for (idx, entry) in sectionsToIndex.enumerated() {
            let chunk = KnowledgeChunk(
                sourceType: .meetingMinutes,
                sourceId: meeting.id,
                projectIds: meeting.projectIds,
                title: meeting.title,
                content: entry.text,
                chunkIndex: idx,
                locationHint: "議事録『\(meeting.title)』- \(entry.hint)",
                isDecisionOrImportant: entry.important,
                sourceUpdatedAt: meeting.updatedAt
            )
            let vector = adapter.generateEmbedding(for: "\(meeting.title) \(entry.hint) \(entry.text)")
            let record = EmbeddingRecord(
                chunkId: chunk.id,
                modelId: embModel.id,
                dimensions: adapter.dimensions,
                vector: vector
            )
            try database.saveKnowledgeChunk(chunk)
            try database.saveEmbeddingRecord(record)
            chunks.append(chunk)
            embeddingsByChunkId[chunk.id] = record
        }

        let assignees = meeting.actionItems.compactMap(\.assignee)
        let fullMeetingText = meeting.markdownContent.isEmpty
            ? sectionsToIndex.map { "【\($0.hint)】\n\($0.text)" }.joined(separator: "\n\n")
            : meeting.markdownContent

        _ = try indexManager.indexDocument(
            id: meeting.id.uuidString,
            title: meeting.title,
            rawText: fullMeetingText,
            type: .meeting,
            sourceType: .local,
            sourceURI: "meeting://\(meeting.id.uuidString)",
            occurredAt: meeting.createdAt,
            createdAt: meeting.createdAt,
            projectIds: meeting.projectIds,
            participants: Array(Set(assignees)).sorted(),
            embeddingAdapter: adapter
        )
    }

    /// プロジェクト関連付け変更時に、再ベクトル化を行わずメタデータのみ高速更新する（仕様書 §11.3）
    public func updateProjectAssociationsForSource(sourceId: UUID, projectIds: [UUID]) throws {
        for idx in chunks.indices where chunks[idx].sourceId == sourceId {
            chunks[idx].projectIds = projectIds
            try database.saveKnowledgeChunk(chunks[idx])
        }
        if var indexedDoc = try documentRepository.fetchDocument(id: sourceId.uuidString) {
            indexedDoc.projectIds = projectIds
            indexedDoc.updatedAt = Date()
            try documentRepository.upsertDocument(indexedDoc)
        }
    }

    /// 仕様書 §3.5 & §11.4: Embeddingモデル変更時の互換性確認と必要に応じたインデックス再生成
    @discardableResult
    public func verifyAndReindexIfIncompatible(targetModel: AIModel) async throws -> Int {
        let incompatibleChunks = chunks.filter { chunk in
            guard let rec = embeddingsByChunkId[chunk.id] else { return true }
            return rec.modelId != targetModel.id
        }

        let adapter = LocalEmbeddingAdapter(model: targetModel)
        _ = try indexManager.regenerateAllIndexes(embeddingAdapter: adapter)

        guard !incompatibleChunks.isEmpty else {
            self.activeEmbeddingModelId = targetModel.id
            return 0
        }

        return try await jobManager.enqueueAndRun(
            type: .embeddingGeneration,
            title: "Embedding互換性更新・再インデックス (\(targetModel.name))",
            priority: .lowBackground,
            modelId: targetModel.id,
            requiredMemoryMB: targetModel.requiredMemoryMB
        ) {
            for chunk in incompatibleChunks {
                let vec = adapter.generateEmbedding(for: "\(chunk.title) \(chunk.content)")
                let record = EmbeddingRecord(
                    chunkId: chunk.id,
                    modelId: targetModel.id,
                    dimensions: adapter.dimensions,
                    vector: vec
                )
                try self.database.saveEmbeddingRecord(record)
                self.embeddingsByChunkId[chunk.id] = record
            }
            self.activeEmbeddingModelId = targetModel.id
            return (incompatibleChunks.count, "\(incompatibleChunks.count)件のチャンクを \(targetModel.name) で再ベクトル化しました")
        }
    }

    public static func splitIntoChunks(text: String, maxLength: Int = 360) -> [String] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        var result: [String] = []
        var current = ""
        for line in lines {
            if current.count + line.count + 1 > maxLength && !current.isEmpty {
                result.append(current)
                current = line
            } else {
                current = current.isEmpty ? line : "\(current)\n\(line)"
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
