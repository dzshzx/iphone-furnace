import Foundation
@preconcurrency import CoreML

enum NPUComputePlan {
    static func convolutions(in block: MLModelStructure.Program.Block) -> [MLModelStructure.Program.Operation] {
        block.operations.filter { $0.operatorName == "conv" }
    }
}
