import Foundation

final class CPUEngine: LoadEngine, @unchecked Sendable {
    let unit = UnitKind.cpu
    private let workers: Int
    private let handle: OpaquePointer
    init(workers: Int) {
        self.workers = workers
        self.handle = furnace_cpu_create()!
    }
    deinit { furnace_cpu_destroy(handle) }
    func prepare() async throws { try Task.checkCancellation() }
    func start() { furnace_cpu_start(handle, Int32(workers)) }
    func stop() async {
        furnace_cpu_request_stop(handle)
        await Task.detached(priority: .userInitiated) { [self] in furnace_cpu_join(handle) }.value
    }
    func sample() -> EngineSnapshot {
        EngineSnapshot(unit: .cpu, completed: furnace_cpu_batches(handle),
                       detail: "\(workers) 个工作线程 · 校验 \(String(format: "%.3f", furnace_cpu_checksum(handle)))",
                       error: furnace_cpu_failed(handle) == 0 ? nil : "CPU 计算校验或线程创建失败")
    }
}

