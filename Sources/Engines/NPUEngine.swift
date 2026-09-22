import Foundation
@preconcurrency import CoreML

private final class PredictionWorker: @unchecked Sendable {
    let model: MLModel
    let input: MLDictionaryFeatureProvider
    let array: MLMultiArray
    init(url: URL, configuration: MLModelConfiguration, channels: Int) throws {
        model = try MLModel(contentsOf: url, configuration: configuration)
        array = try MLMultiArray(shape: [1, NSNumber(value: channels), 64, 64], dataType: .float16)
        let values = array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)
        for i in 0..<array.count { values[i] = Float16(0.2 + Float(i % 29) / 100).bitPattern }
        input = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: array)])
    }
    func predict(serial: UInt64) throws {
        // Change input between calls to detect stale outputs in the private
        // backend and avoid benchmarking a constant graph in either backend.
        array.dataPointer.storeBytes(of: Float16(0.2 + Float(serial % 13) / 100).bitPattern, as: UInt16.self)
        let result = try model.prediction(from: input)
        guard let output = result.featureValue(for: "result")?.multiArrayValue else {
            throw LoadError("Core ML 没有返回模型输出")
        }
        for index in stride(from: 0, to: output.count, by: max(1, output.count / 16)) {
            let value = output[index].doubleValue
            guard value.isFinite, value > 0 else { throw LoadError("Core ML 输出数值校验失败") }
        }
    }
}

final class NPUEngine: LoadEngine, @unchecked Sendable {
    let unit = UnitKind.npu
    private let config: RunConfiguration
    private let state = Locked((stop: true, sample: EngineSnapshot(unit: .npu)))
    private let group = DispatchGroup()
    private var workers: [PredictionWorker] = []
    private var privateBridge: FurnaceANE?

    init(configuration: RunConfiguration) { config = configuration }

    func prepare() async throws {
        #if targetEnvironment(simulator)
        throw LoadError("NPU 压测需要真实 iPhone；模拟器不代表 ANE 执行")
        #else
        if config.npuBackend == .experimental {
            let bridge = FurnaceANE()
            privateBridge = bridge
            try bridge.prepare(channels: config.npuChannels)
            state.withValue { $0.sample.detail = "私有 ANE · 编译/加载/双输入校验通过 · 串行执行" }
            return
        }
        guard let url = Bundle.main.url(forResource: "Stress\(config.npuChannels)", withExtension: "mlmodelc") else {
            throw LoadError("内置 Core ML 模型缺失，请重新下载完整 IPA")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
        guard case .program(let program) = plan.modelStructure,
              let main = program.functions["main"] else { throw LoadError("无法检查模型计算计划") }
        let convolutions = main.block.operations.filter { $0.operatorName == "conv" }
        var aneCount = 0
        for operation in convolutions {
            if let usage = plan.deviceUsage(for: operation), case .neuralEngine = usage.preferred {
                aneCount += 1
            }
        }
        guard !convolutions.isEmpty, aneCount == convolutions.count else {
            throw LoadError("模型卷积未全部预计分配到 ANE（\(aneCount)/\(convolutions.count)）；不将 CPU 回退计作 NPU 压测")
        }
        for _ in 0..<config.npuConcurrency {
            try Task.checkCancellation()
            let worker = try PredictionWorker(url: url, configuration: configuration, channels: config.npuChannels)
            for serial in 0..<3 { try worker.predict(serial: UInt64(serial)) }
            workers.append(worker)
        }
        state.withValue {
            $0.sample.detail = "Core ML · 预计 ANE \(aneCount)/\(convolutions.count) 卷积 · \(config.npuConcurrency) 路 · 实际执行位置待验证"
        }
        #endif
    }

    func start() {
        state.withValue { $0.stop = false }
        let count = config.npuBackend == .experimental ? 1 : workers.count
        for index in 0..<count {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { group.leave() }
                var serial: UInt64 = 0
                while !state.withValue({ $0.stop }) {
                    autoreleasepool {
                        let start = ProcessInfo.processInfo.systemUptime
                        do {
                            if let privateBridge {
                                try privateBridge.evaluate(input: serial % 2 == 0 ? 0.25 : 0.5)
                            } else {
                                try workers[index].predict(serial: serial)
                            }
                            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                            state.withValue {
                                $0.sample.completed += 1
                                $0.sample.lastExecutionMS = ms
                                $0.sample.totalExecutionMS += ms
                            }
                        } catch {
                            state.withValue { $0.stop = true; $0.sample.error = error.localizedDescription }
                        }
                    }
                    serial &+= 1
                }
            }
        }
    }

    func stop() async {
        state.withValue { $0.stop = true }
        await withCheckedContinuation { continuation in
            group.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
        }
        // Stop also runs after partial preparation. Cleanup must happen outside
        // the main actor because a private unload may call into an XPC service.
        privateBridge?.close()
        privateBridge = nil
        workers.removeAll()
    }
    func sample() -> EngineSnapshot { state.withValue { $0.sample } }
}
