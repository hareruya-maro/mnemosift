import Foundation
import AppKit
import PDFKit
import Vision
import CryptoKit
import Observation

/// 仕様書 §7 & ローカルAIドキュメント検索仕様書 v1.0:
/// ファイル管理・解析・段階的分類・整理提案・フォルダ指定一括読み込み・自動再読み込みサービス
/// - 管理領域コピー方式と元場所参照方式（外部ドキュメント）を明確に区別
/// - 外部フォルダ一括読み込み・監視では、まずテキストファイルと画像ファイル（Apple Vision オンデバイスOCR）を対象とし、
///   優先度低（`.lowBackground`）のバックグラウンドジョブとして実行する
/// - 監視対象フォルダ内のファイル更新・追加・削除を自動検知し、差分インデックス更新（未変更チャンクのEmbedding再利用）を実行する
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
    public private(set) var watchedFolderRecords: [WatchedFolderRecord] = []
    public private(set) var lastFolderImportSummary: FolderBulkImportSummary?
    public private(set) var isFolderSyncRunning: Bool = false

    private var directoryAndFileWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var debouncedFolderSyncTasks: [String: Task<Void, Never>] = [:]

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
        let savedFolders = (try? database.loadWatchedFolders()) ?? []
        self.watchedFolderRecords = savedFolders
        self.watchedFolders = savedFolders.filter(\.isEnabled).map(\.folderPath)

        for record in savedFolders where record.isEnabled {
            installFileSystemWatchers(
                forFolderPath: record.folderPath,
                projectId: record.projectId,
                includeSubdirectories: record.includeSubdirectories
            )
        }
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

        let hash = Self.computeFileAndContentHash(
            extractedText: extractedText,
            fileURL: explicitContent == nil ? URL(fileURLWithPath: activeFilePath) : nil
        )
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

        var extraTags = judgeOutput.suggestedTags
        if document.fileType == .image {
            extraTags = Array(Set(extraTags + ["画像OCR"])).sorted()
        }

        if judgeOutput.calibratedConfidence >= config.judgeConfidenceThreshold {
            // 判断モデルのみで十分な確信度（>= 0.72）が得られたため、大型LLMを起動せず完了
            let summary = Self.buildLightweightSummary(from: document.extractedText)
            return (
                category: judgeOutput.category,
                tags: extraTags,
                summary: summary,
                matchedProjectIds: Array(matchedProjects),
                relatedDocumentIds: findRelatedDocumentIds(for: document),
                stageUsed: "Stage 2: 判断モデル (\(config.judgeModel.name)) [確信度 \(Int(judgeOutput.calibratedConfidence * 100))%・大型LLM起動省略]"
            )
        }

        // Stage 3: 判断モデルで確信度が低い場合のみ LLM を起動して詳細分析（優先度低バックグラウンド）
        let llmModel = config.llmModel
        return try await jobManager.enqueueAndRun(
            type: .documentClassification,
            title: "LLM詳細ファイル分類『\(document.fileName)』",
            priority: .lowBackground,
            modelId: llmModel.id,
            requiredMemoryMB: llmModel.requiredMemoryMB
        ) {
            let summary = Self.buildLightweightSummary(from: document.extractedText)
            let enrichedTags = Array(Set(extraTags + ["LLM詳細解析済み"])).sorted()
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

    // MARK: - §2.1 & §11.2, §11.3 ドキュメントの更新・削除と差分インデックス管理

    /// ドキュメントの内容・タイトルを更新し、チャンクハッシュ比較による差分インデックス更新を行う（§11.2）
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

        if doc.storageMode == .copiedToManagedStorage, !doc.filePath.isEmpty {
            try? newContent.write(toFile: doc.filePath, atomically: true, encoding: .utf8)
        }

        documents[idx] = doc
        try database.saveDocument(doc)

        let pids = projectService.projectIds(forDocument: doc.id)
        return try embeddingService.indexDocument(doc, projectIds: pids)
    }

    /// ドキュメントを削除し、documents / document_contents / document_chunks / search_units / FTS5 / embeddings から完全削除する（§11.3）
    public func deleteDocument(documentId: UUID) throws {
        if let idx = documents.firstIndex(where: { $0.id == documentId }) {
            let doc = documents[idx]
            stopWatchingPath(doc.originalPath)
            if doc.storageMode == .copiedToManagedStorage, FileManager.default.fileExists(atPath: doc.filePath) {
                try? FileManager.default.removeItem(atPath: doc.filePath)
            }
            documents.remove(at: idx)
        }
        operationHistories.removeAll { $0.documentId == documentId }
        try database.deleteDocument(id: documentId)
        try embeddingService.deleteDocumentIndex(documentId: documentId)
    }

    // MARK: - フォルダ指定一括読み込み・ファイル更新時の自動再読み込み・低優先度バックグラウンド処理

    /// フォルダを指定してテキストファイル・画像ファイルを優先度低（`.lowBackground`）のバックグラウンド処理として一括読み込み・差分同期し、自動監視を開始する
    @discardableResult
    public func importFolderInBackground(
        path: String,
        projectId: UUID? = nil,
        includeSubdirectories: Bool = true
    ) async -> FolderBulkImportSummary {
        let normalizedPath = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        startMonitoringFolder(path: normalizedPath, projectId: projectId, includeSubdirectories: includeSubdirectories)

        let embModel = modelManager.model(withId: modelManager.globalSettings.embeddingModelId)
            ?? modelManager.models(for: .embedding).first!

        isFolderSyncRunning = true
        defer { isFolderSyncRunning = false }

        if let summary = try? await jobManager.enqueueAndRun(
            type: .folderBulkImport,
            title: "フォルダ一括読み込み・差分同期『\(URL(fileURLWithPath: normalizedPath).lastPathComponent)』",
            priority: .lowBackground,
            projectId: projectId,
            modelId: embModel.id,
            requiredMemoryMB: max(128, embModel.requiredMemoryMB / 2),
            operation: {
                let summary = await self.performFolderScanAndSync(
                    normalizedFolderPath: normalizedPath,
                    projectId: projectId,
                    includeSubdirectories: includeSubdirectories
                )
                self.lastFolderImportSummary = summary
                return (summary, summary.statusSummaryText)
            }
        ) {
            return summary
        }

        let fallback = await performFolderScanAndSync(
            normalizedFolderPath: normalizedPath,
            projectId: projectId,
            includeSubdirectories: includeSubdirectories
        )
        lastFolderImportSummary = fallback
        return fallback
    }

    /// フォルダ監視を開始し、永続化レコードに保存する
    public func startMonitoringFolder(
        path: String,
        projectId: UUID? = nil,
        includeSubdirectories: Bool = true
    ) {
        let normalizedPath = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        guard !normalizedPath.isEmpty else { return }

        if !watchedFolders.contains(normalizedPath) {
            watchedFolders.append(normalizedPath)
        }

        if let existingIdx = watchedFolderRecords.firstIndex(where: { $0.folderPath == normalizedPath }) {
            watchedFolderRecords[existingIdx].isEnabled = true
            watchedFolderRecords[existingIdx].projectId = projectId ?? watchedFolderRecords[existingIdx].projectId
            watchedFolderRecords[existingIdx].includeSubdirectories = includeSubdirectories
            try? database.saveWatchedFolder(watchedFolderRecords[existingIdx])
        } else {
            let record = WatchedFolderRecord(
                folderPath: normalizedPath,
                projectId: projectId,
                includeSubdirectories: includeSubdirectories,
                isEnabled: true
            )
            watchedFolderRecords.append(record)
            try? database.saveWatchedFolder(record)
        }

        installFileSystemWatchers(
            forFolderPath: normalizedPath,
            projectId: projectId,
            includeSubdirectories: includeSubdirectories
        )
    }

    /// 監視対象フォルダを解除する
    public func stopMonitoringFolder(path: String) {
        removeWatchedFolder(path: path)
    }

    /// 監視対象フォルダを解除する
    public func removeWatchedFolder(path: String) {
        let normalizedPath = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        watchedFolders.removeAll { $0 == normalizedPath }
        debouncedFolderSyncTasks[normalizedPath]?.cancel()
        debouncedFolderSyncTasks.removeValue(forKey: normalizedPath)

        // 該当フォルダ配下のウォッチャーをすべて停止
        let keysToStop = directoryAndFileWatchers.keys.filter { $0 == normalizedPath || $0.hasPrefix(normalizedPath + "/") }
        for key in keysToStop {
            stopWatchingPath(key)
        }

        if let idx = watchedFolderRecords.firstIndex(where: { $0.folderPath == normalizedPath }) {
            let recId = watchedFolderRecords[idx].id
            watchedFolderRecords.remove(at: idx)
            try? database.deleteWatchedFolder(id: recId)
        }
    }

    /// 監視対象フォルダのスキャンと差分再読み込み（低優先度バックグラウンドジョブ経由）
    @discardableResult
    public func scanFolderAndSyncChanges(
        path: String,
        projectId: UUID? = nil,
        includeSubdirectories: Bool? = nil
    ) async -> FolderBulkImportSummary {
        let normalizedPath = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        let includeSubdirs = includeSubdirectories
            ?? watchedFolderRecords.first(where: { $0.folderPath == normalizedPath })?.includeSubdirectories
            ?? true
        return await importFolderInBackground(
            path: normalizedPath,
            projectId: projectId,
            includeSubdirectories: includeSubdirs
        )
    }

    // MARK: - Internal Folder Enumeration & File Watcher Implementation

    private func performFolderScanAndSync(
        normalizedFolderPath: String,
        projectId: UUID?,
        includeSubdirectories: Bool
    ) async -> FolderBulkImportSummary {
        let startTime = CFAbsoluteTimeGetCurrent()
        let folderURL = URL(fileURLWithPath: normalizedFolderPath, isDirectory: true)
        let candidateURLs = Self.collectRegularFileURLs(in: folderURL, includeSubdirectories: includeSubdirectories)

        var scannedCount = 0
        var newlyImported = 0
        var textImported = 0
        var imageImported = 0
        var updatedReloaded = 0
        var unchangedSkipped = 0
        var unsupportedSkipped = 0
        var seenFilePaths: Set<String> = []

        for fileURL in candidateURLs {
            scannedCount += 1
            let standardizedFilePath = fileURL.standardizedFileURL.path
            seenFilePaths.insert(standardizedFilePath)

            let fileType = Self.detectFileType(for: fileURL)
            // 要件: まずはテキストファイルと画像ファイルのみを対象とし、PDFやOffice文書等はスキップする
            guard fileType.isSupportedInFolderBulkImport else {
                unsupportedSkipped += 1
                continue
            }

            // 低優先度バックグラウンド処理として、UIやリアルタイム録音/STTを阻害しないよう適宜タスクを譲る
            await Task.yield()
            if jobManager.hasCriticalRealtimeJobRunning {
                try? await Task.sleep(for: .milliseconds(25))
            }

            let extractedText = Self.extractText(from: fileURL, fileType: fileType)
            let hash = Self.computeFileAndContentHash(extractedText: extractedText, fileURL: fileURL)
            let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: standardizedFilePath)[.size] as? Int64)
                ?? Int64(extractedText.utf8.count)

            if let existingIdx = documents.firstIndex(where: {
                URL(fileURLWithPath: $0.originalPath).standardizedFileURL.path == standardizedFilePath ||
                URL(fileURLWithPath: $0.filePath).standardizedFileURL.path == standardizedFilePath
            }) {
                // ファイルが更新され内容ハッシュが変化していた場合のみ自動再読み込み＆差分インデックス更新を実行
                if documents[existingIdx].contentHash != hash {
                    documents[existingIdx].extractedText = extractedText
                    documents[existingIdx].contentHash = hash
                    documents[existingIdx].fileSizeBytes = sizeBytes
                    documents[existingIdx].summary = Self.buildLightweightSummary(from: extractedText)
                    documents[existingIdx].updatedAt = Date()
                    try? database.saveDocument(documents[existingIdx])

                    let pids = projectService.projectIds(forDocument: documents[existingIdx].id)
                    _ = try? embeddingService.indexDocument(documents[existingIdx], projectIds: pids)
                    updatedReloaded += 1
                } else {
                    unchangedSkipped += 1
                }
            } else {
                // 新規テキスト・画像ファイルの取り込み（外部参照モード `.referencedInPlace` で重複ファイルコピーを避ける §4.2）
                let pids = projectId.map { [$0] } ?? []
                if let newDoc = try? await registerExternalDocumentLightweight(
                    fileURL: fileURL,
                    fileType: fileType,
                    extractedText: extractedText,
                    contentHash: hash,
                    fileSizeBytes: sizeBytes,
                    initialProjectIds: pids
                ) {
                    newlyImported += 1
                    if fileType.isImageFile {
                        imageImported += 1
                    } else {
                        textImported += 1
                    }
                    _ = newDoc
                }
            }

            // 個別ファイルの in-place 編集も即時検知できるようファイルウォッチャーを設定
            installSinglePathWatcher(
                targetPath: standardizedFilePath,
                rootFolderPath: normalizedFolderPath,
                projectId: projectId,
                includeSubdirectories: includeSubdirectories
            )
        }

        // フォルダ配下の既存外部ドキュメントで、元ファイルが削除・移動されて参照不能になったものを検知 (§4.2)
        var inaccessibleCount = 0
        for doc in documents where doc.storageMode == .referencedInPlace {
            let stdOrig = URL(fileURLWithPath: doc.originalPath).standardizedFileURL.path
            if stdOrig.hasPrefix(normalizedFolderPath + "/") && !FileManager.default.fileExists(atPath: stdOrig) {
                if var contentRec = try? embeddingService.documentRepository.fetchDocumentContent(documentId: doc.id.uuidString),
                   contentRec.isSourceAccessible {
                    contentRec.isSourceAccessible = false
                    contentRec.updatedAt = Date()
                    try? embeddingService.documentRepository.upsertDocumentContent(contentRec)
                    inaccessibleCount += 1
                }
            }
        }

        // サブディレクトリが増えている場合もウォッチャーを補完
        installFileSystemWatchers(
            forFolderPath: normalizedFolderPath,
            projectId: projectId,
            includeSubdirectories: includeSubdirectories
        )

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let summary = FolderBulkImportSummary(
            folderPath: normalizedFolderPath,
            scannedFileCount: scannedCount,
            newlyImportedCount: newlyImported,
            textImportedCount: textImported,
            imageImportedCount: imageImported,
            updatedReloadedCount: updatedReloaded,
            unchangedSkippedCount: unchangedSkipped,
            unsupportedSkippedCount: unsupportedSkipped,
            inaccessibleMarkedCount: inaccessibleCount,
            durationMs: elapsedMs
        )

        if let rIdx = watchedFolderRecords.firstIndex(where: { $0.folderPath == normalizedFolderPath }) {
            let docsInFolder = documents.filter {
                URL(fileURLWithPath: $0.originalPath).standardizedFileURL.path.hasPrefix(normalizedFolderPath + "/")
            }
            watchedFolderRecords[rIdx].importedDocumentCount = docsInFolder.count
            watchedFolderRecords[rIdx].textDocumentCount = docsInFolder.filter { $0.fileType.isTextFile }.count
            watchedFolderRecords[rIdx].imageDocumentCount = docsInFolder.filter { $0.fileType.isImageFile }.count
            watchedFolderRecords[rIdx].skippedUnsupportedCount = unsupportedSkipped
            watchedFolderRecords[rIdx].lastScannedAt = Date()
            watchedFolderRecords[rIdx].lastStatusSummary = summary.statusSummaryText
            try? database.saveWatchedFolder(watchedFolderRecords[rIdx])
        }

        return summary
    }

    /// フォルダ一括読み込み時の軽量外部ドキュメント登録（大型LLMを起動せずバックグラウンドで高速インデックス化）
    private func registerExternalDocumentLightweight(
        fileURL: URL,
        fileType: DocumentFileType,
        extractedText: String,
        contentHash: String,
        fileSizeBytes: Int64,
        initialProjectIds: [UUID]
    ) async throws -> Document {
        let stdPath = fileURL.standardizedFileURL.path
        var document = Document(
            fileName: fileURL.lastPathComponent,
            filePath: stdPath,
            originalPath: stdPath,
            storageMode: .referencedInPlace,
            fileType: fileType,
            fileSizeBytes: fileSizeBytes,
            contentHash: contentHash,
            extractedText: extractedText
        )

        let config = modelManager.resolveConfiguration()
        let judge = SystemOneJudgeAdapter(model: config.judgeModel)
        let judgeOutput = judge.classifyDocument(
            fileName: document.fileName,
            content: document.extractedText,
            projects: projectService.projects,
            vocabularies: projectService.vocabularies
        )

        var matchedProjects = Set(initialProjectIds)
        for (pid, score) in judgeOutput.projectRelevanceScores where score >= 0.35 {
            matchedProjects.insert(pid)
        }

        var tags = judgeOutput.suggestedTags
        if fileType == .image {
            tags = Array(Set(tags + ["画像OCR"])).sorted()
        }

        document.category = judgeOutput.category
        document.tags = tags
        document.summary = Self.buildLightweightSummary(from: extractedText)
        document.classificationStage = fileType == .image
            ? "Vision OCR + 軽量判断モデル (\(config.judgeModel.name))"
            : "フォルダ一括取込 + 軽量判断モデル (\(config.judgeModel.name))"
        document.relatedDocumentIds = findRelatedDocumentIds(for: document)

        documents.insert(document, at: 0)
        try database.saveDocument(document)

        let finalPids = Array(matchedProjects)
        for pid in finalPids {
            try projectService.associateDocument(
                documentId: document.id,
                projectId: pid,
                relevanceScore: 0.9,
                isSuggestedByAI: !initialProjectIds.contains(pid),
                isApproved: initialProjectIds.contains(pid)
            )
        }
        try embeddingService.indexDocument(document, projectIds: finalPids)
        return document
    }

    private func installFileSystemWatchers(
        forFolderPath folderPath: String,
        projectId: UUID?,
        includeSubdirectories: Bool
    ) {
        installSinglePathWatcher(
            targetPath: folderPath,
            rootFolderPath: folderPath,
            projectId: projectId,
            includeSubdirectories: includeSubdirectories
        )

        guard includeSubdirectories else { return }
        let rootURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var watchedDirCount = 0
        for case let itemURL as URL in enumerator {
            guard watchedDirCount < 64 else { break }
            if (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let dirPath = itemURL.standardizedFileURL.path
                installSinglePathWatcher(
                    targetPath: dirPath,
                    rootFolderPath: folderPath,
                    projectId: projectId,
                    includeSubdirectories: includeSubdirectories
                )
                watchedDirCount += 1
            }
        }
    }

    private func installSinglePathWatcher(
        targetPath: String,
        rootFolderPath: String,
        projectId: UUID?,
        includeSubdirectories: Bool
    ) {
        // 既にウォッチャーが稼働中ならスキップ（合計ディスクリプタ数上限 192 で保護）
        guard directoryAndFileWatchers[targetPath] == nil,
              directoryAndFileWatchers.count < 192 else { return }

        let fd = open(targetPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            Task { @MainActor in
                // エディタによる atomic save (.rename / .delete) の場合はウォッチャーを張り直す
                if flags.contains(.rename) || flags.contains(.delete) {
                    self.stopWatchingPath(targetPath)
                    if FileManager.default.fileExists(atPath: targetPath) {
                        self.installSinglePathWatcher(
                            targetPath: targetPath,
                            rootFolderPath: rootFolderPath,
                            projectId: projectId,
                            includeSubdirectories: includeSubdirectories
                        )
                    }
                }
                self.scheduleDebouncedFolderSync(
                    folderPath: rootFolderPath,
                    projectId: projectId,
                    includeSubdirectories: includeSubdirectories
                )
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        directoryAndFileWatchers[targetPath] = source
    }

    private func stopWatchingPath(_ path: String) {
        if let src = directoryAndFileWatchers.removeValue(forKey: path) {
            src.cancel()
        }
    }

    private func scheduleDebouncedFolderSync(
        folderPath: String,
        projectId: UUID?,
        includeSubdirectories: Bool
    ) {
        debouncedFolderSyncTasks[folderPath]?.cancel()
        debouncedFolderSyncTasks[folderPath] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            _ = await self.importFolderInBackground(
                path: folderPath,
                projectId: projectId,
                includeSubdirectories: includeSubdirectories
            )
        }
    }

    // MARK: - Helpers (ファイル種別判定・テキスト抽出・Apple Vision 画像OCR)

    private static func collectRegularFileURLs(in folderURL: URL, includeSubdirectories: Bool) -> [URL] {
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return [] }
        if !includeSubdirectories {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.path < $1.path }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let ignoredDirNames: Set<String> = ["node_modules", ".git", ".build", "DerivedData", "__pycache__"]
        var files: [URL] = []
        for case let itemURL as URL in enumerator {
            let name = itemURL.lastPathComponent
            if ignoredDirNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if (try? itemURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(itemURL)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

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
        case "txt", "log", "csv", "tsv", "rtf":
            .txt
        case "md", "markdown", "mdx":
            .markdown
        case "json", "jsonl":
            .json
        case "swift", "py", "ts", "tsx", "js", "jsx", "rs", "go", "c", "cpp", "h", "hpp", "yaml", "yml", "toml", "xml", "html", "css", "sh", "zsh", "sql":
            .sourceCode
        case "png", "jpg", "jpeg", "heic", "webp", "tiff", "tif", "bmp", "gif":
            .image
        case "pdf":
            .pdf
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx":
            .officeDocument
        default:
            .other
        }
    }

    public static func extractText(from url: URL, fileType: DocumentFileType) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }

        if fileType == .image {
            return extractTextFromImageUsingVision(at: url)
        }

        if fileType == .pdf {
            if let pdf = PDFDocument(url: url), let pdfText = pdf.string, !pdfText.isEmpty {
                return pdfText
            }
        }

        // テキストファイルの読み込み（UTF-8 → Shift-JIS → EUC-JP → ISO-8859-1 の順にフォールバック）
        for encoding: String.Encoding in [.utf8, .shiftJIS, .japaneseEUC, .isoLatin1] {
            if let str = try? String(contentsOf: url, encoding: encoding), !str.isEmpty {
                return str
            }
        }
        return ""
    }

    /// Apple Vision (`VNRecognizeTextRequest`) を用いた画像ファイルのオンデバイスOCRテキスト抽出（日本語・英語対応）
    public static func extractTextFromImageUsingVision(at url: URL) -> String {
        var recognizedLines: [(minY: CGFloat, minX: CGFloat, text: String)] = []

        let request = VNRecognizeTextRequest { req, _ in
            guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
            for obs in observations {
                if let candidate = obs.topCandidates(1).first {
                    let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        recognizedLines.append((obs.boundingBox.minY, obs.boundingBox.minX, trimmed))
                    }
                }
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ja-JP", "en-US"]

        if let image = NSImage(contentsOf: url),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        } else {
            let handler = VNImageRequestHandler(url: url, options: [:])
            try? handler.perform([request])
        }

        // Vision の座標系は左下が (0,0) のため、上から下（minY の降順）→ 左から右（minX の昇順）に整列する
        let ordered = recognizedLines.sorted { a, b in
            if abs(a.minY - b.minY) > 0.025 {
                return a.minY > b.minY
            }
            return a.minX < b.minX
        }.map(\.text)

        if !ordered.isEmpty {
            return ordered.joined(separator: "\n")
        }

        // 文字が含まれない画像（図形・アイコンのみ等）の場合もファイル名と解像度メタデータを保持する
        if let img = NSImage(contentsOf: url) {
            let w = Int(img.size.width)
            let h = Int(img.size.height)
            return "[画像ファイル: \(url.lastPathComponent) (\(w)x\(h))]"
        }
        return "[画像ファイル: \(url.lastPathComponent)]"
    }

    /// テストおよびプレビュー生成用：指定したテキストを描画したPNG画像ファイルを生成する
    @discardableResult
    public static func renderTextToPNGImageFile(
        lines: [String],
        to destinationURL: URL,
        size: NSSize = NSSize(width: 960, height: 360)
    ) throws -> URL {
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "DocumentService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap representation"])
        }

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep) {
            NSGraphicsContext.current = ctx
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 32),
                .foregroundColor: NSColor.black
            ]
            var yCursor = size.height - 68
            for line in lines {
                let nsStr = line as NSString
                nsStr.draw(at: NSPoint(x: 36, y: yCursor), withAttributes: attrs)
                yCursor -= 56
            }
            ctx.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            try pngData.write(to: destinationURL, options: .atomic)
        }
        return destinationURL
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

    /// 抽出テキストのハッシュに加え、実ファイルがある場合はバイナリのSHA-256も組み合わせて画像変更等を確実に検知する
    public static func computeFileAndContentHash(extractedText: String, fileURL: URL?) -> String {
        if let fileURL,
           let fileData = try? Data(contentsOf: fileURL),
           !fileData.isEmpty {
            var hasher = SHA256()
            hasher.update(data: Data(extractedText.utf8))
            hasher.update(data: fileData)
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        return sha256Hex(of: extractedText)
    }
}
