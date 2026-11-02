import SwiftUI
import AppKit
import MnemosiftCore

/// 仕様書 §9.7 & §10: 設定・AIモデルマネージャー画面
/// - 4分類（STT / 判断モデル / LLM / Embedding）のモデル管理（インストール・削除・更新・ディスク使用量・メタデータ表示）
/// - パワーユーザー向け Hugging Face / Ollama / ローカルGGUF カスタムモデル追加
/// - 設定の優先順位（1. 実行時指定 → 2. プロジェクト固有設定 → 3. アプリ全体設定）
/// - 補正モード、確信度閾値、録音デバイス、ローカルデータ保存先、パフォーマンス設定
public struct SettingsView: View {
    @Bindable var workspace: AppWorkspaceController

    // カスタムモデル追加フォーム用ステート
    @State private var isShowingCustomModelForm: Bool = false
    @State private var customModelName: String = ""
    @State private var customModelCategory: AIModelCategory = .llm
    @State private var customModelRuntime: AIModelRuntime = .ollama
    @State private var customModelEndpoint: String = ""
    @State private var customModelMemoryMB: Int = 4096
    @State private var customModelDiskMB: Int = 3500
    @State private var customModelSupportsVocab: Bool = true
    @State private var customModelNotes: String = ""

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                globalAISettingsSection
                modelManagerCatalogSection
                customModelAdditionSection
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
                        ForEach(RealtimeCorrectionMode.automaticModes) { mode in
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
                    Text("AIモデルマネージャー（推奨モデルのアプリ単体ダウンロード・実行）")
                        .font(.headline)
                    Text("推奨モデルのインストール・更新・削除とメタデータ（ランタイム・必要メモリ・ストリーミング・語彙指定対応）を管理します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("モデル保存フォルダを開く", systemImage: "folder") {
                    NSWorkspace.shared.open(workspace.modelManager.modelsDirectoryURL)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

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

                if let statusMsg = workspace.modelManager.downloadStatusMessages[model.id], !statusMsg.isEmpty {
                    Text("ステータス: \(statusMsg)")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if model.downloadState == .downloading {
                    HStack(spacing: 8) {
                        ProgressView(value: model.downloadProgress, total: 1.0)
                            .frame(width: 90)
                        Text("\(Int(model.downloadProgress * 100))%")
                            .font(.caption2.monospacedDigit())
                        Button("中断", systemImage: "xmark.circle") {
                            workspace.modelManager.cancelModelDownload(id: model.id)
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                    }
                } else if model.downloadState == .notInstalled || model.downloadState == .updateAvailable || model.downloadState == .failed {
                    Button(
                        model.downloadState == .updateAvailable ? "モデル更新" : "ダウンロード",
                        systemImage: "arrow.down.circle.fill"
                    ) {
                        workspace.modelManager.startModelDownloadTask(id: model.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if model.diskSizeMB > 0 {
                    HStack(spacing: 6) {
                        Button("削除", systemImage: "trash") {
                            try? workspace.modelManager.deleteModelFromDisk(id: model.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private var customModelAdditionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("パワーユーザー向け：カスタムモデル追加（Hugging Face / Ollama / ローカルGGUF）")
                        .font(.headline)
                    Text("Hugging Face の MLX / GGUF リポジトリID、ローカルの Ollama モデルタグ、または `.gguf` ファイルパスを指定してカタログに追加できます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("ローカルOllamaモデルを検出", systemImage: "arrow.triangle.2.circlepath") {
                    Task {
                        let tags = await workspace.modelManager.discoverLocalOllamaModels()
                        if tags.isEmpty {
                            workspace.statusBannerMessage = "ローカルで起動中の Ollama モデルは検出されませんでした（127.0.0.1:11434）"
                        } else {
                            workspace.statusBannerMessage = "Ollama から \(tags.count) 個のモデルを検出しました"
                        }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button(isShowingCustomModelForm ? "フォームを閉じる" : "＋ カスタムモデルを追加", systemImage: "plus.circle.fill") {
                    withAnimation {
                        isShowingCustomModelForm.toggle()
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }

            if !workspace.modelManager.discoveredOllamaTags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("検出されたローカル Ollama モデル（クリックでワンタッチ登録）:")
                        .font(.caption.bold())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(workspace.modelManager.discoveredOllamaTags, id: \.self) { tag in
                                Button("＋ \(tag)") {
                                    _ = try? workspace.modelManager.addCustomModel(
                                        name: "Ollama: \(tag)",
                                        category: .llm,
                                        runtime: .ollama,
                                        endpointOrRepoId: tag,
                                        requiredMemoryMB: 4096,
                                        diskSizeMB: 3500,
                                        notes: "ローカル Ollama から自動検出・登録されたモデル"
                                    )
                                    workspace.statusBannerMessage = "Ollama モデル『\(tag)』をカタログに追加しました"
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(10)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if isShowingCustomModelForm {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("表示モデル名:")
                            .font(.subheadline)
                        TextField("例: Gemma 4 27B Instruct / Llama 3.3 8B", text: $customModelName)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("カテゴリ / ランタイム:")
                            .font(.subheadline)
                        HStack(spacing: 12) {
                            Picker("カテゴリ", selection: $customModelCategory) {
                                ForEach(AIModelCategory.allCases) { cat in
                                    Text(cat.rawValue).tag(cat)
                                }
                            }
                            .frame(width: 180)

                            Picker("ランタイム", selection: $customModelRuntime) {
                                ForEach(AIModelRuntime.allCases, id: \.self) { rt in
                                    Text(rt.rawValue).tag(rt)
                                }
                            }
                            .frame(width: 260)
                        }
                    }
                    GridRow {
                        Text("HF Repo / Ollamaタグ / パス:")
                            .font(.subheadline)
                        TextField("例: mlx-community/gemma-2-27b-it-4bit または gemma4:27b または ~/Models/model.gguf", text: $customModelEndpoint)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("推定メモリ / ディスク容量:")
                            .font(.subheadline)
                        HStack(spacing: 16) {
                            Stepper("必要メモリ: \(customModelMemoryMB) MB", value: $customModelMemoryMB, in: 256...65536, step: 512)
                            Stepper("ディスク: \(customModelDiskMB) MB", value: $customModelDiskMB, in: 100...65536, step: 500)
                            Toggle("語彙指定対応", isOn: $customModelSupportsVocab)
                        }
                        .font(.caption)
                    }
                    GridRow {
                        Text("メモ・説明:")
                            .font(.subheadline)
                        HStack {
                            TextField("任意のメモ...", text: $customModelNotes)
                                .textFieldStyle(.roundedBorder)
                            Button("カタログに登録してダウンロード", systemImage: "checkmark.circle.fill") {
                                do {
                                    let added = try workspace.modelManager.addCustomModel(
                                        name: customModelName,
                                        category: customModelCategory,
                                        runtime: customModelRuntime,
                                        endpointOrRepoId: customModelEndpoint,
                                        requiredMemoryMB: customModelMemoryMB,
                                        diskSizeMB: customModelDiskMB,
                                        supportsCustomVocabulary: customModelSupportsVocab,
                                        notes: customModelNotes
                                    )
                                    workspace.modelManager.startModelDownloadTask(id: added.id)
                                    workspace.statusBannerMessage = "カスタムモデル『\(added.name)』を追加しダウンロードを開始しました"
                                    customModelName = ""
                                    customModelEndpoint = ""
                                    customModelNotes = ""
                                    isShowingCustomModelForm = false
                                } catch {
                                    workspace.statusBannerMessage = "⚠️ \(error.localizedDescription)"
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
