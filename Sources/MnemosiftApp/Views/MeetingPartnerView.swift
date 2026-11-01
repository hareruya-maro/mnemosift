import SwiftUI
import AppKit
import MnemosiftCore

/// 「会議のAIパートナー」メイン画面（2カラム集中型レイアウト）
/// - 左カラム: 録音コントロール ＋ リアルタイム文字起こし（⇄ 完成議事録エディタ切替）※過去リストは開閉式
/// - 右カラム上段: リアルタイム議論要約（現在の論点・決定事項・TODO・要点）
/// - 右カラム下段: 会話に連動した関連資料・過去議事録・用語の自動提案 ＆ その場インラインプレビュー
public struct MeetingPartnerView: View {
    @Bindable var workspace: AppWorkspaceController

    public enum LeftColumnTab: String, CaseIterable, Identifiable {
        case liveTranscript = "💬 リアルタイム文字起こし"
        case finalizedMinutes = "📝 議事録・Markdown"
        public var id: String { rawValue }
    }

    @State private var leftTab: LeftColumnTab = .liveTranscript
    @State private var sessionTitleInput: String = ""
    @State private var selectedAudioSource: AudioSourceType = .microphoneAndSystem
    @State private var selectedCorrectionMode: RealtimeCorrectionMode = .fastAI
    @State private var showRawDiffInline: Bool = false
    @State private var speakerInput: String = "佐藤"
    @State private var simulatedUtteranceInput: String = "ネモシフトの検索にはエフティーエスファイブとエンベディングジェマ2を組み合わせる方針で決定します。"
    @State private var selectedTemplateId: String = "template-standard"
    @State private var editableMinutesMarkdown: String = ""

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        HStack(spacing: 0) {
            // 開閉式の過去会議リストドロワー（普段は閉じて2カラムに集中）
            if workspace.isShowingPastSessionsDrawer {
                pastSessionsDrawer
                    .frame(width: 260)
                Divider()
            }

            // メインの2カラム集中型スプリットビュー
            HSplitView {
                leftTranscriptionAndMinutesColumn
                    .frame(minWidth: 460, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

                rightPartnerCopilotColumn
                    .frame(minWidth: 420, idealWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            let activeProject = workspace.projectService.project(for: workspace.selectedProjectId)
            let resolved = workspace.modelManager.resolveConfiguration(project: activeProject)
            selectedCorrectionMode = resolved.correctionMode
            workspace.refreshMeetingPartnerState()
            syncMinutesMarkdown()
        }
        .onChange(of: workspace.activeTranscriptId) {
            workspace.refreshMeetingPartnerState()
            syncMinutesMarkdown()
        }
    }

    // MARK: - Collapsible Past Sessions Drawer

    private var pastSessionsDrawer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("過去の会議一覧")
                    .font(.subheadline.bold())
                Spacer()
                Button("新規会議", systemImage: "plus.circle.fill") {
                    startNewRecordingSession()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(workspace.sttService.transcripts) { tr in
                        let isSelected = currentTranscript?.id == tr.id
                        Button {
                            workspace.activeTranscriptId = tr.id
                            if let matchedMeeting = workspace.llmService.meetings.first(where: { $0.transcriptId == tr.id }) {
                                workspace.selectedMeetingId = matchedMeeting.id
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tr.title)
                                    .font(.caption.bold())
                                    .lineLimit(2)
                                Text(tr.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isSelected ? Color.blue.opacity(0.16) : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }

    // MARK: - Left Column: Recording Bar + Live Transcription / Minutes

    private var leftTranscriptionAndMinutesColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            recordingCompactHeaderBar

            HStack {
                Picker("表示モード", selection: $leftTab) {
                    ForEach(LeftColumnTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)

                Spacer()

                if leftTab == .liveTranscript {
                    Toggle("STT原文との比較を表示", isOn: $showRawDiffInline)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.caption)
                } else if let meeting = currentMeeting {
                    Button("コピー", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(editableMinutesMarkdown, forType: .string)
                        workspace.statusBannerMessage = "議事録Markdownをコピーしました"
                    }
                    .controlSize(.small)

                    Button("Markdown保存", systemImage: "square.and.arrow.up") {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(meeting.title).md")
                        try? workspace.llmService.exportMeetingToMarkdownFile(meeting: meeting, destinationURL: url)
                        workspace.statusBannerMessage = "書き出し完了: \(url.path)"
                    }
                    .controlSize(.small)
                }
            }

            if leftTab == .liveTranscript {
                liveTranscriptStreamView
                quickUtteranceSimulatorFooter
            } else {
                inlineMinutesEditorView
            }
        }
        .padding(16)
    }

    private var recordingCompactHeaderBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        workspace.isShowingPastSessionsDrawer.toggle()
                    }
                } label: {
                    Label(
                        "履歴 (\(workspace.sttService.transcripts.count))",
                        systemImage: workspace.isShowingPastSessionsDrawer ? "sidebar.left" : "clock.arrow.circlepath"
                    )
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                if let activeTr = currentTranscript {
                    Text(activeTr.title)
                        .font(.headline)
                        .lineLimit(1)
                } else {
                    TextField("会議タイトルを入力...", text: $sessionTitleInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }

                Spacer()

                // 録音ボタン群
                if workspace.recordingService.state == .idle || workspace.recordingService.state == .completed {
                    Button("録音開始", systemImage: "record.circle.fill") {
                        startNewRecordingSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)

                    Button("音声ファイル取込", systemImage: "waveform.badge.plus") {
                        importAudioAndTranscribe()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(workspace.recordingService.state == .recording ? .red : .orange)
                            .frame(width: 8, height: 8)
                        Text(LocalLLMAdapter.formatTimestamp(workspace.recordingService.elapsedSeconds))
                            .font(.system(.callout, design: .monospaced).bold())
                    }

                    if workspace.recordingService.state == .recording {
                        Button("一時停止", systemImage: "pause.fill") {
                            workspace.recordingService.pauseRecording()
                        }
                        .controlSize(.small)
                    } else {
                        Button("再開", systemImage: "play.fill") {
                            workspace.recordingService.resumeRecording()
                        }
                        .controlSize(.small)
                    }

                    Button("停止", systemImage: "stop.fill") {
                        stopRecordingAndRefresh()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                Picker("音声入力", selection: $selectedAudioSource) {
                    Text("マイク＋システム音声").tag(AudioSourceType.microphoneAndSystem)
                    Text("マイクのみ").tag(AudioSourceType.microphone)
                    Text("システム音声のみ").tag(AudioSourceType.systemAudio)
                }
                .controlSize(.small)
                .frame(width: 210)

                Picker("AI補正", selection: $selectedCorrectionMode) {
                    ForEach(RealtimeCorrectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .controlSize(.small)
                .frame(width: 220)

                Spacer()

                // ミニ波形インジケーター
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(workspace.recordingService.waveformSamples.suffix(16).enumerated()), id: \.offset) { _, level in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(workspace.recordingService.state == .recording ? .red : .secondary.opacity(0.3))
                            .frame(width: 3, height: max(4, CGFloat(level) * 18))
                    }
                }
                .frame(height: 20)
            }

            // システム音声（画面収録）権限チェックバナー
            if (selectedAudioSource == .systemAudio || selectedAudioSource == .microphoneAndSystem) && !LiveAudioStreamEngine.checkSystemAudioScreenCaptureAccess() {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("YouTubeやWeb会議の音声を文字起こしするには『画面収録』の許可が必要です。")
                        .font(.caption)
                    Spacer()
                    Button("システム設定を開く") {
                        openSystemSettingsForScreenCapture()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var liveTranscriptStreamView: some View {
        let segments = currentTranscript.map { workspace.sttService.segments(for: $0.id) } ?? []
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let provisional = workspace.sttService.currentProvisionalSegment {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("[\(provisional.speakerLabel)] \(provisional.rawText)")
                            .font(.callout.italic())
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                }

                if segments.isEmpty {
                    ContentUnavailableView(
                        "発話がまだありません",
                        systemImage: "waveform.and.mic",
                        description: Text("「録音開始」または下のテスト発話バーから発言を追加すると、右側にリアルタイム要約と関連資料が自動提案されます。")
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(segments) { segment in
                        transcriptUtteranceBubble(segment)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func transcriptUtteranceBubble(_ segment: TranscriptSegment) -> some View {
        let isHighlighted = workspace.highlightedSegmentId == segment.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(segment.speakerLabel)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15), in: Capsule())

                Text(LocalLLMAdapter.formatTimestamp(segment.startTimeSeconds))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                if segment.hasCorrection {
                    Label("用語・文脈補正済", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }

                Spacer()

                if segment.hasCorrection, let tr = currentTranscript {
                    Button("原文に戻す", systemImage: "arrow.uturn.backward") {
                        try? workspace.sttService.revertCorrection(transcriptId: tr.id, segmentId: segment.id)
                        workspace.refreshMeetingPartnerState()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                }
            }

            Text(segment.correctedText)
                .font(.body)
                .textSelection(.enabled)

            if showRawDiffInline && segment.hasCorrection {
                Text("STT原文: \(segment.rawText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(
            isHighlighted ? Color.yellow.opacity(0.18) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private var quickUtteranceSimulatorFooter: some View {
        HStack(spacing: 8) {
            TextField("話者", text: $speakerInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .controlSize(.small)

            TextField("発話をシミュレート入力（リアルタイム要約・資料提案の動作確認用）...", text: $simulatedUtteranceInput)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit {
                    appendRealtimeUtterance()
                }

            Button("発話を追加", systemImage: "plus.bubble.fill") {
                appendRealtimeUtterance()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private var inlineMinutesEditorView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("議事録テンプレート", selection: $selectedTemplateId) {
                    ForEach(workspace.llmService.templates) { tmpl in
                        Text(tmpl.name).tag(tmpl.id)
                    }
                }
                .controlSize(.small)
                .frame(width: 240)

                Button("このテンプレートで再生成", systemImage: "sparkles") {
                    generateOrUpdateFullMinutes()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                if let meeting = currentMeeting {
                    Button("編集を保存", systemImage: "checkmark.circle") {
                        try? workspace.llmService.updateMeetingMarkdown(meetingId: meeting.id, markdown: editableMinutesMarkdown)
                        workspace.statusBannerMessage = "議事録を保存しました"
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }

            TextEditor(text: $editableMinutesMarkdown)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Right Column: Upper = Live Discussion Summary / Lower = Related Docs Auto-Suggest & In-Place Preview

    private var rightPartnerCopilotColumn: some View {
        VSplitView {
            upperLiveSummaryPane
                .frame(minHeight: 240, idealHeight: 330, maxHeight: .infinity)

            lowerRelatedDocumentsPane
                .frame(minHeight: 260, idealHeight: 370, maxHeight: .infinity)
        }
    }

    private var upperLiveSummaryPane: some View {
        let digest = workspace.meetingPartnerService.liveDigest

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("リアルタイム議論要約", systemImage: "brain.head.profile")
                    .font(.headline)
                    .foregroundStyle(.purple)
                Spacer()
                Text("発話 \(digest.utteranceCount)件から自動整理")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("議事録として確定", systemImage: "doc.badge.checkmark") {
                    generateOrUpdateFullMinutes()
                    leftTab = .finalizedMinutes
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
            }

            // 現在の論点バナー
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "target")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("現在の論点・テーマ")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    Text(digest.currentTopic)
                        .font(.subheadline.bold())
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !digest.decisions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("✅ 決定事項 (\(digest.decisions.count))")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                            ForEach(Array(digest.decisions.enumerated()), id: \.offset) { _, dec in
                                Text("・\(dec)")
                                    .font(.caption)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if !digest.actionItems.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("📌 TODO・アクションアイテム (\(digest.actionItems.count))")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                            ForEach(digest.actionItems) { item in
                                Text("・\(item.title) （担当: \(item.assignee ?? "未定") / 期限: \(item.dueDateText ?? "未定")）")
                                    .font(.caption)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if !digest.keyPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("💡 議論のポイント")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            ForEach(Array(digest.keyPoints.enumerated()), id: \.offset) { _, pt in
                                Text("・\(pt)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private var lowerRelatedDocumentsPane: some View {
        let suggestions = workspace.meetingPartnerService.relatedSuggestions

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("会話に関連する資料・過去議事録の自動提案", systemImage: "Sparkles.rectangle.stack.fill")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Spacer()
                if workspace.meetingPartnerService.previewingSuggestion != nil {
                    Button("提案一覧に戻る", systemImage: "chevron.left") {
                        workspace.meetingPartnerService.previewingSuggestion = nil
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("\(suggestions.count)件ヒット")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // クリック時は画面遷移せずその場でインラインプレビューを表示！
            if let preview = workspace.meetingPartnerService.previewingSuggestion {
                inlineResourcePreviewCard(preview)
            } else if suggestions.isEmpty {
                ContentUnavailableView(
                    "関連資料を探しています",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("会話が進むと、発言キーワードや文脈に関連するローカル資料・過去の議事録がここに自動表示されます。")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(suggestions) { item in
                            Button {
                                workspace.meetingPartnerService.previewingSuggestion = item
                            } label: {
                                suggestedResourceRow(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    private func suggestedResourceRow(_ item: RelatedResourceSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: item.kind.systemImage)
                    .foregroundStyle(.blue)
                Text(item.kind.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15), in: Capsule())
                Text(item.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                Label("すぐ見る", systemImage: "eye.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(.blue)
            }

            Text(item.matchedReason)
                .font(.caption2)
                .foregroundStyle(.blue)

            Text(item.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func inlineResourcePreviewCard(_ item: RelatedResourceSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.kind.rawValue)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.18), in: Capsule())
                        Text(item.title)
                            .font(.subheadline.bold())
                    }
                    Text(item.matchedReason)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                Spacer()
                if item.kind == .document {
                    Button("資料管理で開く", systemImage: "arrow.up.right.square") {
                        workspace.selectedDocumentId = item.sourceId
                        workspace.activeMode = .knowledgeHub
                    }
                    .controlSize(.mini)
                }
            }

            Divider()

            ScrollView {
                Text(item.fullPreviewText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers & Actions

    private var currentTranscript: Transcript? {
        if let id = workspace.activeTranscriptId {
            return workspace.sttService.transcripts.first { $0.id == id }
        }
        return workspace.sttService.transcripts.first
    }

    private var currentMeeting: Meeting? {
        if let tr = currentTranscript,
           let m = workspace.llmService.meetings.first(where: { $0.transcriptId == tr.id }) {
            return m
        }
        if let mid = workspace.selectedMeetingId {
            return workspace.llmService.meetings.first { $0.id == mid }
        }
        return workspace.llmService.meetings.first
    }

    private func syncMinutesMarkdown() {
        if let m = currentMeeting {
            editableMinutesMarkdown = m.markdownContent
            selectedTemplateId = m.templateId
        }
    }

    private func startNewRecordingSession() {
        let pids = workspace.selectedProjectId.map { [$0] } ?? []
        let activeProject = workspace.projectService.project(for: workspace.selectedProjectId)
        let config = workspace.modelManager.resolveConfiguration(project: activeProject)
        let vocabs = workspace.projectService.activeVocabularies(forProjectIds: pids)
        let hotwords = vocabs.filter { $0.approvalStatus == .approved }.map(\.canonicalForm)

        Task {
            // 権限要求
            let (micGranted, speechGranted) = await LiveAudioStreamEngine.requestPermissions()
            if !micGranted && (selectedAudioSource == .microphone || selectedAudioSource == .microphoneAndSystem) {
                workspace.statusBannerMessage = "⚠️ マイクの利用が許可されていません（システム設定でMnemosiftを許可してください）"
            }
            if !speechGranted {
                workspace.statusBannerMessage = "⚠️ オンデバイス音声認識の利用が許可されていません（システム設定で許可してください）"
            }

            if selectedAudioSource == .systemAudio || selectedAudioSource == .microphoneAndSystem {
                if !LiveAudioStreamEngine.checkSystemAudioScreenCaptureAccess() {
                    LiveAudioStreamEngine.requestSystemAudioScreenCaptureAccess()
                    workspace.statusBannerMessage = "⚠️ YouTubeやPC音声を文字起こしするには『画面収録』の許可が必要です"
                }
            }

            do {
                let rec = try workspace.recordingService.startRecording(
                    title: sessionTitleInput,
                    source: selectedAudioSource,
                    projectIds: pids,
                    hotwords: hotwords
                )

                let tr = try workspace.sttService.createTranscriptSession(
                    for: rec,
                    sttModelId: config.realtimeSTTModel.id,
                    correctionMode: selectedCorrectionMode
                )

                workspace.activeTranscriptId = tr.id
                sessionTitleInput = ""
                leftTab = .liveTranscript
                workspace.refreshMeetingPartnerState()
            } catch {
                workspace.statusBannerMessage = "録音開始エラー: \(error.localizedDescription)"
            }
        }
    }

    private func openSystemSettingsForScreenCapture() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSystemSettingsForMicrophone() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func stopRecordingAndRefresh() {
        _ = try? workspace.recordingService.stopRecording()
        if let tr = currentTranscript {
            let segs = workspace.sttService.segments(for: tr.id)
            try? workspace.embeddingService.indexTranscript(tr, segments: segs)
            workspace.refreshMeetingPartnerState()
        }
    }

    private func appendRealtimeUtterance() {
        let targetTranscript: Transcript
        if let existing = currentTranscript {
            targetTranscript = existing
        } else {
            startNewRecordingSession()
            guard let created = currentTranscript else { return }
            targetTranscript = created
        }

        let activeProject = workspace.projectService.project(for: workspace.selectedProjectId)
        let config = workspace.modelManager.resolveConfiguration(project: activeProject)
        let vocabs = workspace.projectService.activeVocabularies(forProjectIds: targetTranscript.projectIds)
        let existingSegs = workspace.sttService.segments(for: targetTranscript.id)
        let lastEnd = existingSegs.last?.endTimeSeconds ?? 0.0

        Task {
            _ = try? await workspace.sttService.processRealtimeUtteranceChunk(
                transcriptId: targetTranscript.id,
                rawUtteranceText: simulatedUtteranceInput,
                speakerLabel: speakerInput,
                startTimeSeconds: lastEnd,
                endTimeSeconds: lastEnd + 5.0,
                sttModel: config.realtimeSTTModel,
                correctionMode: selectedCorrectionMode,
                vocabularies: vocabs,
                judgeModel: config.judgeModel,
                llmModel: config.llmModel,
                confidenceThreshold: config.judgeConfidenceThreshold
            )
            let updatedSegs = workspace.sttService.segments(for: targetTranscript.id)
            try? workspace.embeddingService.indexTranscript(targetTranscript, segments: updatedSegs)
            workspace.refreshMeetingPartnerState()
        }
    }

    private func importAudioAndTranscribe() {
        let pids = workspace.selectedProjectId.map { [$0] } ?? []
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("定例ミーティング録音.wav")
        try? RecordingService.writeMinimalWAVFile(to: tempURL, durationSeconds: 18.0)

        guard let rec = try? workspace.recordingService.importAudioFile(
            from: tempURL,
            title: sessionTitleInput.isEmpty ? "取り込み会議：製品ロードマップ確認" : sessionTitleInput,
            projectIds: pids
        ) else { return }

        let activeProject = workspace.projectService.project(for: workspace.selectedProjectId)
        let config = workspace.modelManager.resolveConfiguration(project: activeProject)
        let vocabs = workspace.projectService.activeVocabularies(forProjectIds: pids)

        Task {
            if let tr = try? await workspace.sttService.transcribeImportedRecording(
                rec,
                config: config,
                vocabularies: vocabs
            ) {
                workspace.activeTranscriptId = tr.id
                let segs = workspace.sttService.segments(for: tr.id)
                try? workspace.embeddingService.indexTranscript(tr, segments: segs)
                workspace.refreshMeetingPartnerState()
            }
        }
    }

    private func generateOrUpdateFullMinutes() {
        guard let tr = currentTranscript else { return }
        let segments = workspace.sttService.segments(for: tr.id)
        let activeProject = workspace.projectService.project(for: tr.projectIds.first ?? workspace.selectedProjectId)
        let vocabs = workspace.projectService.activeVocabularies(forProjectIds: tr.projectIds)

        Task {
            if let meeting = try? await workspace.llmService.generateMeetingMinutes(
                from: tr,
                segments: segments,
                templateId: selectedTemplateId,
                project: activeProject,
                vocabularies: vocabs,
                relatedDocuments: workspace.documentService.documents
            ) {
                workspace.selectedMeetingId = meeting.id
                editableMinutesMarkdown = meeting.markdownContent
                workspace.refreshMeetingPartnerState()
            }
        }
    }
}
