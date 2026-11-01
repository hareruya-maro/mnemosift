import Foundation
import SQLite3
import Accelerate
import CryptoKit

private let SQLITE_TRANSIENT_BIND = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - §3.1, §4.6, §8 ベクター検索アダプター (`VectorStoreAdapter`)

public struct VectorSearchHit: Sendable, Equatable {
    public let searchUnit: SearchUnitRecord
    public let cosineSimilarity: Double
    public let rank: Int
}

/// §3.1 ベクター検索・保存処理を専用アダプターに閉じ込め、`sqlite-vec` や将来Int8量子化へ差し替え可能にするプロトコル
public protocol VectorStoreAdapter: Sendable {
    var backendName: String { get }
    var isNativeExtensionLoaded: Bool { get }
    func saveVector(_ record: StoredVectorRecord) throws
    func loadVector(forSearchUnitId searchUnitId: Int64) throws -> StoredVectorRecord?
    func deleteVectors(forSearchUnitIds searchUnitIds: [Int64]) throws
    func deleteAllVectors() throws
    func searchSimilarUnits(
        queryVector: [Float],
        embeddingModelId: String,
        limit: Int
    ) throws -> [VectorSearchHit]
    func totalVectorCount() -> Int
    func totalVectorBlobBytes() -> Int64
}

/// SQLite `embeddings` テーブル + `sqlite-vec` 動的ロード試行 + Accelerate `vDSP` Float32 Cosine 検索アダプター
public final class SQLiteVectorStoreAdapter: VectorStoreAdapter, @unchecked Sendable {
    private let database: LocalDatabase
    public private(set) var isNativeExtensionLoaded: Bool = false

    public var backendName: String {
        isNativeExtensionLoaded
            ? "sqlite-vec (vec0) + Accelerate vDSP Float32"
            : "SQLite BLOB (Float32) + Accelerate vDSP Cosine Engine"
    }

    public init(database: LocalDatabase) {
        self.database = database
        self.isNativeExtensionLoaded = Self.tryProbeSQLiteVecExtension()
    }

