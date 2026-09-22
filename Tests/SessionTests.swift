import XCTest
@testable import Furnace

private final class FakeEngine: LoadEngine, @unchecked Sendable {
    let unit: UnitKind
    let prepareFailure: Bool
    let runtimeFailure: Bool
    let delay: Duration
    let state = Locked((started: false, stops: 0))
    init(_ unit: UnitKind, prepareFailure: Bool = false, runtimeFailure: Bool = false, delay: Duration = .zero) {
        self.unit = unit; self.prepareFailure = prepareFailure
        self.runtimeFailure = runtimeFailure; self.delay = delay
    }
    func prepare() async throws {
        if delay != .zero { try await Task.sleep(for: delay) }
        if prepareFailure { throw LoadError("backend unavailable") }
    }
    func start() { state.withValue { $0.started = true } }
    func stop() async { state.withValue { $0.stops += 1 } }
    func sample() -> EngineSnapshot {
        EngineSnapshot(unit: unit, completed: state.withValue { $0.started ? 10 : 0 },
            detail: "test double", error: runtimeFailure && state.withValue({ $0.started }) ? "execution failed" : nil)
    }
}

@MainActor final class SessionTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func waitFor(_ condition: () -> Bool, timeout: Int = 300) async throws {
        for _ in 0..<timeout {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for lifecycle transition")
    }

    func testEveryNonemptySelectionStartsOnlySelectedEngines() async throws {
        for config in RunConfiguration.selfTestSequence().prefix(7) {
            let all = UnitKind.allCases.map { FakeEngine($0) }
            let controller = SessionController(reportRoot: root()) { config in all.filter { config.units.contains($0.unit) } }
            controller.configuration = config
            controller.start()
            try await waitFor { controller.phase == .running }
            for engine in all { XCTAssertEqual(engine.state.withValue { $0.started }, config.units.contains(engine.unit)) }
            controller.stop()
            try await waitFor { !controller.phase.busy }
            XCTAssertEqual(controller.phase, .completed)
            for engine in all { XCTAssertEqual(engine.state.withValue { $0.stops }, config.units.contains(engine.unit) ? 1 : 0) }
        }
    }

    func testPreparationFailureCleansUpWithoutPartialStart() async throws {
        let cpu = FakeEngine(.cpu)
        let npu = FakeEngine(.npu, prepareFailure: true)
        let controller = SessionController(reportRoot: root()) { _ in [cpu, npu] }
        controller.start()
        try await waitFor { controller.phase == .failed }
        XCTAssertFalse(cpu.state.withValue { $0.started })
        XCTAssertEqual(cpu.state.withValue { $0.stops }, 1)
        XCTAssertEqual(npu.state.withValue { $0.stops }, 1)
        XCTAssertTrue(controller.message.contains("backend unavailable"))
    }

    func testStopDuringPreparationPreventsLaterStart() async throws {
        let engine = FakeEngine(.npu, delay: .seconds(1))
        let controller = SessionController(reportRoot: root()) { _ in [engine] }
        controller.start()
        try await Task.sleep(for: .milliseconds(20))
        controller.stop(reason: "background")
        try await waitFor { !controller.phase.busy }
        XCTAssertFalse(engine.state.withValue { $0.started })
        XCTAssertEqual(controller.message, "background")
    }

    func testRuntimeFailureStopsWholeSessionAndPersistsFailure() async throws {
        let output = root()
        let cpu = FakeEngine(.cpu)
        let gpu = FakeEngine(.gpu, runtimeFailure: true)
        let controller = SessionController(reportRoot: output) { _ in [cpu, gpu] }
        controller.start()
        try await waitFor { controller.phase == .failed }
        XCTAssertEqual(cpu.state.withValue { $0.stops }, 1)
        let directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).first)
        let summary = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("summary.json"))) as? [String: Any]
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

    func testEmptySelectionFailsBeforeAllocating() {
        let controller = SessionController(reportRoot: root()) { _ in XCTFail("factory must not run"); return [] }
        controller.configuration.units = []
        controller.start()
        XCTAssertEqual(controller.phase, .failed)
    }

    func testReportRoundTripAndCSVQuoting() throws {
        let output = root()
        let config = RunConfiguration()
        let report = try ReportStore(configuration: config, root: output)
        let sample = TelemetrySample(elapsed: 1, cpuPercent: 50, memoryMB: 42, batteryLevel: -1,
            charging: false, thermalState: "严重", engines: [EngineSnapshot(unit: .npu, detail: "a,\"b\"\nc")])
        try report.append(sample)
        try report.finish(phase: .completed, reason: "test", elapsed: 1, engines: sample.engines)
        let loaded = try JSONDecoder().decode(TelemetrySample.self, from: Data(contentsOf: report.directory.appendingPathComponent("samples.jsonl")))
        XCTAssertEqual(loaded.engines.first?.detail, "a,\"b\"\nc")
        XCTAssertEqual(ReportStore.csvField("a,\"b\""), "\"a,\"\"b\"\"\"")
        XCTAssertEqual(loaded.thermalState, "严重")
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
        do { try await engine.prepare(); XCTFail("Simulator must not claim ANE execution") }
        catch { XCTAssertTrue(error.localizedDescription.contains("真实 iPhone")) }
        await engine.stop()
        #endif
    }
}

