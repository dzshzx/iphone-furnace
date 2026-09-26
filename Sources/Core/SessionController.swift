import Foundation
import Observation
import UIKit
import os

@MainActor @Observable final class SessionController {
    var configuration = RunConfiguration()
    private(set) var phase = SessionPhase.idle
    private(set) var message = "选择负载，开始压测"
    private(set) var elapsed: Double = 0
    private(set) var samples: [TelemetrySample] = []
    private(set) var snapshots: [EngineSnapshot] = []
    private(set) var reports: [URL] = ReportStore.recentReports()
    private(set) var suiteProgress: String?
    let interruptedPrivateStage: String?

    @ObservationIgnored private var engines: [any LoadEngine] = []
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var report: ReportStore?
    @ObservationIgnored private var sequence: [RunConfiguration] = []
    @ObservationIgnored private var suiteIndex = 0
    @ObservationIgnored private var suiteTotal = 0
    @ObservationIgnored private var savedManualConfiguration: RunConfiguration?
    @ObservationIgnored private var startedAt = 0.0
    @ObservationIgnored private var stopReason = "手动停止"
    @ObservationIgnored private var lastCPUSeconds = 0.0
    @ObservationIgnored private var lastSampleTime = 0.0
    @ObservationIgnored private var savedIdleTimer = false
    @ObservationIgnored private var savedBatteryMonitoring = false
    @ObservationIgnored private var signposter = OSSignposter(subsystem: "com.dzshzx.furnace", category: "Stress")
    @ObservationIgnored private var interval: OSSignpostIntervalState?
    @ObservationIgnored private let factory: @Sendable (RunConfiguration) -> [any LoadEngine]
    @ObservationIgnored private let reportRoot: URL?

    static let interruptedPrivateStageKey: String = FurnaceANEInterruptedStageKey

    init(reportRoot: URL? = nil, defaults: UserDefaults = .standard,
         factory: @escaping @Sendable (RunConfiguration) -> [any LoadEngine] = SessionController.makeEngines) {
        self.reportRoot = reportRoot
        self.factory = factory
        // The native bridge writes the marker before each unsupported private-ANE call and removes it on close.
        // Consume it here: the notice belongs to the launch right after the interruption, not to every later one.
        interruptedPrivateStage = defaults.string(forKey: Self.interruptedPrivateStageKey)
        if let interruptedPrivateStage {
            defaults.removeObject(forKey: Self.interruptedPrivateStageKey)
            message = "上次私有 ANE 在「\(interruptedPrivateStage)」中断；已恢复 Core ML 默认后端"
        }
    }

    nonisolated static func makeEngines(_ config: RunConfiguration) -> [any LoadEngine] {
        var engines: [any LoadEngine] = []
        if config.units.contains(.cpu) { engines.append(CPUEngine(workers: config.cpuWorkers)) }
        if config.units.contains(.gpu) { engines.append(GPUEngine(workload: config.gpuWorkload)) }
        if config.units.contains(.npu) { engines.append(NPUEngine(configuration: config)) }
        return engines
    }

