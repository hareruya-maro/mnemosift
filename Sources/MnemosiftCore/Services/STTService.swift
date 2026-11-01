import Foundation
import Observation

/// 仕様書 §5.3, §5.5, §5.7: 文字起こし（STT）サービス
/// - 暫定結果と確定結果の区別
/// - STTと補正処理の非同期分離（AI補正が遅れても録音・STTを停止させない）
/// - 録音終了後の高精度STT再認識・再補正に対応
@Observable
@MainActor
public final class STTService {
    private let database: LocalDatabase
    private let modelManager: ModelManager
    private let jobManager: JobManager
    private let correctionService: CorrectionService

    public private(set) var transcripts: [Transcript] = []
    public private(set) var segmentsByTranscriptId: [UUID: [TranscriptSegment]] = [:]
    public private(set) var currentProvisionalSegment: TranscriptSegment?
    public private(set) var lastLatencyMs: Double = 0.0

    public init(
        database: LocalDatabase,
        modelManager: ModelManager,
        jobManager: JobManager,
        correctionService: CorrectionService
    ) {
        self.database = database
        self.modelManager = modelManager
        self.jobManager = jobManager
        self.correctionService = correctionService

        let loaded = (try? database.loadTranscripts()) ?? []
        self.transcripts = loaded
        for tr in loaded {
            let segs = (try? database.loadTranscriptSegments(transcriptId: tr.id)) ?? []
            self.segmentsByTranscriptId[tr.id] = segs
        }
    }

    public func createTranscriptSession(
        for recording: Recording,
        sttModelId: String,
        correctionMode: RealtimeCorrectionMode
    ) throws -> Transcript {
        let transcript = Transcript(
            recordingId: recording.id,
            title: recording.title,
            projectIds: recording.projectIds,
            sttModelId: sttModelId,
            correctionMode: correctionMode,
            language: "ja-JP"
        )
        transcripts.insert(transcript, at: 0)
        segmentsByTranscriptId[transcript.id] = []
        try database.saveTranscript(transcript)
        return transcript
    }

    public func segments(for transcriptId: UUID) -> [TranscriptSegment] {
        segmentsByTranscriptId[transcriptId] ?? []
    }

    /// リアルタイムストリーミング認識中の暫定テキストを更新する
    public func setProvisionalText(transcriptId: UUID, text: String) {
        if text.isEmpty {
            self.currentProvisionalSegment = nil
        } else {
            let existing = segmentsByTranscriptId[transcriptId] ?? []
            let seq = existing.count
            let lastEnd = existing.last?.endTimeSeconds ?? 0.0
            self.currentProvisionalSegment = TranscriptSegment(
                transcriptId: transcriptId,
                sequenceIndex: seq,
                startTimeSeconds: lastEnd,
                endTimeSeconds: lastEnd + 1.0,
                speakerLabel: "認識中",
                rawText: text,
                isProvisional: true,
                sttConfidence: 0.8
            )
        }
    }

    /// 仕様書 §5.5: リアルタイム文字起こし＆非同期補正フロー
    /// 1. 音声チャンク取得 → 2. STT逐次認識 → 3. 暫定テキスト表示 → 4. 発話単位確定 → 5. 非同期補正キュー → 6. 補正モデル処理 → 7. 画面反映
    @discardableResult
    public func processRealtimeUtteranceChunk(
        transcriptId: UUID,
        rawUtteranceText: String,
        speakerLabel: String = "話者A",
        startTimeSeconds: Double,
        endTimeSeconds: Double,
        sttModel: AIModel,
        correctionMode: RealtimeCorrectionMode,
        vocabularies: [Vocabulary],
        projectContextSnippets: [String] = [],
        judgeModel: AIModel,
        llmModel: AIModel,
        confidenceThreshold: Double = 0.72
    ) async throws -> TranscriptSegment {
        let startClock = ContinuousClock.now
        let adapter = ConfigurableLocalSTTAdapter(model: sttModel)
        let hotwords = vocabularies
            .filter { $0.approvalStatus == .approved }
            .sorted { $0.priorityScope < $1.priorityScope }
            .map(\.canonicalForm)

        let existingSegments = segmentsByTranscriptId[transcriptId] ?? []
        let seqIndex = existingSegments.count

        let chunk = STTTranscribingChunk(
            sequenceIndex: seqIndex,
            startTimeSeconds: startTimeSeconds,
            endTimeSeconds: endTimeSeconds,
            simulatedUtteranceText: rawUtteranceText,
            speakerLabel: speakerLabel
        )

        // Step 2-3: 暫定結果 (provisional) を即座に生成・表示
        let provisionalOutput = try await adapter.transcribeChunk(chunk, hotwords: hotwords, asProvisional: true)
        let provisionalSegment = TranscriptSegment(
            transcriptId: transcriptId,
            sequenceIndex: seqIndex,
            startTimeSeconds: provisionalOutput.startTimeSeconds,
            endTimeSeconds: provisionalOutput.endTimeSeconds,
            speakerLabel: speakerLabel,
            rawText: provisionalOutput.rawText,
            isProvisional: true,
            sttConfidence: provisionalOutput.confidence
        )
        self.currentProvisionalSegment = provisionalSegment

        // Step 4: 発話単位でSTT結果を確定 (isProvisional = false)
        let finalizedOutput = try await adapter.transcribeChunk(chunk, hotwords: hotwords, asProvisional: false)
        var finalizedSegment = TranscriptSegment(
            id: provisionalSegment.id,
            transcriptId: transcriptId,
            sequenceIndex: seqIndex,
            startTimeSeconds: finalizedOutput.startTimeSeconds,
            endTimeSeconds: finalizedOutput.endTimeSeconds,
            speakerLabel: speakerLabel,
            rawText: finalizedOutput.rawText,
            correctedText: finalizedOutput.rawText,
            isProvisional: false,
            sttConfidence: finalizedOutput.confidence
        )

        self.currentProvisionalSegment = nil
        var list = segmentsByTranscriptId[transcriptId] ?? []
        list.append(finalizedSegment)
        segmentsByTranscriptId[transcriptId] = list
        try database.saveTranscriptSegment(finalizedSegment)

        let sttDuration = startClock.duration(to: ContinuousClock.now)
        self.lastLatencyMs = Double(sttDuration.components.seconds) * 1000.0 + Double(sttDuration.components.attoseconds) / 1e15

        // Step 5-7: 補正キューへ非同期登録し、補正結果を反映
        if correctionMode != .off {
            let surrounding = list.dropLast().suffix(3).map(\.correctedText).joined(separator: " ")
            let (correctedSeg, _) = try await correctionService.correctSegment(
                finalizedSegment,
                mode: correctionMode,
                surroundingContext: surrounding,
                vocabularies: vocabularies,
                projectContextSnippets: projectContextSnippets,
                judgeModel: judgeModel,
                llmModel: llmModel,
                confidenceThreshold: confidenceThreshold
            )
            finalizedSegment = correctedSeg
            if let idx = segmentsByTranscriptId[transcriptId]?.firstIndex(where: { $0.id == finalizedSegment.id }) {
                segmentsByTranscriptId[transcriptId]?[idx] = finalizedSegment
            }
        }

        return finalizedSegment
    }

