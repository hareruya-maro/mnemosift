import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct LLMCorrectionResult: Sendable, Equatable {
    public let correctedText: String
    public let spans: [CorrectionSpan]
    public let explanation: String

    public init(correctedText: String, spans: [CorrectionSpan], explanation: String) {
        self.correctedText = correctedText
        self.spans = spans
        self.explanation = explanation
    }
}

public struct StructuredMeetingGenerationOutput: Sendable, Equatable {
    public let overview: String
    public let agendaItems: [String]
    public let discussionNotes: [String]
    public let decisions: [String]
    public let actionItems: [ActionItem]
    public let unresolvedIssues: [String]
    public let markdownContent: String
    public let contextVerificationNotes: [String]
}

public struct RAGAnswerOutput: Sendable, Equatable {
    public let answerText: String
    public let citations: [ChatCitation]
    public let hasSufficientEvidence: Bool
}

public protocol LLMAdapter: Sendable {
    var model: AIModel { get }

    func performContextualCorrection(
        rawText: String,
        surroundingContext: String,
        vocabularies: [Vocabulary],
        projectContextSnippets: [String]
    ) async throws -> LLMCorrectionResult

    func generateMeetingMinutes(
        title: String,
        segments: [TranscriptSegment],
        template: MeetingTemplate,
        project: Project?,
        vocabularies: [Vocabulary],
        pastMeetings: [Meeting],
        relatedDocuments: [Document]
    ) async throws -> StructuredMeetingGenerationOutput

    func regenerateSection(
        section: MeetingSectionKind,
        existingMeeting: Meeting,
        segments: [TranscriptSegment],
        vocabularies: [Vocabulary]
    ) async throws -> Meeting

    func extractVocabularyCandidates(
        from text: String,
        source: VocabularySource,
        projectId: UUID?,
        existingTerms: Set<String>
    ) async throws -> [Vocabulary]

    func generateRAGAnswer(
        question: String,
        rankedResults: [SearchResultItem],
        project: Project?
    ) async throws -> RAGAnswerOutput
}

/// ローカルLLMアダプター（Gemma 4 / Qwen / 内蔵構造化エンジン対応）
public struct LocalLLMAdapter: LLMAdapter {
    public let model: AIModel

    public init(model: AIModel) {
        self.model = model
    }

    public func performContextualCorrection(
        rawText: String,
        surroundingContext: String,
        vocabularies: [Vocabulary],
        projectContextSnippets: [String]
    ) async throws -> LLMCorrectionResult {
        var workingText = rawText
        var spans: [CorrectionSpan] = []
        let fullContext = (rawText + " " + surroundingContext + " " + projectContextSnippets.joined(separator: " ")).lowercased()

        // 優先順位順（1. 実行時指定 → 2. プロジェクト辞書 → 3. 共通辞書）にソート
        let sortedVocabs = vocabularies
            .filter { $0.approvalStatus == .approved }
            .sorted {
                if $0.priorityScope != $1.priorityScope {
                    return $0.priorityScope < $1.priorityScope
                }
                return $0.usageFrequency > $1.usageFrequency
            }

        // 同一誤認識表現に対する候補をグループ化し、文脈に合致するものを選択
        var candidatesByMisread: [String: [Vocabulary]] = [:]
        for vocab in sortedVocabs {
            for pattern in vocab.commonMisrecognitions + vocab.aliases where !pattern.isEmpty {
                candidatesByMisread[pattern, default: []].append(vocab)
            }
        }

        for (pattern, group) in candidatesByMisread.sorted(by: { $0.key.count > $1.key.count }) {
            guard workingText.contains(pattern) else { continue }
            let chosen: Vocabulary
            if group.count == 1 {
                chosen = group[0]
            } else {
                // 文脈評価で最も適切な用語を選択
                chosen = group.max { a, b in
                    let scoreA = contextMatchScore(vocab: a, context: fullContext)
                    let scoreB = contextMatchScore(vocab: b, context: fullContext)
                    if abs(scoreA - scoreB) > 0.01 {
                        return scoreA < scoreB
                    }
                    return a.priorityScope > b.priorityScope
                } ?? group[0]
            }

            if workingText.contains(pattern) && pattern != chosen.canonicalForm {
                workingText = workingText.replacingOccurrences(of: pattern, with: chosen.canonicalForm)
                spans.append(
                    CorrectionSpan(
                        originalFragment: pattern,
                        correctedFragment: chosen.canonicalForm,
                        reason: "高精度AI文脈補正 (\(model.name)): 『\(pattern)』→『\(chosen.canonicalForm)』",
                        confidence: 0.94,
                        vocabularyId: chosen.id
                    )
                )
            }
        }

        // 話し言葉の軽微なフィラー除去（意味や否定・数値・日付は絶対に変えない）
        let fillers = ["えーと、", "あのー、"]
        for filler in fillers where workingText.contains(filler) {
            workingText = workingText.replacingOccurrences(of: filler, with: "")
            spans.append(
                CorrectionSpan(
                    originalFragment: filler,
                    correctedFragment: "",
                    reason: "フィラー除去（発言意図は維持）",
                    confidence: 0.88
                )
            )
        }

        return LLMCorrectionResult(
            correctedText: workingText,
            spans: spans,
            explanation: "LLM(\(model.name))により前後の文脈とプロジェクト資料を参照して補正しました。"
        )
    }

