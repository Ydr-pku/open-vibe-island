import SwiftUI

struct CPUHostButtons: View {
    @ObservedObject var monitor: CPUMonitorStore

    var body: some View {
        HStack(spacing: 8) {
            ForEach(monitor.hosts) { host in
                Button { monitor.toggle(host.id) } label: {
                    HStack(spacing: 7) {
                        if host.state == .connecting {
                            ProgressView().controlSize(.mini).frame(width: 8, height: 8)
                        } else {
                            Image(systemName: host.state == .disconnected ? "circle" : "checkmark.circle.fill")
                                .font(.system(size: 11)).foregroundStyle(statusColor(host))
                        }
                        Text(host.id).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .foregroundStyle(host.state != .disconnected ? .cyan : .white.opacity(0.8))
                    .background(host.state != .disconnected ? .cyan.opacity(0.12) : .white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(host.state != .disconnected ? .cyan.opacity(0.35) : .white.opacity(0.08))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cpu.connect.\(host.id)")
                .accessibilityValue(host.state == .disconnected ? LanguageManager.shared.t("cpu.unselected") : LanguageManager.shared.t("cpu.selected"))
            }
        }
    }

    private func statusColor(_ host: CPUHostState) -> Color {
        switch host.state {
        case .connected: return .green
        case .connecting: return .cyan
        case .failed: return .orange
        case .disconnected: return .white.opacity(0.25)
        }
    }
}

struct CPUUsagePanel: View {
    @ObservedObject var monitor: CPUMonitorStore
    let hostID: String
    private var lang: LanguageManager { .shared }

    var body: some View {
        if let host = monitor.hosts.first(where: { $0.id == hostID }) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let fresh = host.isFresh(at: context.date, interval: monitor.refreshInterval)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu").foregroundStyle(.cyan)
                        Text("CPU · \(host.id)").fontWeight(.semibold)
                        Spacer(minLength: 0)
                        CPUFanIndicators(host: host, date: context.date)
                        Spacer(minLength: 0)
                        if let sample = host.snapshot {
                            Text(lang.t("cpu.total")).foregroundStyle(.secondary)
                            Text(NPUIslandPresentation.percentage(fresh ? sample.totalUsage : nil))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(fresh ? cpuUsageColor(sample.totalUsage) : .secondary)
                        }
                        if host.isRetrying { Text(lang.t("cpu.retrying")).foregroundStyle(.orange) }
                        if host.state == .failed && !host.isRetrying {
                            Button(lang.t("cpu.retry")) { monitor.connect(host.id) }
                        }
                        Button { monitor.disconnect(host.id) } label: { Image(systemName: "xmark.circle") }
                            .help(lang.t("npu.disconnect"))
                            .accessibilityLabel(lang.t("npu.disconnect"))
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .buttonStyle(.plain)
                    .frame(height: 16)

                    if let sample = host.snapshot {
                        ScrollView(.vertical) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CPUGridLayout.gap),
                                                     count: CPUGridLayout.columns), spacing: CPUGridLayout.gap) {
                                ForEach(sample.cores) { core in
                                    CPUCoreTile(core: core, fresh: fresh)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: CPUGridLayout.gridHeight(for: sample.cores.count))

                        HStack {
                            Circle().fill(fresh ? .green.opacity(0.8) : .orange).frame(width: 4, height: 4)
                                .accessibilityLabel(fresh ? lang.t("cpu.live") : lang.t("cpu.stale"))
                            Text("\(sample.platform) · \(lang.t("cpu.logicalCores", sample.cores.count))")
                                .foregroundStyle(fresh ? Color.secondary : .orange)
                            Spacer()
                            if let date = host.lastUpdated {
                                Text(date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 8, design: .monospaced)).frame(height: 10)
                        .help(host.errorMessage ?? sample.cpuModel ?? sample.hostname)
                    } else {
                        HStack(spacing: 10) {
                            if host.state == .connecting { ProgressView().controlSize(.small) }
                            Text(host.errorMessage ?? lang.t("cpu.connecting"))
                                .font(.system(size: 11))
                                .foregroundStyle(host.state == .failed ? .orange : .secondary)
                                .lineLimit(3).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .help(host.errorMessage ?? "")
                    }
                }
                .padding(8)
                .frame(height: CPUGridLayout.panelHeight(for: host), alignment: .top)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.06)) }
            }
        }
    }
}

