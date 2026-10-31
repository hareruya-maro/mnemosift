import Foundation
import NaturalLanguage

public struct VocabularyCandidateScore: Sendable, Equatable {
    public let vocabulary: Vocabulary
    public let matchedFragment: String
    public let calibratedScore: Double
    public let contextSupportScore: Double
    public let priorityBoost: Double
    public let reason: String

    public init(
        vocabulary: Vocabulary,
        matchedFragment: String,
        calibratedScore: Double,
        contextSupportScore: Double,
        priorityBoost: Double,
        reason: String
    ) {
        self.vocabulary = vocabulary
        self.matchedFragment = matchedFragment
        self.calibratedScore = calibratedScore
        self.contextSupportScore = contextSupportScore
        self.priorityBoost = priorityBoost
        self.reason = reason
    }
}

public struct JudgeDocumentClassificationOutput: Sendable, Equatable {
    public let category: DocumentCategory
    public let calibratedConfidence: Double
    public let suggestedTags: [String]
    public let projectRelevanceScores: [UUID: Double]
    public let reason: String

    public init(
        category: DocumentCategory,
        calibratedConfidence: Double,
        suggestedTags: [String],
        projectRelevanceScores: [UUID: Double],
        reason: String
    ) {
        self.category = category
        self.calibratedConfidence = calibratedConfidence
        self.suggestedTags = suggestedTags
        self.projectRelevanceScores = projectRelevanceScores
        self.reason = reason
    }
}

/// 仕様書 §3.3: 判断モデル（System One系）プロトコル
/// - 文章生成は担当せず、候補の評価・選択・ファイル分類・プロジェクト関連度判定を高速に実行する
/// - スコアをそのまま確率として扱わず、実測に基づくキャリブレーション済みスコアと閾値で判定する
public protocol JudgeModelAdapter: Sendable {
    var model: AIModel { get }

    func evaluateCorrectionCandidates(
        utterance: String,
        surroundingContext: String,
        matchedFragment: String,
        candidates: [Vocabulary]
    ) -> VocabularyCandidateScore?

    func classifyDocument(
        fileName: String,
        content: String,
        projects: [Project],
        vocabularies: [Vocabulary]
    ) -> JudgeDocumentClassificationOutput
}

public struct SystemOneJudgeAdapter: JudgeModelAdapter {
    public let model: AIModel

    public init(model: AIModel) {
        self.model = model
    }

    public func evaluateCorrectionCandidates(
        utterance: String,
        surroundingContext: String,
        matchedFragment: String,
        candidates: [Vocabulary]
    ) -> VocabularyCandidateScore? {
        guard !candidates.isEmpty else { return nil }
        let combinedContext = (utterance + " " + surroundingContext).lowercased()

        var bestResult: VocabularyCandidateScore?

        for candidate in candidates {
            // 1. 優先順位（1: 実行時指定 > 2: プロジェクト辞書 > 3: 共通辞書）に基づくベーススコア
            let priorityBoost: Double = switch candidate.priorityScope {
            case .runtimeSpecified: 0.14
            case .projectDictionary: 0.08
            case .commonDictionary: 0.02
            }

            // 2. 誤認識リスト完全一致 vs 表記揺れ一致 vs 音韻距離
            let exactMisrecognition = candidate.commonMisrecognitions.contains(matchedFragment)
            let exactAlias = candidate.aliases.contains(matchedFragment)
            let phoneticSim = Self.phoneticSimilarity(matchedFragment, candidate.reading.isEmpty ? candidate.canonicalForm : candidate.reading)

            let matchStrength: Double
            if exactMisrecognition {
                matchStrength = 0.72
            } else if exactAlias {
                matchStrength = 0.74
            } else {
                matchStrength = max(0.45, phoneticSim * 0.70)
            }

            // 3. 文脈整合性スコア（説明文やドメインタグのキーワードが文脈に存在するか）
            var contextScore = 0.0
            let contextKeywords = extractKeywords(from: candidate.definition) + candidate.domainTags
            for kw in contextKeywords where !kw.isEmpty {
                if combinedContext.contains(kw.lowercased()) {
                    contextScore += 0.08
                }
            }
            contextScore = min(0.22, contextScore)

            // 同一表現に複数候補がある場合は文脈スコアを重視して差別化
            let rawScore = matchStrength + priorityBoost + contextScore + min(0.05, Double(candidate.usageFrequency) * 0.005)
            // 実測閾値（標準 0.72）と比較可能なキャリブレーションスコア [0.0, 0.99]
            let calibrated = min(0.99, max(0.0, rawScore))

            let scoreItem = VocabularyCandidateScore(
                vocabulary: candidate,
                matchedFragment: matchedFragment,
                calibratedScore: calibrated,
                contextSupportScore: contextScore,
                priorityBoost: priorityBoost,
                reason: "判断モデル(\(model.name)): 一致度\(String(format: "%.2f", matchStrength)) + 優先度\(candidate.priorityScope.label) + 文脈\(String(format: "%.2f", contextScore))"
            )

            if let currentBest = bestResult {
                if scoreItem.calibratedScore > currentBest.calibratedScore {
                    bestResult = scoreItem
                }
            } else {
                bestResult = scoreItem
            }
        }

        return bestResult
    }

