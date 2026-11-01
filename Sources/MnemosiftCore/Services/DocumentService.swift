import Foundation
import PDFKit
import CryptoKit
import Observation

/// 仕様書 §7: ファイル管理・解析・段階的分類・整理提案・フォルダ監視サービス
/// - 管理領域コピー方式と元場所参照方式を明確に区別
/// - ルール → Embedding → 判断モデル(System One) → LLM の段階的分類により、軽量処理で判断可能な場合は大型LLMを起動しない
/// - リネーム・移動・タグ付け・プロジェクト関連付けはユーザー承認後に適用し、変更前後パスを保持してロールバック可能にする
@Observable
@MainActor
public final class DocumentService {
    private let database: LocalDatabase
    private let modelManager: ModelManager
    private let jobManager: JobManager
    private let projectService: ProjectService
    private let embeddingService: EmbeddingService

    public private(set) var documents: [Document] = []
    public private(set) var operationHistories: [FileOperationHistory] = []
    public private(set) var watchedFolders: [String] = []
    private var folderWatchers: [String: DispatchSourceFileSystemObject] = [:]

    public init(
        database: LocalDatabase,
        modelManager: ModelManager,
        jobManager: JobManager,
        projectService: ProjectService,
        embeddingService: EmbeddingService
    ) {
        self.database = database
        self.modelManager = modelManager
        self.jobManager = jobManager
        self.projectService = projectService
        self.embeddingService = embeddingService

        self.documents = (try? database.loadDocuments()) ?? []
        self.operationHistories = (try? database.loadFileOperationHistories()) ?? []
    }

    /// ファイルを登録して解析・分類・Embeddingインデックス作成・整理提案生成を行う
    @discardableResult
    public func registerFile(
        url: URL,
        storageMode: DocumentStorageMode,
        explicitContent: String? = nil,
        initialProjectIds: [UUID] = []
    ) async throws -> Document {
        let originalPath = url.path
        let fileName = url.lastPathComponent
        let fileType = Self.detectFileType(for: url)

        let activeFilePath: String
        if storageMode == .copiedToManagedStorage {
            let managedDir = URL(fileURLWithPath: modelManager.globalSettings.storageRootPath, isDirectory: true)
            try FileManager.default.createDirectory(at: managedDir, withIntermediateDirectories: true)
            let destURL = managedDir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(fileName)")
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.copyItem(at: url, to: destURL)
            } else if let explicitContent {
                try explicitContent.write(to: destURL, atomically: true, encoding: .utf8)
            }
            activeFilePath = destURL.path
        } else {
            activeFilePath = originalPath
        }

        let extractedText: String
        if let explicitContent {
            extractedText = explicitContent
        } else {
            extractedText = Self.extractText(from: URL(fileURLWithPath: activeFilePath), fileType: fileType)
        }

