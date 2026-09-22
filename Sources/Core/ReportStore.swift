import Foundation
import UIKit

struct RunMetadata: Codable {
    let schemaVersion: Int
    let id: String
    let createdAt: Date
    let device: String
    let os: String
    let appVersion: String
    let build: String
    let processors: Int
    let configuration: RunConfiguration
    let measurementNotes: [String]
}

struct RunSummary: Codable {
    let finishedAt: Date
    let phase: SessionPhase
    let reason: String
    let elapsed: Double
    let engines: [EngineSnapshot]
    let droppedSamples: Int
}

// One session is a JSON metadata file, append-only JSONL samples, CSV and a
// summary. Bounded disk/memory use lets an unlimited run stay unlimited.
@MainActor final class ReportStore {
    let directory: URL
    private let encoder: JSONEncoder
    private var jsonFile: FileHandle?
    private var csvFile: FileHandle?
    private var bytesWritten = 0
    private(set) var droppedSamples = 0
    private let limit = 64 * 1024 * 1024

    init(configuration: RunConfiguration, root: URL? = nil) throws {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let id = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
        let parent = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reports", isDirectory: true)
        directory = parent.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var machine = utsname()
        uname(&machine)
        let device = withUnsafeBytes(of: &machine.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let metadata = RunMetadata(schemaVersion: 1, id: id, createdAt: Date(), device: device,
            os: UIDevice.current.systemVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local",
            processors: ProcessInfo.processInfo.processorCount, configuration: configuration,
            measurementNotes: ["CPU 为进程时间 / 墙钟时间 / 核心数；含调度开销", "GPU 为本应用 command buffer 执行耗时，不是整颗 GPU 利用率",
                               "Core ML 分配计划不是实际 ANE 占用率", "无实测瓦数、芯片温度或 ANE 利用率", "64 MiB 后停止逐秒写盘，保留最终累计读数"])
        try encoder.encode(metadata).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
        for name in ["samples.jsonl", "samples.csv"] {
            guard FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil) else {
                throw LoadError("无法创建报告文件")
            }
        }
        jsonFile = try FileHandle(forWritingTo: directory.appendingPathComponent("samples.jsonl"))
        csvFile = try FileHandle(forWritingTo: directory.appendingPathComponent("samples.csv"))
        try csvFile?.write(contentsOf: Data("elapsed_s,cpu_percent,memory_mb,battery_level,charging,thermal,unit,completed,total_execution_ms,last_execution_ms,detail,error\n".utf8))
    }

    func append(_ sample: TelemetrySample) throws {
        guard bytesWritten < limit else { droppedSamples += 1; return }
        var data = try encoder.encode(sample)
        data.append(10)
        try jsonFile?.write(contentsOf: data)
        let csv = sample.engines.map { engine in
            [String(sample.elapsed), String(sample.cpuPercent), String(sample.memoryMB), String(sample.batteryLevel),
             String(sample.charging), sample.thermalState, engine.unit.rawValue, String(engine.completed),
             String(engine.totalExecutionMS), String(engine.lastExecutionMS), engine.detail, engine.error ?? ""]
                .map(Self.csvField).joined(separator: ",")
        }.joined(separator: "\n") + "\n"
        let csvData = Data(csv.utf8)
        try csvFile?.write(contentsOf: csvData)
        bytesWritten += data.count + csvData.count
    }

    func finish(phase: SessionPhase, reason: String, elapsed: Double, engines: [EngineSnapshot]) throws {
        let summary = RunSummary(finishedAt: Date(), phase: phase, reason: reason, elapsed: elapsed,
                                 engines: engines, droppedSamples: droppedSamples)
        try encoder.encode(summary).write(to: directory.appendingPathComponent("summary.json"), options: .atomic)
        try jsonFile?.synchronize(); try csvFile?.synchronize()
        try jsonFile?.close(); try csvFile?.close()
        jsonFile = nil; csvFile = nil
    }

    static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func recentReports() -> [URL] {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Reports")
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func exportFiles(_ directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

