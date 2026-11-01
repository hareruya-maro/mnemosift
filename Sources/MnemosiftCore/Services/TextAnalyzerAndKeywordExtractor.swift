import Foundation
import NaturalLanguage
import CryptoKit

// MARK: - §6 日本語解析・正規化・重要キーワード抽出・§5 チャンク分割

/// トークンの重要度区分（§6.4）
public enum TokenImportanceTier: Int, Codable, Comparable, Sendable {
    case low = 0       // 助詞、接続詞、フィラー（「えーと」「あの」など）
    case medium = 1    // 動作・状態、形容詞・評価語、数量・順序、決定・変更を表す語
    case high = 2      // 固有名詞、人名・組織名・製品名、技術用語・API名・画面名、タイトルに含まれる語

    public static func < (lhs: TokenImportanceTier, rhs: TokenImportanceTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 解析済みトークン情報
public struct AnalyzedToken: Sendable, Equatable, Hashable {
    public let surface: String
    public let normalized: String
    public let tier: TokenImportanceTier
    public let isNegatedContext: Bool
    public let isTechnicalOrProper: Bool

    public init(
        surface: String,
        normalized: String,
        tier: TokenImportanceTier,
        isNegatedContext: Bool = false,
        isTechnicalOrProper: Bool = false
    ) {
        self.surface = surface
        self.normalized = normalized
        self.tier = tier
        self.isNegatedContext = isNegatedContext
        self.isTechnicalOrProper = isTechnicalOrProper
    }
}

/// 文・クエリの意味極性および状態シグナル（§1.1, §6.3, §16.3）
public struct SemanticPolaritySignals: Sendable, Equatable, Hashable {
    public var hasAffirmativeAdoption: Bool = false
    public var hasNegativeRejection: Bool = false
    public var hasConfirmedDecision: Bool = false
    public var hasProposalOrConsideration: Bool = false
    public var hasPlannedStatus: Bool = false
    public var hasCompletedStatus: Bool = false
    public var hasBrightAttribute: Bool = false
    public var hasDarkAttribute: Bool = false
    public var hasCriticalSeverity: Bool = false
    public var hasMinorSeverity: Bool = false
    public var semanticMarkerTokens: [String] = []

    public init() {}
}

/// §3.1 形態素解析・正規化プロバイダーの抽象化プロトコル
public protocol TextAnalyzing: Sendable {
    func normalizeText(_ text: String) -> String
    func analyzeTokens(in text: String, titleContext: String) -> [AnalyzedToken]
    func extractSemanticSignals(in text: String) -> SemanticPolaritySignals
    func buildFTS5TokenString(for text: String, titleContext: String) -> String
    func estimateTokenCount(for text: String) -> Int
}

/// §6 Apple `NaturalLanguage` (`NLTokenizer` + `NLTagger`) を用いた日本語・英語ハイブリッド解析器
public struct NaturalLanguageTextAnalyzer: TextAnalyzing {

    public init() {}

    /// 会話フィラー・無意味語（§6.4 低重要度）
    private static let fillerWords: Set<String> = [
        "えーと", "えっと", "あの", "あのー", "その", "そのー", "まあ", "なんか",
        "うーん", "ええと", "はい", "ええ", "うん", "というか", "ですね", "ますね"
    ]

    /// 助詞・助動詞・形式的機能語（単独では検索キーワードにしない語）
    private static let stopFunctionWords: Set<String> = [
        "の", "は", "が", "を", "に", "へ", "と", "で", "や", "から", "まで", "より",
        "して", "した", "する", "체", "ます", "です", "だ", "である", "ある", "いる",
        "こと", "もの", "ため", "よう", "について", "に関して", "による", "における",
        "これ", "それ", "あれ", "この", "その", "あの", "どの", "ここ", "そこ",
        "the", "a", "an", "of", "to", "in", "for", "on", "with", "at", "by", "from"
    ]

    /// 保護すべき技術用語・記号付き用語の正規化辞書（§6.2, §16.1）
    private static let protectedTechPatterns: [(pattern: String, canonical: String)] = [
        ("c++", "c++"),
        ("c#", "c#"),
        ("f#", "f#"),
        ("oauth2.0", "oauth2"),
        ("oauth2", "oauth2"),
        ("oauth", "oauth"),
        ("swiftui", "swiftui"),
        ("sqlite-vec", "sqlite-vec"),
        ("sqlite3", "sqlite"),
        ("sqlite", "sqlite"),
        ("fts5", "fts5"),
        ("firebase", "firebase"),
        ("apns", "apns"),
        ("jwt", "jwt"),
        ("passkey", "passkey"),
        ("apple id", "appleログイン"),
        ("sign in with apple", "appleログイン"),
        ("appleログイン", "appleログイン"),
        ("googleログイン", "googleログイン"),
        ("qwen3-asr", "qwen3-asr"),
        ("whisperkit", "whisperkit"),
        ("screencapturekit", "screencapturekit"),
        ("gemma 4", "gemma4"),
        ("gemma4", "gemma4")
    ]

    /// 表記ゆれ・同義表現の正規化マップ（§6.2, §16.1）
    private static let synonymNormalizationMap: [String: [String]] = [
        "ログイン": ["サインイン", "login", "signin", "認証"],
        "サインイン": ["ログイン", "login", "signin", "認証"],
        "認証": ["authentication", "auth", "ログイン"],
        "パフォーマンス": ["性能", "速度", "レスポンス", "高速化", "パフォーマンス改善"],
        "性能": ["パフォーマンス", "速度", "高速化"],
        "レスポンス": ["応答速度", "パフォーマンス", "レイテンシ", "遅延"],
        "デザイン": ["配色", "テーマ", "外観", "ui", "画面デザイン", "カラー"],
        "配色": ["デザイン", "カラー", "色合い", "テーマ"],
        "明るい": ["ライトモード", "白基調", "明るめ", "明度が高い"],
        "暗い": ["ダークモード", "黒基調", "暗め", "明度が低い"],
        "会議": ["ミーティング", "打ち合わせ", "定例", "議論"],
        "資料": ["ドキュメント", "仕様書", "設計書", "文書"],
        "障害": ["不具合", "バグ", "トラブル", "インシデント", "エラー"],
        "採用": ["導入", "採択", "利用決定"]
    ]

    /// §6.2 テキスト正規化（全角英数→半角、連続空白整理、技術記号保護）
    public func normalizeText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        // 全角英数字を半角に変換しつつ、元の文字構造を壊さない
        let halfwidth = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let lines = halfwidth
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return lines
    }

    /// §6.3 否定・確定状態・比較形容詞・進捗状態・重大度の意味保護シグナル抽出
    public func extractSemanticSignals(in text: String) -> SemanticPolaritySignals {
        var signals = SemanticPolaritySignals()
        let normalized = normalizeText(text).lowercased()

        // 文単位に分割して文脈内の肯定/否定・決定/検討を精密に判定する
        let clauses = normalized.components(separatedBy: CharacterSet(charactersIn: "。！!？?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for clause in clauses {
            let hasNegationWord =
                clause.contains("しない") ||
                clause.contains("しなかった") ||
                clause.contains("せず") ||
                clause.contains("見送") ||
                clause.contains("不採用") ||
                clause.contains("却下") ||
                clause.contains("断念") ||
                clause.contains("廃止") ||
                clause.contains("対応していない") ||
                clause.contains("未対応") ||
                clause.contains("採用しない") ||
                clause.contains("導入しない") ||
                clause.contains("使わない") ||
                clause.contains("やめる")

            let hasAdoptionVerb =
                clause.contains("採用") ||
                clause.contains("導入") ||
                clause.contains("使う") ||
                clause.contains("利用する") ||
                clause.contains("移行する")

            if hasNegationWord {
                signals.hasNegativeRejection = true
                signals.semanticMarkerTokens.append("__polarity_negated")
                if hasAdoptionVerb || clause.contains("見送") || clause.contains("不採用") || clause.contains("却下") {
                    signals.semanticMarkerTokens.append("__decision_rejected")
                    signals.semanticMarkerTokens.append("採用_否定")
                    signals.semanticMarkerTokens.append("不採用_見送り")
                }
            } else if hasAdoptionVerb && (
                clause.contains("採用した") ||
                clause.contains("採用する") ||
                clause.contains("採用することになった") ||
                clause.contains("採用を決定") ||
                clause.contains("採用に決定") ||
                clause.contains("導入した") ||
                clause.contains("導入する") ||
                clause.contains("決定")
            ) {
                signals.hasAffirmativeAdoption = true
                signals.semanticMarkerTokens.append("__polarity_affirmed")
                signals.semanticMarkerTokens.append("__decision_adopted")
                signals.semanticMarkerTokens.append("採用_肯定")
            }

            // 確定状態（決定 vs 提案・検討中）
            let isProposalOrPending =
                clause.contains("提案") ||
                clause.contains("検討中") ||
                clause.contains("検討する") ||
                clause.contains("検討して") ||
                clause.contains("議論中") ||
                clause.contains("アイデア") ||
                clause.contains("候補") ||
                clause.contains("未決定") ||
                clause.contains("保留")

            let isConfirmedDecision =
                (clause.contains("決定した") ||
                 clause.contains("決定された") ||
                 clause.contains("決定事項") ||
                 clause.contains("ことになった") ||
                 clause.contains("合意した") ||
                 clause.contains("確定した") ||
                 clause.contains("正式決定")) &&
                !clause.contains("未決定") &&
                !clause.contains("決定していない")

            if isConfirmedDecision {
                signals.hasConfirmedDecision = true
                signals.semanticMarkerTokens.append("__status_decided")
                signals.semanticMarkerTokens.append("状態_決定済み")
            }
            if isProposalOrPending {
                signals.hasProposalOrConsideration = true
                signals.semanticMarkerTokens.append("__status_proposed")
                signals.semanticMarkerTokens.append("状態_提案検討")
            }

            // 進捗状態（改善予定 vs 改善完了）
            if clause.contains("改善予定") || clause.contains("対応予定") || clause.contains("予定して") || clause.contains("今後改善") || clause.contains("来月対応") || clause.contains("計画中") {
                signals.hasPlannedStatus = true
                signals.semanticMarkerTokens.append("__progress_planned")
                signals.semanticMarkerTokens.append("進捗_改善予定")
            }
            if clause.contains("改善完了") || clause.contains("対応完了") || clause.contains("完了した") || clause.contains("改善済み") || clause.contains("対応済み") || clause.contains("解消した") || clause.contains("修正完了") {
                signals.hasCompletedStatus = true
                signals.semanticMarkerTokens.append("__progress_completed")
                signals.semanticMarkerTokens.append("進捗_改善完了")
            }

            // 形容詞・比較（明るい vs 暗い）
            if clause.contains("明るく") || clause.contains("明るい") || clause.contains("ライトモード") || clause.contains("白基調") || clause.contains("明度を上げ") {
                signals.hasBrightAttribute = true
                signals.semanticMarkerTokens.append("__adj_bright")
                signals.semanticMarkerTokens.append("属性_明るい")
            }
            if clause.contains("暗く") || clause.contains("暗い") || clause.contains("ダークモード") || clause.contains("黒基調") || clause.contains("明度を下げ") {
                signals.hasDarkAttribute = true
                signals.semanticMarkerTokens.append("__adj_dark")
                signals.semanticMarkerTokens.append("属性_暗い")
            }

            // 重大度（重大な障害 vs 軽微な障害）
            if clause.contains("重大") || clause.contains("深刻") || clause.contains("クリティカル") || clause.contains("致命的") || clause.contains("全面停止") || clause.contains("p0") || clause.contains("sev1") {
                signals.hasCriticalSeverity = true
                signals.semanticMarkerTokens.append("__severity_critical")
                signals.semanticMarkerTokens.append("規模_重大障害")
            }
            if clause.contains("軽微") || clause.contains("マイナー") || clause.contains("影響は小さい") || clause.contains("影響範囲は限定的") || clause.contains("小規模") || clause.contains("p3") || clause.contains("sev3") {
                signals.hasMinorSeverity = true
                signals.semanticMarkerTokens.append("__severity_minor")
                signals.semanticMarkerTokens.append("規模_軽微障害")
            }
        }

        signals.semanticMarkerTokens = Array(Set(signals.semanticMarkerTokens)).sorted()
        return signals
    }

    /// §6.1, §6.2, §6.4 形態素解析・品詞判定・重要度ランク付きトークン抽出
    public func analyzeTokens(in text: String, titleContext: String = "") -> [AnalyzedToken] {
        let normalizedSource = normalizeText(text)
        guard !normalizedSource.isEmpty else { return [] }

        let lowerTitle = normalizeText(titleContext).lowercased()
        let signals = extractSemanticSignals(in: normalizedSource)
        var results: [AnalyzedToken] = []

        // 1. 特殊記号を含む技術用語 (`C++`, `C#`, `OAuth2`, `sqlite-vec`, `Qwen3-ASR`, バージョン番号, 数値+単位) を先行抽出して保護
        let lowerSource = normalizedSource.lowercased()
        for entry in Self.protectedTechPatterns {
            if lowerSource.contains(entry.pattern) {
                results.append(AnalyzedToken(
                    surface: entry.canonical,
                    normalized: entry.canonical,
                    tier: .high,
                    isNegatedContext: signals.hasNegativeRejection,
                    isTechnicalOrProper: true
                ))
            }
        }

        // 数値＋単位やバージョン表記（例: `30%`, `10秒`, `5件`, `v1.2`, `16gb`, `200ms`）を保護抽出（§6.3 #4, #6）
        if let regex = try? NSRegularExpression(pattern: #"(?:v\d+(?:\.\d+)+|\d+(?:\.\d+)?(?:%|％|秒|ms|ミリ秒|分|時間|日|件|回|人|gb|mb|kb|倍|次元))"#, options: [.caseInsensitive]) {
            let nsRange = NSRange(normalizedSource.startIndex..<normalizedSource.endIndex, in: normalizedSource)
            for match in regex.matches(in: normalizedSource, range: nsRange) {
                if let range = Range(match.range, in: normalizedSource) {
                    let tokenStr = String(normalizedSource[range]).lowercased()
                    results.append(AnalyzedToken(
                        surface: tokenStr,
                        normalized: tokenStr,
                        tier: .medium,
                        isNegatedContext: false,
                        isTechnicalOrProper: true
                    ))
                }
            }
        }

        // 英数字・ハイフン・プラス識別子（`C++`, `OAuth2`, `SwiftUI`, `FTS5`, `BM25`, `RRF` 等）を正規表現で確実に抽出
        if let asciiRegex = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9_\-\+\#\.]{1,30}"#) {
            let nsRange = NSRange(normalizedSource.startIndex..<normalizedSource.endIndex, in: normalizedSource)
            for match in asciiRegex.matches(in: normalizedSource, range: nsRange) {
                if let range = Range(match.range, in: normalizedSource) {
                    let raw = String(normalizedSource[range]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    let low = raw.lowercased()
                    guard low.count >= 2, !Self.stopFunctionWords.contains(low) else { continue }
                    results.append(AnalyzedToken(
                        surface: raw,
                        normalized: low,
                        tier: .high,
                        isNegatedContext: signals.hasNegativeRejection,
                        isTechnicalOrProper: true
                    ))
                }
            }
        }

        // 2. Apple NaturalLanguage `NLTagger` + `NLTokenizer` による日本語・多言語トークン分割と品詞判定
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = normalizedSource
        let fullRange = normalizedSource.startIndex..<normalizedSource.endIndex

        tagger.enumerateTags(
            in: fullRange,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, tokenRange in
            let surface = String(normalizedSource[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !surface.isEmpty else { return true }
            let low = surface.lowercased()

            // フィラー判定
            if Self.fillerWords.contains(low) {
                results.append(AnalyzedToken(surface: surface, normalized: low, tier: .low))
                return true
            }
            // 1文字のひらがな助詞・機能語はスキップまたは低重要度
            if Self.stopFunctionWords.contains(low) || (low.count == 1 && Self.isAllHiragana(low)) {
                return true
            }

            let isInTitle = !lowerTitle.isEmpty && lowerTitle.contains(low)
            let isProperOrTech = Self.looksLikeProperOrTechTerm(surface) || tag == .personalName || tag == .placeName || tag == .organizationName

            let tier: TokenImportanceTier
            if isProperOrTech || isInTitle {
                tier = .high
            } else if tag == .noun || tag == .verb || tag == .adjective || tag == .adverb || tag == .number {
                tier = .medium
            } else if tag == .particle || tag == .conjunction || tag == .preposition || tag == .determiner {
                tier = .low
            } else {
                tier = low.count >= 2 ? .medium : .low
            }

            if tier != .low {
                results.append(AnalyzedToken(
                    surface: surface,
                    normalized: low,
                    tier: tier,
                    isNegatedContext: signals.hasNegativeRejection,
                    isTechnicalOrProper: isProperOrTech
                ))

                // 漢字複合語（3文字以上）の場合、2文字検索語（「田中」「認証」「会議」「障害」等）でのヒット漏れを防ぐため2文字部分語も補助展開
                if Self.isAllKanji(low) && low.count >= 3 && low.count <= 8 {
                    let chars = Array(low)
                    for i in 0..<(chars.count - 1) {
                        let bigram = String([chars[i], chars[i + 1]])
                        results.append(AnalyzedToken(
                            surface: bigram,
                            normalized: bigram,
                            tier: .medium,
                            isNegatedContext: signals.hasNegativeRejection,
                            isTechnicalOrProper: false
                        ))
                    }
                }
            }
            return true
        }

        // 3. 人名パターン（「〇〇さん」「〇〇氏」）の明示的抽出（§1.1「田中さんが提案した機能」対応）
        if let personRegex = try? NSRegularExpression(pattern: #"([一-龯々ヶ]{1,5})(?:さん|氏|様|部長|リーダー)"#) {
            let nsRange = NSRange(normalizedSource.startIndex..<normalizedSource.endIndex, in: normalizedSource)
            for match in personRegex.matches(in: normalizedSource, range: nsRange) {
                if match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: normalizedSource) {
                    let name = String(normalizedSource[r])
                    results.append(AnalyzedToken(
                        surface: name,
                        normalized: name.lowercased(),
                        tier: .high,
                        isNegatedContext: false,
                        isTechnicalOrProper: true
                    ))
                }
            }
        }

        // 4. 意味保護マーカートークンを追加（§6.3）
        for marker in signals.semanticMarkerTokens {
            results.append(AnalyzedToken(
                surface: marker,
                normalized: marker,
                tier: .medium,
                isNegatedContext: signals.hasNegativeRejection,
                isTechnicalOrProper: false
            ))
        }

        return results
    }

    /// §4.5, §7.1 FTS5 登録用の空白区切り正規化トークン列を生成する
    public func buildFTS5TokenString(for text: String, titleContext: String = "") -> String {
        let analyzed = analyzeTokens(in: text, titleContext: titleContext)
        var orderedUnique: [String] = []
        var seen: Set<String> = []

        for token in analyzed where token.tier != .low {
            let norm = token.normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !norm.isEmpty else { continue }
            if !seen.contains(norm) {
                seen.insert(norm)
                orderedUnique.append(norm)
            }
            // 表記ゆれ同義語展開（§6.2, §16.1）
            if let synonyms = Self.synonymNormalizationMap[norm] {
                for syn in synonyms where !seen.contains(syn) {
                    seen.insert(syn)
                    orderedUnique.append(syn)
                }
            }
        }

        // 万一形態素解析結果が空になった場合は原文の空白・句読点分割へフォールバック（§14.1）
        if orderedUnique.isEmpty {
            let fallback = normalizeText(text)
                .lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            return fallback.joined(separator: " ")
        }

        return orderedUnique.joined(separator: " ")
    }

    /// トークン数の概算（日本語は1文字≒0.7トークンまたは形態素数ベース、英語は単語数ベース）
    public func estimateTokenCount(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var wordCount = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            wordCount += 1
            return true
        }
        return max(wordCount, text.count / 2)
    }

    // MARK: - Character Helpers

    private static func isAllHiragana(_ str: String) -> Bool {
        guard !str.isEmpty else { return false }
        return str.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) }
    }

