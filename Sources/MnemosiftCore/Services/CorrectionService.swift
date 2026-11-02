import Foundation
import Observation

/// 補正ガードレール検証結果
public struct GuardrailValidationResult: Sendable, Equatable {
    public let isSafe: Bool
    public let finalText: String
    public let notes: [String]
}

/// 仕様書 §5.4-5.7: リアルタイム・再処理AI補正サービス
/// - モード1（補正オフ）、モード2（辞書補正）、モード3（高速AI補正：判断モデル）、モード4（高精度AI補正：LLM）
/// - STT原文 (`rawText`) と補正後テキスト (`correctedText`) を完全分離して保存
/// - 発言の意味・数量・日付・否定表現を変更しない厳格なガードレール
/// - 誤補正のロールバック（取り消し）および録音終了後の高精度再処理に対応
@Observable
@MainActor
public final class CorrectionService {
    private let database: LocalDatabase
    private let modelManager: ModelManager
    public private(set) var revisions: [TranscriptRevision] = []
    public var isThrottledDueToLoad: Bool = false

    public init(database: LocalDatabase, modelManager: ModelManager) {
        self.database = database
        self.modelManager = modelManager
        self.revisions = (try? database.loadTranscriptRevisions()) ?? []
    }

    /// 発話セグメントに対して指定された補正モードを適用する
    public func correctSegment(
        _ segment: TranscriptSegment,
        mode: RealtimeCorrectionMode,
        surroundingContext: String,
        vocabularies: [Vocabulary],
        projectContextSnippets: [String] = [],
        judgeModel: AIModel,
        llmModel: AIModel,
        confidenceThreshold: Double = 0.72
    ) async throws -> (updatedSegment: TranscriptSegment, revision: TranscriptRevision?) {
        // 負荷により一時停止中の場合、またはモード1（補正オフ）の場合は原文をそのまま保持
        if mode == .off || isThrottledDueToLoad {
            return (segment, nil)
        }

        let raw = segment.rawText
        let approvedVocabs = vocabularies
            .filter { $0.approvalStatus == .approved }
            .sorted {
                if $0.priorityScope != $1.priorityScope {
                    return $0.priorityScope < $1.priorityScope
                }
                return $0.usageFrequency > $1.usageFrequency
            }

        var proposedText = raw
        var spans: [CorrectionSpan] = []
        let usedModelId: String

        switch mode {
        case .off, .manual:
            return (segment, nil)

        case .dictionary:
            usedModelId = "dictionary-engine"
            // モード2：辞書補正（明確な一致のみ補正・LLM不使用）
            // 同一表現に複数候補がある場合は文脈評価を行う
            let grouped = Self.groupVocabulariesByTrigger(approvedVocabs)
            for (trigger, candidates) in grouped.sorted(by: { $0.key.count > $1.key.count }) {
                guard proposedText.contains(trigger) else { continue }
                let chosen: Vocabulary
                if candidates.count == 1 {
                    chosen = candidates[0]
                } else {
                    let judge = SystemOneJudgeAdapter(model: judgeModel)
                    guard let evaluated = judge.evaluateCorrectionCandidates(
                        utterance: proposedText,
                        surroundingContext: surroundingContext,
                        matchedFragment: trigger,
                        candidates: candidates
                    ) else { continue }
                    chosen = evaluated.vocabulary
                }
                guard trigger != chosen.canonicalForm else { continue }
                proposedText = proposedText.replacingOccurrences(of: trigger, with: chosen.canonicalForm)
                spans.append(
                    CorrectionSpan(
                        originalFragment: trigger,
                        correctedFragment: chosen.canonicalForm,
                        reason: "辞書補正 (\(chosen.priorityScope.label))",
                        confidence: 0.95,
                        vocabularyId: chosen.id
                    )
                )
            }

        case .fastAI:
            usedModelId = judgeModel.id
            // モード3：高速AI補正（辞書から候補抽出 → System One判断モデルで評価 → 閾値以上のみ補正）
            let judge = SystemOneJudgeAdapter(model: judgeModel)
            let grouped = Self.groupVocabulariesByTrigger(approvedVocabs)
            for (trigger, candidates) in grouped.sorted(by: { $0.key.count > $1.key.count }) {
                guard proposedText.contains(trigger) else { continue }
                if let scoreResult = judge.evaluateCorrectionCandidates(
                    utterance: proposedText,
                    surroundingContext: surroundingContext,
                    matchedFragment: trigger,
                    candidates: candidates
                ), scoreResult.calibratedScore >= confidenceThreshold {
                    let target = scoreResult.vocabulary.canonicalForm
                    if trigger != target {
                        proposedText = proposedText.replacingOccurrences(of: trigger, with: target)
                        spans.append(
                            CorrectionSpan(
                                originalFragment: trigger,
                                correctedFragment: target,
                                reason: scoreResult.reason,
                                confidence: scoreResult.calibratedScore,
                                vocabularyId: scoreResult.vocabulary.id
                            )
                        )
                    }
                }
            }

        case .highPrecisionAI:
            usedModelId = llmModel.id
            // モード4：高精度AI補正（LLM + プロジェクト辞書 + 関連資料文脈）
            let llm = LocalLLMAdapter(model: llmModel)
            let llmResult = try await llm.performContextualCorrection(
                rawText: raw,
                surroundingContext: surroundingContext,
                vocabularies: approvedVocabs,
                projectContextSnippets: projectContextSnippets
            )
            proposedText = llmResult.correctedText
            spans = llmResult.spans
        }

        // 変更がない場合はリビジョンを作成しない
        guard proposedText != raw else {
            return (segment, nil)
        }

        // 仕様書 §5.6: 補正時の制約チェック（数量・日付・否定表現の保護）
        let guardrail = Self.validateCorrectionGuardrails(
            rawText: raw,
            proposedText: proposedText,
            allowedSpans: spans
        )

        guard guardrail.isSafe, guardrail.finalText != raw else {
            return (segment, nil)
        }

        let revision = TranscriptRevision(
            segmentId: segment.id,
            transcriptId: segment.transcriptId,
            sttRawText: raw,
            correctedText: guardrail.finalText,
            correctionSpans: spans,
            correctionMethod: mode,
            modelId: usedModelId,
            guardrailNotes: guardrail.notes,
            isReverted: false,
            createdAt: Date()
        )

        var updated = segment
        // 重要: updated.rawText は let 定数であり絶対に上書きされない
        updated.correctedText = guardrail.finalText
        updated.activeRevisionId = revision.id
        updated.updatedAt = Date()

        try database.saveTranscriptRevision(revision)
        try database.saveTranscriptSegment(updated)
        revisions.insert(revision, at: 0)

        return (updated, revision)
    }

