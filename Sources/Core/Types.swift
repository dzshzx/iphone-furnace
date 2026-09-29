import Foundation

enum UnitKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case cpu = "CPU", gpu = "GPU", npu = "NPU"
    var id: String { rawValue }
}

enum GPUWorkload: String, CaseIterable, Codable, Identifiable, Sendable {
    case mixed = "计算与纹理混合", fp32 = "FP32 计算", matrix = "FP16 矩阵"
    var id: String { rawValue }
}

enum NPUBackend: String, CaseIterable, Codable, Identifiable, Sendable {
    case coreML = "Core ML", experimental = "私有 ANE 实验"
    var id: String { rawValue }
}

struct RunConfiguration: Codable, Equatable, Sendable {
    var units: Set<UnitKind> = Set(UnitKind.allCases)
    var cpuWorkers: Int = ProcessInfo.processInfo.activeProcessorCount
    var gpuWorkload: GPUWorkload = .mixed
    var npuChannels: Int = 256
    var npuConcurrency: Int = 1
    var npuBackend: NPUBackend = .coreML
    var durationSeconds: Int = 0

    func validate() throws {
        guard !units.isEmpty else { throw LoadError("至少选择一个计算单元") }
        guard (1...ProcessInfo.processInfo.processorCount * 2).contains(cpuWorkers),
              [256, 384, 512].contains(npuChannels), [1, 2, 4].contains(npuConcurrency),
              durationSeconds >= 0 else { throw LoadError("负载参数超出范围") }
    }

    static func selfTestSequence() -> [RunConfiguration] {
        let combinations: [Set<UnitKind>] = [
            [.cpu], [.gpu], [.npu], [.cpu, .gpu], [.cpu, .npu], [.gpu, .npu],
            [.cpu, .gpu, .npu]
        ]
        return combinations.map { units in
            var config = RunConfiguration()
            config.units = units
            config.durationSeconds = 60
            return config
        } + [RunConfiguration(durationSeconds: 900)]
    }
}

struct LoadError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum SessionPhase: String, Codable, Sendable {
    case idle, preparing, running, stopping, completed, failed
    var busy: Bool { self == .preparing || self == .running || self == .stopping }
    var label: String {
        switch self {
        case .idle: "就绪"
        case .preparing: "准备负载"
        case .running: "压测中"
        case .stopping: "正在停止"
        case .completed: "已结束"
        case .failed: "运行失败"
        }
    }
}

struct EngineSnapshot: Codable, Sendable {
    var unit: UnitKind
    var completed: UInt64 = 0
    var totalExecutionMS: Double = 0
    var lastExecutionMS: Double = 0
    var detail: String = "未验证"
    var error: String?
}

struct TelemetrySample: Codable, Sendable {
    var elapsed: Double
    var cpuPercent: Double
    var memoryMB: Double
    var batteryLevel: Double
    var charging: Bool
    var thermalState: String
    var engines: [EngineSnapshot]
}

protocol LoadEngine: AnyObject, Sendable {
    var unit: UnitKind { get }
    func prepare() async throws
    func start()
    func stop() async
    func sample() -> EngineSnapshot
}

// Every mutable value shared with a worker lives behind a Synchronization.Mutex.
// No async body may run inside withLock; GPU/Core ML waits must never hold it.

