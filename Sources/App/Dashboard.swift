import SwiftUI
import Charts

private enum InstrumentStyle {
    static let ink = Color(red: 0.09, green: 0.17, blue: 0.23)
    static let background = Color(red: 0.94, green: 0.95, blue: 0.96)
    static func color(_ unit: UnitKind) -> Color {
        switch unit {
        case .cpu: Color(red: 0.73, green: 0.24, blue: 0.23)
        case .gpu: Color(red: 0.22, green: 0.47, blue: 0.68)
        case .npu: Color(red: 0.13, green: 0.50, blue: 0.47)
        }
    }
}

struct Dashboard: View {
    @Bindable var session: SessionController
    @State private var showPrivateConfirmation = false
    @State private var showReports = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    selectors
                    readings
                    configuration
                    Text("单烤只开启对应压力引擎；GPU 与 NPU 仍需要 CPU 调度。热状态只记录，不主动减载。")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button("运行完整自测") { session.startSelfTest() }
                            .disabled(session.phase.busy)
                        Spacer()
                        Button("历史报告") { showReports = true }
                    }.font(.subheadline.weight(.semibold))
                    Text("完整自测约 22 分钟：七种组合各 1 分钟，三路联合 15 分钟。模型准备时间另计。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("比较 NPU 1 / 2 / 4 路并发") { session.startNPUComparison() }
                        .font(.subheadline.weight(.semibold)).disabled(session.phase.busy)
                    Text("使用当前通道数，每档运行 30 秒并保存独立报告。比较吞吐量，不将最快档位称为最高功耗。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(22)
            }
            .background(InstrumentStyle.background)
            .foregroundStyle(InstrumentStyle.ink)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            .sheet(isPresented: $showReports) { ReportsView(reports: session.reports) }
            .confirmationDialog("启用私有 ANE 实验后端", isPresented: $showPrivateConfirmation, titleVisibility: .visible) {
                Button("启用实验后端") { session.configuration.npuBackend = .experimental }
                Button("取消", role: .cancel) { }
            } message: {
                Text("接口可能不可用或使应用退出。首次运行将测试编译、加载和输出。下次启动仍默认使用 Core ML。")
            }
        }.tint(InstrumentStyle.ink)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Furnace").font(.system(size: 38, weight: .heavy, design: .rounded))
                Spacer()
                Text(session.suiteProgress ?? session.phase.label).font(.subheadline.weight(.medium))
            }
            HStack(alignment: .firstTextBaseline) {
                Text("计算负载实验室").font(.subheadline)
                Spacer()
                Text(duration(session.elapsed)).font(.title2.monospacedDigit())
                    .accessibilityLabel("已运行 \(Int(session.elapsed)) 秒")
            }
            Text(session.message).font(.footnote)
                .foregroundStyle(session.phase == .failed ? .red : .secondary)
                .frame(minHeight: 34, alignment: .topLeading)
        }
    }

    private var selectors: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ForEach(UnitKind.allCases) { unit in
                    let enabled = session.configuration.units.contains(unit)
                    Button {
                        if enabled { session.configuration.units.remove(unit) }
                        else { session.configuration.units.insert(unit) }
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(unit.rawValue).font(.title2.weight(.bold))
                            Text(enabled ? "已开启" : "已关闭").font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .foregroundStyle(enabled ? .white : InstrumentStyle.ink)
                            .background(enabled ? InstrumentStyle.color(unit) : .white,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(unit.rawValue)，\(enabled ? "已开启" : "已关闭")")
                }
            }
            HStack {
                Button("三路全开") { session.configuration.units = Set(UnitKind.allCases) }
                Spacer()
                ForEach(UnitKind.allCases) { unit in
                    Button("仅 \(unit.rawValue)") { session.configuration.units = [unit] }
                }
            }.font(.caption.weight(.semibold))
        }.disabled(session.phase.busy)
    }

    private var readings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("进程 CPU").font(.headline)
                Spacer()
                Text(session.samples.last.map { String(format: "%.1f%%", $0.cpuPercent) } ?? "—")
                    .font(.title.monospacedDigit().weight(.semibold))
            }
            Chart(Array(session.samples.enumerated()), id: \.offset) { _, sample in
                LineMark(x: .value("秒", sample.elapsed), y: .value("CPU %", sample.cpuPercent))
                    .foregroundStyle(InstrumentStyle.color(.cpu))
            }.chartYScale(domain: 0...100).chartXAxis(.hidden).frame(height: 90)
            ForEach(UnitKind.allCases) { unit in
                let snapshot = session.snapshots.first { $0.unit == unit }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(unit.rawValue).font(.subheadline.weight(.bold)).foregroundStyle(InstrumentStyle.color(unit))
                        Spacer()
                        Text(rate(unit)).font(.body.monospacedDigit())
                        if unit != .cpu {
                            Text(snapshot.map { String(format: "%.1f ms", $0.lastExecutionMS) } ?? "— ms")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Text(snapshot?.detail ?? "未运行").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                stat("内存", session.samples.last.map { String(format: "%.0f MB", $0.memoryMB) } ?? "—")
                Spacer()
                stat("电量", battery)
                Spacer()
                stat("热状态", session.samples.last?.thermalState ?? "—")
            }
            Text("GPU 显示本应用执行耗时；ANE 占用率、芯片温度和功耗瓦数不可用。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 12))
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("负载设置").font(.headline)
            Stepper("CPU 工作线程：\(session.configuration.cpuWorkers)", value: $session.configuration.cpuWorkers,
                    in: 1...ProcessInfo.processInfo.processorCount * 2)
            Picker("GPU 工作负载", selection: $session.configuration.gpuWorkload) {
                ForEach(GPUWorkload.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("NPU 模型通道", selection: $session.configuration.npuChannels) {
                ForEach([256, 384, 512], id: \.self) { Text(String($0)).tag($0) }
            }
            Picker("NPU 并发请求", selection: $session.configuration.npuConcurrency) {
                ForEach([1, 2, 4], id: \.self) { Text(String($0)).tag($0) }
            }.disabled(session.configuration.npuBackend == .experimental)
            HStack {
                Text("NPU 后端")
                Spacer()
                Button(session.configuration.npuBackend.rawValue) {
                    if session.configuration.npuBackend == .coreML { showPrivateConfirmation = true }
                    else { session.configuration.npuBackend = .coreML }
                }.fontWeight(.semibold)
            }
            Picker("持续时间", selection: $session.configuration.durationSeconds) {
                Text("持续运行").tag(0)
                Text("5 分钟").tag(300)
                Text("15 分钟").tag(900)
                Text("30 分钟").tag(1800)
                if session.suiteProgress != nil {
                    Text("自测 1 分钟").tag(60)
                    Text("并发比较 30 秒").tag(30)
                }
            }
        }.font(.subheadline).disabled(session.phase.busy)
    }

    private var controls: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.phase.busy ? "前台持续运行" : "负载已选择 \(session.configuration.units.count)/3")
                    .font(.subheadline.weight(.semibold))
                Text(session.phase.busy ? "锁屏或退后台将结束" : "结果保存在手机本地")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(session.phase.busy ? "停止" : "开始压测") {
                if session.phase.busy { session.stop() } else { session.start() }
            }.font(.headline).foregroundStyle(.white).padding(.horizontal, 26).padding(.vertical, 15)
                .background(session.phase.busy ? InstrumentStyle.color(.cpu) : InstrumentStyle.ink,
                            in: RoundedRectangle(cornerRadius: 10))
                .disabled(session.phase == .stopping || (!session.phase.busy && session.configuration.units.isEmpty))
        }.padding(.horizontal, 22).padding(.vertical, 12).background(.regularMaterial)
    }

    private func stat(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospacedDigit().weight(.medium))
        }
    }
    private func duration(_ seconds: Double) -> String {
        let value = Int(seconds)
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
    private var battery: String {
        guard let sample = session.samples.last, sample.batteryLevel >= 0 else { return "—" }
        return "\(Int(sample.batteryLevel * 100))%" + (sample.charging ? " 充电" : "")
    }
    private func rate(_ unit: UnitKind) -> String {
        guard session.samples.count >= 2 else { return "— 次/秒" }
        let last = session.samples[session.samples.count - 1]
        let previous = session.samples[session.samples.count - 2]
        guard let a = last.engines.first(where: { $0.unit == unit }),
              let b = previous.engines.first(where: { $0.unit == unit }) else { return "— 次/秒" }
        let perSecond = Double(a.completed - min(a.completed, b.completed)) / max(0.001, last.elapsed - previous.elapsed)
        return String(format: "%.1f 次/秒", perSecond)
    }
}

private struct ReportsView: View {
    let reports: [URL]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if reports.isEmpty { Text("运行一次压测后，报告会出现在这里。") }
                ForEach(reports, id: \.self) { directory in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(directory.lastPathComponent).font(.caption.monospacedDigit())
                        ShareLink(items: ReportStore.exportFiles(directory)) { Text("导出 JSON / CSV") }
                    }.padding(.vertical, 6)
                }
                Text("也可以在“文件”App 的“我的 iPhone / Furnace / Reports”中读取。没有 summary.json 的会话表示曾中断，不计作通过。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("压测报告")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