    /// 誤補正を取り消してSTT原文にロールバックする（仕様書 §5.6）
    public func revertSegmentCorrection(_ segment: TranscriptSegment) throws -> TranscriptSegment {
        var revertedSegment = segment
        revertedSegment.correctedText = segment.rawText
        if let activeRevId = segment.activeRevisionId,
           let idx = revisions.firstIndex(where: { $0.id == activeRevId }) {
            revisions[idx].isReverted = true
            try database.saveTranscriptRevision(revisions[idx])
        }
        revertedSegment.activeRevisionId = nil
        revertedSegment.updatedAt = Date()
        try database.saveTranscriptSegment(revertedSegment)
        return revertedSegment
    }

    /// 発話セグメントに対してユーザーによる手動訂正を適用する
    /// - STT原文 (`rawText`) は不変のまま保護し、補正後テキスト (`correctedText`) とリビジョン履歴を更新する
    public func applyManualCorrection(
        segment: TranscriptSegment,
        correctedText: String
    ) throws -> (updatedSegment: TranscriptSegment, revision: TranscriptRevision?) {
        let trimmed = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == segment.correctedText {
            return (segment, nil)
        }

        // 原文と完全に一致するよう編集された場合はロールバック扱いとする
        if trimmed == segment.rawText {
            let reverted = try revertSegmentCorrection(segment)
            return (reverted, nil)
        }

        let revision = TranscriptRevision(
            segmentId: segment.id,
            transcriptId: segment.transcriptId,
            sttRawText: segment.rawText,
            correctedText: trimmed,
            correctionSpans: [
                CorrectionSpan(
                    originalFragment: segment.correctedText,
                    correctedFragment: trimmed,
                    reason: "手動訂正",
                    confidence: 1.0,
                    vocabularyId: nil
                )
            ],
            correctionMethod: .manual,
            modelId: "manual-user-edit",
            guardrailNotes: ["ユーザーによる手動訂正（原文保護・即時反映）"],
            isReverted: false,
            createdAt: Date()
        )

        var updated = segment
        updated.correctedText = trimmed
        updated.activeRevisionId = revision.id
        updated.updatedAt = Date()

        try database.saveTranscriptRevision(revision)
        try database.saveTranscriptSegment(updated)
        revisions.insert(revision, at: 0)

        return (updated, revision)
    }

