import Foundation
import SQLite3
import os

public enum DatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case prepareFailed(String)
    case executionFailed(String)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): "SQLiteオープンエラー: \(msg)"
        case .prepareFailed(let msg): "SQLiteクエリ準備エラー: \(msg)"
        case .executionFailed(let msg): "SQLite実行エラー: \(msg)"
        case .encodingFailed(let msg): "データエンコードエラー: \(msg)"
        }
    }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// ローカルSQLite + FTS5 全文検索 + ベクトルインデックスを管理するデータベースサービス
public final class LocalDatabase: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?
    public let databasePath: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.mnemosift.app", category: "LocalDatabase")

    public init(databasePath: String? = nil) throws {
        let resolvedPath: String
        if let databasePath {
            resolvedPath = databasePath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("Mnemosift", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            resolvedPath = dir.appendingPathComponent("mnemosift.sqlite3").path
        }
        self.databasePath = resolvedPath

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        var handle: OpaquePointer?
        if sqlite3_open_v2(
            resolvedPath,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw DatabaseError.openFailed(msg)
        }
        self.db = handle
        try migrate()
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    private func migrate() throws {
        let statements = [
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous = NORMAL;",
            """
            CREATE TABLE IF NOT EXISTS entity_records (
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                parent_id TEXT,
                updated_at REAL NOT NULL,
                json_payload BLOB NOT NULL,
                PRIMARY KEY (entity_type, entity_id)
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_entity_type_updated ON entity_records(entity_type, updated_at DESC);",
            "CREATE INDEX IF NOT EXISTS idx_entity_parent ON entity_records(entity_type, parent_id);",
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_chunks_fts USING fts5(
                chunk_id UNINDEXED,
                title,
                content,
                tokenize = 'unicode61'
            );
            """
        ]
        for sql in statements {
            try executeRaw(sql)
        }
    }

    private func executeRaw(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw DatabaseError.openFailed("Database closed") }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "SQL execution failed"
            sqlite3_free(errMsg)
            throw DatabaseError.executionFailed(message)
        }
    }

    // MARK: - Generic Entity Storage Helper

    public func upsertEntity<T: Codable>(
        type: String,
        id: String,
        parentId: String? = nil,
        updatedAt: Date = Date(),
        value: T
    ) throws {
        let payload = try encoder.encode(value)
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw DatabaseError.openFailed("Database closed") }

        let sql = """
        INSERT INTO entity_records (entity_type, entity_id, parent_id, updated_at, json_payload)
        VALUES (?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(entity_type, entity_id) DO UPDATE SET
            parent_id = excluded.parent_id,
            updated_at = excluded.updated_at,
            json_payload = excluded.json_payload;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, type, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        if let parentId {
            sqlite3_bind_text(stmt, 3, parentId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_double(stmt, 4, updatedAt.timeIntervalSince1970)
        _ = payload.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, 5, rawBuffer.baseAddress, Int32(payload.count), SQLITE_TRANSIENT_DESTRUCTOR)
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func fetchEntities<T: Codable>(
        type: String,
        parentId: String? = nil,
        ascending: Bool = false
    ) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw DatabaseError.openFailed("Database closed") }

        let order = ascending ? "ASC" : "DESC"
        let sql: String
        if parentId != nil {
            sql = "SELECT json_payload FROM entity_records WHERE entity_type = ?1 AND parent_id = ?2 ORDER BY updated_at \(order);"
        } else {
            sql = "SELECT json_payload FROM entity_records WHERE entity_type = ?1 ORDER BY updated_at \(order);"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, type, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        if let parentId {
            sqlite3_bind_text(stmt, 2, parentId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let bytes = sqlite3_column_blob(stmt, 0)
            let count = Int(sqlite3_column_bytes(stmt, 0))
            if let bytes, count > 0 {
                let data = Data(bytes: bytes, count: count)
                if let decoded = try? decoder.decode(T.self, from: data) {
                    results.append(decoded)
                }
            }
        }
        return results
    }

    public func fetchEntity<T: Codable>(type: String, id: String) throws -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw DatabaseError.openFailed("Database closed") }

        let sql = "SELECT json_payload FROM entity_records WHERE entity_type = ?1 AND entity_id = ?2 LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, type, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let bytes = sqlite3_column_blob(stmt, 0)
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard let bytes, count > 0 else { return nil }
        let data = Data(bytes: bytes, count: count)
        return try decoder.decode(T.self, from: data)
    }

    public func deleteEntity(type: String, id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw DatabaseError.openFailed("Database closed") }

        let sql = "DELETE FROM entity_records WHERE entity_type = ?1 AND entity_id = ?2;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, type, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func deleteEntitiesByParent(type: String, parentId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw DatabaseError.openFailed("Database closed") }

        let sql = "DELETE FROM entity_records WHERE entity_type = ?1 AND parent_id = ?2;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, type, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, parentId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - 15 Domain Entities Convenience API

    // 1. Project
    public func saveProject(_ project: Project) throws {
        try upsertEntity(type: "Project", id: project.id.uuidString, updatedAt: project.updatedAt, value: project)
    }
    public func loadProjects() throws -> [Project] {
        try fetchEntities(type: "Project")
    }
    public func deleteProject(id: UUID) throws {
        try deleteEntity(type: "Project", id: id.uuidString)
    }

    // 2. Document
    public func saveDocument(_ document: Document) throws {
        try upsertEntity(type: "Document", id: document.id.uuidString, updatedAt: document.updatedAt, value: document)
    }
    public func loadDocuments() throws -> [Document] {
        try fetchEntities(type: "Document")
    }
    public func deleteDocument(id: UUID) throws {
        try deleteEntity(type: "Document", id: id.uuidString)
    }

    // 3. ProjectDocument
    public func saveProjectDocument(_ link: ProjectDocument) throws {
        try upsertEntity(
            type: "ProjectDocument",
            id: link.id.uuidString,
            parentId: link.projectId.uuidString,
            updatedAt: link.createdAt,
            value: link
        )
    }
    public func loadProjectDocuments(projectId: UUID? = nil) throws -> [ProjectDocument] {
        try fetchEntities(type: "ProjectDocument", parentId: projectId?.uuidString)
    }
    public func deleteProjectDocument(id: UUID) throws {
        try deleteEntity(type: "ProjectDocument", id: id.uuidString)
    }

    // 4. Recording
    public func saveRecording(_ recording: Recording) throws {
        try upsertEntity(type: "Recording", id: recording.id.uuidString, updatedAt: recording.createdAt, value: recording)
    }
    public func loadRecordings() throws -> [Recording] {
        try fetchEntities(type: "Recording")
    }

    // 5. Transcript
    public func saveTranscript(_ transcript: Transcript) throws {
        try upsertEntity(
            type: "Transcript",
            id: transcript.id.uuidString,
            parentId: transcript.recordingId.uuidString,
            updatedAt: transcript.updatedAt,
            value: transcript
        )
    }
    public func loadTranscripts() throws -> [Transcript] {
        try fetchEntities(type: "Transcript")
    }

    // 6. TranscriptSegment
    public func saveTranscriptSegment(_ segment: TranscriptSegment) throws {
        let orderingTime = Date(timeIntervalSince1970: Double(segment.sequenceIndex))
        try upsertEntity(
            type: "TranscriptSegment",
            id: segment.id.uuidString,
            parentId: segment.transcriptId.uuidString,
            updatedAt: orderingTime,
            value: segment
        )
    }
    public func loadTranscriptSegments(transcriptId: UUID) throws -> [TranscriptSegment] {
        try fetchEntities(type: "TranscriptSegment", parentId: transcriptId.uuidString, ascending: true)
    }

    // 7. TranscriptRevision
    public func saveTranscriptRevision(_ revision: TranscriptRevision) throws {
        try upsertEntity(
            type: "TranscriptRevision",
            id: revision.id.uuidString,
            parentId: revision.segmentId.uuidString,
            updatedAt: revision.createdAt,
            value: revision
        )
    }
    public func loadTranscriptRevisions(segmentId: UUID? = nil) throws -> [TranscriptRevision] {
        try fetchEntities(type: "TranscriptRevision", parentId: segmentId?.uuidString)
    }

    // 8. Meeting
    public func saveMeeting(_ meeting: Meeting) throws {
        try upsertEntity(type: "Meeting", id: meeting.id.uuidString, updatedAt: meeting.updatedAt, value: meeting)
    }
    public func loadMeetings() throws -> [Meeting] {
        try fetchEntities(type: "Meeting")
    }
    public func deleteMeeting(id: UUID) throws {
        try deleteEntity(type: "Meeting", id: id.uuidString)
    }

    // 9. Vocabulary
    public func saveVocabulary(_ vocab: Vocabulary) throws {
        try upsertEntity(
            type: "Vocabulary",
            id: vocab.id.uuidString,
            parentId: vocab.projectId?.uuidString,
            updatedAt: vocab.updatedAt,
            value: vocab
        )
    }
    public func loadVocabularies(projectId: UUID? = nil) throws -> [Vocabulary] {
        if let projectId {
            return try fetchEntities(type: "Vocabulary", parentId: projectId.uuidString)
        }
        return try fetchEntities(type: "Vocabulary")
    }
    public func deleteVocabulary(id: UUID) throws {
        try deleteEntity(type: "Vocabulary", id: id.uuidString)
    }

    // 10. KnowledgeChunk (+ FTS5 Index Sync)
    public func saveKnowledgeChunk(_ chunk: KnowledgeChunk) throws {
        try upsertEntity(
            type: "KnowledgeChunk",
            id: chunk.id.uuidString,
            parentId: chunk.sourceId.uuidString,
            updatedAt: chunk.sourceUpdatedAt,
            value: chunk
        )
        try indexChunkInFTS(chunk)
    }

    public func loadKnowledgeChunks(sourceId: UUID? = nil) throws -> [KnowledgeChunk] {
        try fetchEntities(type: "KnowledgeChunk", parentId: sourceId?.uuidString)
    }

    public func deleteKnowledgeChunks(sourceId: UUID) throws {
        let existing = try loadKnowledgeChunks(sourceId: sourceId)
        for chunk in existing {
            try removeChunkFromFTS(chunkId: chunk.id)
            try deleteEntitiesByParent(type: "EmbeddingRecord", parentId: chunk.id.uuidString)
        }
        try deleteEntitiesByParent(type: "KnowledgeChunk", parentId: sourceId.uuidString)
    }

    private func indexChunkInFTS(_ chunk: KnowledgeChunk) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let deleteSql = "DELETE FROM knowledge_chunks_fts WHERE chunk_id = ?1;"
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSql, -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, chunk.id.uuidString, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            _ = sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }

        let insertSql = "INSERT INTO knowledge_chunks_fts (chunk_id, title, content) VALUES (?1, ?2, ?3);"
        var insStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSql, -1, &insStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(insStmt) }
        sqlite3_bind_text(insStmt, 1, chunk.id.uuidString, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(insStmt, 2, chunk.title, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(insStmt, 3, chunk.content, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        _ = sqlite3_step(insStmt)
    }

    private func removeChunkFromFTS(chunkId: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        let sql = "DELETE FROM knowledge_chunks_fts WHERE chunk_id = ?1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, chunkId.uuidString, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// FTS5 による全文検索を実行し、マッチした Chunk ID と BM25 スコアを返す
    public func searchFTS(query: String, limit: Int = 50) -> [UUID: Double] {
        let sanitizedTerms = query
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !sanitizedTerms.isEmpty else { return [:] }

        let ftsQuery = sanitizedTerms.map { "\"\($0)\"*" }.joined(separator: " OR ")
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [:] }

        let sql = """
        SELECT chunk_id, bm25(knowledge_chunks_fts)
        FROM knowledge_chunks_fts
        WHERE knowledge_chunks_fts MATCH ?1
        LIMIT ?2;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ftsQuery, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var scores: [UUID: Double] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0),
               let uuid = UUID(uuidString: String(cString: cStr)) {
                let rawBm25 = abs(sqlite3_column_double(stmt, 1))
                let normalized = min(1.0, 0.5 + (rawBm25 / (1.0 + rawBm25)) * 0.5)
                scores[uuid] = normalized
            }
        }
        return scores
    }

    // 11. EmbeddingRecord
    public func saveEmbeddingRecord(_ record: EmbeddingRecord) throws {
        try upsertEntity(
            type: "EmbeddingRecord",
            id: record.id.uuidString,
            parentId: record.chunkId.uuidString,
            updatedAt: record.createdAt,
            value: record
        )
    }
    public func loadEmbeddingRecords() throws -> [EmbeddingRecord] {
        try fetchEntities(type: "EmbeddingRecord")
    }
    public func clearAllEmbeddingRecords() throws {
        try executeRaw("DELETE FROM entity_records WHERE entity_type = 'EmbeddingRecord';")
    }

    // 12. ProcessingJob
    public func saveProcessingJob(_ job: ProcessingJob) throws {
        try upsertEntity(type: "ProcessingJob", id: job.id.uuidString, updatedAt: job.createdAt, value: job)
    }
    public func loadProcessingJobs() throws -> [ProcessingJob] {
        try fetchEntities(type: "ProcessingJob")
    }

    // 13. AIModel
    public func saveAIModel(_ model: AIModel) throws {
        try upsertEntity(type: "AIModel", id: model.id, value: model)
    }
    public func loadAIModels() throws -> [AIModel] {
        try fetchEntities(type: "AIModel", ascending: true)
    }

    // 14. AISettings
    public func saveAISettings(_ settings: AISettings) throws {
        try upsertEntity(type: "AISettings", id: settings.id, updatedAt: settings.updatedAt, value: settings)
    }
    public func loadGlobalAISettings() throws -> AISettings? {
        try fetchEntity(type: "AISettings", id: "global-settings")
    }

    // 15. FileOperationHistory
    public func saveFileOperationHistory(_ history: FileOperationHistory) throws {
        try upsertEntity(
            type: "FileOperationHistory",
            id: history.id.uuidString,
            parentId: history.documentId.uuidString,
            updatedAt: history.createdAt,
            value: history
        )
    }
    public func loadFileOperationHistories(documentId: UUID? = nil) throws -> [FileOperationHistory] {
        try fetchEntities(type: "FileOperationHistory", parentId: documentId?.uuidString)
    }

    // Custom Templates & Benchmark History
    public func saveMeetingTemplate(_ template: MeetingTemplate) throws {
        try upsertEntity(type: "MeetingTemplate", id: template.id, value: template)
    }
    public func loadMeetingTemplates() throws -> [MeetingTemplate] {
        try fetchEntities(type: "MeetingTemplate", ascending: true)
    }

    public func saveBenchmarkRecord(_ record: BenchmarkMetricRecord) throws {
        try upsertEntity(type: "BenchmarkMetricRecord", id: record.id.uuidString, updatedAt: record.executedAt, value: record)
    }
    public func loadBenchmarkRecords() throws -> [BenchmarkMetricRecord] {
        try fetchEntities(type: "BenchmarkMetricRecord")
    }
}