    private static func isAllKanji(_ str: String) -> Bool {
        guard !str.isEmpty else { return false }
        return str.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || $0.value == 0x3005 }
    }

    private static func looksLikeProperOrTechTerm(_ str: String) -> Bool {
        guard !str.isEmpty else { return false }
        // 英字を含む、またはカタカナ2文字以上、または大文字始まり
        let hasASCIIAlpha = str.unicodeScalars.contains { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }
        if hasASCIIAlpha { return true }
        let isKatakana = str.count >= 2 && str.unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) }
        return isKatakana
    }
}

// MARK: - §6.4 重要キーワード抽出 (`KeywordExtractor`)

public protocol KeywordExtracting: Sendable {
    func extractDocumentKeywords(from text: String, title: String, minCount: Int, maxCount: Int) -> [String]
    func extractChunkKeywords(from chunkText: String, title: String, minCount: Int, maxCount: Int) -> [String]
}

/// §6.4 重要度（高・中・低）と出現頻度・位置に基づいた重要キーワード抽出器
/// - 文書単位：5〜15語程度
/// - チャンク単位：3〜8語程度
public struct ImportantKeywordExtractor: KeywordExtracting {
    private let analyzer: any TextAnalyzing

    public init(analyzer: any TextAnalyzing = NaturalLanguageTextAnalyzer()) {
        self.analyzer = analyzer
    }

