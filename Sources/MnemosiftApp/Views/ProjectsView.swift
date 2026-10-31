import SwiftUI
import MnemosiftCore

/// 仕様書 §9.6 & §4: プロジェクト管理・専門用語辞書画面
/// - プロジェクト作成・編集、未所属データの関連付け（複数プロジェクト対応）
/// - プロジェクト専門用語辞書（手動登録、関連文書/議事録からのAI抽出、補正履歴からの候補生成、候補の承認・却下）
/// - プロジェクト内から録音・ファイル・AI検索を開始するクイック導線（対象プロジェクトを初期選択）
public struct ProjectsView: View {
    @Bindable var workspace: AppWorkspaceController

    @State private var newProjectName: String = ""
    @State private var newProjectDesc: String = ""
    @State private var newTermCanonical: String = ""
    @State private var newTermReading: String = ""
    @State private var newTermMisread: String = ""
    @State private var newTermDefinition: String = ""

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        HSplitView {
            leftProjectsListColumn
                .frame(minWidth: 290, maxWidth: 350)

            rightProjectDetailAndDictionaryColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("プロジェクト・専門用語辞書")
    }

    private var activeProject: Project? {
        if let pid = workspace.selectedProjectId {
            return workspace.projectService.project(for: pid)
        }
        return workspace.projectService.projects.first
    }

    private var leftProjectsListColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("新規プロジェクト作成")
                    .font(.headline)
                TextField("プロジェクト名", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                TextField("説明・文脈メモ", text: $newProjectDesc)
                    .textFieldStyle(.roundedBorder)
                Button("プロジェクトを追加", systemImage: "plus.circle.fill") {
                    guard !newProjectName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    if let created = try? workspace.projectService.createProject(
                        name: newProjectName,
                        description: newProjectDesc
                    ) {
                        workspace.selectedProjectId = created.id
                        newProjectName = ""
                        newProjectDesc = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            Text("プロジェクト一覧 (\(workspace.projectService.projects.count))")
                .font(.subheadline.bold())

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(workspace.projectService.projects) { project in
                        Button {
                            workspace.selectedProjectId = project.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                    .font(.subheadline.bold())
                                Text(project.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                activeProject?.id == project.id ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.08),
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

    private var rightProjectDetailAndDictionaryColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let project = activeProject {
                    projectOverviewHeader(project)
                    vocabularyManagementCard(project: project)
                    projectDataAssociationCard(project: project)
                }
            }
            .padding(20)
        }
    }

    private func projectOverviewHeader(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.title2.bold())
                    Text(project.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                // 仕様書 §9.6: プロジェクト内から操作を開始した場合は対象プロジェクトを初期選択する
                HStack(spacing: 8) {
                    Button("このPJで録音開始", systemImage: "waveform.badge.mic") {
                        workspace.navigateFromProject(project.id, to: .recording)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("このPJをAI検索", systemImage: "sparkle.magnifyingglass") {
                        workspace.navigateFromProject(project.id, to: .searchChat)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func vocabularyManagementCard(project: Project) -> some View {
        let projectVocabs = workspace.projectService.vocabularies.filter {
            $0.projectId == project.id || $0.projectId == nil
        }

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("専門用語辞書（適用優先順位: 1.実行時指定 → 2.プロジェクト辞書 → 3.共通辞書）")
                        .font(.headline)
                    Text("AI抽出用語・補正履歴からの生成用語は『候補（承認待ち）』として登録され、承認後にSTT補正へ適用されます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button("補正履歴から候補生成", systemImage: "clock.arrow.circlepath") {
                    _ = try? workspace.projectService.generateCandidatesFromCorrectionHistory(
                        revisions: workspace.correctionService.revisions,
                        projectId: project.id
                    )
                }
                .controlSize(.small)

                Button("過去議事録からAI抽出", systemImage: "doc.text.magnifyingglass") {
                    let combinedMinutes = workspace.llmService.meetings.map(\.markdownContent).joined(separator: "\n")
                    Task {
                        _ = try? await workspace.projectService.extractVocabularyCandidatesWithAI(
                            fromText: combinedMinutes,
                            source: .extractedFromMeeting,
                            projectId: project.id
                        )
                    }
                }
                .controlSize(.small)
            }

            // 手動登録フォーム
            HStack(spacing: 8) {
                TextField("正式表記 (例: WhisperKit)", text: $newTermCanonical)
                    .textFieldStyle(.roundedBorder)
                TextField("読み方 (例: ウィスパーキット)", text: $newTermReading)
                    .textFieldStyle(.roundedBorder)
                TextField("よくある誤認識 (カンマ区切り)", text: $newTermMisread)
                    .textFieldStyle(.roundedBorder)
                TextField("説明", text: $newTermDefinition)
                    .textFieldStyle(.roundedBorder)
                Button("手動登録", systemImage: "plus") {
                    guard !newTermCanonical.isEmpty else { return }
                    let misreads = newTermMisread
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    _ = try? workspace.projectService.addVocabularyManually(
                        projectId: project.id,
                        canonicalForm: newTermCanonical,
                        reading: newTermReading,
                        aliases: [],
                        commonMisrecognitions: misreads,
                        definition: newTermDefinition
                    )
                    newTermCanonical = ""
                    newTermReading = ""
                    newTermMisread = ""
                    newTermDefinition = ""
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            ForEach(projectVocabs) { vocab in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(vocab.canonicalForm)
                                .font(.subheadline.bold())
                            if !vocab.reading.isEmpty {
                                Text("(\(vocab.reading))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(vocab.priorityScope.label)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.15), in: Capsule())
                            Text(vocab.approvalStatus.rawValue)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    vocab.approvalStatus == .approved ? Color.green.opacity(0.2) : Color.orange.opacity(0.2),
                                    in: Capsule()
                                )
                            Text("登録元: \(vocab.source.rawValue)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if !vocab.commonMisrecognitions.isEmpty {
                            Text("誤認識パターン: \(vocab.commonMisrecognitions.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(vocab.definition)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if vocab.approvalStatus == .candidate {
                        HStack(spacing: 6) {
                            Button("承認", systemImage: "checkmark") {
                                try? workspace.projectService.approveVocabulary(id: vocab.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .controlSize(.mini)

                            Button("却下", systemImage: "xmark") {
                                try? workspace.projectService.rejectVocabulary(id: vocab.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func projectDataAssociationCard(project: Project) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プロジェクト関連データ（未所属のデータも後から関連付け・複数プロジェクト共有可能）")
                .font(.headline)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ファイル (\(workspace.documentService.documents.count)件)")
                        .font(.subheadline.bold())
                    ForEach(workspace.documentService.documents) { doc in
                        let linked = workspace.projectService.projectIds(forDocument: doc.id).contains(project.id)
                        HStack {
                            Text(doc.fileName)
                                .font(.caption)
                            Spacer()
                            Button(linked ? "関連付け解除" : "このPJに追加") {
                                if linked {
                                    try? workspace.projectService.removeDocumentAssociation(documentId: doc.id, projectId: project.id)
                                } else {
                                    try? workspace.projectService.associateDocument(documentId: doc.id, projectId: project.id)
                                }
                            }
                            .controlSize(.mini)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("会議録音・議事録 (\(workspace.llmService.meetings.count)件)")
                        .font(.subheadline.bold())
                    ForEach(workspace.llmService.meetings) { meeting in
                        HStack {
                            Text(meeting.title)
                                .font(.caption)
                            Spacer()
                            Button("議事録を開く") {
                                workspace.selectedMeetingId = meeting.id
                                workspace.selectedSection = .meetings
                            }
                            .controlSize(.mini)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
