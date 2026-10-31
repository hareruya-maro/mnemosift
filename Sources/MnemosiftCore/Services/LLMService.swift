import Foundation
import Observation

/// 仕様書 §6: 議事録生成・テンプレート管理サービス
/// - 4種の標準テンプレート＋ユーザー定義テンプレートに対応
/// - プロジェクト文脈（過去の議事録・仕様書・専門用語辞書・過去決定事項）の参照と最新発言優先ルール
/// - Markdown編集・全体再生成・一部項目のみの再生成・Markdownエクスポート
@Observable
@MainActor
public final class LLMService {
    private let database: LocalDatabase
    private let modelManager: ModelManager
    private let jobManager: JobManager
    private let embeddingService: EmbeddingService

    public private(set) var meetings: [Meeting] = []
    public private(set) var templates: [MeetingTemplate] = []

    public init(
        database: LocalDatabase,
        modelManager: ModelManager,
        jobManager: JobManager,
        embeddingService: EmbeddingService
    ) {
        self.database = database
        self.modelManager = modelManager
        self.jobManager = jobManager
        self.embeddingService = embeddingService

        self.meetings = (try? database.loadMeetings()) ?? []
        let customTemplates = (try? database.loadMeetingTemplates()) ?? []
        var merged = MeetingTemplate.builtInTemplates
        for custom in customTemplates where !merged.contains(where: { $0.id == custom.id }) {
            merged.append(custom)
        }
        self.templates = merged
    }

    public func template(withId id: String) -> MeetingTemplate {
        templates.first { $0.id == id } ?? MeetingTemplate.builtInTemplates[0]
    }

    @discardableResult
    public func addCustomTemplate(
        name: String,
        description: String,
        instructions: String,
        sections: [String]
    ) throws -> MeetingTemplate {
        let custom = MeetingTemplate(
            id: "template-custom-\(UUID().uuidString.prefix(8))",
            name: name,
            type: .custom,
            description: description,
            instructions: instructions,
            sections: sections.isEmpty ? ["会議の概要", "決定事項", "TODO・アクションアイテム"] : sections,
            isBuiltIn: false
        )
        templates.append(custom)
        try database.saveMeetingTemplate(custom)
        return custom
    }

    /// 文字起こしから議事録を生成する
    @discardableResult
    public func generateMeetingMinutes(
        from transcript: Transcript,
        segments: [TranscriptSegment],
        templateId: String,
        project: Project?,
        vocabularies: [Vocabulary],
        relatedDocuments: [Document],
        llmModelOverride: AIModel? = nil
    ) async throws -> Meeting {
        let resolved = modelManager.resolveConfiguration(project: project)
        let activeLLM = llmModelOverride ?? resolved.llmModel
        let activeTemplate = template(withId: templateId)
        let pastMeetings = meetings.filter { m in
            guard let pid = project?.id else { return false }
            return m.projectIds.contains(pid) && m.transcriptId != transcript.id
        }

        return try await jobManager.enqueueAndRun(
            type: .meetingMinutesGeneration,
            title: "議事録生成『\(transcript.title)』(\(activeTemplate.name))",
            priority: .normal,
            projectId: project?.id,
            modelId: activeLLM.id,
            requiredMemoryMB: activeLLM.requiredMemoryMB
        ) {
            let adapter = LocalLLMAdapter(model: activeLLM)
            let output = try await adapter.generateMeetingMinutes(
                title: transcript.title,
                segments: segments,
                template: activeTemplate,
                project: project,
                vocabularies: vocabularies,
                pastMeetings: pastMeetings,
                relatedDocuments: relatedDocuments
            )

            let meeting = Meeting(
                title: transcript.title,
                recordingId: transcript.recordingId,
                transcriptId: transcript.id,
                projectIds: transcript.projectIds,
                templateId: activeTemplate.id,
                llmModelId: activeLLM.id,
                overview: output.overview,
                agendaItems: output.agendaItems,
                discussionNotes: output.discussionNotes,
                decisions: output.decisions,
                actionItems: output.actionItems,
                unresolvedIssues: output.unresolvedIssues,
                markdownContent: output.markdownContent,
                contextNotes: output.contextVerificationNotes
            )

            if let existingIdx = self.meetings.firstIndex(where: { $0.transcriptId == transcript.id }) {
                var replaced = meeting
                replaced.id = self.meetings[existingIdx].id
                self.meetings[existingIdx] = replaced
                try self.database.saveMeeting(replaced)
                try self.embeddingService.indexMeeting(replaced)
                return (replaced, "議事録を再生成し保存しました")
            } else {
                self.meetings.insert(meeting, at: 0)
                try self.database.saveMeeting(meeting)
                try self.embeddingService.indexMeeting(meeting)
                return (meeting, "決定事項\(meeting.decisions.count)件・TODO\(meeting.actionItems.count)件を抽出しました")
            }
        }
    }

    /// 仕様書 §6.4: 一部項目（セクション）のみの再生成
    @discardableResult
    public func regenerateSection(
        meetingId: UUID,
        section: MeetingSectionKind,
        segments: [TranscriptSegment],
        vocabularies: [Vocabulary]
    ) async throws -> Meeting {
        guard let idx = meetings.firstIndex(where: { $0.id == meetingId }) else {
            throw NSError(domain: "LLMService", code: 404, userInfo: [NSLocalizedDescriptionKey: "対象の議事録が見つかりません"])
        }
        let current = meetings[idx]
        let llmModel = modelManager.model(withId: current.llmModelId) ?? modelManager.models(for: .llm).first!
        let adapter = LocalLLMAdapter(model: llmModel)

        let updated = try await adapter.regenerateSection(
            section: section,
            existingMeeting: current,
            segments: segments,
            vocabularies: vocabularies
        )
        meetings[idx] = updated
        try database.saveMeeting(updated)
        try embeddingService.indexMeeting(updated)
        return updated
    }

    public func updateMeetingMarkdown(meetingId: UUID, markdown: String) throws {
        guard let idx = meetings.firstIndex(where: { $0.id == meetingId }) else { return }
        meetings[idx].markdownContent = markdown
        meetings[idx].updatedAt = Date()
        try database.saveMeeting(meetings[idx])
        try embeddingService.indexMeeting(meetings[idx])
    }

    public func toggleActionItemCompletion(meetingId: UUID, actionItemId: UUID) throws {
        guard let idx = meetings.firstIndex(where: { $0.id == meetingId }),
              let itemIdx = meetings[idx].actionItems.firstIndex(where: { $0.id == actionItemId }) else { return }
        meetings[idx].actionItems[itemIdx].isCompleted.toggle()
        meetings[idx].updatedAt = Date()
        try database.saveMeeting(meetings[idx])
    }

    public func exportMeetingToMarkdownFile(meeting: Meeting, destinationURL: URL) throws {
        try meeting.markdownContent.write(to: destinationURL, atomically: true, encoding: .utf8)
    }
}