    public func extractDocumentKeywords(
        from text: String,
        title: String,
        minCount: Int = 5,
        maxCount: Int = 15
    ) -> [String] {
        extractRankedKeywords(from: "\(title)\n\(text)", title: title, minCount: minCount, maxCount: maxCount)
    }

    public func extractChunkKeywords(
        from chunkText: String,
        title: String,
        minCount: Int = 3,
        maxCount: Int = 8
    ) -> [String] {
        extractRankedKeywords(from: chunkText, title: title, minCount: minCount, maxCount: maxCount)
    }

    private func extractRankedKeywords(
        from text: String,
        title: String,
        minCount: Int,
        maxCount: Int
    ) -> [String] {
        let tokens = analyzer.analyzeTokens(in: text, titleContext: title)
        let lowerTitle = analyzer.normalizeText(title).lowercased()

        var scores: [String: Double] = [:]
        var firstPosition: [String: Int] = [:]

        for (idx, token) in tokens.enumerated() {
            guard token.tier != .low else { continue }
            let key = token.normalized
            // 内部マーカー (`__...`) はキーワード表示リストからは除外し、実体語と日本語状態タグを優先
            guard !key.hasPrefix("__"), key.count >= 2 || token.isTechnicalOrProper else { continue }

            if firstPosition[key] == nil {
                firstPosition[key] = idx
            }

            var weight: Double = switch token.tier {
            case .high: 3.5
            case .medium: 1.6
            case .low: 0.0
            }

            if token.isTechnicalOrProper {
                weight += 1.5
            }
            if !lowerTitle.isEmpty && lowerTitle.contains(key) {
                weight += 2.0
            }
            // 決定・否定・比較・規模などの重要意味語にボーナス
            if key.contains("決定") || key.contains("採用") || key.contains("見送") || key.contains("提案") ||
               key.contains("明") || key.contains("暗") || key.contains("重大") || key.contains("軽微") ||
               key.contains("予定") || key.contains("完了") {
                weight += 1.8
            }

            scores[key, default: 0.0] += weight
        }

        let sorted = scores.keys.sorted { a, b in
            let sa = scores[a] ?? 0
            let sb = scores[b] ?? 0
            if abs(sa - sb) > 0.01 { return sa > sb }
            return (firstPosition[a] ?? Int.max) < (firstPosition[b] ?? Int.max)
        }

        return Array(sorted.prefix(max(minCount, maxCount)))
    }
}