private struct CPUFanIndicators: View {
    let host: CPUHostState
    let date: Date
    private var lang: LanguageManager { .shared }
    private var fresh: Bool { host.fansAreFresh(at: date) }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "fanblades").foregroundStyle(.secondary)
            if let fans = host.fanSnapshot?.fans, !fans.isEmpty {
                ForEach(fans) { fan in
                    HStack(spacing: 3) {
                        if fresh, let rpm = fan.rpm {
                            Text("\(Int(rpm.rounded())) RPM")
                            if let percentage = fan.percentage {
                                Text("\(Int(percentage.rounded()))%")
                                    .fontWeight(.semibold)
                            }
                        } else {
                            Text("—")
                        }
                    }
                    .foregroundStyle(color(fan))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(color(fan).opacity(0.10), in: Capsule())
                    .help(detail(fan))
                    .accessibilityLabel(detail(fan))
                }
            } else {
                Text("—").foregroundStyle(.secondary)
                    .help(placeholderHelp)
                    .accessibilityLabel(placeholderHelp)
            }
        }
        .font(.system(size: 8, design: .monospaced))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cpu.fans.\(host.id)")
    }

    private var placeholderHelp: String {
        if !FanCollector.supports(host.id) { return lang.t("fan.unsupported") }
        if let error = host.fanError { return error }
        return lang.t(host.fanSnapshot == nil ? "fan.waiting" : "fan.unavailable")
    }

    private func color(_ fan: FanReading) -> Color {
        guard fresh, let band = fan.speedBand else { return .secondary }
        return band == 2 ? .orange : (band == 1 ? .yellow : .cyan)
    }

    private func detail(_ fan: FanReading) -> String {
        guard fresh else { return host.fanError ?? lang.t("fan.stale") }
        guard let rpm = fan.rpm else { return "\(fan.name) · \(lang.t("fan.unavailable"))" }
        if let maximum = fan.maximumRPM, let percentage = fan.percentage {
            return lang.t("fan.maximum.detail", fan.name, rpm, maximum, percentage)
        }
        return lang.t("fan.rpm.detail", fan.name, rpm)
    }
}

struct CPUUsagePanels: View {
    @ObservedObject var monitor: CPUMonitorStore

    var body: some View {
        VStack(spacing: 8) {
            ForEach(monitor.monitoredHosts) { host in
                CPUUsagePanel(monitor: monitor, hostID: host.id)
            }
        }
    }
}

private struct CPUCoreTile: View {
    let core: CPUCore
    let fresh: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text("\(core.id)").font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Spacer(minLength: 0)
                Text(NPUIslandPresentation.percentage(fresh ? core.usage : nil))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(fresh ? cpuUsageColor(core.usage) : .white.opacity(0.35))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07))
                    Capsule().fill(fresh ? cpuUsageColor(core.usage) : .clear)
                        .frame(width: geometry.size.width * core.usage / 100)
                }
            }.frame(height: 2)
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CPUGridLayout.tileHeight)
        .background(fresh ? cpuUsageColor(core.usage).opacity(0.055) : .white.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU \(core.id): \(NPUIslandPresentation.percentage(fresh ? core.usage : nil))")
        .help("CPU \(core.id) · \(NPUIslandPresentation.percentage(fresh ? core.usage : nil))")
    }
}

struct CPUConnectionView: View {
    @ObservedObject var monitor: CPUMonitorStore
    private var lang: LanguageManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CPUHostButtons(monitor: monitor)
            HStack {
                Text(lang.t("cpu.connection.help")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker(lang.t("npu.interval"), selection: $monitor.refreshInterval) {
                    ForEach([1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { seconds in
                        Text("\(Int(seconds)) s").tag(seconds)
                    }
                }
                .font(.caption).frame(width: 150)
            }
            Text(lang.t("cpu.chooseServer")).font(.caption).foregroundStyle(.secondary)
            ForEach(monitor.monitoredHosts) { host in
                if host.state == .connecting {
                    Text("\(host.id) · \(lang.t("cpu.connecting"))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let error = host.errorMessage {
                    HStack {
                        Text("\(host.id) · \(error)").font(.caption).foregroundStyle(.orange)
                            .lineLimit(2).textSelection(.enabled).help(error)
                        if !host.isRetrying {
                            Button(lang.t("cpu.retry")) { monitor.connect(host.id) }
                                .font(.caption)
                        }
                    }
                }
            }
            Text(lang.t("cpu.scope.help")).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

private func cpuUsageColor(_ value: Double) -> Color {
    if value >= 85 { return .orange }
    if value >= 60 { return .yellow }
    return .cyan
}
