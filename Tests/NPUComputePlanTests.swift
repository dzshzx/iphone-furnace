import XCTest
@preconcurrency import CoreML
@testable import Furnace

final class NPUComputePlanTests: XCTestCase {
    func testQualifiedConvolutionNamesMatchWithoutAcceptingOtherOperators() {
        for name in ["conv", "ios17.conv", "ios18.conv", "macOS15.conv"] {
            XCTAssertTrue(NPUComputePlan.isConvolution(name), name)
        }
        for name in ["", "conv_0", "conv_transpose", "ios17.conv_transpose", "conv.", "ios18.relu"] {
            XCTAssertFalse(NPUComputePlan.isConvolution(name), name)
        }
    }

    func testOnlyNonemptyEntirelyANEAssignmentsCanStart() throws {
        let accepted = NPUComputePlan.Inspection(operatorCounts: ["ios17.conv": 16],
                                               convolutionDevices: Array(repeating: .ane, count: 16))
        XCTAssertNoThrow(try accepted.requireANE())
        for device in [NPUComputePlan.Device.cpu, .gpu, .unknown] {
            let rejected = NPUComputePlan.Inspection(operatorCounts: ["ios17.conv": 16],
                convolutionDevices: Array(repeating: .ane, count: 15) + [device])
            XCTAssertThrowsError(try rejected.requireANE()) { error in
                XCTAssertTrue(error.localizedDescription.contains("15/16"))
            }
            XCTAssertEqual(rejected.cpuCount + rejected.gpuCount + rejected.unknownCount, 1)
        }
    }

    func testMissingConvolutionsAreReportedAsUnrecognizedRatherThanCPUFallback() {
        let inspection = NPUComputePlan.Inspection(operatorCounts: ["future.fused_compute": 1],
                                                 convolutionDevices: [])
        XCTAssertThrowsError(try inspection.requireANE()) { error in
            XCTAssertTrue(error.localizedDescription.contains("无法识别"))
            XCTAssertTrue(error.localizedDescription.contains("future.fused_compute"))
            XCTAssertFalse(error.localizedDescription.contains("CPU 回退"))
        }
        XCTAssertTrue(inspection.detail.contains("future.fused_compute=1"))
        let empty = NPUComputePlan.Inspection(operatorCounts: [:], convolutionDevices: [])
        XCTAssertThrowsError(try empty.requireANE())
    }

    @MainActor func testRealCompiledCPUPlansRecognizeAllConvolutionsAndRejectNPUStart() async throws {
        for channels in [256, 384, 512] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Stress\(channels)", withExtension: "mlmodelc"))
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
            let inspection = try NPUComputePlan.inspect(plan)
            XCTAssertEqual(inspection.convolutionCount, 16, inspection.detail)
            XCTAssertEqual(inspection.cpuCount, 16, inspection.detail)
            XCTAssertEqual(inspection.aneCount, 0, inspection.detail)
            XCTAssertThrowsError(try inspection.requireANE()) { error in
                XCTAssertTrue(error.localizedDescription.contains("0/16"))
            }
        }
    }
}
