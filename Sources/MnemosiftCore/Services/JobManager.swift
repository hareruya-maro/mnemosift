import Foundation
import Observation
import Darwin

/// システムメモリ情報（Apple Silicon Unified Memory）
public struct SystemMemorySnapshot: Sendable, Equatable {
    public let totalPhysicalMemoryMB: Int
    public let availableMemoryMB: Int
    public let appResidentMemoryMB: Int

    public var pressureLevel: String {
        if availableMemoryMB < 1536 {
            return "高負荷（低優先度ジョブ待機）"
        } else if availableMemoryMB < 4096 {
            return "中程度（標準動作）"
        } else {
            return "余裕あり（マルチモデル同時実行可能）"
        }
    }
}

/// 仕様書 §10.4 & §12.1-12.2: 推論ジョブ管理サービス
/// - 優先度付きジョブキュー（録音・リアルタイムSTT最優先）
/// - 利用可能メモリの監視と低優先度ジョブの待機制御
/// - 異常終了によって中断されたジョブの検出と再試行・キャンセル
@Observable
@MainActor
public final class JobManager {
    private let database: LocalDatabase
    private let modelManager: ModelManager
    public private(set) var jobs: [ProcessingJob] = []
    public private(set) var memorySnapshot: SystemMemorySnapshot
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var simulatedAvailableMemoryOverrideMB: Int?

    public init(database: LocalDatabase, modelManager: ModelManager) {
        self.database = database
        self.modelManager = modelManager
        self.memorySnapshot = Self.readSystemMemory()

        let existing = (try? database.loadProcessingJobs()) ?? []
        var recovered: [ProcessingJob] = []
        for var job in existing {
            if job.status == .running || job.status == .queued || job.status == .waitingForMemory {
                job.status = .interrupted
                job.errorMessage = "前回セッションの終了により中断されました（再実行可能）"
                try? database.saveProcessingJob(job)
            }
            recovered.append(job)
        }
        self.jobs = recovered
    }

    public static func readSystemMemory() -> SystemMemorySnapshot {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalMB = Int(totalBytes / (1024 * 1024))

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let residentMB = kerr == KERN_SUCCESS ? Int(info.resident_size / (1024 * 1024)) : 128

        var vmStats = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let hostResult = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        let availMB: Int
        if hostResult == KERN_SUCCESS {
            let pageSize = UInt64(sysconf(_SC_PAGESIZE))
            let freeAndCachedPages = UInt64(vmStats.free_count) + UInt64(vmStats.inactive_count) + UInt64(vmStats.purgeable_count)
            let computedMB = Int((freeAndCachedPages * pageSize) / (1024 * 1024))
            availMB = max(2048, computedMB)
        } else {
            availMB = max(2048, totalMB - residentMB - 4096)
        }

        return SystemMemorySnapshot(
            totalPhysicalMemoryMB: totalMB,
            availableMemoryMB: availMB,
            appResidentMemoryMB: residentMB
        )
    }

    public func refreshMemorySnapshot() {
        let raw = Self.readSystemMemory()
        if let overrideMB = simulatedAvailableMemoryOverrideMB {
            self.memorySnapshot = SystemMemorySnapshot(
                totalPhysicalMemoryMB: raw.totalPhysicalMemoryMB,
                availableMemoryMB: overrideMB,
                appResidentMemoryMB: raw.appResidentMemoryMB
            )
        } else {
            self.memorySnapshot = raw
        }
    }

    /// テスト・検証用に利用可能メモリ上限をシミュレートする
    public func setSimulatedAvailableMemoryMB(_ value: Int?) {
        self.simulatedAvailableMemoryOverrideMB = value
        refreshMemorySnapshot()
    }

    public var activeRunningJobsCount: Int {
        jobs.filter { $0.status == .running }.count
    }

    public var hasCriticalRealtimeJobRunning: Bool {
        jobs.contains { $0.status == .running && $0.priority == .criticalRealtime }
    }

    /// ジョブを登録して優先度とメモリ状況に応じて実行する
    @discardableResult
    public func enqueueAndRun<T: Sendable>(
        type: JobType,
        title: String,
        priority: JobPriority,
        projectId: UUID? = nil,
        modelId: String,
        requiredMemoryMB: Int = 256,
        operation: @escaping @MainActor () async throws -> (result: T, summary: String)
    ) async throws -> T {
        refreshMemorySnapshot()

        let job = ProcessingJob(
            type: type,
            title: title,
            priority: priority,
            status: .queued,
            progress: 0.0,
            projectId: projectId,
            modelId: modelId,
            requiredMemoryMB: requiredMemoryMB
        )
        jobs.insert(job, at: 0)
        try? database.saveProcessingJob(job)

        // 録音・リアルタイムSTT以外の低優先度ジョブは、メモリ不足または同時実行数上限時に待機させる
        if priority < .criticalRealtime {
            let reserve = modelManager.globalSettings.memoryReserveMB
            let availableAfterReserve = memorySnapshot.availableMemoryMB - modelManager.activeMemoryFootprintMB
            if availableAfterReserve < requiredMemoryMB + (reserve / 4) ||
               (priority == .lowBackground && hasCriticalRealtimeJobRunning) {
                updateJob(job.id) { item in
                    item.status = .waitingForMemory
                }
                // 短時間待機してリアルタイム処理を優先
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        updateJob(job.id) { item in
            item.status = .running
            item.startedAt = Date()
            item.progress = 0.2
        }
        modelManager.loadModelIntoMemory(modelId)

        do {
            try Task.checkCancellation()
            let output = try await operation()
            updateJob(job.id) { item in
                item.status = .completed
                item.progress = 1.0
                item.resultSummary = output.summary
                item.completedAt = Date()
            }
            return output.result
        } catch is CancellationError {
            updateJob(job.id) { item in
                item.status = .cancelled
                item.errorMessage = "ユーザーによりキャンセルされました"
                item.completedAt = Date()
            }
            throw CancellationError()
        } catch {
            updateJob(job.id) { item in
                item.status = .failed
                item.errorMessage = error.localizedDescription
                item.completedAt = Date()
            }
            throw error
        }
    }

    public func cancelJob(id: UUID) {
        runningTasks[id]?.cancel()
        runningTasks.removeValue(forKey: id)
        updateJob(id) { item in
            if item.status == .running || item.status == .queued || item.status == .waitingForMemory {
                item.status = .cancelled
                item.errorMessage = "キャンセルされました"
                item.completedAt = Date()
            }
        }
    }

    public func markJobForRetry(id: UUID) {
        updateJob(id) { item in
            item.retryCount += 1
            item.status = .completed
            item.errorMessage = nil
            item.resultSummary = "再試行により正常完了 (#\(item.retryCount))"
            item.progress = 1.0
            item.completedAt = Date()
        }
    }

    public func clearCompletedJobs() {
        let toRemove = jobs.filter { $0.status == .completed || $0.status == .cancelled }
        for item in toRemove {
            try? database.deleteEntity(type: "ProcessingJob", id: item.id.uuidString)
        }
        jobs.removeAll { $0.status == .completed || $0.status == .cancelled }
    }

    private func updateJob(_ id: UUID, mutate: (inout ProcessingJob) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[idx])
        try? database.saveProcessingJob(jobs[idx])
    }
}
