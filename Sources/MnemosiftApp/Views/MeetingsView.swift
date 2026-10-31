import SwiftUI
import AppKit
import MnemosiftCore

/// 仕様書 §9.4 & §6: 議事録画面
/// - 議事録一覧、検索、Markdown編集、元の文字起こしへの参照移動
/// - TODO・決定事項（担当者・期限が不明な場合は推測しない）
/// - テンプレート変更（4種の標準テンプレート＋カスタムテンプレート作成）
/// - 全体再生成、一部項目のみの再生成、Markdownエクスポート・テキストコピー
public struct MeetingsView: View {
    @Bindable var workspace: AppWorkspaceController
    @State private var filterText: String = ""
    @State private var selectedTemplateId: String = "template-standard"
    @State private var selectedLLMModelId: String = "llm-gemma-4"
    @State private var editableMarkdown: String = ""
    @State private var isShowingCustomTemplateSheet: Bool = false
    @State private var customTemplateName: String = ""
    @State private var customTemplateDesc: String = ""
    @State private var customTemplateSections: String = "会議の概要, 決定事項, TODO・アクションアイテム"

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        HSplitView {
            meetingsListColumn
                .frame(minWidth: 290, maxWidth: 350)

            meetingDetailWorkspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("議事録")
        .sheet(isPresented: $isShowingCustomTemplateSheet) {
            customTemplateSheet
        }
        .onChange(of: workspace.selectedMeetingId) {
            syncSelectedMeetingState()
        }
        .onAppear {
            syncSelectedMeetingState()
        }
    }

    private var filteredMeetings: [Meeting] {
        if filterText.trimmingCharacters(in: .whitespaces).isEmpty {
            return workspace.llmService.meetings
        }
        return workspace.llmService.meetings.filter {
            $0.title.localizedCaseInsensitiveContains(filterText) ||
            $0.markdownContent.localizedCaseInsensitiveContains(filterText)
        }
    }

    private var currentMeeting: Meeting? {
        if let id = workspace.selectedMeetingId {
            return workspace.llmService.meetings.first { $0.id == id }
        }
        return workspace.llmService.meetings.first
    }

