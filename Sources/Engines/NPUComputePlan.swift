import Foundation
@preconcurrency import CoreML

enum NPUComputePlan {
    enum Device: Sendable {
        case ane, cpu, gpu, unknown
    }

    struct Inspection: Sendable {
        let operatorCounts: [String: Int]
        let convolutionDevices: [Device]

        var convolutionCount: Int { convolutionDevices.count }
        var aneCount: Int { convolutionDevices.filter { $0 == .ane }.count }
        var cpuCount: Int { convolutionDevices.filter { $0 == .cpu }.count }
        var gpuCount: Int { convolutionDevices.filter { $0 == .gpu }.count }
        var unknownCount: Int { convolutionDevices.filter { $0 == .unknown }.count }
        var operatorSummary: String {
            operatorCounts.keys.sorted().map { "\($0)=\(operatorCounts[$0]!)" }.joined(separator: ", ")
        }
        var detail: String {
            "Core ML · 预计 ANE \(aneCount)/\(convolutionCount) 卷积 · CPU \(cpuCount) / GPU \(gpuCount) / 未知 \(unknownCount) · 算子：\(operatorSummary)"
        }

        func requireANE() throws {
            guard convolutionCount > 0 else {
                throw LoadError("无法识别计算计划中的卷积，尚未确认 ANE 分配（算子：\(operatorSummary)）")
            }
            guard aneCount == convolutionCount else {
                throw LoadError("模型卷积未全部预计分配到 ANE（\(aneCount)/\(convolutionCount)；CPU \(cpuCount) / GPU \(gpuCount) / 未知 \(unknownCount)）；不将 CPU 回退计作 NPU 压测")
            }
        }
    }

    static func isConvolution(_ operatorName: String) -> Bool {
        // Compute plans may qualify MIL operators, e.g. "ios17.conv".
        // Match the complete operator kind, never a substring such as "conv_0".
        operatorName.split(separator: ".", omittingEmptySubsequences: false).last == "conv"
    }

    static func convolutions(in block: MLModelStructure.Program.Block) -> [MLModelStructure.Program.Operation] {
        block.operations.filter { isConvolution($0.operatorName) }
    }

    static func inspect(_ plan: MLComputePlan) throws -> Inspection {
        guard case .program(let program) = plan.modelStructure,
              let main = program.functions["main"] else { throw LoadError("无法检查模型计算计划") }
        let counts = Dictionary(grouping: main.block.operations, by: \.operatorName).mapValues(\.count)
        let devices: [Device] = convolutions(in: main.block).map { operation in
            guard let usage = plan.deviceUsage(for: operation) else { return .unknown }
            switch usage.preferred {
            case .neuralEngine: return .ane
            case .cpu: return .cpu
            case .gpu: return .gpu
            @unknown default: return .unknown
            }
        }
        return Inspection(operatorCounts: counts, convolutionDevices: devices)
    }
}