    func start() {
        guard !phase.busy else { return }
        let config = configuration
        do { try config.validate() } catch { phase = .failed; message = error.localizedDescription; return }
        phase = .preparing
        message = "分配缓冲区并验证计算后端"
        elapsed = 0; samples.removeAll(); snapshots.removeAll()
        stopReason = "手动停止"
        startedAt = 0
        savedIdleTimer = UIApplication.shared.isIdleTimerDisabled
        savedBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        engines = factory(config)
        runTask = Task { [self] in
            var failure: String?
            do {
                report = try ReportStore(configuration: config, root: reportRoot)
                for engine in engines {
                    try Task.checkCancellation()
                    message = "准备 \(engine.unit.rawValue)"
                    try await engine.prepare()
                    snapshots = engines.map { $0.sample() }
                }
                try Task.checkCancellation()
                startedAt = ProcessInfo.processInfo.systemUptime
                lastSampleTime = startedAt
                lastCPUSeconds = furnace_process_cpu_seconds()
                interval = signposter.beginInterval("FurnaceSession")
                for engine in engines { engine.start() }
                phase = .running
                message = "持续提交负载 · 温度变化只记录"
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                    try capture()
                    if let error = snapshots.compactMap(\.error).first { throw LoadError(error) }
                    if config.durationSeconds > 0 && elapsed >= Double(config.durationSeconds) {
                        stopReason = "定时结束"; break
                    }
                }
            } catch is CancellationError {
                // Explicit stop/background interrupts do not turn a run into a failure.
            } catch {
                failure = error.localizedDescription
            }
            phase = .stopping
            message = "停止提交并等待在途计算结束"
            await withTaskGroup(of: Void.self) { group in
                for engine in engines { group.addTask { await engine.stop() } }
            }
            if startedAt > 0 {
                do { try capture() } catch { failure = failure ?? error.localizedDescription }
            }
            snapshots = engines.map { $0.sample() }
            failure = failure ?? snapshots.compactMap(\.error).first
            if let interval { signposter.endInterval("FurnaceSession", interval) }
            interval = nil
            UIApplication.shared.isIdleTimerDisabled = savedIdleTimer
            UIDevice.current.isBatteryMonitoringEnabled = savedBatteryMonitoring
            let finalPhase: SessionPhase = failure == nil ? .completed : .failed
            let finalReason = failure ?? stopReason
            do { try report?.finish(phase: finalPhase, reason: finalReason, elapsed: elapsed, engines: snapshots) }
            catch { failure = "报告保存失败：\(error.localizedDescription)" }
            report = nil
            engines.removeAll()
            phase = failure == nil ? .completed : .failed
            message = failure ?? finalReason
            reports = ReportStore.recentReports()
            runTask = nil
            if failure == nil && stopReason == "定时结束" && !sequence.isEmpty {
                suiteIndex += 1
                configuration = sequence.removeFirst()
                suiteProgress = "自测 \(suiteIndex)/\(suiteTotal)"
                start()
            } else {
                sequence.removeAll()
                suiteProgress = nil
                if let savedManualConfiguration { configuration = savedManualConfiguration }
                savedManualConfiguration = nil
            }
        }
    }

    func stop(reason: String = "手动停止") {
        guard phase.busy else { return }
        sequence.removeAll()
        stopReason = reason
        phase = .stopping
        runTask?.cancel()
    }

    func startSelfTest() {
        guard !phase.busy else { return }
        savedManualConfiguration = configuration
        sequence = RunConfiguration.selfTestSequence()
        suiteTotal = sequence.count
        configuration = sequence.removeFirst()
        suiteIndex = 1
        suiteProgress = "自测 1/8"
        start()
    }

    func startNPUComparison() {
        guard !phase.busy else { return }
        savedManualConfiguration = configuration
        sequence = [1, 2, 4].map { count in
            var config = configuration
            config.units = [.npu]
            config.npuBackend = .coreML
            config.npuConcurrency = count
            config.durationSeconds = 30
            return config
        }
        suiteTotal = sequence.count
        suiteIndex = 1
        suiteProgress = "自测 1/3"
        configuration = sequence.removeFirst()
        start()
    }

    private func capture() throws {
        let now = ProcessInfo.processInfo.systemUptime
        elapsed = max(0, now - startedAt)
        let cpu = furnace_process_cpu_seconds()
        let cpuPercent = max(0, min(100, (cpu - lastCPUSeconds) / max(0.001, now - lastSampleTime)
            / Double(ProcessInfo.processInfo.processorCount) * 100))
        lastCPUSeconds = cpu; lastSampleTime = now
        snapshots = engines.map { $0.sample() }
        let sample = TelemetrySample(elapsed: elapsed, cpuPercent: cpuPercent,
            memoryMB: Double(furnace_memory_bytes()) / 1_048_576,
            batteryLevel: Double(UIDevice.current.batteryLevel),
            charging: [.charging, .full].contains(UIDevice.current.batteryState),
            thermalState: Self.thermalLabel(ProcessInfo.processInfo.thermalState), engines: snapshots)
        samples.append(sample)
        if samples.count > 180 { samples.removeFirst(samples.count - 180) }
        try report?.append(sample)
    }

    nonisolated static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "正常"
        case .fair: "温热"
        case .serious: "较热"
        case .critical: "严重"
        @unknown default: "未知"
        }
    }
}