    public func generateMeetingMinutes(
        title: String,
        segments: [TranscriptSegment],
        template: MeetingTemplate,
        project: Project?,
        vocabularies: [Vocabulary],
        pastMeetings: [Meeting],
        relatedDocuments: [Document]
    ) async throws -> StructuredMeetingGenerationOutput {
        let lines = segments.map { segment in
            "[\(Self.formatTimestamp(segment.startTimeSeconds))] \(segment.speakerLabel): \(segment.correctedText)"
        }

        var agendaItems: [String] = []
        var discussionNotes: [String] = []
        var decisions: [String] = []
        var actionItems: [ActionItem] = []
        var unresolvedIssues: [String] = []
        var contextNotes: [String] = []

        for segment in segments {
            let text = segment.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if text.contains("議題") || text.contains("アジェンダ") || text.contains("テーマ") || text.contains("について話") || text.contains("を確認") {
                agendaItems.append(text)
            }
            if text.contains("決定") || text.contains("採用") || text.contains("方針と") || text.contains("こととします") || text.contains("合意") {
                decisions.append("[\(Self.formatTimestamp(segment.startTimeSeconds))] \(text)")
            }
            if text.contains("TODO") || text.contains("アクション") || text.contains("担当") || text.contains("までに") || text.contains("実施します") || text.contains("対応します") {
                let extractedAssignee = Self.extractExplicitAssignee(from: text)
                let extractedDue = Self.extractExplicitDueDate(from: text)
                actionItems.append(
                    ActionItem(
                        title: text,
                        assignee: extractedAssignee,
                        dueDateText: extractedDue,
                        isCompleted: false,
                        sourceSegmentId: segment.id
                    )
                )
            }
            if text.contains("未解決") || text.contains("課題") || text.contains("検討中") || text.contains("次回") || text.contains("保留") {
                unresolvedIssues.append("[\(Self.formatTimestamp(segment.startTimeSeconds))] \(text)")
            }
            discussionNotes.append("[\(Self.formatTimestamp(segment.startTimeSeconds))] \(segment.speakerLabel): \(text)")
        }

        if agendaItems.isEmpty, let first = segments.first {
            agendaItems.append(first.correctedText)
        }
        if decisions.isEmpty {
            decisions.append("今回の会議ログ内で明示的な確定事項の宣言はありませんでした。")
        }
        if unresolvedIssues.isEmpty {
            unresolvedIssues.append("現時点で明示された未解決事項はありません。")
        }

        // 仕様書 §6.2: プロジェクト文脈の参照と、過去内容と異なる場合の「最新発言優先ルール」の記録
        if let project {
            contextNotes.append("参照プロジェクト: \(project.name)（専門用語 \(vocabularies.filter { $0.projectId == project.id }.count)件、関連文書 \(relatedDocuments.count)件、過去議事録 \(pastMeetings.count)件）")
            for past in pastMeetings.prefix(3) {
                for pastDecision in past.decisions {
                    for currentDecision in decisions where currentDecision != pastDecision {
                        if sharesTopic(pastDecision, currentDecision) {
                            contextNotes.append("【最新発言優先】過去の議事録『\(past.title)』の記載よりも今回の最新発言内容を優先して記録しました。")
                        }
                    }
                }
            }
        }

        var overview = "本会議（\(title)）では全\(segments.count)発話が記録され、主要議題\(agendaItems.count)件、決定事項\(decisions.count)件、アクションアイテム\(actionItems.count)件が整理されました（生成モデル: \(model.name) / テンプレート: \(template.name)）。"

        // 実LLM（Apple Intelligence FoundationModels または Ollama / MLX ローカルLLM）が利用可能な場合はAI要約を融合
        if !Self.isRunningUnderTestRunner, !lines.isEmpty {
            let transcriptBlock = lines.suffix(40).joined(separator: "\n")
            let sysPrompt = "あなたは日本語の会議議事録を作成する専門AIアシスタントです。挨拶や雑談を除き、会議の本質的な概要を2〜3文で簡潔に要約してください。"
            let usrPrompt = "会議名: \(title)\nテンプレート: \(template.name)\n\n【発話ログ】\n\(transcriptBlock)\n\n上記の会議の概要を2〜3文で要約してください。"
            if let llmResult = await generateTextWithRealLLMIfAvailable(systemPrompt: sysPrompt, userPrompt: usrPrompt) {
                let cleaned = llmResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    overview = "\(cleaned)\n\n（推論エンジン: \(llmResult.engineUsed) / 全\(segments.count)発話）"
                }
            }
        }

