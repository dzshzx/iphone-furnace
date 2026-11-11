import XCTest
import Synchronization
import Metal
@preconcurrency import CoreML
@testable import Furnace

private final class FakeEngine: LoadEngine, Sendable {
    let unit: UnitKind
    let prepareFailure: Bool
    let runtimeFailure: Bool
    let onPrepare: (@Sendable () async -> Void)?
    let state = Mutex((started: false, stops: 0, prepares: 0))
    init(_ unit: UnitKind, prepareFailure: Bool = false, runtimeFailure: Bool = false,
         onPrepare: (@Sendable () async -> Void)? = nil) {
        self.unit = unit; self.prepareFailure = prepareFailure
        self.runtimeFailure = runtimeFailure; self.onPrepare = onPrepare
    }
    func prepare() async throws {
        state.withLock { $0.prepares += 1 }
        await onPrepare?()
        if prepareFailure { throw LoadError("backend unavailable") }
    }
    func start() { state.withLock { $0.started = true } }
    func stop() async { state.withLock { $0.stops += 1 } }
    func sample() -> EngineSnapshot {
        EngineSnapshot(unit: unit, completed: state.withLock { $0.started ? 10 : 0 },
            detail: "test double", error: runtimeFailure && state.withLock({ $0.started }) ? "execution failed" : nil)
    }
}

