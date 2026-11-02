import SwiftUI
import MnemosiftCore

/// 仕様書 §9.3 & §5: 録音・文字起こし画面
/// - 録音操作（開始/一時停止/再開/停止）、音声ソース選択（マイク/システム音声/同時録音/ファイル取込）
/// - プロジェクト選択（任意）、STTモデル選択、4つのリアルタイム補正モード選択
/// - 音声波形・入力レベル・逐次文字起こし（暫定結果と確定結果の区別）
/// - STT原文 (`rawText`) と補正結果 (`correctedText`) の切り替え・並列比較・誤補正の取り消し（ロールバック）
/// - 録音終了後の高精度再処理・議事録生成連携
public struct RecordingTranscriptionView: View {
    @Bindable var workspace: AppWorkspaceController

    @State private var sessionTitle: String = ""
    @State private var selectedAudioSource: AudioSourceType = .microphoneAndSystem
    @State private var selectedSTTModelId: String = "stt-qwen3-asr-0.6b"
    @State private var selectedReprocessSTTModelId: String = "stt-whisper-large-v3-turbo"
    @State private var selectedCorrectionMode: RealtimeCorrectionMode = .fastAI
    @State private var showComparisonMode: Bool = true
    @State private var simulatedUtteranceInput: String = "ネモシフトではキュウエン・エーエスアールとジェマフォーをローカル実行します。"
    @State private var speakerInput: String = "話者A"
    @State private var runtimeHotwordsInput: String = ""
    @State private var editingSegmentId: UUID?
    @State private var editingSegmentText: String = ""

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        HSplitView {
            leftControlAndSessionsColumn
                .frame(minWidth: 330, maxWidth: 390)

            rightTranscriptWorkspaceColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("録音・文字起こし")
        .onAppear {
            let activeProject = workspace.projectService.project(for: workspace.selectedProjectId)
            let resolved = workspace.modelManager.resolveConfiguration(project: activeProject)
            selectedSTTModelId = resolved.realtimeSTTModel.id
            selectedReprocessSTTModelId = resolved.reprocessSTTModel.id
            selectedCorrectionMode = resolved.correctionMode
            _ = workspace.recordingService.checkPermissionsStatus()
        }
    }

    // MARK: - Left Column: Controls & Session History

