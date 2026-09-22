import Foundation
@preconcurrency import Metal
@preconcurrency import MetalPerformanceShaders

final class GPUEngine: LoadEngine, @unchecked Sendable {
    let unit = UnitKind.gpu
    private let workload: GPUWorkload
    private let state = Locked((stop: true, sample: EngineSnapshot(unit: .gpu), iterations: UInt32(128)))
    private let group = DispatchGroup()
    private let slotsAvailable = DispatchSemaphore(value: 3)
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var pipeline: MTLComputePipelineState!
    private var texture: MTLTexture!
    private var outputs: [MTLBuffer] = []
    private var matrices: [MPSMatrix] = []
    private var left: MPSMatrix!
    private var right: MPSMatrix!
    private var multiplication: MPSMatrixMultiplication!
    private let count = 262_144
    private let matrixSize = 2048

    init(workload: GPUWorkload) { self.workload = workload }

    func prepare() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let function = device.makeDefaultLibrary()?.makeFunction(name: "furnace_compute") else {
            throw LoadError("Metal 设备、队列或内置计算内核不可用")
        }
        self.device = device
        self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)
        for _ in 0..<3 {
            guard let buffer = device.makeBuffer(length: count * MemoryLayout<Float>.stride, options: .storageModeShared) else {
                throw LoadError("GPU 输出缓冲区分配失败")
            }
            outputs.append(buffer)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 256, height: 256, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw LoadError("纹理分配失败") }
        self.texture = texture
        let pixels = (0..<(256 * 256 * 4)).map { Float($0 % 251) / 251 }
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: 256 * 4 * 4)
        }
        if workload != .fp32 {
            let matrixDescriptor = MPSMatrixDescriptor(rows: matrixSize, columns: matrixSize,
                                                       rowBytes: matrixSize * 2, dataType: .float16)
            func matrix() throws -> MPSMatrix {
                guard let buffer = device.makeBuffer(length: matrixSize * matrixSize * 2, options: .storageModeShared) else {
                    throw LoadError("矩阵缓冲区分配失败")
                }
                return MPSMatrix(buffer: buffer, descriptor: matrixDescriptor)
            }
            left = try matrix(); right = try matrix()
            let a = left.data.contents().bindMemory(to: UInt16.self, capacity: matrixSize * matrixSize)
            let b = right.data.contents().bindMemory(to: UInt16.self, capacity: matrixSize * matrixSize)
            for i in 0..<(matrixSize * matrixSize) {
                a[i] = Float16(Float(i % 7 + 1) / 256).bitPattern
                b[i] = Float16(Float(i % 11 + 1) / 256).bitPattern
            }
            matrices = try (0..<3).map { _ in try matrix() }
            multiplication = MPSMatrixMultiplication(device: device, transposeLeft: false, transposeRight: false,
                resultRows: matrixSize, resultColumns: matrixSize, interiorColumns: matrixSize, alpha: 1, beta: 0)
        }
        state.withValue { $0.sample.detail = "Metal · \(workload.rawValue) · 最多 3 个在途批次" }
        try Task.checkCancellation()
    }

    func start() {
        state.withValue { $0.stop = false }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }
            var index = 0
            var serial: UInt32 = 0
            while !state.withValue({ $0.stop }) {
                guard slotsAvailable.wait(timeout: .now() + 0.1) == .success else { continue }
                if state.withValue({ $0.stop }) { slotsAvailable.signal(); break }
                let slot = index % 3
                index += 1
                serial &+= 1
                autoreleasepool { submit(slot: slot, serial: serial) }
            }
        }
    }

    private func submit(slot: Int, serial: UInt32) {
        guard let command = queue.makeCommandBuffer() else {
            fail("无法创建 GPU 命令缓冲区"); slotsAvailable.signal(); return
        }
        command.label = "Furnace batch \(serial)"
        let matrixPass = workload == .matrix || (workload == .mixed && serial % 3 == 0)
        if matrixPass {
            multiplication.encode(commandBuffer: command, leftMatrix: left, rightMatrix: right, resultMatrix: matrices[slot])
        } else {
            guard let encoder = command.makeComputeCommandEncoder() else {
                fail("无法创建 GPU 计算编码器"); slotsAvailable.signal(); return
            }
            var iterations = state.withValue { $0.iterations }
            var seed = serial
            var useTexture: UInt32 = workload == .mixed ? 1 : 0
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(outputs[slot], offset: 0, index: 0)
            encoder.setBytes(&iterations, length: 4, index: 1)
            encoder.setBytes(&seed, length: 4, index: 2)
            encoder.setBytes(&useTexture, length: 4, index: 3)
            encoder.setTexture(texture, index: 0)
            let width = min(256, pipeline.maxTotalThreadsPerThreadgroup)
            encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            encoder.endEncoding()
        }
        group.enter()
        command.addCompletedHandler { [self] buffer in
            defer { slotsAvailable.signal(); group.leave() }
            guard buffer.status == .completed else {
                fail(buffer.error?.localizedDescription ?? "GPU 执行失败"); return
            }
            let ms = max(0, (buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
            let value: Float
            if matrixPass {
                value = Float(Float16(bitPattern: matrices[slot].data.contents().load(as: UInt16.self)))
            } else {
                value = outputs[slot].contents().load(as: Float.self)
            }
            guard value.isFinite, value > 0 else { fail("GPU 输出校验失败"); return }
            state.withValue {
                $0.sample.completed += 1
                $0.sample.lastExecutionMS = ms
                $0.sample.totalExecutionMS += ms
                if !matrixPass && ms > 0 {
                    // Bound individual kernels, not overall duty cycle. Keep
                    // submitting continuously even when thermalState rises.
                    if ms > 35 { $0.iterations = max(16, $0.iterations / 2) }
                    else if ms < 8 { $0.iterations = min(2048, $0.iterations * 2) }
                }
            }
        }
        command.commit()
    }

    private func fail(_ message: String) {
        state.withValue { $0.sample.error = message; $0.stop = true }
    }
    func stop() async {
        state.withValue { $0.stop = true }
        await withCheckedContinuation { continuation in
            group.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
        }
    }
    func sample() -> EngineSnapshot { state.withValue { $0.sample } }
}