    public func classifyDocument(
        fileName: String,
        content: String,
        projects: [Project],
        vocabularies: [Vocabulary]
    ) -> JudgeDocumentClassificationOutput {
        let lowerName = fileName.lowercased()
        let lowerContent = content.lowercased()

        let category: DocumentCategory
        let confidence: Double
        var tags: Set<String> = []

        if lowerName.hasSuffix(".swift") || lowerName.hasSuffix(".py") || lowerName.hasSuffix(".ts") || lowerName.hasSuffix(".rs") || lowerContent.contains("import foundation") || lowerContent.contains("public struct") {
            category = .sourceCode
            confidence = 0.92
            tags.insert("コード")
        } else if lowerName.contains("spec") || lowerName.contains("仕様") || lowerName.contains("設計") || lowerContent.contains("仕様書") || lowerContent.contains("要件") {
            category = .specification
            confidence = 0.89
            tags.insert("仕様書")
            tags.insert("設計")
        } else if lowerName.contains("minutes") || lowerName.contains("議事録") || lowerName.contains("meeting") || lowerContent.contains("決定事項") || lowerContent.contains("アクションアイテム") {
            category = .meetingMinutes
            confidence = 0.91
            tags.insert("議事録")
            tags.insert("会議")
        } else if lowerName.contains("bench") || lowerName.contains("検証") || lowerName.contains("paper") || lowerContent.contains("ベンチマーク") || lowerContent.contains("技術検証") {
            category = .researchNote
            confidence = 0.85
            tags.insert("技術検証")
        } else if lowerName.hasSuffix(".json") || lowerName.hasSuffix(".yaml") || lowerName.hasSuffix(".toml") || lowerName.contains("config") {
            category = .configuration
            confidence = 0.88
            tags.insert("設定")
        } else {
            category = .general
            confidence = 0.64
            tags.insert("ドキュメント")
        }

        // 語彙辞書に含まれる専門用語が文書内にあればタグとして付与
        for vocab in vocabularies where vocab.approvalStatus == .approved {
            if content.localizedCaseInsensitiveContains(vocab.canonicalForm) {
                tags.insert(vocab.canonicalForm)
            }
        }

        // プロジェクト関連度判定
        var projectScores: [UUID: Double] = [:]
        for project in projects {
            var score = 0.0
            if content.localizedCaseInsensitiveContains(project.name) || fileName.localizedCaseInsensitiveContains(project.name) {
                score += 0.55
            }
            let descWords = extractKeywords(from: project.description)
            for word in descWords where content.localizedCaseInsensitiveContains(word) {
                score += 0.12
            }
            let projVocabs = vocabularies.filter { $0.projectId == project.id && $0.approvalStatus == .approved }
            for pv in projVocabs where content.localizedCaseInsensitiveContains(pv.canonicalForm) {
                score += 0.15
            }
            if score > 0 {
                projectScores[project.id] = min(0.98, score)
            }
        }

        return JudgeDocumentClassificationOutput(
            category: category,
            calibratedConfidence: confidence,
            suggestedTags: Array(tags).sorted(),
            projectRelevanceScores: projectScores,
            reason: "System One判断モデル(\(model.name))による高速分類 (確信度: \(Int(confidence * 100))%)"
        )
    }

    private func extractKeywords(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var words: [String] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, range in
            let token = String(text[range])
            if token.count >= 2 && (tag == .noun || tag == .otherWord || tag == nil) {
                words.append(token)
            }
            return true
        }
        return words
    }

    public static func phoneticSimilarity(_ a: String, _ b: String) -> Double {
        let s1 = Array(a.lowercased())
        let s2 = Array(b.lowercased())
        guard !s1.isEmpty, !s2.isEmpty else { return 0.0 }
        if s1 == s2 { return 1.0 }

        var prev = Array(0...s2.count)
        var curr = Array(repeating: 0, count: s2.count + 1)

        for i in 1...s1.count {
            curr[0] = i
            for j in 1...s2.count {
                let cost = s1[i - 1] == s2[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            prev = curr
        }
        let distance = Double(prev[s2.count])
        let maxLen = Double(max(s1.count, s2.count))
        return max(0.0, 1.0 - (distance / maxLen))
    }
}