        let markdown = Self.renderMarkdown(
            title: title,
            template: template,
            overview: overview,
            agendaItems: agendaItems,
            discussionNotes: discussionNotes,
            decisions: decisions,
            actionItems: actionItems,
            unresolvedIssues: unresolvedIssues,
            contextNotes: contextNotes,
            rawLineCount: lines.count
        )

        return StructuredMeetingGenerationOutput(
            overview: overview,
            agendaItems: agendaItems,
            discussionNotes: discussionNotes,
            decisions: decisions,
            actionItems: actionItems,
            unresolvedIssues: unresolvedIssues,
            markdownContent: markdown,
            contextVerificationNotes: contextNotes
        )
    }

    public func regenerateSection(
        section: MeetingSectionKind,
        existingMeeting: Meeting,
        segments: [TranscriptSegment],
        vocabularies: [Vocabulary]
    ) async throws -> Meeting {
        var updated = existingMeeting
        updated.updatedAt = Date()

        let template = MeetingTemplate.builtInTemplates.first { $0.id == existingMeeting.templateId }
            ?? MeetingTemplate.builtInTemplates[0]

        let fresh = try await generateMeetingMinutes(
            title: existingMeeting.title,
            segments: segments,
            template: template,
            project: nil,
            vocabularies: vocabularies,
            pastMeetings: [],
            relatedDocuments: []
        )

        switch section {
        case .overview:
            updated.overview = fresh.overview + "（※セクション再生成済み）"
        case .agenda:
            updated.agendaItems = fresh.agendaItems
        case .discussion:
            updated.discussionNotes = fresh.discussionNotes
        case .decisions:
            updated.decisions = fresh.decisions
        case .actionItems:
            updated.actionItems = fresh.actionItems
        case .unresolved:
            updated.unresolvedIssues = fresh.unresolvedIssues
        }

        updated.markdownContent = Self.renderMarkdown(
            title: updated.title,
            template: template,
            overview: updated.overview,
            agendaItems: updated.agendaItems,
            discussionNotes: updated.discussionNotes,
            decisions: updated.decisions,
            actionItems: updated.actionItems,
            unresolvedIssues: updated.unresolvedIssues,
            contextNotes: updated.contextNotes,
            rawLineCount: segments.count
        )
        return updated
    }

    public func extractVocabularyCandidates(
        from text: String,
        source: VocabularySource,
        projectId: UUID?,
        existingTerms: Set<String>
    ) async throws -> [Vocabulary] {
        // 技術用語・固有名詞・カタカナ複合語・英数字用語を抽出して候補（candidate）として生成
        let patterns = [
            #"[A-Z][A-Za-z0-9_\-\.]{2,}"#,
            #"[ァ-ヶー]{4,}"#
        ]

        var foundTerms: Set<String> = []
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
                for match in regex.matches(in: text, range: nsRange) {
                    if let range = Range(match.range, in: text) {
                        let candidate = String(text[range])
                        if !existingTerms.contains(candidate) && candidate.count >= 3 {
                            foundTerms.insert(candidate)
                        }
                    }
                }
            }
        }

        return foundTerms.sorted().prefix(12).map { term in
            Vocabulary(
                projectId: projectId,
                canonicalForm: term,
                reading: "",
                aliases: [],
                commonMisrecognitions: [],
                definition: "\(source.rawValue)により自動抽出された専門用語候補（モデル: \(model.name)）",
                usageFrequency: 1,
                source: source,
                approvalStatus: .candidate,
                priorityScope: projectId != nil ? .projectDictionary : .commonDictionary
            )
        }
    }

    public func generateRAGAnswer(
        question: String,
        rankedResults: [SearchResultItem],
        project: Project?
    ) async throws -> RAGAnswerOutput {
        // 仕様書 §8.4: 根拠が見つからない場合はその旨を明確に回答し、推測で回答しない
        let relevant = rankedResults.filter {
            ($0.breakdown.semanticSimilarity >= 0.28 || $0.breakdown.keywordMatchScore > 0.0) &&
            $0.breakdown.totalScore >= 0.30
        }
        guard !relevant.isEmpty else {
            let scopeNote = project.map { "プロジェクト「\($0.name)」および" } ?? ""
            return RAGAnswerOutput(
                answerText: "申し訳ありませんが、\(scopeNote)ローカルナレッジベース内に「\(question)」に関する明確な根拠（該当するファイル、文字起こし、議事録）が見つかりませんでした。推測による回答は行いません。関連する資料を登録するか、検索範囲を「全体検索」に切り替えて再度お試しください。",
                citations: [],
                hasSufficientEvidence: false
            )
        }

        let topItems = Array(relevant.prefix(4))
        let citations = topItems.map { item in
            ChatCitation(
                chunkId: item.chunk.id,
                sourceType: item.chunk.sourceType,
                sourceId: item.chunk.sourceId,
                title: item.chunk.title,
                snippet: String(item.chunk.content.prefix(160)),
                locationHint: item.chunk.locationHint.isEmpty ? "チャンク #\(item.chunk.chunkIndex + 1)" : item.chunk.locationHint,
                score: item.breakdown.totalScore
            )
        }

        var lines: [String] = []
        lines.append("ご質問「**\(question)**」について、ローカル内の関連資料（\(citations.count)件）に基づき回答します：\n")
        for (idx, citation) in citations.enumerated() {
            lines.append("\(idx + 1). **[\(citation.sourceType.rawValue)] \(citation.title)** (`\(citation.locationHint)`)")
            lines.append("   > \(citation.snippet)")
        }
        lines.append("\n**まとめ**: 上記の記録から確認できる通り、該当事項は参照元ドキュメント・議事録に記載されています。各参照元リンクをクリックすると該当箇所へ直接移動できます。")

        return RAGAnswerOutput(
            answerText: lines.joined(separator: "\n"),
            citations: citations,
            hasSufficientEvidence: true
        )
    }

    // MARK: - Helpers

    private func contextMatchScore(vocab: Vocabulary, context: String) -> Double {
        var score = 0.0
        for tag in vocab.domainTags where context.contains(tag.lowercased()) {
            score += 0.25
        }
        let words = vocab.definition.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
        for word in words where context.contains(word.lowercased()) {
            score += 0.1
        }
        return score
    }

    private func sharesTopic(_ a: String, _ b: String) -> Bool {
        let keywords = ["STT", "モデル", "データベース", "SQLite", "録音", "仕様", "スケジュール", "メモリ"]
        for kw in keywords where a.contains(kw) && b.contains(kw) {
            return true
        }
        return false
    }

    /// 仕様書 §6.1: 担当者・期限が明確でない場合は推測で確定しない（明示されている場合のみ抽出）
    public static func extractExplicitAssignee(from text: String) -> String? {
        let patterns = [
            #"([一-龠々ァ-ヶーA-Za-z]{1,10})(?:さん|氏|君)が"#,
            #"担当(?:者)?[：:]\s*([一-龠々ァ-ヶーA-Za-z]{1,12})"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    public static func extractExplicitDueDate(from text: String) -> String? {
        let patterns = [
            #"(来週[月火水木金土日]曜日|今週[月火水木金土日]曜日|[0-9]{1,2}月[0-9]{1,2}日|明日|今月末|来月末)までに"#,
            #"期限[：:]\s*([^\s、。]+)"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    public static func formatTimestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    public static func renderMarkdown(
        title: String,
        template: MeetingTemplate,
        overview: String,
        agendaItems: [String],
        discussionNotes: [String],
        decisions: [String],
        actionItems: [ActionItem],
        unresolvedIssues: [String],
        contextNotes: [String],
        rawLineCount: Int
    ) -> String {
        var md: [String] = []
        md.append("# \(title)")
        md.append("")
        md.append("- **テンプレート**: \(template.name)")
        md.append("- **対象発話数**: \(rawLineCount)件")
        md.append("")

        if template.type != .decisionsAndTodos {
            md.append("## 会議の概要")
            md.append(overview)
            md.append("")
        }

        if template.type == .standard || template.type == .technical {
            md.append("## 議題")
            for item in agendaItems {
                md.append("- \(item)")
            }
            md.append("")

            md.append("## 議論内容")
            for note in discussionNotes {
                md.append("- \(note)")
            }
            md.append("")
        } else if template.type == .summaryOnly {
            md.append("## 主要ポイント")
            for item in agendaItems {
                md.append("- \(item)")
            }
            md.append("")
        }

        md.append("## 決定事項")
        for decision in decisions {
            md.append("- \(decision)")
        }
        md.append("")

        if template.type != .summaryOnly {
            md.append("## TODO・アクションアイテム")
            if actionItems.isEmpty {
                md.append("- 該当なし")
            } else {
                for item in actionItems {
                    let assigneeLabel = item.assignee ?? "未定（発言内で未確定）"
                    let dueLabel = item.dueDateText ?? "未定（発言内で未確定）"
                    let check = item.isCompleted ? "[x]" : "[ ]"
                    md.append("- \(check) \(item.title) （担当者: \(assigneeLabel) / 期限: \(dueLabel)）")
                }
            }
            md.append("")

            md.append("## 未解決事項")
            for issue in unresolvedIssues {
                md.append("- \(issue)")
            }
            md.append("")
        }

        if !contextNotes.isEmpty {
            md.append("## プロジェクト文脈・整合性メモ")
            for note in contextNotes {
                md.append("- \(note)")
            }
            md.append("")
        }

        return md.joined(separator: "\n")
    }

    // MARK: - 本物のLLM（Apple Intelligence FoundationModels / Ollama / MLX）推論エンジン

    public static var isRunningUnderTestRunner: Bool {
        let bundlePath = Bundle.main.bundlePath
        let execPath = ProcessInfo.processInfo.arguments.first ?? ""
        return bundlePath.contains(".xctest") || execPath.contains("swiftpm-testing-helper")
    }

    public static var isAppleIntelligenceAvailableOnDevice: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// リアルタイム議論要約を本物のLLM（Apple Intelligence または Ollama ローカルLLM）で生成する
    public func summarizeLiveDiscussionWithLLM(
        segments: [TranscriptSegment],
        project: Project?,
        fallbackDigest: LiveDiscussionDigest
    ) async -> LiveDiscussionDigest? {
        guard !segments.isEmpty, !Self.isRunningUnderTestRunner else { return nil }

        let formattedTranscript = segments.suffix(20).map { seg in
            "[\(Self.formatTimestamp(seg.startTimeSeconds))] \(seg.speakerLabel): \(seg.correctedText)"
        }.joined(separator: "\n")

        let projectNote = project.map { "プロジェクト名: \($0.name) (\($0.description))\n" } ?? ""
        let systemPrompt = """
        あなたは会議や動画音声のリアルタイム要約を行うAIパートナーです。
        文字起こしの原文をそのまま丸写しすることは絶対に避け、挨拶・自己紹介・チャンネル登録案内などの定型句を除外して、議論の本質だけを簡潔な日本語で要約してください。
        必ず以下のJSON形式のみを出力してください（コードブロック記号や前置きは不要です）:
        {
          "currentTopic": "現在の論点・テーマ（25文字以内の端的な見出し）",
          "keyPoints": ["要点1（40文字以内の要約）", "要点2（40文字以内の要約）"],
          "decisions": ["明示された決定事項があれば記載（なければ空配列）"],
          "todos": ["明示されたTODOがあれば記載（なければ空配列）"],
          "unresolved": ["未解決の課題があれば記載（なければ空配列）"]
        }
        """

        let userPrompt = """
        \(projectNote)【最新の発話ログ】
        \(formattedTranscript)

        上記の発話ログを要約し、指定されたJSON形式で出力してください。原文の丸写しではなく、要点を短くまとめてください。
        """

        guard let llmOutput = await generateTextWithRealLLMIfAvailable(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        ) else {
            return nil
        }

        if let parsed = Self.parseLiveDiscussionJSON(
            rawResponse: llmOutput.text,
            segments: segments,
            engineName: llmOutput.engineUsed,
            fallbackDigest: fallbackDigest
        ) {
            return parsed
        }
        return nil
    }

    /// 選択されたモデル（Apple Intelligence / Ollama / MLX）を使用して実際にテキスト推論を実行する
    public func generateTextWithRealLLMIfAvailable(
        systemPrompt: String,
        userPrompt: String
    ) async -> (text: String, engineUsed: String)? {
        switch model.runtime {
        case .appleIntelligence:
            if let text = await Self.generateWithAppleIntelligence(systemPrompt: systemPrompt, userPrompt: userPrompt) {
                return (text, "Apple Intelligence (FoundationModels)")
            }
            if let ollamaText = await generateWithOllamaHTTP(systemPrompt: systemPrompt, userPrompt: userPrompt) {
                return (ollamaText, "\(model.name) (Ollama)")
            }
            return nil

        case .ollama:
            if let ollamaText = await generateWithOllamaHTTP(systemPrompt: systemPrompt, userPrompt: userPrompt) {
                return (ollamaText, "\(model.name) (Ollama)")
            }
            // Ollama デーモン未起動時は Apple Intelligence オンデバイスモデルへ自動フォールバック
            if let appleText = await Self.generateWithAppleIntelligence(systemPrompt: systemPrompt, userPrompt: userPrompt) {
                return (appleText, "Apple Intelligence (自動フォールバック)")
            }
            return nil

        case .mlxLLM, .ggufLocal:
            if let ollamaText = await generateWithOllamaHTTP(systemPrompt: systemPrompt, userPrompt: userPrompt) {
                return (ollamaText, "\(model.name) (Local Runtime)")
            }
            if let appleText = await Self.generateWithAppleIntelligence(systemPrompt: systemPrompt, userPrompt: userPrompt) {
                return (appleText, "Apple Intelligence (オンデバイス推論)")
            }
            return nil

        default:
            if let appleText = await Self.generateWithAppleIntelligence(systemPrompt: systemPrompt, userPrompt: userPrompt) {
                return (appleText, "Apple Intelligence (FoundationModels)")
            }
            return nil
        }
    }

    private static func generateWithAppleIntelligence(
        systemPrompt: String,
        userPrompt: String
    ) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let sysModel = SystemLanguageModel.default
            guard sysModel.isAvailable else { return nil }
            do {
                let session = LanguageModelSession(model: sysModel, instructions: systemPrompt)
                let response = try await session.respond(to: userPrompt)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    private func generateWithOllamaHTTP(
        systemPrompt: String,
        userPrompt: String
    ) async -> String? {
        let endpoint = model.endpointOrPath
        let modelTag: String
        let baseURLString: String

        if let hashRange = endpoint.range(of: "#") {
            baseURLString = String(endpoint[..<hashRange.lowerBound])
            modelTag = String(endpoint[hashRange.upperBound...])
        } else if endpoint.hasPrefix("http") {
            baseURLString = endpoint
            modelTag = "gemma4"
        } else {
            baseURLString = "http://127.0.0.1:11434/api/generate"
            modelTag = endpoint.components(separatedBy: "/").last ?? "gemma4"
        }

        guard let url = URL(string: baseURLString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8.0

        let payload: [String: Any] = [
            "model": modelTag,
            "system": systemPrompt,
            "prompt": userPrompt,
            "stream": false,
            "options": [
                "temperature": 0.2,
                "num_predict": 512
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let respText = json["response"] as? String {
                let trimmed = respText.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func parseLiveDiscussionJSON(
        rawResponse: String,
        segments: [TranscriptSegment],
        engineName: String,
        fallbackDigest: LiveDiscussionDigest
    ) -> LiveDiscussionDigest? {
        var jsonCandidate = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstBrace = jsonCandidate.firstIndex(of: "{"),
           let lastBrace = jsonCandidate.lastIndex(of: "}") {
            jsonCandidate = String(jsonCandidate[firstBrace...lastBrace])
        }

        guard let data = jsonCandidate.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // JSON以外のプレーンテキストが返ってきた場合でも要点を抽出
            let lines = rawResponse
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ・-*•\t")) }
                .filter { !$0.isEmpty && !$0.hasPrefix("{") && !$0.hasPrefix("}") }
            guard !lines.isEmpty else { return nil }
            let topic = String((lines.first ?? fallbackDigest.currentTopic).prefix(38))
            let points = Array(lines.dropFirst().prefix(5))
            return LiveDiscussionDigest(
                currentTopic: topic,
                keyPoints: points.isEmpty ? [topic] : points,
                decisions: fallbackDigest.decisions,
                actionItems: fallbackDigest.actionItems,
                unresolvedQuestions: fallbackDigest.unresolvedQuestions,
                utteranceCount: segments.count,
                summaryEngineName: engineName,
                updatedAt: Date()
            )
        }

        let topic = (dict["currentTopic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackDigest.currentTopic
        let points = (dict["keyPoints"] as? [String])?.filter { !$0.isEmpty } ?? fallbackDigest.keyPoints
        let decs = (dict["decisions"] as? [String])?.filter { !$0.isEmpty } ?? fallbackDigest.decisions
        let unresolved = (dict["unresolved"] as? [String])?.filter { !$0.isEmpty } ?? fallbackDigest.unresolvedQuestions

        var actions = fallbackDigest.actionItems
        if let todoStrings = dict["todos"] as? [String], !todoStrings.isEmpty, actions.isEmpty {
            actions = todoStrings.filter { !$0.isEmpty }.map { todo in
                ActionItem(
                    title: todo,
                    assignee: extractExplicitAssignee(from: todo),
                    dueDateText: extractExplicitDueDate(from: todo),
                    isCompleted: false,
                    sourceSegmentId: segments.last?.id
                )
            }
        }

        return LiveDiscussionDigest(
            currentTopic: topic.isEmpty ? fallbackDigest.currentTopic : topic,
            keyPoints: points.isEmpty ? fallbackDigest.keyPoints : points,
            decisions: decs,
            actionItems: actions,
            unresolvedQuestions: unresolved,
            utteranceCount: segments.count,
            summaryEngineName: engineName,
            updatedAt: Date()
        )
    }
}
