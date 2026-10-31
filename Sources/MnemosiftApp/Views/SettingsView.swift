import SwiftUI
import MnemosiftCore

/// 仕様書 §9.7 & §10: 設定・AIモデルマネージャー画面
/// - 4分類（STT / 判断モデル / LLM / Embedding）のモデル管理（インストール・削除・更新・ディスク使用量・メタデータ表示）
/// - 設定の優先順位（1. 実行時指定 → 2. プロジェクト固有設定 → 3. アプリ全体設定）
/// - 補正モード、確信度閾値、録音デバイス、ローカルデータ保存先、パフォーマンス設定
public struct SettingsView: View {
    @Bindable var workspace: AppWorkspaceController

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                globalAISettingsSection
                modelManagerCatalogSection
                storageAndPrivacySection
            }
            .padding(20)
        }
        .navigationTitle("設定・AIモデル管理")
    }

    private var globalAISettingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("標準AIモデル・補正モード設定（優先順位3: アプリ全体設定）")
                .font(.headline)

            Text("※ 実行時の個別指定（優先順位1）およびプロジェクト固有設定（優先順位2）がある場合はそちらが優先適用されます。設定変更は新規ジョブから適用されます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    Text("リアルタイム文字起こし用 STT:")
                        .font(.subheadline)
                    Picker("リアルタイムSTT", selection: Binding(
                        get: { workspace.modelManager.globalSettings.realtimeSTTModelId },
                        set: { newValue in
                            var s = workspace.modelManager.globalSettings
                            s.realtimeSTTModelId = newValue
                            try? workspace.modelManager.updateGlobalSettings(s)
                        }
                    )) {
                        ForEach(workspace.modelManager.models(for: .stt)) { model in
                            Text("\(model.name) (\(model.requiredMemoryMB) MB)").tag(model.id)
                        }
                    }
                    .labelsHidden()
                }

                GridRow {
                    Text("録音終了後の高精度再処理用 STT:")
                        .font(.subheadline)
                    Picker("再処理用STT", selection: Binding(
                        get: { workspace.modelManager.globalSettings.reprocessSTTModelId },
                        set: { newValue in
                            var s = workspace.modelManager.globalSettings
                            s.reprocessSTTModelId = newValue
                            try? workspace.modelManager.updateGlobalSettings(s)
                        }
                    )) {
                        ForEach(workspace.modelManager.models(for: .stt)) { model in
                            Text("\(model.name) (\(model.requiredMemoryMB) MB)").tag(model.id)
                        }
                    }
                    .labelsHidden()
                }

                GridRow {
                    Text("判断モデル (System One):")
                        .font(.subheadline)
                    Picker("判断モデル", selection: Binding(
                        get: { workspace.modelManager.globalSettings.judgeModelId },
                        set: { newValue in
                            var s = workspace.modelManager.globalSettings
                            s.judgeModelId = newValue
                            try? workspace.modelManager.updateGlobalSettings(s)
                        }
                    )) {
                        ForEach(workspace.modelManager.models(for: .judge)) { model in
                            Text("\(model.name) (\(model.requiredMemoryMB) MB)").tag(model.id)
                        }
                    }
                    .labelsHidden()
                }

                GridRow {
                    Text("LLM（議事録生成・高度補正・RAG）:")
                        .font(.subheadline)
                    Picker("LLM", selection: Binding(
                        get: { workspace.modelManager.globalSettings.llmModelId },
                        set: { newValue in
                            var s = workspace.modelManager.globalSettings
                            s.llmModelId = newValue
                            try? workspace.modelManager.updateGlobalSettings(s)
                        }
                    )) {
                        ForEach(workspace.modelManager.models(for: .llm)) { model in
                            Text("\(model.name) (\(model.requiredMemoryMB) MB)").tag(model.id)
                        }
                    }
                    .labelsHidden()
                }

                GridRow {
                    Text("Embeddingモデル（変更時は互換性確認＆再インデックス）:")
                        .font(.subheadline)
                    Picker("Embedding", selection: Binding(
                        get: { workspace.modelManager.globalSettings.embeddingModelId },
                        set: { newValue in
                            var s = workspace.modelManager.globalSettings
                            s.embeddingModelId = newValue
                            try? workspace.modelManager.updateGlobalSettings(s)
                            if let targetModel = workspace.modelManager.model(withId: newValue) {
                                Task {
                                    let count = (try? await workspace.embeddingService.verifyAndReindexIfIncompatible(targetModel: targetModel)) ?? 0
                                    if count > 0 {
                                        workspace.statusBannerMessage = "Embeddingモデル変更に伴い \(count) 件のチャンクを再インデックスしました"
                                    }
                                }
                            }
                        }
                    )) {
                        ForEach(workspace.modelManager.models(for: .embedding)) { model in
                            Text("\(model.name) (\(model.requiredMemoryMB) MB)").tag(model.id)
                        }
                    }
                    .labelsHidden()
                }

                GridRow {
                    Text("標準リアルタイム補正モード:")
                        .font(.subheadline)
                    Picker("補正モード", selection: Binding(
                        get: { workspace.modelManager.globalSettings.correctionMode },
                        set: { newValue in
                            var s = workspace.modelManager.globalSettings
                            s.correctionMode = newValue
                            try? workspace.modelManager.updateGlobalSettings(s)
                        }
                    )) {
                        ForEach(RealtimeCorrectionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var modelManagerCatalogSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AIモデルマネージャー")
                        .font(.headline)
                    Text("推奨モデルのインストール・更新・削除とメタデータ（ランタイム・必要メモリ・ストリーミング・語彙指定対応）を管理します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("総ディスク使用量: \(workspace.modelManager.totalDiskUsageMB) MB")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.15), in: Capsule())
            }

            ForEach(AIModelCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(category.rawValue) — \(category.description)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.blue)

                    ForEach(workspace.modelManager.models(for: category)) { model in
                        modelCatalogRow(model)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func modelCatalogRow(_ model: AIModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.subheadline.bold())
                    Text("v\(model.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(model.downloadState.rawValue)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            model.downloadState == .installed ? Color.green.opacity(0.2) : Color.orange.opacity(0.2),
                            in: Capsule()
                        )
                    Text("ライセンス: \(model.license)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(model.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Text("ランタイム: \(model.runtime.rawValue)")
                    Text("必要メモリ: \(model.requiredMemoryMB) MB")
                    Text("ディスク: \(model.diskSizeMB) MB")
                    Text("ストリーミング: \(model.streamingCapability.rawValue)")
                    Text("語彙指定: \(model.supportsCustomVocabulary ? "対応" : "非対応")")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if model.downloadState == .downloading {
                    ProgressView(value: model.downloadProgress, total: 1.0)
                        .frame(width: 100)
                } else if model.downloadState == .notInstalled || model.downloadState == .updateAvailable {
                    Button(
                        model.downloadState == .updateAvailable ? "モデル更新" : "インストール",
                        systemImage: "arrow.down.circle"
                    ) {
                        Task {
                            await workspace.modelManager.installOrUpdateModel(id: model.id)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if model.diskSizeMB > 0 {
                    Button("削除", systemImage: "trash") {
                        try? workspace.modelManager.deleteModelFromDisk(id: model.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private var storageAndPrivacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ローカルデータ保存場所・プライバシー保護方針")
                .font(.headline)

            LabeledContent("SQLite データベースパス:") {
                Text(workspace.database.databasePath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            LabeledContent("管理ファイル保存ルート:") {
                Text(workspace.modelManager.globalSettings.storageRootPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            LabeledContent("ネットワークポリシー:") {
                Text("会議音声・文字起こし・議事録・登録文書は外部APIへ一切送信されません（完全ローカル実行）")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
