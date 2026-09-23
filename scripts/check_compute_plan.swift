import Foundation
@preconcurrency import CoreML

// Native macOS coverage of the app's compiled-model inspection. ANE availability
// is a host capability result, not a required runner feature or iPhone evidence.
@main
struct CheckComputePlan {
    static func main() async {
        do { try await checkPlans() }
        catch {
            FileHandle.standardError.write(Data("Compute-plan check failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func log(_ message: String) {
        FileHandle.standardOutput.write(Data("\(message)\n".utf8))
    }

    static func checkPlans() async throws {
        guard CommandLine.arguments.count > 1 else { throw LoadError("Provide one or more .mlpackage paths") }
        for path in CommandLine.arguments.dropFirst() {
            log("Compiling \(path)")
            let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: path))
            defer { try? FileManager.default.removeItem(at: compiled) }
            for (name, units) in [("cpuOnly", MLComputeUnits.cpuOnly), ("cpuAndNeuralEngine", .cpuAndNeuralEngine)] {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = units
                let plan = try await MLComputePlan.load(contentsOf: compiled, configuration: configuration)
                let inspection = try NPUComputePlan.inspect(plan)
                log("\(path) / \(name): \(inspection.detail)")
                if case .program(let program) = plan.modelStructure, let main = program.functions["main"] {
                    let bareCount = main.block.operations.filter { $0.operatorName == "conv" }.count
                    log("Exact bare-name matcher: \(bareCount); qualified-name matcher: \(inspection.convolutionCount)")
                }
                guard inspection.convolutionCount == 16 else {
                    throw LoadError("Expected 16 convolutions; \(inspection.detail)")
                }
                if units == .cpuOnly {
                    guard inspection.cpuCount == 16, inspection.aneCount == 0 else {
                        throw LoadError("CPU-only plan must not be reported as NPU load")
                    }
                }
                if inspection.aneCount == 16 {
                    try inspection.requireANE()
                    log("Host plan accepted; actual iPhone execution still requires device evidence")
                } else {
                    do { try inspection.requireANE() }
                    catch {
                        log("NPU start correctly refused: \(error.localizedDescription)")
                        continue
                    }
                    throw LoadError("A plan with CPU, GPU or unknown convolution assignments was accepted")
                }
            }
        }
    }
}
