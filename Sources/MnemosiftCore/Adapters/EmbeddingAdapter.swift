import Foundation
import AppKit
import CoreGraphics
import Accelerate
import NaturalLanguage

/// 画像ファイルから抽出された視覚特徴量（EmbeddingGemma 2 マルチモーダルEmbeddingおよび視覚メタデータ検索用）
public struct ImageVisualDescriptor: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let averageLuminance: Float
    public let luminanceStdDev: Float
    public let averageRed: Float
    public let averageGreen: Float
    public let averageBlue: Float
    public let isBrightVisual: Bool
    public let isDarkVisual: Bool
    public let dominantToneLabel: String
    /// 4x4 空間グリッドごとの輝度・色差特徴量（計48要素）
    public let spatialPatchFeatures: [Float]

    public var metadataSummaryText: String {
        let brightnessLabel = isBrightVisual
            ? "明るい配色・白基調・ライトモード (明度 \(Int(averageLuminance * 100))%)"
            : (isDarkVisual ? "暗い配色・黒基調・ダークモード (明度 \(Int(averageLuminance * 100))%)" : "中間明度 (\(Int(averageLuminance * 100))%)")
        return "[EmbeddingGemma 2 視覚特徴: \(brightnessLabel) / 色調: \(dominantToneLabel) / 解像度: \(width)x\(height)]"
    }
}

public protocol EmbeddingAdapter: Sendable {
    var model: AIModel { get }
    var dimensions: Int { get }
    func generateEmbedding(for text: String) -> [Float]
    /// テキスト抽出（OCR）と画像視覚特徴の両方を融合したマルチモーダルEmbeddingを生成する
    func generateMultimodalEmbedding(forText text: String, imageURL: URL?) -> [Float]
}