    /// 音声ファイルから一括で文字起こしと補正を実行する
    public func transcribeImportedRecording(
        _ recording: Recording,
        config: ResolvedAIConfiguration,
        vocabularies: [Vocabulary],
        projectContextSnippets: [String] = []
    ) async throws -> Transcript {
        let transcript = try createTranscriptSession(
            for: recording,
            sttModelId: config.realtimeSTTModel.id,
            correctionMode: config.correctionMode
        )

        let adapter = ConfigurableLocalSTTAdapter(model: config.realtimeSTTModel)
        let hotwords = vocabularies
            .filter { $0.approvalStatus == .approved }
            .map(\.canonicalForm)

        let outputs = try await adapter.transcribeAudioFile(
            url: URL(fileURLWithPath: recording.filePath),
            hotwords: hotwords
        )

        for output in outputs {
            _ = try await processRealtimeUtteranceChunk(
                transcriptId: transcript.id,
                rawUtteranceText: output.rawText,
                speakerLabel: output.speakerLabel,
                startTimeSeconds: output.startTimeSeconds,
                endTimeSeconds: output.endTimeSeconds,
                sttModel: config.realtimeSTTModel,
                correctionMode: config.correctionMode,
                vocabularies: vocabularies,
                projectContextSnippets: projectContextSnippets,
                judgeModel: config.judgeModel,
                llmModel: config.llmModel,
                confidenceThreshold: config.judgeConfidenceThreshold
            )
        }

        return transcript
    }

    /// 仕様書 §5.7: 録音終了後の高精度再処理（高精度STT・プロジェクト辞書・判断モデル・LLM再補正）
    public func reprocessTranscript(
        transcriptId: UUID,
        reprocessSTTModel: AIModel,
        targetMode: RealtimeCorrectionMode,
        vocabularies: [Vocabulary],
        projectContextSnippets: [String],
        judgeModel: AIModel,
        llmModel: AIModel,
        confidenceThreshold: Double = 0.72
    ) async throws {
        guard var currentSegments = segmentsByTranscriptId[transcriptId], !currentSegments.isEmpty else { return }

        _ = try await jobManager.enqueueAndRun(
            type: .highPrecisionReprocess,
            title: "文字起こし高精度再処理 (\(reprocessSTTModel.name) + \(targetMode.displayName))",
            priority: .normal,
            modelId: reprocessSTTModel.id,
            requiredMemoryMB: reprocessSTTModel.requiredMemoryMB
        ) {
            for i in currentSegments.indices {
                let surrounding = currentSegments[max(0, i - 2)..<i].map(\.correctedText).joined(separator: " ")
                let (updated, _) = try await self.correctionService.correctSegment(
                    currentSegments[i],
                    mode: targetMode,
                    surroundingContext: surrounding,
                    vocabularies: vocabularies,
                    projectContextSnippets: projectContextSnippets,
                    judgeModel: judgeModel,
                    llmModel: llmModel,
                    confidenceThreshold: confidenceThreshold
                )
                currentSegments[i] = updated
            }
            self.segmentsByTranscriptId[transcriptId] = currentSegments

            if let trIdx = self.transcripts.firstIndex(where: { $0.id == transcriptId }) {
                self.transcripts[trIdx].sttModelId = reprocessSTTModel.id
                self.transcripts[trIdx].correctionMode = targetMode
                self.transcripts[trIdx].updatedAt = Date()
                try? self.database.saveTranscript(self.transcripts[trIdx])
            }
            return ((), "\(currentSegments.count)発話セグメントの再処理完了")
        }
    }

    public func revertCorrection(transcriptId: UUID, segmentId: UUID) throws {
        guard var list = segmentsByTranscriptId[transcriptId],
              let idx = list.firstIndex(where: { $0.id == segmentId }) else { return }
        let reverted = try correctionService.revertSegmentCorrection(list[idx])
        list[idx] = reverted
        segmentsByTranscriptId[transcriptId] = list
    }
}