private actor PreparationGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func prepare() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
    }

    func waitUntilEntered() async {
        if !entered {
            await withCheckedContinuation { entryWaiter = $0 }
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

/// Polls every 10 ms, so `timeout` counts polls rather than seconds.
@MainActor private func waitFor(timeout: Int = 300, _ condition: () -> Bool) async throws {
    for _ in 0..<timeout {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for lifecycle transition")
}

@MainActor final class SessionTests: XCTestCase {
    func testEveryNonemptySelectionStartsOnlySelectedEngines() async throws {
        for config in RunConfiguration.selfTestSequence().prefix(7) {
            let all = UnitKind.allCases.map { FakeEngine($0) }
            let controller = SessionController(reportRoot: root()) { config in
                all.filter { config.units.contains($0.unit) }
            }
            controller.configuration = config
            controller.start()
            try await waitFor { controller.phase == .running }
            for engine in all {
                XCTAssertEqual(engine.state.withLock { $0.started }, config.units.contains(engine.unit))
            }
            controller.stop()
            try await waitFor { !controller.phase.busy }
            XCTAssertEqual(controller.phase, .completed)
            for engine in all {
                XCTAssertEqual(engine.state.withLock { $0.stops }, config.units.contains(engine.unit) ? 1 : 0)
            }
        }
    }

    func testPreparationFailureCleansUpWithoutPartialStart() async throws {
        let cpu = FakeEngine(.cpu)
        let npu = FakeEngine(.npu, prepareFailure: true)
        let controller = SessionController(reportRoot: root()) { _ in [cpu, npu] }
        controller.start()
        try await waitFor { controller.phase == .failed }
        XCTAssertFalse(cpu.state.withLock { $0.started })
        XCTAssertEqual(cpu.state.withLock { $0.stops }, 1)
        XCTAssertEqual(npu.state.withLock { $0.stops }, 1)
        XCTAssertTrue(controller.message.contains("backend unavailable"))
    }

    func testStopDuringPreparationPreventsLaterStart() async throws {
        let gate = PreparationGate()
        let engine = FakeEngine(.npu, onPrepare: { await gate.prepare() })
        let controller = SessionController(reportRoot: root()) { _ in [engine] }
        controller.start()
        await gate.waitUntilEntered()
        XCTAssertEqual(controller.phase, .preparing)
        controller.stop(reason: "background")
        XCTAssertEqual(controller.phase, .stopping)
        XCTAssertEqual(engine.state.withLock { $0.stops }, 0)
        await gate.release()
        try await waitFor { !controller.phase.busy }
        XCTAssertFalse(engine.state.withLock { $0.started })
        XCTAssertEqual(engine.state.withLock { $0.stops }, 1)
        XCTAssertEqual(controller.phase, .completed)
        XCTAssertEqual(controller.message, "background")
    }

    func testRuntimeFailureStopsWholeSessionAndPersistsFailure() async throws {
        let output = root()
        let cpu = FakeEngine(.cpu)
        let gpu = FakeEngine(.gpu, runtimeFailure: true)
        let controller = SessionController(reportRoot: output) { _ in [cpu, gpu] }
        controller.start()
        try await waitFor { controller.phase == .failed }
        XCTAssertEqual(cpu.state.withLock { $0.stops }, 1)
        let directory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).first)
        let summaryData = try Data(contentsOf: directory.appendingPathComponent("summary.json"))
        let summary = try JSONSerialization.jsonObject(with: summaryData) as? [String: Any]
        XCTAssertEqual(summary?["phase"] as? String, "failed")
        XCTAssertEqual(summary?["reason"] as? String, "execution failed")
    }

    func testTimerAndRepeatedRuns() async throws {
        let controller = SessionController(reportRoot: root()) { _ in [FakeEngine(.cpu)] }
        controller.configuration.durationSeconds = 1
        for _ in 0..<2 {
            controller.start()
            try await waitFor { controller.phase == .completed }
            XCTAssertEqual(controller.message, "定时结束")
        }
    }

    func testInterruptedPrivateANEMarkerIsShownOnceThenCleared() throws {
        let suite = "furnace.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("编译", forKey: SessionController.interruptedPrivateStageKey)

        let first = SessionController(reportRoot: root(), defaults: defaults) { _ in [] }
        XCTAssertEqual(first.interruptedPrivateStage, "编译")
        XCTAssertTrue(first.message.contains("「编译」中断"))
        XCTAssertNil(defaults.string(forKey: SessionController.interruptedPrivateStageKey))

        let second = SessionController(reportRoot: root(), defaults: defaults) { _ in [] }
        XCTAssertNil(second.interruptedPrivateStage)
        XCTAssertEqual(second.message, "选择负载，开始压测")
    }

    func testEmptySelectionFailsBeforeAllocating() {
        let controller = SessionController(reportRoot: root()) { _ in XCTFail("factory must not run"); return [] }
        controller.configuration.units = []
        controller.start()
        XCTAssertEqual(controller.phase, .failed)
    }

    func testCancellingSelfTestRestoresManualConfiguration() async throws {
        let controller = SessionController(reportRoot: root()) { _ in [FakeEngine(.cpu)] }
        controller.configuration.units = [.gpu]
        controller.configuration.durationSeconds = 300
        let original = controller.configuration
        controller.startSelfTest()
        try await waitFor { controller.phase == .running }
        controller.stop()
        try await waitFor { !controller.phase.busy }
        XCTAssertEqual(controller.configuration, original)
        XCTAssertNil(controller.suiteProgress)
    }

    func testReportRoundTripAndCSVQuoting() throws {
        let output = root()
        let config = RunConfiguration()
        let report = try ReportStore(configuration: config, root: output)
        let sample = TelemetrySample(elapsed: 1, cpuPercent: 50, memoryMB: 42, batteryLevel: -1,
            charging: false, thermalState: "严重", engines: [EngineSnapshot(unit: .npu, detail: "a,\"b\"\nc")])
        try report.append(sample)
        try report.finish(phase: .completed, reason: "test", elapsed: 1, engines: sample.engines)
        let lines = try Data(contentsOf: report.directory.appendingPathComponent("samples.jsonl"))
        let loaded = try JSONDecoder().decode(TelemetrySample.self, from: lines)
        XCTAssertEqual(loaded.engines.first?.detail, "a,\"b\"\nc")
        XCTAssertEqual(ReportStore.csvField("a,\"b\""), "\"a,\"\"b\"\"\"")
        XCTAssertEqual(loaded.thermalState, "严重")
        let metadataData = try Data(contentsOf: report.directory.appendingPathComponent("metadata.json"))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
        XCTAssertEqual(Set(metadata.keys), ["appVersion", "build", "configuration", "createdAt", "device",
                                            "id", "measurementNotes", "os", "processors", "schemaVersion"])
    }

    func testNativeCPUProducesFiniteWorkAndStops() async throws {
        let engine = CPUEngine(workers: 1)
        try await engine.prepare()
        engine.start()
        try await Task.sleep(for: .milliseconds(100))
        await engine.stop()
        XCTAssertGreaterThan(engine.sample().completed, 0)
        XCTAssertNil(engine.sample().error)
        let completed = engine.sample().completed
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.sample().completed, completed)
    }

    func testSimulatorDoesNotClaimANEAvailability() async {
        #if targetEnvironment(simulator)
        let engine = NPUEngine(configuration: RunConfiguration())
        do {
            try await engine.prepare()
            XCTFail("Simulator must not claim ANE execution")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("真实 iPhone"))
        }
        await engine.stop()
        #endif
    }

    func testGPUWorkloadsCompleteAndDrainOnSimulatorHost() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Host has no Metal device") }
        for workload in GPUWorkload.allCases {
            let engine = GPUEngine(workload: workload)
            try await engine.prepare()
            engine.start()
            try await Task.sleep(for: .milliseconds(250))
            await engine.stop()
            XCTAssertNil(engine.sample().error, workload.rawValue)
            XCTAssertGreaterThan(engine.sample().completed, 0, workload.rawValue)
            let count = engine.sample().completed
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(engine.sample().completed, count)
        }
    }

    func testBundledModelProducesFiniteInputDependentOutputOnCPU() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Stress256", withExtension: "mlmodelc"))
        let results = try await Task.detached {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: url, configuration: config)
            var results: [Double] = []
            for value in [Float16(0.25), Float16(0.5)] {
                let array = try MLMultiArray(shape: [1, 256, 64, 64], dataType: .float16)
                let buffer = array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)
                for index in 0..<array.count { buffer[index] = value.bitPattern }
                let input = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: array)])
                let output = try model.prediction(from: input)
                guard let data = output.featureValue(for: "result")?.multiArrayValue else {
                    throw LoadError("output missing")
                }
                results.append(data[0].doubleValue)
            }
            return results
        }.value
        XCTAssertTrue(results.allSatisfy { $0.isFinite && $0 > 0 })
        XCTAssertEqual(results[1] / results[0], 2, accuracy: 0.03)
    }
}