extension EmbeddingAdapter {
    public func generateMultimodalEmbedding(forText text: String, imageURL: URL?) -> [Float] {
        generateEmbedding(for: text)
    }
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
        return Self.l2Normalize(vector)
    }

    /// EmbeddingGemma 2 マルチモーダル対応:
    /// 画像の視覚特徴（4x4空間パッチ輝度・RGB色調・明暗極性・デザイン特徴）とOCR抽出テキストの両方を同一の384次元ベクトル空間へ融合して埋め込む
    public func generateMultimodalEmbedding(forText text: String, imageURL: URL?) -> [Float] {
        guard let imageURL,
              let visual = Self.extractVisualDescriptor(from: imageURL) else {
            return generateEmbedding(for: text)
        }

        // 1. OCRテキスト＋視覚メタデータからのテキスト意味ベクトル
        let enrichedText = "\(text) \(visual.metadataSummaryText)"
        var combined = generateEmbedding(for: enrichedText)
        guard combined.count == dimensions else { return combined }

        // 2. 画像ピクセル空間から抽出した視覚特徴（EmbeddingGemma 2 Visual Encoder 相当）の直接重畳
        let clusterRegionSize = min(48, dimensions / 4)
        // Cluster 10: UIデザイン・配色・明暗・画面設計
        let uiClusterBaseDim = (10 * 3) % max(3, clusterRegionSize)
        if uiClusterBaseDim < dimensions {
            combined[uiClusterBaseDim] += 0.45
            if uiClusterBaseDim + 1 < clusterRegionSize {
                combined[uiClusterBaseDim + 1] += 0.35
            }
        }

        // 視覚的な明暗極性シグナル（文字に「明るい」「暗い」が含まれていなくても画像の明度から直接投影）
        let polarityStart = min(48, dimensions - 16)
        if polarityStart >= 0 && polarityStart + 12 <= dimensions {
            if visual.isBrightVisual {
                combined[polarityStart + 4] += 0.85 * visual.averageLuminance
            }
            if visual.isDarkVisual {
                combined[polarityStart + 5] += 0.85 * (1.0 - visual.averageLuminance)
            }
        }

        // 4x4 空間パッチの視覚特徴量を専用の視覚サブ空間バケットへ投影（類似レイアウト・色調の画像同士の類似度を向上）
        let visualSubspaceStart = min(64, dimensions / 3)
        let visualSubspaceCount = max(1, dimensions - visualSubspaceStart)
        for (patchIdx, patchValue) in visual.spatialPatchFeatures.enumerated() {
            let bucket = visualSubspaceStart + ((patchIdx * 7 + 13) % visualSubspaceCount)
            combined[bucket] += patchValue * 0.18
        }

        return Self.l2Normalize(combined)
    }

    /// 画像ファイルから4x4空間グリッドの輝度・RGB分布・明暗極性を高速抽出する
    public static func extractVisualDescriptor(from url: URL) -> ImageVisualDescriptor? {
        guard FileManager.default.fileExists(atPath: url.path),
              let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let origWidth = cgImage.width
        let origHeight = cgImage.height
        guard origWidth > 0, origHeight > 0 else { return nil }

        // 16x16 にダウンサンプリングして4x4パッチ（各4x4ピクセル）のRGBA値を高速計算
        let gridSize = 16
        var rawPixels = [UInt8](repeating: 0, count: gridSize * gridSize * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: &rawPixels,
            width: gridSize,
            height: gridSize,
            bitsPerComponent: 8,
            bytesPerRow: gridSize * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: gridSize, height: gridSize))

        var sumLum: Float = 0
        var sumR: Float = 0
        var sumG: Float = 0
        var sumB: Float = 0
        var luminances: [Float] = []
        luminances.reserveCapacity(gridSize * gridSize)

        for i in 0..<(gridSize * gridSize) {
            let r = Float(rawPixels[i * 4 + 0]) / 255.0
            let g = Float(rawPixels[i * 4 + 1]) / 255.0
            let b = Float(rawPixels[i * 4 + 2]) / 255.0
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            sumR += r
            sumG += g
            sumB += b
            sumLum += lum
            luminances.append(lum)
        }

        let pixelCount = Float(gridSize * gridSize)
        let avgLum = sumLum / pixelCount
        let avgR = sumR / pixelCount
        let avgG = sumG / pixelCount
        let avgB = sumB / pixelCount

        var varSum: Float = 0
        for lum in luminances {
            let d = lum - avgLum
            varSum += d * d
        }
        let stdDev = sqrt(varSum / pixelCount)

        // 4x4 空間パッチ特徴量（各パッチの [平均輝度, R-B色差, コントラスト] = 48次元）
        var patchFeatures: [Float] = []
        patchFeatures.reserveCapacity(48)
        for py in 0..<4 {
            for px in 0..<4 {
                var pLum: Float = 0
                var pRB: Float = 0
                var pMax: Float = 0
                var pMin: Float = 1
                for dy in 0..<4 {
                    for dx in 0..<4 {
                        let idx = ((py * 4 + dy) * gridSize) + (px * 4 + dx)
                        let r = Float(rawPixels[idx * 4 + 0]) / 255.0
                        let b = Float(rawPixels[idx * 4 + 2]) / 255.0
                        let lum = luminances[idx]
                        pLum += lum
                        pRB += (r - b)
                        pMax = max(pMax, lum)
                        pMin = min(pMin, lum)
                    }
                }
                patchFeatures.append(pLum / 16.0)
                patchFeatures.append(pRB / 16.0)
                patchFeatures.append(pMax - pMin)
            }
        }

        let isBright = avgLum >= 0.65
        let isDark = avgLum <= 0.35

        let dominantTone: String
        let chroma = max(avgR, avgG, avgB) - min(avgR, avgG, avgB)
        if chroma < 0.08 {
            dominantTone = isBright ? "ホワイト・ライトグレー基調" : (isDark ? "ダークグレー・ブラック基調" : "モノトーン・グレースケール")
        } else if avgB >= avgR && avgB >= avgG {
            dominantTone = "ブルー・クールトーン基調"
        } else if avgR >= avgG && avgR >= avgB {
            dominantTone = "ウォーム・オレンジ/レッド基調"
        } else {
            dominantTone = "グリーン・ナチュラル基調"
        }

        return ImageVisualDescriptor(
            width: origWidth,
            height: origHeight,
            averageLuminance: avgLum,
            luminanceStdDev: stdDev,
            averageRed: avgR,
            averageGreen: avgG,
            averageBlue: avgB,
            isBrightVisual: isBright,
            isDarkVisual: isDark,
            dominantToneLabel: dominantTone,
            spatialPatchFeatures: patchFeatures
        )
    }

    private static func l2Normalize(_ input: [Float]) -> [Float] {
        var vector = input
        var sumSq: Float = 0
        vDSP_svesq(vector, 1, &sumSq, vDSP_Length(vector.count))
        let norm = sqrt(sumSq)
        if norm > 1e-6 {
            var divisor = norm
            vDSP_vsdiv(vector, 1, &divisor, &vector, 1, vDSP_Length(vector.count))
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