// MARK: - §5.2 文書全体要約生成 & §5.3 意味単位チャンク分割 (`Chunker`)

/// チャンク分割の計画結果
public struct PlannedDocumentChunk: Sendable, Equatable {
    public let chunkIndex: Int
    public let text: String
    public let startOffset: Int
    public let endOffset: Int
    public let startTimeMs: Int64?
    public let endTimeMs: Int64?
    public let contentHash: String
}

/// §5.3 チャンク分割と §5.2 文書全体要約生成を担うモジュール
public struct SemanticDocumentChunker: Sendable {
    private let analyzer: any TextAnalyzing

    public init(analyzer: any TextAnalyzing = NaturalLanguageTextAnalyzer()) {
        self.analyzer = analyzer
    }

    /// §5.2 文書全体要約の生成
    /// - 主な話題、議論された技術・機能・製品、主な検討内容、決定事項または結論、重要な固有名詞を含める
    /// - 検討しただけの内容を決定事項として書かない／否定された案を採用案として書かない／未決定事項を確定事項として書かない
    public func generateStructuredDocumentSummary(title: String, rawText: String) -> String {
        let normalized = analyzer.normalizeText(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return title }

        let sentences = Self.splitIntoSentencesWithOffsets(text: normalized).map(\.text)
        guard !sentences.isEmpty else { return String(normalized.prefix(300)) }

        var topicSentences: [String] = []
        var decisionSentences: [String] = []
        var proposalOrPendingSentences: [String] = []
        var rejectedSentences: [String] = []

        for s in sentences {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let sig = analyzer.extractSemanticSignals(in: trimmed)
            if sig.hasNegativeRejection {
                rejectedSentences.append(trimmed)
            } else if sig.hasConfirmedDecision {
                decisionSentences.append(trimmed)
            } else if sig.hasProposalOrConsideration || sig.hasPlannedStatus {
                proposalOrPendingSentences.append(trimmed)
            } else if topicSentences.count < 2 {
                topicSentences.append(trimmed)
            }
        }

        var parts: [String] = []
        if !title.isEmpty {
            parts.append("【主題】\(title)")
        }
        if !topicSentences.isEmpty {
            parts.append("【概要】" + topicSentences.prefix(2).joined(separator: " "))
        }
        if !decisionSentences.isEmpty {
            parts.append("【決定・確定事項】" + decisionSentences.prefix(2).joined(separator: " "))
        }
        if !proposalOrPendingSentences.isEmpty {
            parts.append("【提案・検討・予定事項】" + proposalOrPendingSentences.prefix(2).joined(separator: " "))
        }
        if !rejectedSentences.isEmpty {
            parts.append("【不採用・見送り事項】" + rejectedSentences.prefix(2).joined(separator: " "))
        }

        let combined = parts.joined(separator: " / ")
        if combined.isEmpty {
            return String(normalized.prefix(320))
        }
        return String(combined.prefix(600))
    }