    private var leftControlAndSessionsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                recordingControlBox
                modelAndCorrectionSettingsBox
                transcriptHistoryListBox
            }
            .padding(16)
        }
    }

    private var recordingControlBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("録音コントロール")
                .font(.headline)

            TextField("会議・録音タイトル（任意）", text: $sessionTitle)
                .textFieldStyle(.roundedBorder)

            Picker("録音ソース", selection: $selectedAudioSource) {
                ForEach([AudioSourceType.microphone, .systemAudio, .microphoneAndSystem], id: \.self) { src in
                    Text(src.displayName).tag(src)
                }
            }

            Picker("所属プロジェクト（任意）", selection: $workspace.selectedProjectId) {
                Text("未所属（単発録音）").tag(UUID?.none)
                ForEach(workspace.projectService.projects) { project in
                    Text(project.name).tag(UUID?.some(project.id))
                }
            }

            // 波形と入力レベルメーター
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("状態: \(workspace.recordingService.state.rawValue)")
                        .font(.caption.bold())
                    Spacer()
                    Text(LocalLLMAdapter.formatTimestamp(workspace.recordingService.elapsedSeconds))
                        .font(.system(.body, design: .monospaced).bold())
                }

                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(workspace.recordingService.waveformSamples.enumerated()), id: \.offset) { _, sample in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(workspace.recordingService.state == .recording ? .red : .secondary.opacity(0.35))
                            .frame(width: 6, height: max(4, CGFloat(sample) * 38))
                    }
                }
                .frame(height: 42)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                if workspace.recordingService.state == .idle || workspace.recordingService.state == .completed {
                    Button("録音開始", systemImage: "record.circle") {
                        startNewRecordingSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button("音声ファイル取込", systemImage: "square.and.arrow.down") {
                        importSampleOrFileRecording()
                    }
                    .buttonStyle(.bordered)
                } else {
                    if workspace.recordingService.state == .recording {
                        Button("一時停止", systemImage: "pause.fill") {
                            workspace.recordingService.pauseRecording()
                        }
                    } else if workspace.recordingService.state == .paused {
                        Button("再開", systemImage: "play.fill") {
                            workspace.recordingService.resumeRecording()
                        }
                    }
                    Button("録音停止", systemImage: "stop.fill") {
                        stopCurrentRecordingSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }

            Text(workspace.recordingService.permissionStatusNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var modelAndCorrectionSettingsBox: some View {
        @Bindable var correctionService = workspace.correctionService
        return VStack(alignment: .leading, spacing: 12) {
            Text("STTモデル・リアルタイム補正設定")
                .font(.headline)

            Picker("リアルタイムSTT", selection: $selectedSTTModelId) {
                ForEach(workspace.modelManager.models(for: .stt)) { model in
                    Text("\(model.name) (\(model.streamingCapability.rawValue))").tag(model.id)
                }
            }

            Picker("リアルタイム補正モード", selection: $selectedCorrectionMode) {
                ForEach(RealtimeCorrectionMode.automaticModes) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Text(selectedCorrectionMode.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("実行時指定用語（カンマ区切り・優先度1）", text: $runtimeHotwordsInput)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            Toggle("高負荷時に補正を一時待機し録音・STTを最優先", isOn: $correctionService.isThrottledDueToLoad)
                .font(.caption)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var transcriptHistoryListBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文字起こしセッション一覧 (\(workspace.sttService.transcripts.count))")
                .font(.headline)

            ForEach(workspace.sttService.transcripts) { tr in
                Button {
                    workspace.activeTranscriptId = tr.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr.title)
                                .font(.subheadline.bold())
                            Text("モデル: \(tr.sttModelId) ・ \(tr.correctionMode.displayName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if workspace.activeTranscriptId == tr.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(8)
                    .background(
                        workspace.activeTranscriptId == tr.id ? Color.blue.opacity(0.14) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Right Column: Live Transcript, Comparison, Reprocessing & Minutes Generation

    private var rightTranscriptWorkspaceColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            transcriptToolbar

            liveUtteranceSimulatorBar

            segmentsListView
        }
        .padding(20)
    }

    private var transcriptToolbar: some View {
        HStack(spacing: 12) {
            if let activeTr = currentTranscript {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeTr.title)
                        .font(.title3.bold())
                    Text("STT認識遅延: \(String(format: "%.1f", workspace.sttService.lastLatencyMs)) ms ・ 原文と補正後テキストを分離保存中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("文字起こしセッションを選択または開始してください")
                    .font(.headline)
            }

            Spacer()

            Toggle("原文と補正結果を並列比較", isOn: $showComparisonMode)
                .toggleStyle(.switch)
                .controlSize(.small)

            Menu("録音後の高精度再処理", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                Button("Whisper Large v3 Turbo + 高速AI補正で再処理") {
                    runPostRecordingReprocess(mode: .fastAI)
                }
                Button("Whisper Large v3 Turbo + LLM高精度補正で再処理") {
                    runPostRecordingReprocess(mode: .highPrecisionAI)
                }
                Button("プロジェクト辞書のみで再補正") {
                    runPostRecordingReprocess(mode: .dictionary)
                }
            }
            .controlSize(.small)

            Button("この文字起こしから議事録を生成", systemImage: "sparkles") {
                generateMinutesFromCurrentTranscript()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var liveUtteranceSimulatorBar: some View {
        HStack(spacing: 8) {
            TextField("話者", text: $speakerInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)

            TextField("リアルタイム発話ストリーム入力（マイク発話テスト用）", text: $simulatedUtteranceInput)
                .textFieldStyle(.roundedBorder)

            Button("発話を逐次認識＆AI補正", systemImage: "waveform.badge.plus") {
                sendSimulatedRealtimeUtterance()
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private var segmentsListView: some View {
        let segments = currentTranscript.map { workspace.sttService.segments(for: $0.id) } ?? []
        let provisional = workspace.sttService.currentProvisionalSegment
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(segments) { segment in
                        segmentCard(segment)
                            .id(segment.id)
                    }

                    if let provisional {
                        provisionalCard(provisional)
                            .id("provisional-bottom")
                    }
                }
            }
            .onChange(of: segments.count) {
                scrollToBottom(proxy: proxy, segments: segments, provisional: provisional)
            }
            .onChange(of: workspace.sttService.currentProvisionalSegment?.rawText) {
                scrollToBottom(proxy: proxy, segments: segments, provisional: provisional)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, segments: [TranscriptSegment], provisional: TranscriptSegment?) {
        if provisional != nil {
            withAnimation {
                proxy.scrollTo("provisional-bottom", anchor: .bottom)
            }
        } else if let lastSegment = segments.last {
            withAnimation {
                proxy.scrollTo(lastSegment.id, anchor: .bottom)
            }
        }
    }

    private func provisionalCard(_ provisional: TranscriptSegment) -> some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text("[暫定認識中] \(provisional.speakerLabel): \(provisional.rawText)")
                .font(.callout.italic())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private func segmentCard(_ segment: TranscriptSegment) -> some View {
        let revisions = workspace.correctionService.revisions(for: segment.id)
        let isHighlighted = workspace.highlightedSegmentId == segment.id
        let isEditing = editingSegmentId == segment.id
        let isManual = revisions.first?.correctionMethod == .manual

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("[\(LocalLLMAdapter.formatTimestamp(segment.startTimeSeconds)) - \(LocalLLMAdapter.formatTimestamp(segment.endTimeSeconds))]")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(segment.speakerLabel)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15), in: Capsule())

                if isManual {
                    Text("手動訂正済み")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                } else if segment.hasCorrection {
                    Text("AI補正適用済み")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                } else {
                    Text("STT原文のまま")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let activeTr = currentTranscript {
                    if !isEditing {
                        Button("手動訂正", systemImage: "pencil") {
                            editingSegmentId = segment.id
                            editingSegmentText = segment.correctedText
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                    }

                    if segment.hasCorrection {
                        Button("訂正・補正を取り消す（原文へ戻す）", systemImage: "arrow.uturn.backward") {
                            workspace.revertTranscriptSegmentCorrection(transcriptId: activeTr.id, segmentId: segment.id)
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                    }
                }
            }

            if isEditing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("文字起こしの手動訂正（STT原文は保護されます）")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                        Spacer()
                        Text("STT原文: \(segment.rawText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    TextField("訂正後のテキストを入力", text: $editingSegmentText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .onSubmit {
                            saveManualCorrection(segment: segment)
                        }

                    HStack(spacing: 8) {
                        Button("保存して反映", systemImage: "checkmark") {
                            saveManualCorrection(segment: segment)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("キャンセル", systemImage: "xmark") {
                            editingSegmentId = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Text("Returnキーまたは「保存して反映」で確定")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if showComparisonMode && segment.hasCorrection {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("STT原文（変更不可・保護済み）")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Text(segment.rawText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(isManual ? "手動訂正後テキスト" : "補正後テキスト")
                            .font(.caption2.bold())
                            .foregroundStyle(isManual ? .orange : .green)
                        Text(segment.correctedText)
                            .font(.callout.bold())
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (isManual ? Color.orange : Color.green).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .onTapGesture(count: 2) {
                    editingSegmentId = segment.id
                    editingSegmentText = segment.correctedText
                }
            } else {
                Text(segment.correctedText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        editingSegmentId = segment.id
                        editingSegmentText = segment.correctedText
                    }
            }

            if let latestRev = revisions.first, !latestRev.correctionSpans.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(latestRev.correctionSpans.enumerated()), id: \.offset) { _, span in
                        let prefix = latestRev.correctionMethod == .manual ? "・手動訂正履歴" : "・補正履歴"
                        Text("\(prefix): 『\(span.originalFragment)』→『\(span.correctedFragment)』(\(span.reason) / 確信度 \(Int(span.confidence * 100))%)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(
            isHighlighted ? Color.yellow.opacity(0.18) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private func saveManualCorrection(segment: TranscriptSegment) {
        guard let activeTr = currentTranscript else { return }
        workspace.updateTranscriptSegmentText(
            transcriptId: activeTr.id,
            segmentId: segment.id,
            newText: editingSegmentText
        )
        editingSegmentId = nil
    }

    // MARK: - Actions

    private var currentTranscript: Transcript? {
        if let activeId = workspace.activeTranscriptId {
            return workspace.sttService.transcripts.first { $0.id == activeId }
        }
        return workspace.sttService.transcripts.first
    }

    private func buildRuntimeVocabularies() -> [Vocabulary] {
        let terms = runtimeHotwordsInput
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return terms.map { term in
            Vocabulary(
                canonicalForm: term,
                reading: term,
                aliases: [term],
                commonMisrecognitions: [],
                definition: "実行時に個別指定された最優先用語",
                usageFrequency: 10,
                source: .manual,
                approvalStatus: .approved,
                priorityScope: .runtimeSpecified
            )
        }
    }

    private func startNewRecordingSession() {
        let projectIds = workspace.selectedProjectId.map { [$0] } ?? []
        guard let rec = try? workspace.recordingService.startRecording(
            title: sessionTitle,
            source: selectedAudioSource,
            projectIds: projectIds
        ) else { return }

        if let tr = try? workspace.sttService.createTranscriptSession(
            for: rec,
            sttModelId: selectedSTTModelId,
            correctionMode: selectedCorrectionMode
        ) {
            workspace.activeTranscriptId = tr.id
        }
    }

    private func stopCurrentRecordingSession() {
        _ = try? workspace.recordingService.stopRecording()
        if let tr = currentTranscript {
            let segs = workspace.sttService.segments(for: tr.id)
            try? workspace.embeddingService.indexTranscript(tr, segments: segs)
        }
    }

    private func importSampleOrFileRecording() {
        let projectIds = workspace.selectedProjectId.map { [$0] } ?? []
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("技術定例録音サンプル.wav")
        try? RecordingService.writeMinimalWAVFile(to: tempURL, durationSeconds: 16.0)

        guard let rec = try? workspace.recordingService.importAudioFile(
            from: tempURL,
            title: sessionTitle.isEmpty ? "取り込み音声：スプリント技術レビュー" : sessionTitle,
            projectIds: projectIds
        ) else { return }

        let activeProject = workspace.projectService.project(for: workspace.selectedProjectId)
        let config = workspace.modelManager.resolveConfiguration(project: activeProject)
        let vocabs = workspace.projectService.activeVocabularies(
            forProjectIds: projectIds,
            runtimeTerms: buildRuntimeVocabularies()
        )

        Task {
            if let tr = try? await workspace.sttService.transcribeImportedRecording(
                rec,
                config: config,
                vocabularies: vocabs
            ) {
                workspace.activeTranscriptId = tr.id
                let segs = workspace.sttService.segments(for: tr.id)
                try? workspace.embeddingService.indexTranscript(tr, segments: segs)
            }
        }
    }

    private func sendSimulatedRealtimeUtterance() {
        let targetTranscript: Transcript
        if let existing = currentTranscript {
            targetTranscript = existing
        } else {
            startNewRecordingSession()
            guard let created = currentTranscript else { return }
            targetTranscript = created
        }

        let sttModel = workspace.modelManager.model(withId: selectedSTTModelId)
            ?? workspace.modelManager.models(for: .stt).first!
        let activeProject = workspace.projectService.project(for: workspace.selectedProjectId)
        let config = workspace.modelManager.resolveConfiguration(project: activeProject)
        let vocabs = workspace.projectService.activeVocabularies(
            forProjectIds: targetTranscript.projectIds,
            runtimeTerms: buildRuntimeVocabularies()
        )

        let existingSegs = workspace.sttService.segments(for: targetTranscript.id)
        let lastEnd = existingSegs.last?.endTimeSeconds ?? 0.0

        Task {
            _ = try? await workspace.sttService.processRealtimeUtteranceChunk(
                transcriptId: targetTranscript.id,
                rawUtteranceText: simulatedUtteranceInput,
                speakerLabel: speakerInput,
                startTimeSeconds: lastEnd,
                endTimeSeconds: lastEnd + 5.0,
                sttModel: sttModel,
                correctionMode: selectedCorrectionMode,
                vocabularies: vocabs,
                judgeModel: config.judgeModel,
                llmModel: config.llmModel,
                confidenceThreshold: config.judgeConfidenceThreshold
            )
            let updatedSegs = workspace.sttService.segments(for: targetTranscript.id)
            try? workspace.embeddingService.indexTranscript(targetTranscript, segments: updatedSegs)
        }
    }

    private func runPostRecordingReprocess(mode: RealtimeCorrectionMode) {
        guard let tr = currentTranscript else { return }
        let reprocessModel = workspace.modelManager.model(withId: selectedReprocessSTTModelId)
            ?? workspace.modelManager.models(for: .stt).first!
        let activeProject = workspace.projectService.project(for: workspace.selectedProjectId)
        let config = workspace.modelManager.resolveConfiguration(project: activeProject)
        let vocabs = workspace.projectService.activeVocabularies(
            forProjectIds: tr.projectIds,
            runtimeTerms: buildRuntimeVocabularies()
        )

        Task {
            try? await workspace.sttService.reprocessTranscript(
                transcriptId: tr.id,
                reprocessSTTModel: reprocessModel,
                targetMode: mode,
                vocabularies: vocabs,
                projectContextSnippets: [],
                judgeModel: config.judgeModel,
                llmModel: config.llmModel,
                confidenceThreshold: config.judgeConfidenceThreshold
            )
        }
    }

    private func generateMinutesFromCurrentTranscript() {
        guard let tr = currentTranscript else { return }
        let segments = workspace.sttService.segments(for: tr.id)
        let activeProject = workspace.projectService.project(for: tr.projectIds.first ?? workspace.selectedProjectId)
        let vocabs = workspace.projectService.activeVocabularies(forProjectIds: tr.projectIds)
        let templateId = activeProject?.defaultTemplateId ?? "template-standard"

        Task {
            if let meeting = try? await workspace.llmService.generateMeetingMinutes(
                from: tr,
                segments: segments,
                templateId: templateId,
                project: activeProject,
                vocabularies: vocabs,
                relatedDocuments: workspace.documentService.documents
            ) {
                workspace.selectedMeetingId = meeting.id
                workspace.selectedSection = .meetings
            }
        }
    }
}
