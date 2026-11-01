import SwiftUI
import AppKit
import MnemosiftCore

/// アップデート情報・リリース確認ビュー
public struct UpdateSheetView: View {
    @State private var updateService = AppUpdateService.shared
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Label("ソフトウェアアップデート", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.headline)
                Spacer()
                Button("閉じる", systemImage: "xmark.circle.fill") {
                    updateService.isShowingUpdateSheet = false
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.regularMaterial)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 現在のバージョン情報カード
                    currentVersionCard

                    // 状態別のステータス表示
                    switch updateService.status {
                    case .idle:
                        idleView
                    case .checking:
                        checkingView
                    case let .upToDate(version):
                        upToDateView(version: version)
                    case let .updateAvailable(release):
                        updateAvailableView(release: release)
                    case let .downloading(progress):
                        downloadingView(progress: progress)
                    case .installing:
                        installingView
                    case let .failed(message):
                        failedView(message: message)
                    }

                    Divider()

                    // 設定オプション
                    autoUpdateSettingsSection
                }
                .padding(20)
            }
        }
        .frame(width: 580, height: 500)
    }

    // MARK: - コンポーネント

    private var currentVersionCard: some View {
        HStack(spacing: 16) {
            if let icon = MnemosiftApp.loadAppIconImage() {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Mnemosift")
                    .font(.title3.bold())
                Text("バージョン \(updateService.currentVersion) (Apple Silicon / macOS 14+)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let lastChecked = updateService.lastCheckedDate {
                    Text("最終確認: \(lastChecked.formatted(date: .numeric, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if updateService.status != .checking && !updateService.isDownloading {
                Button("アップデートを確認", systemImage: "arrow.clockwise") {
                    Task {
                        await updateService.checkForUpdates(isUserInitiated: true)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private var idleView: some View {
        VStack(spacing: 12) {
            Text("「アップデートを確認」をクリックして最新のリリースを確認できます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 20)
    }

    private var checkingView: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("GitHub Releases から最新リリースを確認中...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    private func upToDateView(version: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("最新バージョンを使用しています")
                    .font(.headline)
                Text("Mnemosift v\(version) は現在配布されている最新版です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("GitHubで見る", systemImage: "arrow.up.right.square") {
                updateService.openReleaseWebPage()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func updateAvailableView(release: GitHubRelease) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("新しいバージョンが利用可能です！")
                        .font(.headline)
                    Text("\(release.displayTitle)（公開: \(release.publishedAt?.formatted(date: .numeric, time: .omitted) ?? "最新")）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let zip = release.zipAsset {
                    Text(zip.formattedSize)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // リリースノート
            if let body = release.body, !body.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("リリースノート:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(body)
                            .font(.system(.caption, design: .default))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            // アクションボタン群
            HStack(spacing: 12) {
                Button {
                    Task {
                        await updateService.downloadAndInstall(release: release)
                    }
                } label: {
                    Label("今すぐアップデートして再起動", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button("ブラウザで開く", systemImage: "arrow.up.right.square") {
                    updateService.openReleaseWebPage(url: release.htmlURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()

                Button("このバージョンをスキップ") {
                    updateService.ignoreVersion(release.tagName)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func downloadingView(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最新バージョンをダウンロード中...")
                    .font(.headline)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)

            Text("ダウンロード完了後、自動的に新しいバージョンへ置き換えて再起動します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var installingView: some View {
        HStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("インストール・アプリ置換中...")
                    .font(.headline)
                Text("間もなく Mnemosift が再起動します。少々お待ちください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func failedView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                Text("アップデートの確認またはダウンロードに失敗しました")
                    .font(.headline)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("再試行", systemImage: "arrow.clockwise") {
                    Task {
                        await updateService.checkForUpdates(isUserInitiated: true)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("GitHub Releases を直接開く", systemImage: "arrow.up.right.square") {
                    updateService.openReleaseWebPage()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var autoUpdateSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("起動時に自動でアップデートを確認する", isOn: Binding(
                get: { updateService.automaticallyCheckForUpdates },
                set: { updateService.automaticallyCheckForUpdates = $0 }
            ))
            .font(.subheadline)

            Text("GitHub Releases (https://github.com/hareruya-maro/mnemosift) から安全に最新版を取得します。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