    public func revisions(for segmentId: UUID) -> [TranscriptRevision] {
        revisions.filter { $0.segmentId == segmentId }
    }

    // MARK: - Guardrails (仕様書 §5.6 補正時の制約)

    /// 発言の意味変更・話者発言の推測追加・数量/日付/否定表現の改変を検知し防止する
    public static func validateCorrectionGuardrails(
        rawText: String,
        proposedText: String,
        allowedSpans: [CorrectionSpan]
    ) -> GuardrailValidationResult {
        var notes: [String] = []

        // 1. 否定表現の整合性チェック（肯定⇔否定の勝手な反転を禁止）
        let negationMarkers = ["しない", "しません", "ではない", "ではありません", "不可", "未定", "反対", "見送り", "なし"]
        for marker in negationMarkers {
            let rawHas = rawText.contains(marker)
            let propHas = proposedText.contains(marker)
            if rawHas != propHas {
                return GuardrailValidationResult(
                    isSafe: false,
                    finalText: rawText,
                    notes: ["否定表現（\(marker)）の変化を検出したため、安全制約により原文を保持しました。"]
                )
            }
        }

        // 2. 数値・日付の保護（辞書用語名自体に含まれる数字例: Qwen3, Gemma 4 以外の数値改変を禁止）
        var rawWithoutAllowed = rawText
        var propWithoutAllowed = proposedText
        for span in allowedSpans {
            rawWithoutAllowed = rawWithoutAllowed.replacingOccurrences(of: span.originalFragment, with: "")
            propWithoutAllowed = propWithoutAllowed.replacingOccurrences(of: span.correctedFragment, with: "")
        }

        let rawNumbers = extractNumbers(from: rawWithoutAllowed)
        let propNumbers = extractNumbers(from: propWithoutAllowed)
        if rawNumbers != propNumbers {
            return GuardrailValidationResult(
                isSafe: false,
                finalText: rawText,
                notes: ["数量または日付の数値変更（\(rawNumbers) → \(propNumbers)）を検出したため原文を保持しました。"]
            )
        }

        notes.append("制約チェック通過（否定表現・数値・日付の改変なし）")
        return GuardrailValidationResult(
            isSafe: true,
            finalText: proposedText,
            notes: notes
        )
    }

    private static func extractNumbers(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[0-9]+"#) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func groupVocabulariesByTrigger(_ vocabularies: [Vocabulary]) -> [String: [Vocabulary]] {
        var map: [String: [Vocabulary]] = [:]
        for vocab in vocabularies {
            for trigger in vocab.commonMisrecognitions + vocab.aliases where !trigger.isEmpty {
                map[trigger, default: []].append(vocab)
            }
        }
        return map
    }
}
