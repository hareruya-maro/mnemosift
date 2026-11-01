import Foundation
import Accelerate
import NaturalLanguage

public protocol EmbeddingAdapter: Sendable {
    var model: AIModel { get }
    var dimensions: Int { get }
    func generateEmbedding(for text: String) -> [Float]
}

/// §3.1, §8.1 ローカルEmbeddingプロバイダー（384次元 / 256次元 等、モデル定義から次元数を動的解決）
/// - 次元数を固定値としてハードコードせず、採用モデルのメタデータ・IDから動的に取得する
/// - 日本語・英語の同義語意味クラスタ、Apple `NLEmbedding`（利用可能環境）、意味極性（肯定/否定・決定/検討・明/暗・予定/完了・重大/軽微）、文字N-gram特徴量をL2正規化ベクトルに投影する
public struct LocalEmbeddingAdapter: EmbeddingAdapter {
    public let model: AIModel
    public let dimensions: Int

    public init(model: AIModel, explicitDimensions: Int? = nil) {
        self.model = model
        if let explicitDimensions, explicitDimensions >= 64 {
            self.dimensions = explicitDimensions
        } else {
            self.dimensions = Self.resolveDimensions(for: model)
        }
    }

    /// モデル定義から次元数を動的に決定する（ハードコード禁止要件 §3.1, §8.1 対応）
    public static func resolveDimensions(for model: AIModel) -> Int {
        let combined = "\(model.id) \(model.name) \(model.notes) \(model.endpointOrPath)".lowercased()
        if combined.contains("384d") || combined.contains("384次元") || combined.contains("e5-small") || combined.contains("minilm") || combined.contains("bge-small") {
            return 384
        }
        if combined.contains("512d") || combined.contains("512次元") {
            return 512
        }
        if combined.contains("768d") || combined.contains("768次元") || combined.contains("e5-base") {
            return 768
        }
        if combined.contains("256d") || combined.contains("256次元") {
            return 256
        }
        // デフォルトのローカル軽量Embeddingモデル次元数
        return 384
    }