    /// §5.3 チャンク分割ルール
    /// - 優先順位: 1. 見出し・セクション → 2. 話題の切り替わり → 3. 段落 → 4. 文の区切り → 5. トークン数上限
    /// - 目標チャンクサイズ: 250〜400トークン（見出しセクションが明確に分かれている場合はセクション境界も尊重）
    /// - オーバーラップ: 0〜10%
    /// - マルチバイト文字でも正確に元文書へジャンプできるよう、原文 `rawText` 上の `Character` オフセット (`startOffset`, `endOffset`) を厳密に保持する
    public func splitIntoChunks(
        rawText: String,
        targetMinTokens: Int = 250,
        targetMaxTokens: Int = 400,
        overlapRatio: Double = 0.08
    ) -> [PlannedDocumentChunk] {
        guard !rawText.isEmpty else { return [] }

        // 原文を行・文スパン（原文の startOffset / endOffset 付き）に分解
        let segments = Self.splitIntoSemanticBlocksWithOffsets(rawText: rawText)
        guard !segments.isEmpty else { return [] }

        var planned: [PlannedDocumentChunk] = []
        var currentBlocks: [TextSpanBlock] = []
        var currentTokens = 0

        let flushCurrentBlocks = { (blocks: [TextSpanBlock]) in
            guard let first = blocks.first, let last = blocks.last else { return }
            let startIdx = rawText.index(rawText.startIndex, offsetBy: first.startOffset)
            let endIdx = rawText.index(rawText.startIndex, offsetBy: last.endOffset)
            let exactSlice = String(rawText[startIdx..<endIdx])
            guard !exactSlice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            let (startMs, endMs) = Self.extractTimestampRangeMs(from: exactSlice)
            let hash = Self.sha256Hex(of: exactSlice)
            planned.append(PlannedDocumentChunk(
                chunkIndex: planned.count,
                text: exactSlice,
                startOffset: first.startOffset,
                endOffset: last.endOffset,
                startTimeMs: startMs,
                endTimeMs: endMs,
                contentHash: hash
            ))
        }

        for block in segments {
            let blockTokens = max(1, analyzer.estimateTokenCount(for: block.text))

            // 1. 見出し・大セクション切り替え（§5.3 優先順位1）、またはトークン数上限到達でチャンクを確定
            let shouldSplitByHeading = block.isHeadingOrTopicBoundary && !currentBlocks.isEmpty
            let shouldSplitByTokenLimit = (currentTokens + blockTokens > targetMaxTokens) && !currentBlocks.isEmpty

            if shouldSplitByHeading || shouldSplitByTokenLimit {
                flushCurrentBlocks(currentBlocks)

                // オーバーラップ（0〜10%）の付与：直前チャンクの末尾ブロックが短い文であれば引き継ぐ
                let maxOverlapTokens = Int(Double(targetMaxTokens) * max(0.0, min(0.10, overlapRatio)))
                if !block.isHeadingOrTopicBoundary,
                   maxOverlapTokens > 0,
                   let tailBlock = currentBlocks.last,
                   analyzer.estimateTokenCount(for: tailBlock.text) <= maxOverlapTokens {
                    currentBlocks = [tailBlock]
                    currentTokens = analyzer.estimateTokenCount(for: tailBlock.text)
                } else {
                    currentBlocks = []
                    currentTokens = 0
                }
            }

            // 単一ブロックが極端に長い場合（上限の1.5倍超）は文・文字単位で安全に分割
            if blockTokens > targetMaxTokens * 2 && currentBlocks.isEmpty {
                let subSpans = Self.forceSplitLongSpan(rawText: rawText, span: block, maxChars: targetMaxTokens * 2)
                for sub in subSpans {
                    flushCurrentBlocks([sub])
                }
            } else {
                currentBlocks.append(block)
                currentTokens += blockTokens
            }
        }

        if !currentBlocks.isEmpty {
            flushCurrentBlocks(currentBlocks)
        }

        return planned
    }