// Paths through SessionController.start that the lifecycle tests above do not reach.
@MainActor final class SessionStartPathTests: XCTestCase {
    func testStartWhileBusyIsIgnored() async throws {
        let engine = FakeEngine(.cpu)
        let controller = SessionController(reportRoot: root()) { _ in [engine] }
        controller.start()
        try await waitFor { controller.phase == .running }
        controller.start()
        XCTAssertEqual(controller.phase, .running)
        controller.stop()
        try await waitFor { !controller.phase.busy }
        XCTAssertEqual(controller.phase, .completed)
        XCTAssertEqual(engine.state.withLock { $0.prepares }, 1)
        XCTAssertEqual(engine.state.withLock { $0.stops }, 1)
    }

    func testReportCreationFailureFailsBeforePreparingEngines() async throws {
        // A regular file where the report directory should go makes ReportStore throw.
        let blocked = root()
        try Data().write(to: blocked)
        let engine = FakeEngine(.cpu)
        let controller = SessionController(reportRoot: blocked) { _ in [engine] }
        controller.start()
        try await waitFor { !controller.phase.busy }
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertNotEqual(controller.message, "手动停止")
        XCTAssertEqual(engine.state.withLock { $0.prepares }, 0)
        XCTAssertFalse(engine.state.withLock { $0.started })
        XCTAssertEqual(engine.state.withLock { $0.stops }, 1)
    }

    func testStopDuringFirstPreparationSkipsLaterEngines() async throws {
        let gate = PreparationGate()
        let first = FakeEngine(.cpu, onPrepare: { await gate.prepare() })
        let second = FakeEngine(.gpu)
        let controller = SessionController(reportRoot: root()) { _ in [first, second] }
        controller.start()
        await gate.waitUntilEntered()
        controller.stop(reason: "background")
        await gate.release()
        try await waitFor { !controller.phase.busy }
        XCTAssertEqual(second.state.withLock { $0.prepares }, 0)
        XCTAssertFalse(first.state.withLock { $0.started })
        XCTAssertEqual(first.state.withLock { $0.stops }, 1)
        XCTAssertEqual(second.state.withLock { $0.stops }, 1)
        XCTAssertEqual(controller.phase, .completed)
        XCTAssertEqual(controller.message, "background")
    }

    func testEngineErrorFoundAtStopFailsSession() async throws {
        let engine = FakeEngine(.gpu, runtimeFailure: true)
        let controller = SessionController(reportRoot: root()) { _ in [engine] }
        controller.start()
        try await waitFor { controller.phase == .running }
        // Stop before the first one-second sample, so only the final snapshot carries the error.
        controller.stop()
        try await waitFor { !controller.phase.busy }
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(controller.message, "execution failed")
    }

    func testReportSaveFailureFailsSession() async throws {
        let output = root()
        let controller = SessionController(reportRoot: output) { _ in [FakeEngine(.cpu)] }
        controller.start()
        try await waitFor { controller.phase == .running }
        // Open sample files stay writable; the summary written at the end has no directory left.
        try FileManager.default.removeItem(at: output)
        controller.stop()
        try await waitFor { !controller.phase.busy }
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertTrue(controller.message.hasPrefix("报告保存失败："), controller.message)
    }

    func testTimedSuiteRunContinuesWithNextConfiguration() async throws {
        let output = root()
        let controller = SessionController(reportRoot: output) { _ in [FakeEngine(.npu)] }
        let original = controller.configuration
        controller.startNPUComparison()
        XCTAssertEqual(controller.suiteProgress, "自测 1/3")
        // Each comparison step is timed at 30 seconds.
        try await waitFor(timeout: 4_500) { controller.suiteProgress == "自测 2/3" }
        XCTAssertTrue(controller.phase.busy)
        XCTAssertEqual(controller.configuration.npuConcurrency, 2)
        controller.stop()
        try await waitFor { !controller.phase.busy }
        XCTAssertEqual(controller.phase, .completed)
        XCTAssertEqual(controller.configuration, original)
        XCTAssertNil(controller.suiteProgress)
        let runs = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        XCTAssertEqual(runs.count, 2)
    }
}