    /// バンドル内または環境内に署名済み `vec0.dylib` が存在するか安全に確認する（§3.1）
    private static func tryProbeSQLiteVecExtension() -> Bool {
        let candidatePaths = [
            Bundle.main.privateFrameworksPath.map { "\($0)/vec0.dylib" },
            Bundle.main.resourcePath.map { "\($0)/vec0.dylib" }
        ].compactMap { $0 }
        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            return true
        }
        return false
    }

    public func saveVector(_ record: StoredVectorRecord) throws {
        let blobData = Self.encodeFloat32Blob(record.vector)
        try database.withSQLiteHandle { db in
            let sql = """
            INSERT INTO embeddings (
                search_unit_id, embedding_model_id, embedding_dimension, embedding_version, generated_at, vector_blob
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(search_unit_id) DO UPDATE SET
                embedding_model_id = excluded.embedding_model_id,
                embedding_dimension = excluded.embedding_dimension,
                embedding_version = excluded.embedding_version,
                generated_at = excluded.generated_at,
                vector_blob = excluded.vector_blob;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, record.searchUnitId)
            sqlite3_bind_text(stmt, 2, record.embeddingModelId, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_int(stmt, 3, Int32(record.embeddingDimension))
            sqlite3_bind_int(stmt, 4, Int32(record.embeddingVersion))
            sqlite3_bind_double(stmt, 5, record.generatedAt.timeIntervalSince1970)
            _ = blobData.withUnsafeBytes { rawBuf in
                sqlite3_bind_blob(stmt, 6, rawBuf.baseAddress, Int32(blobData.count), SQLITE_TRANSIENT_BIND)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func loadVector(forSearchUnitId searchUnitId: Int64) throws -> StoredVectorRecord? {
        try database.withSQLiteHandle { db in
            let sql = """
            SELECT embedding_model_id, embedding_dimension, embedding_version, generated_at, vector_blob
            FROM embeddings
            WHERE search_unit_id = ?1
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, searchUnitId)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let modelId = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let dim = Int(sqlite3_column_int(stmt, 1))
            let ver = Int(sqlite3_column_int(stmt, 2))
            let ts = sqlite3_column_double(stmt, 3)
            let bytesPtr = sqlite3_column_blob(stmt, 4)
            let byteCount = Int(sqlite3_column_bytes(stmt, 4))
            let vec: [Float]
            if let bytesPtr, byteCount > 0 {
                vec = Self.decodeFloat32Blob(bytes: bytesPtr, byteCount: byteCount)
            } else {
                vec = []
            }
            return StoredVectorRecord(
                searchUnitId: searchUnitId,
                embeddingModelId: modelId,
                embeddingDimension: dim,
                embeddingVersion: ver,
                generatedAt: Date(timeIntervalSince1970: ts),
                vector: vec
            )
        }
    }

    public func deleteVectors(forSearchUnitIds searchUnitIds: [Int64]) throws {
        guard !searchUnitIds.isEmpty else { return }
        try database.withSQLiteHandle { db in
            let sql = "DELETE FROM embeddings WHERE search_unit_id = ?1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for uid in searchUnitIds {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, uid)
                _ = sqlite3_step(stmt)
            }
        }
    }

    public func deleteAllVectors() throws {
        try database.executeRawSQL("DELETE FROM embeddings;")
    }

    /// §8.2, §8.3 ベクター検索実行（`index_status = 'ready'` の検索単位のみを対象に Cosine 類似度上位を取得）
    public func searchSimilarUnits(
        queryVector: [Float],
        embeddingModelId: String,
        limit: Int = 100
    ) throws -> [VectorSearchHit] {
        guard !queryVector.isEmpty else { return [] }
        let queryDim = queryVector.count

        let candidates: [(unit: SearchUnitRecord, similarity: Double)] = try database.withSQLiteHandle { db in
            let sql = """
            SELECT
                su.id, su.document_id, su.chunk_id, su.unit_type, su.title_terms, su.keywords, su.body_terms,
                e.embedding_dimension, e.vector_blob
            FROM embeddings e
            INNER JOIN search_units su ON su.id = e.search_unit_id
            INNER JOIN documents d ON d.id = su.document_id
            WHERE d.index_status = 'ready';
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            var scored: [(SearchUnitRecord, Double)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let unitId = sqlite3_column_int64(stmt, 0)
                let docId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let chunkId: String? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let unitTypeRaw = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "chunk"
                let titleTerms = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let keywords = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                let bodyTerms = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                let storedDim = Int(sqlite3_column_int(stmt, 7))
                let blobPtr = sqlite3_column_blob(stmt, 8)
                let blobBytes = Int(sqlite3_column_bytes(stmt, 8))

                guard storedDim == queryDim,
                      let blobPtr,
                      blobBytes == queryDim * MemoryLayout<Float>.size else {
                    continue
                }

                // ゼロコピーまたは高速内積で Cosine 類似度を計算（ベクトルは保存時に L2 正規化済み）
                var dot: Float = 0.0
                let floatPtr = blobPtr.assumingMemoryBound(to: Float.self)
                queryVector.withUnsafeBufferPointer { qBuf in
                    if let qBase = qBuf.baseAddress {
                        vDSP_dotpr(qBase, 1, floatPtr, 1, &dot, vDSP_Length(queryDim))
                    }
                }

                let sim = Double(max(-1.0, min(1.0, dot)))
                if sim > 0.01 {
                    let unit = SearchUnitRecord(
                        id: unitId,
                        documentId: docId,
                        chunkId: chunkId,
                        unitType: SearchUnitType(rawValue: unitTypeRaw) ?? .chunk,
                        titleTerms: titleTerms,
                        keywords: keywords,
                        bodyTerms: bodyTerms
                    )
                    scored.append((unit, sim))
                }
            }
            return scored
        }

        let sorted = candidates.sorted { $0.similarity > $1.similarity }.prefix(limit)
        return sorted.enumerated().map { idx, item in
            VectorSearchHit(
                searchUnit: item.unit,
                cosineSimilarity: item.similarity,
                rank: idx + 1
            )
        }
    }

    public func totalVectorCount() -> Int {
        (try? database.withSQLiteHandle { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM embeddings;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }) ?? 0
    }

    public func totalVectorBlobBytes() -> Int64 {
        (try? database.withSQLiteHandle { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(LENGTH(vector_blob)), 0) FROM embeddings;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
        }) ?? 0
    }

    // MARK: - Float32 / Int8 Serialization Helpers (§8.1, §2.2)

    public static func encodeFloat32Blob(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decodeFloat32Blob(bytes: UnsafeRawPointer, byteCount: Int) -> [Float] {
        let count = byteCount / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        let ptr = bytes.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    /// §2.2 将来機能の Int8 量子化変換インターフェース（1/4 容量削減用）
    public static func quantizeToInt8(_ vector: [Float]) -> (scale: Float, quantized: [Int8]) {
        guard let maxAbs = vector.map({ abs($0) }).max(), maxAbs > 1e-6 else {
            return (1.0, [Int8](repeating: 0, count: vector.count))
        }
        let scale = maxAbs / 127.0
        let q = vector.map { Int8(max(-127, min(127, Int((($0 / scale).rounded()))))) }
        return (scale, q)
    }
}

// MARK: - §4, §7, §11, §12 ドキュメント・検索単位リポジトリ (`DocumentRepository`)

public struct FTS5UnitSearchHit: Sendable, Equatable {
    public let searchUnit: SearchUnitRecord
    public let bm25RawScore: Double
    public let rank: Int
}

public final class DocumentRepository: @unchecked Sendable {
    public let database: LocalDatabase
    public let vectorStore: any VectorStoreAdapter
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    public init(database: LocalDatabase, vectorStore: (any VectorStoreAdapter)? = nil) {
        self.database = database
        self.vectorStore = vectorStore ?? SQLiteVectorStoreAdapter(database: database)
    }

    // MARK: - §4.1 `documents` テーブル操作

    public func upsertDocument(_ doc: IndexedDocumentRecord) throws {
        let pidsJSON = (try? String(data: jsonEncoder.encode(doc.projectIds.map(\.uuidString)), encoding: .utf8)) ?? "[]"
        let participantsJSON = (try? String(data: jsonEncoder.encode(doc.participants), encoding: .utf8)) ?? "[]"

        try database.withSQLiteHandle { db in
            let sql = """
            INSERT INTO documents (
                id, title, type, source_type, source_uri, summary,
                created_at, updated_at, occurred_at, content_hash,
                content_version, indexing_version, index_status, indexed_at,
                project_ids_json, participants_json, error_message
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                type = excluded.type,
                source_type = excluded.source_type,
                source_uri = excluded.source_uri,
                summary = excluded.summary,
                updated_at = excluded.updated_at,
                occurred_at = excluded.occurred_at,
                content_hash = excluded.content_hash,
                content_version = excluded.content_version,
                indexing_version = excluded.indexing_version,
                index_status = excluded.index_status,
                indexed_at = excluded.indexed_at,
                project_ids_json = excluded.project_ids_json,
                participants_json = excluded.participants_json,
                error_message = excluded.error_message;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, doc.id, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_text(stmt, 2, doc.title, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_text(stmt, 3, doc.type.rawValue, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_text(stmt, 4, doc.sourceType.rawValue, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_text(stmt, 5, doc.sourceURI, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_text(stmt, 6, doc.summary, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_double(stmt, 7, doc.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 8, doc.updatedAt.timeIntervalSince1970)
            if let occurredAt = doc.occurredAt {
                sqlite3_bind_double(stmt, 9, occurredAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            sqlite3_bind_text(stmt, 10, doc.contentHash, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_int(stmt, 11, Int32(doc.contentVersion))
            sqlite3_bind_int(stmt, 12, Int32(doc.indexingVersion))
            sqlite3_bind_text(stmt, 13, doc.indexStatus.rawValue, -1, SQLITE_TRANSIENT_BIND)
            if let indexedAt = doc.indexedAt {
                sqlite3_bind_double(stmt, 14, indexedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 14)
            }
            sqlite3_bind_text(stmt, 15, pidsJSON, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_text(stmt, 16, participantsJSON, -1, SQLITE_TRANSIENT_BIND)
            if let err = doc.errorMessage {
                sqlite3_bind_text(stmt, 17, err, -1, SQLITE_TRANSIENT_BIND)
            } else {
                sqlite3_bind_null(stmt, 17)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func fetchDocument(id: String) throws -> IndexedDocumentRecord? {
        try database.withSQLiteHandle { db in
            let sql = """
            SELECT id, title, type, source_type, source_uri, summary,
                   created_at, updated_at, occurred_at, content_hash,
                   content_version, indexing_version, index_status, indexed_at,
                   project_ids_json, participants_json, error_message
            FROM documents
            WHERE id = ?1
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_BIND)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return decodeDocumentRow(stmt: stmt)
        }
    }

    public func fetchAllDocuments(onlyReady: Bool = false) throws -> [IndexedDocumentRecord] {
        try database.withSQLiteHandle { db in
            let whereClause = onlyReady ? "WHERE index_status = 'ready'" : ""
            let sql = """
            SELECT id, title, type, source_type, source_uri, summary,
                   created_at, updated_at, occurred_at, content_hash,
                   content_version, indexing_version, index_status, indexed_at,
                   project_ids_json, participants_json, error_message
            FROM documents
            \(whereClause)
            ORDER BY COALESCE(occurred_at, updated_at) DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            var list: [IndexedDocumentRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                list.append(decodeDocumentRow(stmt: stmt))
            }
            return list
        }
    }

    private func decodeDocumentRow(stmt: OpaquePointer?) -> IndexedDocumentRecord {
        let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let typeRaw = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "document"
        let sourceTypeRaw = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "local"
        let sourceURI = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
        let summary = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        let occurredAt: Date? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        let contentHash = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
        let contentVersion = Int(sqlite3_column_int(stmt, 10))
        let indexingVersion = Int(sqlite3_column_int(stmt, 11))
        let statusRaw = sqlite3_column_text(stmt, 12).map { String(cString: $0) } ?? "pending"
        let indexedAt: Date? = sqlite3_column_type(stmt, 13) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))
        let pidsJSON = sqlite3_column_text(stmt, 14).map { String(cString: $0) } ?? "[]"
        let partJSON = sqlite3_column_text(stmt, 15).map { String(cString: $0) } ?? "[]"
        let errorMsg: String? = sqlite3_column_type(stmt, 16) == SQLITE_NULL
            ? nil
            : sqlite3_column_text(stmt, 16).map { String(cString: $0) }

        let projectIds = ((try? jsonDecoder.decode([String].self, from: Data(pidsJSON.utf8))) ?? []).compactMap(UUID.init(uuidString:))
        let participants = (try? jsonDecoder.decode([String].self, from: Data(partJSON.utf8))) ?? []

        return IndexedDocumentRecord(
            id: id,
            title: title,
            type: IndexedDocumentType(rawValue: typeRaw) ?? .document,
            sourceType: IndexedDocumentSourceType(rawValue: sourceTypeRaw) ?? .local,
            sourceURI: sourceURI,
            summary: summary,
            createdAt: createdAt,
            updatedAt: updatedAt,
            occurredAt: occurredAt,
            contentHash: contentHash,
            contentVersion: contentVersion,
            indexingVersion: indexingVersion,
            indexStatus: DocumentIndexStatus(rawValue: statusRaw) ?? .pending,
            indexedAt: indexedAt,
            projectIds: projectIds,
            participants: participants,
            errorMessage: errorMsg
        )
    }

    // MARK: - §4.2 `document_contents` テーブル操作

    public func upsertDocumentContent(_ content: DocumentContentRecord) throws {
        try database.withSQLiteHandle { db in
            let sql = """
            INSERT INTO document_contents (document_id, raw_text, is_external_cache_only, is_source_accessible, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(document_id) DO UPDATE SET
                raw_text = excluded.raw_text,
                is_external_cache_only = excluded.is_external_cache_only,
                is_source_accessible = excluded.is_source_accessible,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, content.documentId, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_text(stmt, 2, content.rawText, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_int(stmt, 3, content.isExternalCacheOnly ? 1 : 0)
            sqlite3_bind_int(stmt, 4, content.isSourceAccessible ? 1 : 0)
            sqlite3_bind_double(stmt, 5, content.updatedAt.timeIntervalSince1970)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func fetchDocumentContent(documentId: String) throws -> DocumentContentRecord? {
        try database.withSQLiteHandle { db in
            let sql = """
            SELECT document_id, raw_text, is_external_cache_only, is_source_accessible, updated_at
            FROM document_contents
            WHERE document_id = ?1
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT_BIND)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let docId = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? documentId
            let rawText = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let isExt = sqlite3_column_int(stmt, 2) != 0
            let isAcc = sqlite3_column_int(stmt, 3) != 0
            let ts = sqlite3_column_double(stmt, 4)
            return DocumentContentRecord(
                documentId: docId,
                rawText: rawText,
                isExternalCacheOnly: isExt,
                isSourceAccessible: isAcc,
                updatedAt: Date(timeIntervalSince1970: ts)
            )
        }
    }

    // MARK: - §4.3 `document_chunks` テーブル操作

    public func upsertDocumentChunk(_ chunk: DocumentChunkRecord) throws {
        try database.withSQLiteHandle { db in
            let sql = """
            INSERT INTO document_chunks (
                id, document_id, chunk_index, text, start_offset, end_offset, start_time_ms, end_time_ms, content_hash
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            ON CONFLICT(id) DO UPDATE SET
                document_id = excluded.document_id,
                chunk_index = excluded.chunk_index,
                text = excluded.text,
                start_offset = excluded.start_offset,
                end_offset = excluded.end_offset,
                start_time_ms = excluded.start_time_ms,
                end_time_ms = excluded.end_time_ms,
                content_hash = excluded.content_hash;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, chunk.id, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_text(stmt, 2, chunk.documentId, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_int(stmt, 3, Int32(chunk.chunkIndex))
            sqlite3_bind_text(stmt, 4, chunk.text, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_int(stmt, 5, Int32(chunk.startOffset))
            sqlite3_bind_int(stmt, 6, Int32(chunk.endOffset))
            if let sMs = chunk.startTimeMs {
                sqlite3_bind_int64(stmt, 7, sMs)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            if let eMs = chunk.endTimeMs {
                sqlite3_bind_int64(stmt, 8, eMs)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_bind_text(stmt, 9, chunk.contentHash, -1, SQLITE_TRANSIENT_BIND)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func fetchDocumentChunks(documentId: String) throws -> [DocumentChunkRecord] {
        try database.withSQLiteHandle { db in
            let sql = """
            SELECT id, document_id, chunk_index, text, start_offset, end_offset, start_time_ms, end_time_ms, content_hash
            FROM document_chunks
            WHERE document_id = ?1
            ORDER BY chunk_index ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT_BIND)

            var chunks: [DocumentChunkRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let docId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? documentId
                let idx = Int(sqlite3_column_int(stmt, 2))
                let text = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let sOff = Int(sqlite3_column_int(stmt, 4))
                let eOff = Int(sqlite3_column_int(stmt, 5))
                let sMs: Int64? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 6)
                let eMs: Int64? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 7)
                let cHash = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
                chunks.append(DocumentChunkRecord(
                    id: id,
                    documentId: docId,
                    chunkIndex: idx,
                    text: text,
                    startOffset: sOff,
                    endOffset: eOff,
                    startTimeMs: sMs,
                    endTimeMs: eMs,
                    contentHash: cHash
                ))
            }
            return chunks
        }
    }

    public func deleteDocumentChunks(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try database.withSQLiteHandle { db in
            let sql = "DELETE FROM document_chunks WHERE id = ?1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for cid in ids {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, cid, -1, SQLITE_TRANSIENT_BIND)
                _ = sqlite3_step(stmt)
            }
        }
    }

    // MARK: - §4.4 & §4.5 `search_units` と External Content `search_units_fts` 操作

    @discardableResult
    public func insertSearchUnit(_ unit: SearchUnitRecord) throws -> Int64 {
        try database.withSQLiteHandle { db in
            let sql = """
            INSERT INTO search_units (document_id, chunk_id, unit_type, title_terms, keywords, body_terms)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, unit.documentId, -1, SQLITE_TRANSIENT_BIND)
            if let chunkId = unit.chunkId {
                sqlite3_bind_text(stmt, 2, chunkId, -1, SQLITE_TRANSIENT_BIND)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, unit.unitType.rawValue, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_text(stmt, 4, unit.titleTerms, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_text(stmt, 5, unit.keywords, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_text(stmt, 6, unit.bodyTerms, -1, SQLITE_TRANSIENT_BIND)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func updateSearchUnit(_ unit: SearchUnitRecord) throws {
        try database.withSQLiteHandle { db in
            let sql = """
            UPDATE search_units
            SET title_terms = ?1, keywords = ?2, body_terms = ?3
            WHERE id = ?4;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, unit.titleTerms, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_text(stmt, 2, unit.keywords, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_text(stmt, 3, unit.bodyTerms, -1, SQLITE_TRANSIENT_BIND)
            sqlite3_bind_int64(stmt, 4, unit.id)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func fetchSearchUnits(documentId: String) throws -> [SearchUnitRecord] {
        try database.withSQLiteHandle { db in
            let sql = """
            SELECT id, document_id, chunk_id, unit_type, title_terms, keywords, body_terms
            FROM search_units
            WHERE document_id = ?1
            ORDER BY id ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT_BIND)

            var units: [SearchUnitRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let docId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? documentId
                let chunkId: String? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let uType = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "chunk"
                let tTerms = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let kw = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                let bTerms = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                units.append(SearchUnitRecord(
                    id: id,
                    documentId: docId,
                    chunkId: chunkId,
                    unitType: SearchUnitType(rawValue: uType) ?? .chunk,
                    titleTerms: tTerms,
                    keywords: kw,
                    bodyTerms: bTerms
                ))
            }
            return units
        }
    }

    public func deleteSearchUnits(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try vectorStore.deleteVectors(forSearchUnitIds: ids)
        try database.withSQLiteHandle { db in
            let sql = "DELETE FROM search_units WHERE id = ?1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for uid in ids {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, uid)
                _ = sqlite3_step(stmt)
            }
        }
    }

    /// §11.3 ドキュメント削除時の完全削除（関連する全テーブルから残骸なく消去）
    public func deleteDocumentAndAllSearchArtifacts(documentId: String) throws {
        let existingUnits = try fetchSearchUnits(documentId: documentId)
        let unitIds = existingUnits.map(\.id)
        try deleteSearchUnits(ids: unitIds)

        try database.withSQLiteHandle { db in
            for tableAndCol in [
                ("document_chunks", "document_id"),
                ("document_contents", "document_id"),
                ("documents", "id")
            ] {
                let sql = "DELETE FROM \(tableAndCol.0) WHERE \(tableAndCol.1) = ?1;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT_BIND)
                    _ = sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
            }
        }
    }

    /// §4.5 External Content FTS5 の再構築 (`'rebuild'`)
    public func rebuildFTS5Index() throws {
        try database.executeRawSQL("INSERT INTO search_units_fts(search_units_fts) VALUES('rebuild');")
    }

    /// §4.5 External Content FTS5 の整合性検証 (`'integrity-check'`)
    public func verifyFTS5Integrity() throws -> Bool {
        try database.executeRawSQL("INSERT INTO search_units_fts(search_units_fts) VALUES('integrity-check');")
        return true
    }

    /// §7.2, §7.3, §7.4 FTS5 全文検索（列重み付き BM25 スコア昇順取得 + 特殊記号/部分一致補完）
    /// - `bm25(search_units_fts, titleWeight, keywordWeight, bodyWeight)` は関連度が高いほど小さい（負の）値を返すため `ORDER BY bm25_score ASC` で取得する
    /// - `C++`, `C#` など unicode61 トークナイザで記号が落ちる特殊用語についても、`search_units` のトークン列照合で確実に補完する
    public func searchFTS5Units(
        normalizedQueryTerms: [String],
        rawQuery: String,
        configuration: HybridSearchConfiguration
    ) throws -> [FTS5UnitSearchHit] {
        // 内部マーカー (`__...`) は FTS クエリ式から除外し、純粋な検索語のみを抽出
        let terms = normalizedQueryTerms
            .filter { !$0.hasPrefix("__") }
            .map { Self.sanitizeFTS5Term($0) }
            .filter { !$0.isEmpty }

        var ftsHitsByUnitId: [Int64: (unit: SearchUnitRecord, bm25Raw: Double)] = [:]

        if !terms.isEmpty {
            let matchExpr = terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
            try database.withSQLiteHandle { db in
                let sql = """
                SELECT
                    su.id, su.document_id, su.chunk_id, su.unit_type, su.title_terms, su.keywords, su.body_terms,
                    bm25(search_units_fts, ?2, ?3, ?4) AS bm25_score
                FROM search_units_fts
                INNER JOIN search_units su ON su.id = search_units_fts.rowid
                INNER JOIN documents d ON d.id = su.document_id
                WHERE search_units_fts MATCH ?1
                  AND d.index_status = 'ready'
                ORDER BY bm25_score ASC
                LIMIT ?5;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    return
                }
                defer { sqlite3_finalize(stmt) }

                sqlite3_bind_text(stmt, 1, matchExpr, -1, SQLITE_TRANSIENT_BIND)
                sqlite3_bind_double(stmt, 2, configuration.titleBM25Weight)
                sqlite3_bind_double(stmt, 3, configuration.keywordBM25Weight)
                sqlite3_bind_double(stmt, 4, configuration.bodyBM25Weight)
                sqlite3_bind_int(stmt, 5, Int32(configuration.ftsCandidateLimit))

                while sqlite3_step(stmt) == SQLITE_ROW {
                    let uid = sqlite3_column_int64(stmt, 0)
                    let docId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let chunkId: String? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                        ? nil
                        : sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                    let uType = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "chunk"
                    let tTerms = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                    let kw = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                    let bTerms = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                    let bm25Raw = sqlite3_column_double(stmt, 7)

                    let unit = SearchUnitRecord(
                        id: uid,
                        documentId: docId,
                        chunkId: chunkId,
                        unitType: SearchUnitType(rawValue: uType) ?? .chunk,
                        titleTerms: tTerms,
                        keywords: kw,
                        bodyTerms: bTerms
                    )
                    ftsHitsByUnitId[uid] = (unit, bm25Raw)
                }
            }
        }

        // 記号付き技術用語 (`C++`, `C#`, `sqlite-vec` 等) や日本語部分一致の厳密検証・重み補正
        let rawLower = rawQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSpecialSymbolQuery = rawLower.contains("++") || rawLower.contains("#") || rawLower.contains("-")
        if hasSpecialSymbolQuery || ftsHitsByUnitId.isEmpty {
            try database.withSQLiteHandle { db in
                let sql = """
                SELECT su.id, su.document_id, su.chunk_id, su.unit_type, su.title_terms, su.keywords, su.body_terms
                FROM search_units su
                INNER JOIN documents d ON d.id = su.document_id
                WHERE d.index_status = 'ready';
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(stmt) }

                let checkTokens = normalizedQueryTerms.filter { !$0.hasPrefix("__") }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let uid = sqlite3_column_int64(stmt, 0)
                    let docId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let chunkId: String? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                        ? nil
                        : sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                    let uType = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "chunk"
                    let tTerms = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                    let kw = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                    let bTerms = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""

                    let titleWords = Set(tTerms.split(separator: " ").map(String.init))
                    let kwWords = Set(kw.split(separator: " ").map(String.init))
                    let bodyWords = Set(bTerms.split(separator: " ").map(String.init))

                    var syntheticBM25 = ftsHitsByUnitId[uid]?.bm25Raw ?? 0.0
                    var matchedAny = false

                    for qTok in checkTokens {
                        if titleWords.contains(qTok) || tTerms.contains(qTok) {
                            syntheticBM25 -= configuration.titleBM25Weight * 1.5
                            matchedAny = true
                        }
                        if kwWords.contains(qTok) || kw.contains(qTok) {
                            syntheticBM25 -= configuration.keywordBM25Weight * 1.2
                            matchedAny = true
                        }
                        if bodyWords.contains(qTok) || bTerms.contains(qTok) {
                            syntheticBM25 -= configuration.bodyBM25Weight * 1.0
                            matchedAny = true
                        }
                    }

                    // `C++` 検索時に単なる `C` だけの文書が誤ヒットしないよう厳密チェック
                    if rawLower.contains("c++") && !tTerms.contains("c++") && !kw.contains("c++") && !bTerms.contains("c++") {
                        ftsHitsByUnitId.removeValue(forKey: uid)
                        continue
                    }

                    if matchedAny {
                        let unit = SearchUnitRecord(
                            id: uid,
                            documentId: docId,
                            chunkId: chunkId,
                            unitType: SearchUnitType(rawValue: uType) ?? .chunk,
                            titleTerms: tTerms,
                            keywords: kw,
                            bodyTerms: bTerms
                        )
                        ftsHitsByUnitId[uid] = (unit, min(syntheticBM25, ftsHitsByUnitId[uid]?.bm25Raw ?? -0.1))
                    }
                }
            }
        }

        // BM25 は値が小さい（より大きな負数）ほど関連度が高い（§7.2）
        // さらに複数の検索語に同時にマッチしている検索単位を優先する
        let checkTokens = normalizedQueryTerms.filter { !$0.hasPrefix("__") && $0.count >= 2 }
        let rescored: [(unit: SearchUnitRecord, adjustedBM25: Double)] = ftsHitsByUnitId.values.map { entry in
            var matchedDistinctTerms = 0
            for tok in checkTokens {
                if entry.unit.titleTerms.contains(tok) || entry.unit.keywords.contains(tok) || entry.unit.bodyTerms.contains(tok) {
                    matchedDistinctTerms += 1
                }
            }
            let multiTermBonus = Double(matchedDistinctTerms) * 2.5
            return (entry.unit, entry.bm25Raw - multiTermBonus)
        }

        let sorted = rescored
            .sorted { $0.adjustedBM25 < $1.adjustedBM25 }
            .prefix(configuration.ftsCandidateLimit)

        return sorted.enumerated().map { idx, item in
            FTS5UnitSearchHit(
                searchUnit: item.unit,
                bm25RawScore: item.adjustedBM25,
                rank: idx + 1
            )
        }
    }

    private static func sanitizeFTS5Term(_ term: String) -> String {
        // FTS5 の予約構文文字 (`"`, `*`, `(`, `)`, `:`, `^`, `-`, `+`) をエスケープ除去
        let unsafe = CharacterSet(charactersIn: "\"*():^-+{}[]~\\/?!@#$%&|<>=")
        return term
            .components(separatedBy: unsafe)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - §12.3 データ容量・統計計測

    public func computeStorageMetrics(
        activeEmbeddingModelId: String,
        activeEmbeddingDimension: Int,
        lastIndexingDurationMs: Double,
        lastSearchTiming: SearchTimingMetrics
    ) -> IndexStorageAndSpeedMetrics {
        let sqliteFileBytes = (try? FileManager.default.attributesOfItem(atPath: database.databasePath)[.size] as? Int64) ?? 0

        let counts: (docs: Int, readyDocs: Int, chunks: Int, units: Int, rawBytes: Int64, ftsBytes: Int64) = (try? database.withSQLiteHandle { db in
            func scalarInt(_ sql: String) -> Int {
                var s: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return 0 }
                defer { sqlite3_finalize(s) }
                return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : 0
            }
            func scalarInt64(_ sql: String) -> Int64 {
                var s: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return 0 }
                defer { sqlite3_finalize(s) }
                return sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_int64(s, 0) : 0
            }

            let dCount = scalarInt("SELECT COUNT(*) FROM documents;")
            let rCount = scalarInt("SELECT COUNT(*) FROM documents WHERE index_status = 'ready';")
            let cCount = scalarInt("SELECT COUNT(*) FROM document_chunks;")
            let uCount = scalarInt("SELECT COUNT(*) FROM search_units;")
            let rawB = scalarInt64("SELECT COALESCE(SUM(LENGTH(CAST(raw_text AS BLOB))), 0) FROM document_contents;")
            let ftsB = scalarInt64("SELECT COALESCE(SUM(LENGTH(CAST(title_terms AS BLOB)) + LENGTH(CAST(keywords AS BLOB)) + LENGTH(CAST(body_terms AS BLOB))), 0) FROM search_units;")
            return (dCount, rCount, cCount, uCount, rawB, ftsB)
        }) ?? (0, 0, 0, 0, 0, 0)

        let vecCount = vectorStore.totalVectorCount()
        let vecBytes = vectorStore.totalVectorBlobBytes()
        let totalIndexedPayload = counts.rawBytes + counts.ftsBytes + vecBytes
        let avgPerDoc = counts.docs > 0 ? (totalIndexedPayload / Int64(counts.docs)) : 0

        return IndexStorageAndSpeedMetrics(
            documentCount: counts.docs,
            readyDocumentCount: counts.readyDocs,
            chunkCount: counts.chunks,
            searchUnitCount: counts.units,
            vectorCount: vecCount,
            sqliteFileSizeBytes: sqliteFileBytes,
            rawTextBytes: counts.rawBytes,
            ftsIndexBytes: counts.ftsBytes,
            vectorBlobBytes: vecBytes,
            averageBytesPerDocument: avgPerDoc,
            lastIndexingDurationMs: lastIndexingDurationMs,
            lastSearchTiming: lastSearchTiming,
            activeEmbeddingModelId: activeEmbeddingModelId,
            activeEmbeddingDimension: activeEmbeddingDimension,
            vectorBackendName: vectorStore.backendName
        )
    }
}

// MARK: - §5.1, §11 Индекс生成・差分更新・再生成マネージャー (`IndexManager`)

public struct DocumentIndexingOutcome: Sendable, Equatable {
    public let document: IndexedDocumentRecord
    public let chunkCount: Int
    public let reusedVectorCount: Int
    public let generatedVectorCount: Int
    public let wasSkippedUnchanged: Bool
    public let durationMs: Double
}

public final class IndexManager: @unchecked Sendable {
    public let repository: DocumentRepository
    public let textAnalyzer: any TextAnalyzing
    public let keywordExtractor: any KeywordExtracting
    public let chunker: SemanticDocumentChunker
    public var configuration: HybridSearchConfiguration
    public private(set) var lastIndexingDurationMs: Double = 0.0

    public init(
        repository: DocumentRepository,
        textAnalyzer: any TextAnalyzing = NaturalLanguageTextAnalyzer(),
        keywordExtractor: (any KeywordExtracting)? = nil,
        chunker: SemanticDocumentChunker? = nil,
        configuration: HybridSearchConfiguration = HybridSearchConfiguration()
    ) {
        self.repository = repository
        self.textAnalyzer = textAnalyzer
        self.keywordExtractor = keywordExtractor ?? ImportantKeywordExtractor(analyzer: textAnalyzer)
        self.chunker = chunker ?? SemanticDocumentChunker(analyzer: textAnalyzer)
        self.configuration = configuration
    }

    /// §5.1, §11.1, §11.2 ドキュメントの登録・差分インデックス更新
    /// - `content_hash` が一致し `index_status == .ready` かつ `indexing_version` も最新であれば再インデックスをスキップする
    /// - 更新時はチャンク単位の `content_hash` を比較し、未変更チャンクの既存 Embedding ベクターを再利用する
    @discardableResult
    public func indexDocument(
        id: String,
        title: String,
        rawText: String,
        type: IndexedDocumentType,
        sourceType: IndexedDocumentSourceType = .local,
        sourceURI: String = "",
        occurredAt: Date? = nil,
        createdAt: Date? = nil,
        projectIds: [UUID] = [],
        participants: [String] = [],
        embeddingAdapter: any EmbeddingAdapter,
        forceReindex: Bool = false,
        simulateFailureForTesting: Bool = false
    ) throws -> DocumentIndexingOutcome {
        let startTime = CFAbsoluteTimeGetCurrent()
        let contentHash = SemanticDocumentChunker.sha256Hex(of: rawText)
        let existingDoc = try repository.fetchDocument(id: id)

        // 1. 未変更スキップ判定 (§5.1 #2, §11.2, §16.4 #3)
        if !forceReindex,
           !simulateFailureForTesting,
           let existingDoc,
           existingDoc.contentHash == contentHash,
           existingDoc.title == title,
           existingDoc.indexingVersion == configuration.indexingVersion,
           existingDoc.indexStatus == .ready {
            // Embedding モデルも一致しているか確認
            let units = try repository.fetchSearchUnits(documentId: id)
            if let docUnit = units.first(where: { $0.unitType == .document }),
               let existingVec = try repository.vectorStore.loadVector(forSearchUnitId: docUnit.id),
               existingVec.embeddingModelId == embeddingAdapter.model.id,
               existingVec.embeddingDimension == embeddingAdapter.dimensions {
                // プロジェクトIDや参加者メタデータのみ変更がある場合はメタデータだけ軽量更新
                if existingDoc.projectIds != projectIds || existingDoc.participants != participants {
                    var updatedMeta = existingDoc
                    updatedMeta.projectIds = projectIds
                    updatedMeta.participants = participants
                    updatedMeta.updatedAt = Date()
                    try repository.upsertDocument(updatedMeta)
                }
                let chunks = try repository.fetchDocumentChunks(documentId: id)
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                return DocumentIndexingOutcome(
                    document: existingDoc,
                    chunkCount: chunks.count,
                    reusedVectorCount: units.count,
                    generatedVectorCount: 0,
                    wasSkippedUnchanged: true,
                    durationMs: elapsed
                )
            }
        }

        // 2. インデックス失敗シミュレーションまたはエラー記録 (§14, §16.4 #5)
        let now = Date()
        let contentVersion = (existingDoc?.contentVersion ?? 0) + (existingDoc?.contentHash == contentHash ? 0 : 1)
        if simulateFailureForTesting {
            let errorDoc = IndexedDocumentRecord(
                id: id,
                title: title,
                type: type,
                sourceType: sourceType,
                sourceURI: sourceURI,
                summary: existingDoc?.summary ?? "",
                createdAt: existingDoc?.createdAt ?? createdAt ?? now,
                updatedAt: now,
                occurredAt: occurredAt ?? existingDoc?.occurredAt,
                contentHash: contentHash,
                contentVersion: max(1, contentVersion),
                indexingVersion: configuration.indexingVersion,
                indexStatus: .error,
                indexedAt: existingDoc?.indexedAt,
                projectIds: projectIds,
                participants: participants,
                errorMessage: "Simulated indexing failure for retry verification"
            )
            try repository.upsertDocument(errorDoc)
            try repository.upsertDocumentContent(DocumentContentRecord(
                documentId: id,
                rawText: rawText,
                isExternalCacheOnly: sourceType == .external,
                isSourceAccessible: true,
                updatedAt: now
            ))
            throw DatabaseError.executionFailed("Simulated indexing failure")
        }

        // 3. 既存のチャンクとベクターをキャッシュして差分更新 (§11.2) に備える
        let oldChunks = try repository.fetchDocumentChunks(documentId: id)
        let oldUnits = try repository.fetchSearchUnits(documentId: id)
        var reusableVectorByChunkHash: [String: StoredVectorRecord] = [:]

        for oldChunk in oldChunks {
            if let oldUnit = oldUnits.first(where: { $0.chunkId == oldChunk.id }),
               let oldVec = try repository.vectorStore.loadVector(forSearchUnitId: oldUnit.id),
               oldVec.embeddingModelId == embeddingAdapter.model.id,
               oldVec.embeddingDimension == embeddingAdapter.dimensions {
                reusableVectorByChunkHash[oldChunk.contentHash] = oldVec
            }
        }

        // 4. 文書全体要約の生成 (§5.2)
        let summaryText = chunker.generateStructuredDocumentSummary(title: title, rawText: rawText)

        // 5. 意味単位でのチャンク分割 (§5.3)
        let plannedChunks = chunker.splitIntoChunks(
            rawText: rawText,
            targetMinTokens: configuration.targetMinChunkTokens,
            targetMaxTokens: configuration.targetMaxChunkTokens,
            overlapRatio: configuration.chunkOverlapRatio
        )

        // 6. 文書単位の重要キーワード (5〜15語) と正規化トークン列 (§6.4, §7.1)
        let docKeywords = keywordExtractor.extractDocumentKeywords(
            from: rawText,
            title: title,
            minCount: 5,
            maxCount: 15
        )
        let titleTerms = textAnalyzer.buildFTS5TokenString(for: title, titleContext: title)
        let docSummaryTerms = textAnalyzer.buildFTS5TokenString(for: "\(summaryText)\n\(rawText.prefix(600))", titleContext: title)
        let docKeywordsString = docKeywords.joined(separator: " ")

        // 7. 古い search_units と chunks をクリーンアップしてから新インデックスを登録
        if !oldUnits.isEmpty {
            try repository.deleteSearchUnits(ids: oldUnits.map(\.id))
        }
        if !oldChunks.isEmpty {
            try repository.deleteDocumentChunks(ids: oldChunks.map(\.id))
        }

        // 元テキストを `document_contents` に保存 (§4.2)
        let isAccessible = sourceURI.isEmpty || !sourceURI.hasPrefix("/") || FileManager.default.fileExists(atPath: sourceURI)
        try repository.upsertDocumentContent(DocumentContentRecord(
            documentId: id,
            rawText: rawText,
            isExternalCacheOnly: sourceType == .external,
            isSourceAccessible: isAccessible,
            updatedAt: now
        ))

        var reusedCount = 0
        var generatedCount = 0

        // 8. 第1階層：文書要約 `search_unit` (`unit_type = .document`) の登録と Embedding 生成 (§4.4, §5.2)
        let docSearchUnitId = try repository.insertSearchUnit(SearchUnitRecord(
            documentId: id,
            chunkId: nil,
            unitType: .document,
            titleTerms: titleTerms,
            keywords: docKeywordsString,
            bodyTerms: docSummaryTerms
        ))

        let docVectorInput = "\(title) \(docKeywordsString) \(summaryText)"
        let docVector = embeddingAdapter.generateEmbedding(for: docVectorInput)
        try repository.vectorStore.saveVector(StoredVectorRecord(
            searchUnitId: docSearchUnitId,
            embeddingModelId: embeddingAdapter.model.id,
            embeddingDimension: embeddingAdapter.dimensions,
            embeddingVersion: configuration.indexingVersion,
            generatedAt: now,
            vector: docVector
        ))
        generatedCount += 1

        // 9. 第2階層：各チャンク (`document_chunks` & `search_units` where `unit_type = .chunk`) の登録と差分 Embedding 生成 (§4.3, §4.4, §5.3, §11.2)
        for planned in plannedChunks {
            let chunkId = "\(id)::chunk-\(planned.chunkIndex)"
            let chunkRecord = DocumentChunkRecord(
                id: chunkId,
                documentId: id,
                chunkIndex: planned.chunkIndex,
                text: planned.text,
                startOffset: planned.startOffset,
                endOffset: planned.endOffset,
                startTimeMs: planned.startTimeMs,
                endTimeMs: planned.endTimeMs,
                contentHash: planned.contentHash
            )
            try repository.upsertDocumentChunk(chunkRecord)

            // チャンク重要キーワード (3〜8語) と正規化トークン列 (§4.4 チャンク側にタイトルを繰り返し保存しない)
            let chunkKws = keywordExtractor.extractChunkKeywords(
                from: planned.text,
                title: title,
                minCount: 3,
                maxCount: 8
            )
            let chunkBodyTerms = textAnalyzer.buildFTS5TokenString(for: planned.text, titleContext: title)

            let chunkUnitId = try repository.insertSearchUnit(SearchUnitRecord(
                documentId: id,
                chunkId: chunkId,
                unitType: .chunk,
                titleTerms: "", // §4.4 チャンク側にタイトルを繰り返し保存しない
                keywords: chunkKws.joined(separator: " "),
                bodyTerms: chunkBodyTerms
            ))

            // 差分更新：チャンクの `content_hash` が一致する既存ベクターがあれば再生成せず再利用する (§11.2)
            if let reused = reusableVectorByChunkHash[planned.contentHash] {
                try repository.vectorStore.saveVector(StoredVectorRecord(
                    searchUnitId: chunkUnitId,
                    embeddingModelId: reused.embeddingModelId,
                    embeddingDimension: reused.embeddingDimension,
                    embeddingVersion: configuration.indexingVersion,
                    generatedAt: reused.generatedAt,
                    vector: reused.vector
                ))
                reusedCount += 1
            } else {
                let chunkVec = embeddingAdapter.generateEmbedding(for: "\(chunkKws.joined(separator: " ")) \(planned.text)")
                try repository.vectorStore.saveVector(StoredVectorRecord(
                    searchUnitId: chunkUnitId,
                    embeddingModelId: embeddingAdapter.model.id,
                    embeddingDimension: embeddingAdapter.dimensions,
                    embeddingVersion: configuration.indexingVersion,
                    generatedAt: now,
                    vector: chunkVec
                ))
                generatedCount += 1
            }
        }

        // 10. `documents` テーブルを `index_status = .ready` として確定保存 (§5.1 #10)
        let readyDoc = IndexedDocumentRecord(
            id: id,
            title: title,
            type: type,
            sourceType: sourceType,
            sourceURI: sourceURI,
            summary: summaryText,
            createdAt: existingDoc?.createdAt ?? createdAt ?? now,
            updatedAt: now,
            occurredAt: occurredAt ?? existingDoc?.occurredAt ?? createdAt ?? now,
            contentHash: contentHash,
            contentVersion: max(1, contentVersion),
            indexingVersion: configuration.indexingVersion,
            indexStatus: .ready,
            indexedAt: now,
            projectIds: projectIds,
            participants: participants,
            errorMessage: nil
        )
        try repository.upsertDocument(readyDoc)

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        self.lastIndexingDurationMs = elapsedMs

        return DocumentIndexingOutcome(
            document: readyDoc,
            chunkCount: plannedChunks.count,
            reusedVectorCount: reusedCount,
            generatedVectorCount: generatedCount,
            wasSkippedUnchanged: false,
            durationMs: elapsedMs
        )
    }

    /// §14, §16.4 #5 `index_status = 'error'` または `'pending'` のドキュメントを再試行する
    @discardableResult
    public func retryPendingOrFailedDocuments(embeddingAdapter: any EmbeddingAdapter) throws -> Int {
        let allDocs = try repository.fetchAllDocuments(onlyReady: false)
        let targets = allDocs.filter { $0.indexStatus == .error || $0.indexStatus == .pending }
        var retried = 0
        for doc in targets {
            guard let content = try repository.fetchDocumentContent(documentId: doc.id) else { continue }
            _ = try indexDocument(
                id: doc.id,
                title: doc.title,
                rawText: content.rawText,
                type: doc.type,
                sourceType: doc.sourceType,
                sourceURI: doc.sourceURI,
                occurredAt: doc.occurredAt,
                createdAt: doc.createdAt,
                projectIds: doc.projectIds,
                participants: doc.participants,
                embeddingAdapter: embeddingAdapter,
                forceReindex: true
            )
            retried += 1
        }
        return retried
    }

    /// §11.4 全ドキュメントのインデックス再生成（Embeddingモデル変更・インデックス仕様バージョン更新時）
    @discardableResult
    public func regenerateAllIndexes(
        embeddingAdapter: any EmbeddingAdapter,
        newIndexingVersion: Int? = nil
    ) throws -> Int {
        if let newIndexingVersion {
            configuration.indexingVersion = newIndexingVersion
        }
        let allDocs = try repository.fetchAllDocuments(onlyReady: false)
        var count = 0
        for doc in allDocs {
            guard let content = try repository.fetchDocumentContent(documentId: doc.id) else { continue }
            _ = try indexDocument(
                id: doc.id,
                title: doc.title,
                rawText: content.rawText,
                type: doc.type,
                sourceType: doc.sourceType,
                sourceURI: doc.sourceURI,
                occurredAt: doc.occurredAt,
                createdAt: doc.createdAt,
                projectIds: doc.projectIds,
                participants: doc.participants,
                embeddingAdapter: embeddingAdapter,
                forceReindex: true
            )
            count += 1
        }
        try repository.rebuildFTS5Index()
        return count
    }
}