    // MARK: - Internal Span Helpers

    private struct TextSpanBlock {
        let text: String
        let startOffset: Int
        let endOffset: Int
        let isHeadingOrTopicBoundary: Bool
    }

    private static func splitIntoSemanticBlocksWithOffsets(rawText: String) -> [TextSpanBlock] {
        var blocks: [TextSpanBlock] = []
        var lineStartOffset = 0
        let chars = Array(rawText)
        let totalCount = chars.count
        var i = 0

        while i < totalCount {
            // 改行まで1行を読み取る
            while i < totalCount && chars[i] != "\n" {
                i += 1
            }
            // 改行文字も含める
            if i < totalCount && chars[i] == "\n" {
                i += 1
            }

            let lineSlice = String(chars[lineStartOffset..<i])
            let trimmed = lineSlice.trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmed.isEmpty {
                let isHeading =
                    trimmed.hasPrefix("#") ||
                    trimmed.hasPrefix("■") ||
                    trimmed.hasPrefix("◆") ||
                    (trimmed.hasPrefix("【") && trimmed.contains("】")) ||
                    trimmed.hasPrefix("議題:") ||
                    trimmed.hasPrefix("議題：") ||
                    trimmed.hasPrefix("テーマ:") ||
                    trimmed.hasPrefix("テーマ：")

                blocks.append(TextSpanBlock(
                    text: lineSlice,
                    startOffset: lineStartOffset,
                    endOffset: i,
                    isHeadingOrTopicBoundary: isHeading
                ))
            }
            lineStartOffset = i
        }

        return blocks
    }