    private var meetingsListColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("議事録を検索...", text: $filterText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredMeetings) { meeting in
                        Button {
                            workspace.selectedMeetingId = meeting.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meeting.title)
                                    .font(.subheadline.bold())
                                Text(meeting.overview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                HStack {
                                    Text("決定 \(meeting.decisions.count)")
                                    Text("・")
                                    Text("TODO \(meeting.actionItems.count)")
                                    Spacer()
                                    Text(meeting.llmModelId)
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                currentMeeting?.id == meeting.id ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var meetingDetailWorkspace: some View {
        if let meeting = currentMeeting {
            VStack(alignment: .leading, spacing: 14) {
                meetingHeaderToolbar(meeting: meeting)

                HSplitView {
                    structuredSummaryColumn(meeting: meeting)
                        .frame(minWidth: 340, maxWidth: 440)

                    markdownEditorColumn(meeting: meeting)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(18)
        } else {
            ContentUnavailableView(
                "議事録が選択されていません",
                systemImage: "doc.text",
                description: Text("録音・文字起こし画面から議事録を生成するか、左の一覧から選択してください。")
            )
        }
    }

    private func meetingHeaderToolbar(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.title3.bold())
                    Text("生成モデル: \(meeting.llmModelId) ・ テンプレート: \(workspace.llmService.template(withId: meeting.templateId).name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button("元の文字起こしを参照", systemImage: "waveform") {
                    workspace.jumpToTranscript(from: meeting)
                }
                .controlSize(.small)

                Button("テキストコピー", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(editableMarkdown, forType: .string)
                    workspace.statusBannerMessage = "議事録Markdownをクリップボードにコピーしました"
                }
                .controlSize(.small)

                Button("Markdownエクスポート", systemImage: "square.and.arrow.up") {
                    exportMeetingMarkdown(meeting: meeting)
                }
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                Picker("テンプレート", selection: $selectedTemplateId) {
                    ForEach(workspace.llmService.templates) { tmpl in
                        Text(tmpl.name).tag(tmpl.id)
                    }
                }
                .frame(width: 240)

                Button("＋カスタム定義", systemImage: "plus") {
                    isShowingCustomTemplateSheet = true
                }
                .controlSize(.small)

                Picker("使用LLM", selection: $selectedLLMModelId) {
                    ForEach(workspace.modelManager.models(for: .llm)) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .frame(width: 240)

                Button("全体を再生成", systemImage: "arrow.clockwise") {
                    regenerateFullMeeting(meeting: meeting)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Menu("一部項目のみ再生成", systemImage: "wand.and.stars") {
                    ForEach(MeetingSectionKind.allCases) { sec in
                        Button("『\(sec.rawValue)』のみ再生成") {
                            regeneratePartialSection(meeting: meeting, section: sec)
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func structuredSummaryColumn(meeting: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("決定事項 (\(meeting.decisions.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(meeting.decisions.enumerated()), id: \.offset) { _, dec in
                            Label(dec, systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("TODO・アクションアイテム (\(meeting.actionItems.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        if meeting.actionItems.isEmpty {
                            Text("抽出されたTODOはありません")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(meeting.actionItems) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Button(
                                        item.isCompleted ? "完了済み" : "未完了",
                                        systemImage: item.isCompleted ? "checkmark.square.fill" : "square"
                                    ) {
                                        try? workspace.llmService.toggleActionItemCompletion(
                                            meetingId: meeting.id,
                                            actionItemId: item.id
                                        )
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.plain)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.caption.bold())
                                            .strikethrough(item.isCompleted)
                                        HStack(spacing: 8) {
                                            Text("担当: \(item.assignee ?? "未定（推測なし）")")
                                            Text("期限: \(item.dueDateText ?? "未定（推測なし）")")
                                            if let segId = item.sourceSegmentId {
                                                Button("発言箇所へ", systemImage: "arrow.turn.down.right") {
                                                    workspace.jumpToTranscript(from: meeting, highlightSegmentId: segId)
                                                }
                                                .controlSize(.mini)
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("未解決事項") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(meeting.unresolvedIssues.enumerated()), id: \.offset) { _, issue in
                            Text("・\(issue)")
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                if !meeting.contextNotes.isEmpty {
                    GroupBox("プロジェクト文脈・整合性メモ") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(meeting.contextNotes.enumerated()), id: \.offset) { _, note in
                                Text("・\(note)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }
            }
            .padding(.trailing, 8)
        }
    }

    private func markdownEditorColumn(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Markdown エディタ（直接編集・保存可能）")
                    .font(.subheadline.bold())
                Spacer()
                Button("編集内容を保存＆インデックス更新", systemImage: "checkmark.circle") {
                    try? workspace.llmService.updateMeetingMarkdown(meetingId: meeting.id, markdown: editableMarkdown)
                    workspace.statusBannerMessage = "議事録の変更を保存し検索インデックスを更新しました"
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }

            TextEditor(text: $editableMarkdown)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.leading, 8)
    }

    private var customTemplateSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ユーザー定義議事録テンプレートの追加")
                .font(.headline)

            TextField("テンプレート名（例：1on1ミーティング）", text: $customTemplateName)
                .textFieldStyle(.roundedBorder)
            TextField("説明", text: $customTemplateDesc)
                .textFieldStyle(.roundedBorder)
            TextField("セクション一覧（カンマ区切り）", text: $customTemplateSections)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("キャンセル") {
                    isShowingCustomTemplateSheet = false
                }
                Button("追加") {
                    let sections = customTemplateSections
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if let created = try? workspace.llmService.addCustomTemplate(
                        name: customTemplateName.isEmpty ? "カスタム議事録" : customTemplateName,
                        description: customTemplateDesc,
                        instructions: "指定セクションに沿って簡潔に整理する",
                        sections: sections
                    ) {
                        selectedTemplateId = created.id
                    }
                    isShowingCustomTemplateSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func syncSelectedMeetingState() {
        guard let meeting = currentMeeting else { return }
        editableMarkdown = meeting.markdownContent
        selectedTemplateId = meeting.templateId
        selectedLLMModelId = meeting.llmModelId
    }

    private func regenerateFullMeeting(meeting: Meeting) {
        guard let tid = meeting.transcriptId,
              let tr = workspace.sttService.transcripts.first(where: { $0.id == tid }) else { return }
        let segments = workspace.sttService.segments(for: tid)
        let proj = workspace.projectService.project(for: meeting.projectIds.first)
        let vocabs = workspace.projectService.activeVocabularies(forProjectIds: meeting.projectIds)
        let llmOverride = workspace.modelManager.model(withId: selectedLLMModelId)

        Task {
            if let updated = try? await workspace.llmService.generateMeetingMinutes(
                from: tr,
                segments: segments,
                templateId: selectedTemplateId,
                project: proj,
                vocabularies: vocabs,
                relatedDocuments: workspace.documentService.documents,
                llmModelOverride: llmOverride
            ) {
                editableMarkdown = updated.markdownContent
            }
        }
    }

    private func regeneratePartialSection(meeting: Meeting, section: MeetingSectionKind) {
        let segments = meeting.transcriptId.map { workspace.sttService.segments(for: $0) } ?? []
        let vocabs = workspace.projectService.activeVocabularies(forProjectIds: meeting.projectIds)
        Task {
            if let updated = try? await workspace.llmService.regenerateSection(
                meetingId: meeting.id,
                section: section,
                segments: segments,
                vocabularies: vocabs
            ) {
                editableMarkdown = updated.markdownContent
                workspace.statusBannerMessage = "セクション『\(section.rawValue)』を再生成しました"
            }
        }
    }

    private func exportMeetingMarkdown(meeting: Meeting) {
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(meeting.title).md")
        try? workspace.llmService.exportMeetingToMarkdownFile(meeting: meeting, destinationURL: exportURL)
        workspace.statusBannerMessage = "Markdownファイルを書き出しました: \(exportURL.path)"
    }
}