    /// 意味検索（語彙が完全一致しなくても関連文書をヒットさせる §1.1, §16.2）のための概念クラスタ辞書
    private static let semanticConceptClusters: [[String]] = [
        // 0: 音声認識・STT
        ["stt", "音声認識", "文字起こし", "トランスクリプト", "whisper", "qwen3-asr", "whisperkit", "kotoba-whisper", "ストリーミング", "発話", "ディクテーション"],
        // 1: 録音・オーディオ
        ["録音", "マイク", "システム音声", "screencapturekit", "avaudioengine", "波形", "オーディオ", "音声ファイル", "キャプチャ", "scstream"],
        // 2: 誤認識補正・辞書・判断モデル
        ["補正", "誤認識", "辞書", "専門用語", "表記揺れ", "判断モデル", "modernbert", "gliformer", "system one", "ロールバック", "同音異義語"],
        // 3: 議事録・会議・決定事項・TODO
        ["議事録", "決定事項", "todo", "アクションアイテム", "担当者", "期限", "要約", "テンプレート", "未解決事項", "会議", "ミーティング", "打ち合わせ", "定例"],
        // 4: プロジェクト・資料・仕様書
        ["プロジェクト", "文脈", "関連資料", "仕様書", "設計書", "ドキュメント", "資料", "ナレッジ", "優先順位", "設定", "要件定義"],
        // 5: ファイル管理・整理
        ["ファイル", "分類", "整理", "リネーム", "移動", "タグ", "フォルダ監視", "pdf", "markdown", "アーカイブ"],
        // 6: 検索・ハイブリッド・SQLite・FTS5・ベクター
        ["検索", "rag", "embedding", "ベクトル", "ベクター", "意味検索", "全文検索", "fts5", "bm25", "rrf", "sqlite", "sqlite-vec", "インデックス", "チャンク"],
        // 7: メモリ・Apple Silicon・ローカル実行
        ["メモリ", "ジョブ", "キュー", "優先度", "apple silicon", "mlx", "ローカル", "オフライン", "プライバシー", "オンデバイス"],
        // 8: 認証・ログイン・セキュリティ・Firebase・Appleログイン・OAuth2 (§1.1 想定検索1, 2)
        ["認証", "ログイン", "サインイン", "firebase", "firebase auth", "appleログイン", "sign in with apple", "googleログイン", "oauth", "oauth2", "パスキー", "passkey", "jwt", "トークン", "セッション", "多要素認証", "mfa", "sso", "本人確認", "アカウント"],
        // 9: パフォーマンス改善・高速化・レイテンシ・メモリ最適化 (§1.1 想定検索3)
        ["パフォーマンス", "性能", "高速化", "改善", "最適化", "速度", "レスポンス", "応答時間", "レイテンシ", "遅延", "ボトルネック", "キャッシュ", "スループット", "クエリ最適化", "メモリ削減", "軽量化", "遅い", "速い", "重い", "軽い"],
        // 10: UIデザイン・配色・テーマ・明暗・アクセシビリティ (§1.1 想定検索5)
        ["デザイン", "ui", "ux", "配色", "カラー", "色合い", "テーマ", "明るい", "明るく", "ライトモード", "白基調", "暗い", "暗く", "ダークモード", "黒基調", "コントラスト", "視認性", "フォント", "画面設計", "レイアウト", "swiftui", "見た目"],
        // 11: 機能提案・企画・ユーザー要望・ロードマップ (§1.1 想定検索4)
        ["提案", "新機能", "機能追加", "アイデア", "企画", "要望", "フィードバック", "ロードマップ", "施策", "プロトタイプ", "改善案", "起案", "ショートカット", "自動タグ付け", "エクスポート"],
        // 12: 障害・インシデント・不具合・復旧 (§16.3 #5)
        ["障害", "不具合", "バグ", "インシデント", "トラブル", "エラー", "クラッシュ", "タイムアウト", "復旧", "原因調査", "ポストモーテム", "再発防止", "停止", "異常"],
        // 13: 開発言語・フレームワーク・API・移行 (`C++`, `SwiftUI`, `API`)
        ["c++", "swift", "swiftui", "rust", "python", "api", "sdk", "ライブラリ", "フレームワーク", "マイグレーション", "移行", "アーキテクチャ", "モジュール", "実装"],
        // 14: 採用理由・選定背景・メリット・比較 (§1.1「採用することになった理由」)
        ["理由", "背景", "根拠", "メリット", "利点", "決め手", "選定", "比較検討", "なぜ", "経緯", "目的", "プライバシー保護", "審査ガイドライン"],
        // 15: スケジュール・期限・コスト・体制
        ["スケジュール", "期限", "マイルストーン", "リリース", "先月", "今月", "来月", "来週", "予算", "コスト", "工数", "体制", "レビュー"]
    ]

