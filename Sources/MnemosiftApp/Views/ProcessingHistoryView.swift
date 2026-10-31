import SwiftUI
import MnemosiftCore

/// 仕様書 §9.1, §10.4, §12.1-12.2, §13 (Phase 0): 処理履歴・推論ジョブ管理・技術検証ベンチマーク画面
/// - 優先度付き推論ジョブキューの一覧・ステータス・メモリ待機・キャンセル・再試行
/// - Phase 0 技術検証プロトタイプ（一般会話とIT専門用語でのSTT・判断モデル・LLM同時実行・ガードレール検証）の実測・記録
public struct ProcessingHistoryView: View {
    @Bindable var workspace: AppWorkspaceController

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                memoryAndQueueHeaderCard

                phase0BenchmarkSection

                jobsQueueSection
            }
            .padding(20)
        }
        .navigationTitle("処理履歴・技術検証")
    }

    private var memoryAndQueueHeaderCard: some View {
        let mem = workspace.jobManager.memorySnapshot
        return HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Silicon メモリ・ジョブスケジューラ監視")
                    .font(.headline)
                Text("録音処理とリアルタイムSTTを最優先し、メモリ不足時は低優先度のファイル分類・Embedding生成を自動待機させます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("物理メモリ: \(mem.totalPhysicalMemoryMB) MB / 利用可能: \(mem.availableMemoryMB) MB")
                    .font(.caption.bold())
                Text("ロード中AIモデル推定使用量: \(workspace.modelManager.activeMemoryFootprintMB) MB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("メモリ状態を更新", systemImage: "arrow.clockwise") {
                workspace.jobManager.refreshMemorySnapshot()
            }
            .controlSize(.small)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var phase0BenchmarkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Phase 0 技術検証プロトタイプ（実測ベンチマークスイート）")
                        .font(.headline)
                    Text("一般会話・IT専門用語の双方で STT / System One判断モデル / Gemma 4 LLM / 同時実行 / ガードレールを実測し記録します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(
                    workspace.benchmarkRunner.isRunning ? "検証実行中..." : "Phase 0 技術検証を実行",
                    systemImage: "gauge.with.dots.needle.67percent"
                ) {
                    Task {
                        _ = try? await workspace.benchmarkRunner.runPhase0VerificationSuite()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(workspace.benchmarkRunner.isRunning)
            }

            if workspace.benchmarkRunner.records.isEmpty {
                Text("右上の「Phase 0 技術検証を実行」ボタンを押すと、現在の端末環境での処理時間・メモリ使用量・補正精度を実測します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(workspace.benchmarkRunner.records.prefix(8)) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(record.scenarioName)
                                .font(.subheadline.bold())
                            Spacer()
                            Text(String(format: "処理時間: %.2f ms", record.latencyMs))
                                .font(.caption.bold())
                                .foregroundStyle(.blue)
                            Text("メモリ: \(record.memoryUsedMB) MB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "精度スコア: %.0f%%", record.accuracyScore * 100))
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                        }
                        Text("入力: \(record.inputSample)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("出力: \(record.outputSample)")
                            .font(.caption.bold())
                        Text("検証メモ: \(record.notes)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var jobsQueueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("推論ジョブ実行履歴 (\(workspace.jobManager.jobs.count)件)")
                    .font(.headline)
                Spacer()
                Button("完了済みジョブを整理", systemImage: "Checkmark.gobackward") {
                    workspace.jobManager.clearCompletedJobs()
                }
                .controlSize(.small)
            }

            ForEach(workspace.jobManager.jobs) { job in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(job.status.rawValue)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(jobStatusColor(job.status).opacity(0.2), in: Capsule())
                                .foregroundStyle(jobStatusColor(job.status))
                            Text(job.type.rawValue)
                                .font(.caption.bold())
                            Text(job.priority.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(job.title)
                            .font(.subheadline.bold())
                        if let summary = job.resultSummary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let err = job.errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Spacer()

                    Text("モデル: \(job.modelId) (\(job.requiredMemoryMB) MB)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if job.status == .running || job.status == .queued || job.status == .waitingForMemory {
                        Button("キャンセル", systemImage: "xmark.circle") {
                            workspace.jobManager.cancelJob(id: job.id)
                        }
                        .controlSize(.mini)
                    } else if job.status == .failed || job.status == .interrupted {
                        Button("再試行", systemImage: "arrow.clockwise") {
                            workspace.jobManager.markJobForRetry(id: job.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func jobStatusColor(_ status: JobStatus) -> Color {
        switch status {
        case .completed: .green
        case .running: .blue
        case .queued, .waitingForMemory: .orange
        case .failed, .interrupted: .red
        case .cancelled: .secondary
        }
    }
}