    private static func splitIntoSentencesWithOffsets(text: String) -> [(text: String, start: Int, end: Int)] {
        var result: [(String, Int, Int)] = []
        let chars = Array(text)
        var start = 0
        for idx in chars.indices {
            let c = chars[idx]
            if c == "。" || c == "\n" || c == "！" || c == "？" {
                let slice = String(chars[start...idx])
                if !slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append((slice, start, idx + 1))
                }
                start = idx + 1
            }
        }
        if start < chars.count {
            let tail = String(chars[start..<chars.count])
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append((tail, start, chars.count))
            }
        }
        return result
    }

    private static func forceSplitLongSpan(rawText: String, span: TextSpanBlock, maxChars: Int) -> [TextSpanBlock] {
        let chars = Array(rawText)
        var subBlocks: [TextSpanBlock] = []
        var cursor = span.startOffset
        let step = max(120, maxChars)
        while cursor < span.endOffset {
            let next = min(span.endOffset, cursor + step)
            let text = String(chars[cursor..<next])
            subBlocks.append(TextSpanBlock(
                text: text,
                startOffset: cursor,
                endOffset: next,
                isHeadingOrTopicBoundary: cursor == span.startOffset && span.isHeadingOrTopicBoundary
            ))
            cursor = next
        }
        return subBlocks
    }

    /// 議事録チャンク内のタイムスタンプ表記（例: `[01:23]`, `00:15 - 00:45`, `[00:10-00:25]`）から開始・終了ミリ秒を抽出する
    public static func extractTimestampRangeMs(from text: String) -> (Int64?, Int64?) {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?"#) else {
            return (nil, nil)
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return (nil, nil) }

        var timesMs: [Int64] = []
        for match in matches {
            guard match.numberOfRanges >= 3,
                  let minR = Range(match.range(at: 1), in: text),
                  let secR = Range(match.range(at: 2), in: text),
                  let mins = Int64(text[minR]),
                  let secs = Int64(text[secR]) else { continue }
            var totalMs = (mins * 60 + secs) * 1000
            if match.numberOfRanges >= 4,
               match.range(at: 3).location != NSNotFound,
               let msR = Range(match.range(at: 3), in: text),
               let msVal = Int64(text[msR]) {
                totalMs += msVal
            }
            timesMs.append(totalMs)
        }

        guard let first = timesMs.first else { return (nil, nil) }
        let last = timesMs.count >= 2 ? timesMs.last : first
        return (first, last)
    }

    public static func sha256Hex(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
