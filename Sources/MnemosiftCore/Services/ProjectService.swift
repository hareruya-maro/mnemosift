import Foundation
import Observation

/// 仕様書 §4: プロジェクト管理・プロジェクト辞書サービス
/// - プロジェクトは任意であり、未所属データも正式データとして扱う
/// - 1つのファイルや議事録を複数プロジェクトに関連付け可能
/// - 4つの辞書作成経路と承認フロー、3段階の適用優先順位を提供
@Observable
@MainActor
public final class ProjectService {
    private let database: LocalDatabase
    private let modelManager: ModelManager
    private let jobManager: JobManager

    public private(set) var projects: [Project] = []
    public private(set) var vocabularies: [Vocabulary] = []
    public private(set) var projectDocuments: [ProjectDocument] = []

    public init(database: LocalDatabase, modelManager: ModelManager, jobManager: JobManager) {
        self.database = database
        self.modelManager = modelManager
        self.jobManager = jobManager

        let loadedProjects = (try? database.loadProjects()) ?? []
        let loadedVocabs = (try? database.loadVocabularies()) ?? []
        let loadedLinks = (try? database.loadProjectDocuments()) ?? []

        if loadedProjects.isEmpty && loadedVocabs.isEmpty {
            let seeded = Self.seedInitialProjectsAndDictionary(database: database)
            self.projects = seeded.projects
            self.vocabularies = seeded.vocabularies
        } else {
            self.projects = loadedProjects
            self.vocabularies = loadedVocabs
        }
        self.projectDocuments = loadedLinks
    }

    private static func seedInitialProjectsAndDictionary(database: LocalDatabase) -> (projects: [Project], vocabularies: [Vocabulary]) {
        let coreProject = Project(
            name: "Mnemosift 開発プロジェクト",
            description: "macOS Apple Silicon向けローカルAIワークスペース（STT・System One判断モデル・LLM・RAG統合）の設計・開発",
            relatedFolderPaths: [],
            defaultTemplateId: "template-technical",
            classificationRules: [
                ClassificationRule(
                    name: "仕様・設計ドキュメント自動分類",
                    filenameKeyword: "spec",
                    contentKeyword: "仕様書",
                    targetCategory: .specification,
                    targetTags: ["Mnemosift", "仕様書"]
                )
            ]
        )
        try? database.saveProject(coreProject)

        let defaultVocabs: [Vocabulary] = [
            Vocabulary(
                projectId: coreProject.id,
                canonicalForm: "Mnemosift",
                reading: "ネモシフト",
                aliases: ["MnemoSift", "mnemosift"],
                commonMisrecognitions: ["ネモシフト", "メモシフト", "ニモシフト"],
                definition: "本プロジェクトで開発するmacOSローカルAIワークスペースアプリの名称",
                usageFrequency: 15,
                source: .manual,
                approvalStatus: .approved,
                priorityScope: .projectDictionary,
                domainTags: ["アプリ名", "ローカルAI", "macOS"]
            ),
            Vocabulary(
                projectId: coreProject.id,
                canonicalForm: "Qwen3-ASR",
                reading: "キュウエン・スリー・エーエスアール",
                aliases: ["Qwen3 ASR", "Qwen-ASR"],
                commonMisrecognitions: ["キュウエン・エーエスアール", "クウェンエーエスアール", "9円ASR"],
                definition: "ローカル実行に対応した多言語音声認識(STT)モデル",
                usageFrequency: 12,
                source: .manual,
                approvalStatus: .approved,
                priorityScope: .projectDictionary,
                domainTags: ["STT", "音声認識", "モデル"]
            ),
            Vocabulary(
                projectId: coreProject.id,
                canonicalForm: "WhisperKit",
                reading: "ウィスパーキット",
                aliases: ["Whisper Kit"],
                commonMisrecognitions: ["ウィスパーキット", "イスパーキット"],
                definition: "Apple Silicon Core ML 向けに最適化された Whisper 音声認識フレームワーク",
                usageFrequency: 10,
                source: .manual,
                approvalStatus: .approved,
                priorityScope: .projectDictionary,
                domainTags: ["STT", "CoreML", "Apple Silicon"]
            ),
            Vocabulary(
                projectId: nil,
                canonicalForm: "ScreenCaptureKit",
                reading: "スクリーンキャプチャキット",
                aliases: ["SCStream"],
                commonMisrecognitions: ["スクリーンキャプチャーキット", "スクリーンキャプチャキッド"],
                definition: "macOSでシステム音声および画面を高効率にキャプチャするApple公式フレームワーク",
                usageFrequency: 8,
                source: .manual,
                approvalStatus: .approved,
                priorityScope: .commonDictionary,
                domainTags: ["macOS", "システム音声", "録音"]
            ),
            Vocabulary(
                projectId: nil,
                canonicalForm: "Gemma 4",
                reading: "ジェマ・フォー",
                aliases: ["Gemma4"],
                commonMisrecognitions: ["ジェマフォー", "ジェマ4", "ゲマフォー"],
                definition: "ローカル議事録生成・高精度補正に使用する標準LLMモデル",
                usageFrequency: 9,
                source: .manual,
                approvalStatus: .approved,
                priorityScope: .commonDictionary,
                domainTags: ["LLM", "議事録", "AI"]
            ),
            Vocabulary(
                projectId: coreProject.id,
                canonicalForm: "EmbeddingGemma 2",
                reading: "エンベディング・ジェマ・ツー",
                aliases: ["EmbeddingGemma2"],
                commonMisrecognitions: ["エンベディングジェマ2", "エンベッディングジェマ"],
                definition: "意味検索・RAGインデックス生成用の標準Embeddingモデル",
                usageFrequency: 5,
                source: .extractedFromDocument,
                approvalStatus: .candidate,
                priorityScope: .projectDictionary,
                domainTags: ["Embedding", "RAG", "検索"]
            )
        ]

        for vocab in defaultVocabs {
            try? database.saveVocabulary(vocab)
        }
        return ([coreProject], defaultVocabs)
    }