        let hash = Self.sha256Hex(of: extractedText)
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: activeFilePath)[.size] as? Int64)
            ?? Int64(extractedText.utf8.count)

        var document = Document(
            fileName: fileName,
            filePath: activeFilePath,
            originalPath: originalPath,
            storageMode: storageMode,
            fileType: fileType,
            fileSizeBytes: sizeBytes,
            contentHash: hash,
            extractedText: extractedText
        )

        // 段階的分類を実行（軽量処理で判断できれば大型LLMを起動しない）
        let classification = try await classifyDocumentTiered(document: document, initialProjectIds: initialProjectIds)
        document.category = classification.category
        document.tags = classification.tags
        document.summary = classification.summary
        document.classificationStage = classification.stageUsed
        document.relatedDocumentIds = classification.relatedDocumentIds

        documents.insert(document, at: 0)
        try database.saveDocument(document)

        // プロジェクト関連付けとEmbeddingインデックス更新
        for pid in classification.matchedProjectIds {
            try projectService.associateDocument(
                documentId: document.id,
                projectId: pid,
                relevanceScore: 0.9,
                isSuggestedByAI: !initialProjectIds.contains(pid),
                isApproved: initialProjectIds.contains(pid)
            )
        }
        try embeddingService.indexDocument(document, projectIds: classification.matchedProjectIds)

        // 整理提案（リネーム・フォルダ移動・タグ付け・プロジェクト関連付け）を生成（ユーザー承認待ち）
        _ = try createOrganizationProposal(for: document, suggestedProjectIds: classification.matchedProjectIds)

        return document
    }

    /// 仕様書 §7.3: ルール → Embedding → 判断モデル(System One) → LLM の段階的分類
    /// 軽量な処理で十分な確信度が得られた場合は大型LLMを起動しない
    public func classifyDocumentTiered(
        document: Document,
        initialProjectIds: [UUID]
    ) async throws -> (
        category: DocumentCategory,
        tags: [String],
        summary: String,
        matchedProjectIds: [UUID],
        relatedDocumentIds: [UUID],
        stageUsed: String
    ) {
        let allProjects = projectService.projects
        let allVocabs = projectService.vocabularies

        // Stage 1: プロジェクト分類ルールによる判定（最軽量・LLM/モデル起動なし）
        for project in allProjects {
            for rule in project.classificationRules where rule.isEnabled {
                let matchesFile = !rule.filenameKeyword.isEmpty && document.fileName.localizedCaseInsensitiveContains(rule.filenameKeyword)
                let matchesContent = !rule.contentKeyword.isEmpty && document.extractedText.localizedCaseInsensitiveContains(rule.contentKeyword)
                if matchesFile || matchesContent {
                    var pids = Set(initialProjectIds)
                    pids.insert(project.id)
                    let summary = Self.buildLightweightSummary(from: document.extractedText)
                    return (
                        category: rule.targetCategory,
                        tags: Array(Set(rule.targetTags + [project.name])).sorted(),
                        summary: summary,
                        matchedProjectIds: Array(pids),
                        relatedDocumentIds: findRelatedDocumentIds(for: document),
                        stageUsed: "Stage 1: 分類ルール一致（LLM未起動）"
                    )
                }
            }
        }

        // Stage 2: System One 判断モデル + Embedding による高速分類
        let config = modelManager.resolveConfiguration()
        let judge = SystemOneJudgeAdapter(model: config.judgeModel)
        let judgeOutput = judge.classifyDocument(
            fileName: document.fileName,
            content: document.extractedText,
            projects: allProjects,
            vocabularies: allVocabs
        )

        var matchedProjects = Set(initialProjectIds)
        for (pid, score) in judgeOutput.projectRelevanceScores where score >= 0.35 {
            matchedProjects.insert(pid)
        }

        if judgeOutput.calibratedConfidence >= config.judgeConfidenceThreshold {
            // 判断モデルのみで十分な確信度（>= 0.72）が得られたため、大型LLMを起動せず完了
            let summary = Self.buildLightweightSummary(from: document.extractedText)
            return (
                category: judgeOutput.category,
                tags: judgeOutput.suggestedTags,
                summary: summary,
                matchedProjectIds: Array(matchedProjects),
                relatedDocumentIds: findRelatedDocumentIds(for: document),
                stageUsed: "Stage 2: 判断モデル (\(config.judgeModel.name)) [確信度 \(Int(judgeOutput.calibratedConfidence * 100))%・大型LLM起動省略]"
            )
        }

        // Stage 3: 判断モデルで確信度が低い場合のみ LLM を起動して詳細分析
        let llmModel = config.llmModel
        return try await jobManager.enqueueAndRun(
            type: .documentClassification,
            title: "LLM詳細ファイル分類『\(document.fileName)』",
            priority: .lowBackground,
            modelId: llmModel.id,
            requiredMemoryMB: llmModel.requiredMemoryMB
        ) {
            let summary = Self.buildLightweightSummary(from: document.extractedText)
            let enrichedTags = Array(Set(judgeOutput.suggestedTags + ["LLM詳細解析済み"])).sorted()
            return (
                (
                    category: judgeOutput.category,
                    tags: enrichedTags,
                    summary: summary,
                    matchedProjectIds: Array(matchedProjects),
                    relatedDocumentIds: self.findRelatedDocumentIds(for: document),
                    stageUsed: "Stage 3: LLM詳細分析 (\(llmModel.name))"
                ),
                "LLMによる分類・要約完了"
            )
        }
    }

    /// 仕様書 §7.4: ファイル整理提案の作成（初期状態は `pendingApproval` で自動適用しない）
    @discardableResult
    public func createOrganizationProposal(
        for document: Document,
        suggestedProjectIds: [UUID]
    ) throws -> FileOperationHistory {
        let prefix = switch document.category {
        case .specification: "spec"
        case .meetingMinutes: "minutes"
        case .sourceCode: "code"
        case .researchNote: "research"
        case .configuration: "config"
        case .general: "doc"
        }

        let cleanName: String
        if document.fileName.lowercased().hasPrefix("\(prefix)_") || document.fileName.lowercased().hasPrefix("\(prefix)-") {
            cleanName = document.fileName
        } else {
            cleanName = "\(prefix)_\(document.fileName)"
        }

        let parentDir = URL(fileURLWithPath: document.filePath).deletingLastPathComponent()
        let categoryFolder = parentDir.appendingPathComponent(document.category.rawValue, isDirectory: true)
        let proposedPath = categoryFolder.appendingPathComponent(cleanName).path

        let currentProjectIds = projectService.projectIds(forDocument: document.id, approvedOnly: true)
        let history = FileOperationHistory(
            documentId: document.id,
            operationType: .combinedOrganize,
            previousFileName: document.fileName,
            proposedFileName: cleanName,
            previousFilePath: document.filePath,
            proposedFilePath: proposedPath,
            previousCategory: document.category,
            proposedCategory: document.category,
            previousTags: document.tags,
            proposedTags: Array(Set(document.tags + [document.category.rawValue])).sorted(),
            previousProjectIds: currentProjectIds,
            proposedProjectIds: suggestedProjectIds,
            reason: "カテゴリ『\(document.category.rawValue)』に基づく標準命名規則およびフォルダ整理の提案",
            modelId: modelManager.globalSettings.judgeModelId,
            status: .pendingApproval
        )

        operationHistories.insert(history, at: 0)
        try database.saveFileOperationHistory(history)
        return history
    }

    /// 仕様書 §7.4 & §1.2(5): ユーザー承認後にファイル整理提案を適用する
    public func approveAndApplyFileOperation(historyId: UUID) throws {
        guard let hIdx = operationHistories.firstIndex(where: { $0.id == historyId }) else { return }
        var history = operationHistories[hIdx]
        guard history.status == .pendingApproval else { return }

        guard let dIdx = documents.firstIndex(where: { $0.id == history.documentId }) else { return }
        var doc = documents[dIdx]

        // 実ファイルが存在し管理領域内にある場合は移動・リネームを実行
        let prevURL = URL(fileURLWithPath: history.previousFilePath)
        let nextURL = URL(fileURLWithPath: history.proposedFilePath)
        if FileManager.default.fileExists(atPath: prevURL.path) && prevURL.path != nextURL.path {
            try FileManager.default.createDirectory(at: nextURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: nextURL.path) {
                try? FileManager.default.removeItem(at: nextURL)
            }
            try FileManager.default.moveItem(at: prevURL, to: nextURL)
            doc.filePath = nextURL.path
        } else {
            doc.filePath = history.proposedFilePath
        }

        doc.fileName = history.proposedFileName
        doc.category = history.proposedCategory
        doc.tags = history.proposedTags
        doc.updatedAt = Date()

        for pid in history.proposedProjectIds {
            try projectService.associateDocument(
                documentId: doc.id,
                projectId: pid,
                relevanceScore: 1.0,
                isSuggestedByAI: false,
                isApproved: true
            )
        }

        history.status = .approvedAndApplied
        history.appliedAt = Date()

        documents[dIdx] = doc
        operationHistories[hIdx] = history
        try database.saveDocument(doc)
        try database.saveFileOperationHistory(history)
        try embeddingService.indexDocument(doc, projectIds: history.proposedProjectIds)
    }

    public func rejectFileOperation(historyId: UUID) throws {
        guard let hIdx = operationHistories.firstIndex(where: { $0.id == historyId }) else { return }
        operationHistories[hIdx].status = .rejected
        try database.saveFileOperationHistory(operationHistories[hIdx])
    }

    /// 仕様書 §7.4: 適用済みのファイル操作を取り消し（ロールバック）、元のファイル名・パス・タグに戻す
    public func undoFileOperation(historyId: UUID) throws {
        guard let hIdx = operationHistories.firstIndex(where: { $0.id == historyId }) else { return }
        var history = operationHistories[hIdx]
        guard history.status == .approvedAndApplied else { return }

        guard let dIdx = documents.firstIndex(where: { $0.id == history.documentId }) else { return }
        var doc = documents[dIdx]

        let currentURL = URL(fileURLWithPath: history.proposedFilePath)
        let originalURL = URL(fileURLWithPath: history.previousFilePath)
        if FileManager.default.fileExists(atPath: currentURL.path) && currentURL.path != originalURL.path {
            try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: originalURL.path) {
                try? FileManager.default.removeItem(at: originalURL)
            }
            try FileManager.default.moveItem(at: currentURL, to: originalURL)
        }

        doc.fileName = history.previousFileName
        doc.filePath = history.previousFilePath
        doc.category = history.previousCategory
        doc.tags = history.previousTags
        doc.updatedAt = Date()

        history.status = .undone
        history.undoneAt = Date()

        documents[dIdx] = doc
        operationHistories[hIdx] = history
        try database.saveDocument(doc)
        try database.saveFileOperationHistory(history)
        try embeddingService.indexDocument(doc, projectIds: history.previousProjectIds)
    }

    // MARK: - §2.1 & §11.2, §11.3 アプリ内登録ドキュメントの更新・削除と差分インデックス管理

    /// アプリ内で登録したドキュメントの内容・タイトルを更新し、チャンクハッシュ比較による差分インデックス更新を行う（§11.2）
    @discardableResult
    public func updateDocumentContent(
        documentId: UUID,
        newFileName: String? = nil,
        newContent: String
    ) throws -> DocumentIndexingOutcome {
        guard let idx = documents.firstIndex(where: { $0.id == documentId }) else {
            throw NSError(domain: "DocumentService", code: 404, userInfo: [NSLocalizedDescriptionKey: "対象のドキュメントが見つかりません"])
        }
        var doc = documents[idx]
        if let newFileName, !newFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.fileName = newFileName
        }
        doc.extractedText = newContent
        doc.contentHash = Self.sha256Hex(of: newContent)
        doc.fileSizeBytes = Int64(newContent.utf8.count)
        doc.summary = Self.buildLightweightSummary(from: newContent)
        doc.updatedAt = Date()

        // 管理領域コピー方式でローカルファイルが存在する場合はファイル内容も更新
        if doc.storageMode == .copiedToManagedStorage, !doc.filePath.isEmpty {
            try? newContent.write(toFile: doc.filePath, atomically: true, encoding: .utf8)
        }

        documents[idx] = doc
        try database.saveDocument(doc)

        let pids = projectService.projectIds(forDocument: doc.id)
        return try embeddingService.indexDocument(doc, projectIds: pids)
    }

    /// アプリ内で登録したドキュメントを削除し、documents / document_contents / document_chunks / search_units / FTS5 / embeddings から完全削除する（§11.3）
    public func deleteDocument(documentId: UUID) throws {
        if let idx = documents.firstIndex(where: { $0.id == documentId }) {
            let doc = documents[idx]
            if doc.storageMode == .copiedToManagedStorage, FileManager.default.fileExists(atPath: doc.filePath) {
                try? FileManager.default.removeItem(atPath: doc.filePath)
            }
            documents.remove(at: idx)
        }
        operationHistories.removeAll { $0.documentId == documentId }
        try database.deleteDocument(id: documentId)
        try embeddingService.deleteDocumentIndex(documentId: documentId)
    }

    // MARK: - Folder Monitoring (仕様書 §7.5 自動分類・フォルダ監視)

    public func startMonitoringFolder(path: String, projectId: UUID? = nil) {
        guard !watchedFolders.contains(path) else { return }
        watchedFolders.append(path)

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.scanFolderAndSyncChanges(path: path, projectId: projectId)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        folderWatchers[path] = source
    }

    public func scanFolderAndSyncChanges(path: String, projectId: UUID? = nil) async {
        let folderURL = URL(fileURLWithPath: path, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in urls {
            let fileType = Self.detectFileType(for: fileURL)
            guard fileType != .other else { continue }
            let text = Self.extractText(from: fileURL, fileType: fileType)
            let hash = Self.sha256Hex(of: text)

            if let existingIdx = documents.firstIndex(where: { $0.originalPath == fileURL.path || $0.filePath == fileURL.path }) {
                // 内容ハッシュが変化していた場合のみ差分更新・Embedding再生成を行う
                if documents[existingIdx].contentHash != hash {
                    documents[existingIdx].extractedText = text
                    documents[existingIdx].contentHash = hash
                    documents[existingIdx].updatedAt = Date()
                    try? database.saveDocument(documents[existingIdx])
                    let pids = projectService.projectIds(forDocument: documents[existingIdx].id)
                    _ = try? embeddingService.indexDocument(documents[existingIdx], projectIds: pids)
                }
            } else {
                let pids = projectId.map { [$0] } ?? []
                _ = try? await registerFile(
                    url: fileURL,
                    storageMode: .referencedInPlace,
                    explicitContent: text,
                    initialProjectIds: pids
                )
            }
        }
    }

    // MARK: - Helpers

    private func findRelatedDocumentIds(for document: Document) -> [UUID] {
        let embModel = modelManager.model(withId: modelManager.globalSettings.embeddingModelId)
            ?? modelManager.models(for: .embedding).first!
        let adapter = LocalEmbeddingAdapter(model: embModel)
        let targetVec = adapter.generateEmbedding(for: "\(document.fileName) \(document.extractedText.prefix(500))")

        var scored: [(UUID, Double)] = []
        for other in documents where other.id != document.id {
            let otherVec = adapter.generateEmbedding(for: "\(other.fileName) \(other.extractedText.prefix(500))")
            let sim = LocalEmbeddingAdapter.cosineSimilarity(targetVec, otherVec)
            if sim >= 0.35 {
                scored.append((other.id, sim))
            }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
    }

    public static func detectFileType(for url: URL) -> DocumentFileType {
        switch url.pathExtension.lowercased() {
        case "txt", "log": .txt
        case "md", "markdown": .markdown
        case "pdf": .pdf
        case "json": .json
        case "swift", "py", "ts", "tsx", "js", "rs", "go", "c", "cpp", "h", "yaml", "yml", "toml": .sourceCode
        default: .other
        }
    }

    public static func extractText(from url: URL, fileType: DocumentFileType) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        if fileType == .pdf {
            if let pdf = PDFDocument(url: url), let pdfText = pdf.string, !pdfText.isEmpty {
                return pdfText
            }
        }
        if let str = try? String(contentsOf: url, encoding: .utf8) {
            return str
        }
        return ""
    }

    public static func buildLightweightSummary(from text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return "テキスト内容なし" }
        let joined = lines.prefix(3).joined(separator: " ")
        return String(joined.prefix(180))
    }

    public static func sha256Hex(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
