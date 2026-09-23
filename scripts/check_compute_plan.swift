import Foundation
@preconcurrency import CoreML

// A native macOS check of the same compiled-model inspection used by the app.
// CPU-only planning keeps this useful on runners without an accessible ANE.
@main
struct CheckComputePlan {
    static func main() async throws {
        for path in CommandLine.arguments.dropFirst() {
            let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: path))
            defer { try? FileManager.default.removeItem(at: compiled) }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            let plan = try await MLComputePlan.load(contentsOf: compiled, configuration: configuration)
            guard case .program(let program) = plan.modelStructure,
                  let main = program.functions["main"] else {
                throw NSError(domain: "Furnace.ComputePlan", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Missing main ML Program"])
            }
            let names = Set(main.block.operations.map(\.operatorName)).sorted()
            let convolutions = NPUComputePlan.convolutions(in: main.block)
            print("\(path): operators=\(names), recognizedConvolutions=\(convolutions.count)")
            guard convolutions.count == 16 else {
                throw NSError(domain: "Furnace.ComputePlan", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Expected 16 convolutions; found \(convolutions.count)"])
            }
        }
    }
}