    // MARK: - Project CRUD

    @discardableResult
    public func createProject(
        name: String,
        description: String,
        relatedFolderPaths: [String] = [],
        defaultTemplateId: String = "template-standard"
    ) throws -> Project {
        let project = Project(
            name: name,
            description: description,
            relatedFolderPaths: relatedFolderPaths,
            defaultTemplateId: defaultTemplateId
        )
        projects.insert(project, at: 0)
        try database.saveProject(project)
        return project
    }

    public func updateProject(_ project: Project) throws {
        var updated = project
        updated.updatedAt = Date()
        if let idx = projects.firstIndex(where: { $0.id == updated.id }) {
            projects[idx] = updated
        }
        try database.saveProject(updated)
    }

    public func deleteProject(id: UUID) throws {
        projects.removeAll { $0.id == id }
        try database.deleteProject(id: id)
    }

    public func project(for id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    // MARK: - ProjectDocument Associations (1ファイルを複数プロジェクトに関連付け可能)

    public func associateDocument(
        documentId: UUID,
        projectId: UUID,
        relevanceScore: Double = 1.0,
        isSuggestedByAI: Bool = false,
        isApproved: Bool = true
    ) throws {
        if let idx = projectDocuments.firstIndex(where: { $0.documentId == documentId && $0.projectId == projectId }) {
            projectDocuments[idx].relevanceScore = relevanceScore
            projectDocuments[idx].isApproved = isApproved
            try database.saveProjectDocument(projectDocuments[idx])
            return
        }
        let link = ProjectDocument(
            projectId: projectId,
            documentId: documentId,
            relevanceScore: relevanceScore,
            isSuggestedByAI: isSuggestedByAI,
            isApproved: isApproved
        )
        projectDocuments.append(link)
        try database.saveProjectDocument(link)
    }

    public func removeDocumentAssociation(documentId: UUID, projectId: UUID) throws {
        let matches = projectDocuments.filter { $0.documentId == documentId && $0.projectId == projectId }
        for match in matches {
            try database.deleteProjectDocument(id: match.id)
        }
        projectDocuments.removeAll { $0.documentId == documentId && $0.projectId == projectId }
    }

    public func projectIds(forDocument documentId: UUID, approvedOnly: Bool = true) -> [UUID] {
        projectDocuments
            .filter { $0.documentId == documentId && (!approvedOnly || $0.isApproved) }
            .map(\.projectId)
    }

    // MARK: - Vocabulary & 3-Tier Priority Resolution (仕様書 §4.3)

    /// 仕様書 §4.3: 辞書の適用優先順位
    /// 1. 実行時に指定された用語 (`runtimeTerms`)
    /// 2. プロジェクト辞書 (`projectIds` に所属する用語)
    /// 3. 共通辞書 (`projectId == nil` の用語)
    public func activeVocabularies(
        forProjectIds projectIds: [UUID],
        runtimeTerms: [Vocabulary] = []
    ) -> [Vocabulary] {
        var result: [Vocabulary] = []

        // 1. 実行時指定用語
        for var rt in runtimeTerms {
            rt.priorityScope = .runtimeSpecified
            rt.approvalStatus = .approved
            result.append(rt)
        }

        // 2. 対象プロジェクトの辞書
        let projectSet = Set(projectIds)
        for var pv in vocabularies where pv.approvalStatus == .approved {
            if let pid = pv.projectId, projectSet.contains(pid) {
                pv.priorityScope = .projectDictionary
                result.append(pv)
            }
        }

        // 3. 共通辞書
        for var cv in vocabularies where cv.approvalStatus == .approved && cv.projectId == nil {
            cv.priorityScope = .commonDictionary
            result.append(cv)
        }

        return result.sorted {
            if $0.priorityScope != $1.priorityScope {
                return $0.priorityScope < $1.priorityScope
            }
            return $0.usageFrequency > $1.usageFrequency
        }
    }

    /// 経路1: ユーザーによる手動登録
    @discardableResult
    public func addVocabularyManually(
        projectId: UUID?,
        canonicalForm: String,
        reading: String,
        aliases: [String],
        commonMisrecognitions: [String],
        definition: String,
        domainTags: [String] = []
    ) throws -> Vocabulary {
        let vocab = Vocabulary(
            projectId: projectId,
            canonicalForm: canonicalForm,
            reading: reading,
            aliases: aliases,
            commonMisrecognitions: commonMisrecognitions,
            definition: definition,
            usageFrequency: 1,
            source: .manual,
            approvalStatus: .approved,
            priorityScope: projectId != nil ? .projectDictionary : .commonDictionary,
            domainTags: domainTags
        )
        vocabularies.insert(vocab, at: 0)
        try database.saveVocabulary(vocab)
        return vocab
    }

    /// 経路2 & 3: 関連文書または過去の議事録からAIが専門用語候補を抽出（承認待ち `candidate` として登録）
    @discardableResult
    public func extractVocabularyCandidatesWithAI(
        fromText text: String,
        source: VocabularySource,
        projectId: UUID?
    ) async throws -> [Vocabulary] {
        let config = modelManager.resolveConfiguration(project: project(for: projectId))
        let existingSet = Set(vocabularies.map(\.canonicalForm))

        return try await jobManager.enqueueAndRun(
            type: .vocabularyExtraction,
            title: "専門用語候補のAI抽出 (\(source.rawValue))",
            priority: .lowBackground,
            projectId: projectId,
            modelId: config.llmModel.id,
            requiredMemoryMB: 256
        ) {
            let adapter = LocalLLMAdapter(model: config.llmModel)
            let extracted = try await adapter.extractVocabularyCandidates(
                from: text,
                source: source,
                projectId: projectId,
                existingTerms: existingSet
            )
            for item in extracted {
                self.vocabularies.insert(item, at: 0)
                try? self.database.saveVocabulary(item)
            }
            return (extracted, "\(extracted.count)件の用語候補を抽出しました（要承認）")
        }
    }

    /// 経路4: 文字起こしの補正履歴から辞書候補を自動生成（承認待ち `candidate` として登録）
    @discardableResult
    public func generateCandidatesFromCorrectionHistory(
        revisions: [TranscriptRevision],
        projectId: UUID?
    ) throws -> [Vocabulary] {
        let existingCanonical = Set(vocabularies.map(\.canonicalForm))
        var generated: [Vocabulary] = []

        for rev in revisions where !rev.isReverted {
            for span in rev.correctionSpans where !span.correctedFragment.isEmpty && !span.originalFragment.isEmpty {
                guard !existingCanonical.contains(span.correctedFragment) else { continue }
                let candidate = Vocabulary(
                    projectId: projectId,
                    canonicalForm: span.correctedFragment,
                    reading: "",
                    aliases: [],
                    commonMisrecognitions: [span.originalFragment],
                    definition: "文字起こし補正履歴（『\(span.originalFragment)』→『\(span.correctedFragment)』）から生成された候補",
                    usageFrequency: 1,
                    source: .generatedFromCorrectionHistory,
                    approvalStatus: .candidate,
                    priorityScope: projectId != nil ? .projectDictionary : .commonDictionary
                )
                vocabularies.insert(candidate, at: 0)
                try database.saveVocabulary(candidate)
                generated.append(candidate)
            }
        }
        return generated
    }

    public func approveVocabulary(id: UUID) throws {
        guard let idx = vocabularies.firstIndex(where: { $0.id == id }) else { return }
        vocabularies[idx].approvalStatus = .approved
        vocabularies[idx].updatedAt = Date()
        try database.saveVocabulary(vocabularies[idx])
    }

    public func rejectVocabulary(id: UUID) throws {
        guard let idx = vocabularies.firstIndex(where: { $0.id == id }) else { return }
        vocabularies[idx].approvalStatus = .rejected
        vocabularies[idx].updatedAt = Date()
        try database.saveVocabulary(vocabularies[idx])
    }

    public func deleteVocabulary(id: UUID) throws {
        vocabularies.removeAll { $0.id == id }
        try database.deleteVocabulary(id: id)
    }
}