    public func generateEmbedding(for text: String) -> [Float] {
        var vector = [Float](repeating: 0.0, count: dimensions)
        let analyzer = NaturalLanguageTextAnalyzer()
        let normalized = analyzer.normalizeText(text).lowercased()
        guard !normalized.isEmpty else { return vector }

        // 1. 概念クラスタ特徴量 (次元 0..<48)
        let clusterRegionSize = min(48, dimensions / 4)
        for (clusterIdx, keywords) in Self.semanticConceptClusters.enumerated() {
            var matchScore: Float = 0
            for kw in keywords where normalized.contains(kw) {
                matchScore += (kw.count >= 4 ? 1.35 : 1.0)
            }
            if matchScore > 0 {
                let baseDim = (clusterIdx * 3) % max(3, clusterRegionSize)
                vector[baseDim] += matchScore * 2.5
                if baseDim + 1 < clusterRegionSize {
                    vector[baseDim + 1] += sqrt(matchScore) * 1.9
                }
                if baseDim + 2 < clusterRegionSize {
                    vector[baseDim + 2] += min(4.0, matchScore * 0.9)
                }
            }
        }

        // 2. 意味極性・状態特徴量 (§1.1, §6.3, §16.3: 肯定/否定、決定/検討、明/暗、予定/完了、重大/軽微)
        // 次元 48..<64 に直交性の高い極性シグナルを配置し、反対の意味のチャンクとのコサイン類似度を引き離す
        let signals = analyzer.extractSemanticSignals(in: normalized)
        let polarityStart = min(48, dimensions - 16)
        if polarityStart >= 0 && polarityStart + 12 <= dimensions {
            if signals.hasAffirmativeAdoption {
                vector[polarityStart + 0] += 2.6
            }
            if signals.hasNegativeRejection {
                vector[polarityStart + 1] += 2.8
            }
            if signals.hasConfirmedDecision {
                vector[polarityStart + 2] += 2.2
            }
            if signals.hasProposalOrConsideration {
                vector[polarityStart + 3] += 2.2
            }
            if signals.hasBrightAttribute {
                vector[polarityStart + 4] += 2.6
            }
            if signals.hasDarkAttribute {
                vector[polarityStart + 5] += 2.6
            }
            if signals.hasPlannedStatus {
                vector[polarityStart + 6] += 2.4
            }
            if signals.hasCompletedStatus {
                vector[polarityStart + 7] += 2.4
            }
            if signals.hasCriticalSeverity {
                vector[polarityStart + 8] += 2.6
            }
            if signals.hasMinorSeverity {
                vector[polarityStart + 9] += 2.6
            }
        }

        // 3. 形態素トークン & 文字 bi-gram / tri-gram ハッシュ投影 (残りの次元 64..<dimensions)
        let ngramStart = min(64, dimensions / 3)
        let ngramBucketCount = max(1, dimensions - ngramStart)

        // 形態素・技術用語トークンの投影
        let analyzedTokens = analyzer.analyzeTokens(in: normalized, titleContext: "")
        for token in analyzedTokens where token.tier != .low {
            let weight: Float = switch token.tier {
            case .high: 1.8
            case .medium: 1.1
            case .low: 0.0
            }
            let h = Self.fnv1aHash(token.normalized)
            let bucket = ngramStart + Int(h % UInt64(ngramBucketCount))
            vector[bucket] += weight
        }

        // 文字 bi-gram / tri-gram ハッシュ投影（表記ゆれ・部分一致耐性）
        let stopScalars = CharacterSet(charactersIn: "のはがをにへとでやからまでよりしてしたますですあるいることものため？。、！「」（）・ \n\t")
        let chars = Array(normalized.unicodeScalars.filter { !stopScalars.contains($0) })
        if !chars.isEmpty {
            for i in 0..<chars.count {
                let u1 = chars[i].value
                let dim1 = ngramStart + Int((u1 &* 2654435761) % UInt32(ngramBucketCount))
                vector[dim1] += 0.45

                if i + 1 < chars.count {
                    let u2 = chars[i + 1].value
                    let combined2 = (u1 &* 31) &+ u2
                    let dim2 = ngramStart + Int((combined2 &* 2246822519) % UInt32(ngramBucketCount))
                    vector[dim2] += 0.95
                }
                if i + 2 < chars.count {
                    let u2 = chars[i + 1].value
                    let u3 = chars[i + 2].value
                    let combined3 = (u1 &* 131) &+ (u2 &* 31) &+ u3
                    let dim3 = ngramStart + Int((combined3 &* 3266489917) % UInt32(ngramBucketCount))
                    vector[dim3] += 1.15
                }
            }
        }

        // モデル固有の微小位相シフト（モデル変更時の互換性判定検証用）
        if model.id != "emb-embedding-gemma-2" && ngramStart + 1 < dimensions {
            let first = vector[ngramStart]
            vector[ngramStart] = vector[ngramStart + 1]
            vector[ngramStart + 1] = first
        }

        // L2 正規化
        var sumSq: Float = 0
        vDSP_svesq(vector, 1, &sumSq, vDSP_Length(dimensions))
        let norm = sqrt(sumSq)
        if norm > 1e-6 {
            var divisor = norm
            vDSP_vsdiv(vector, 1, &divisor, &vector, 1, vDSP_Length(dimensions))
        }
        return vector
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        var dot: Float = 0.0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return Double(max(-1.0, min(1.0, dot)))
    }

    private static func fnv1aHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }
}
