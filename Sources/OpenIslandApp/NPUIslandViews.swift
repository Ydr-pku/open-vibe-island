import AppKit
import SwiftUI

/// Shared sizing and freshness rules for both the panel and its hit area.
enum NPUIslandPresentation {
    static let rowHeight: CGFloat = 24
    static let visibleRows = 6
    static let utilizationRowHeight: CGFloat = 18
    static let visibleDeviceRows = 4
    static let utilizationHeaderHeight: CGFloat = 14
    static let utilizationHeaderSpacing: CGFloat = 4
    static let networkRowHeight: CGFloat = 16
    static let visibleNetworkRows = 2
    private static func textWidth(_ value: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        return ceil((value as NSString).size(withAttributes: [.font: font]).width)
    }

    static func coreLabel(_ value: Double?) -> String {
        "AIC\(percentage(value))"
    }

    static func compactWidth(state: ConnectionState, isDemo: Bool = false,
                             hbm: Double? = nil, core: Double? = nil) -> CGFloat {
        switch state {
        case .connected:
            let demoWidth: CGFloat = isDemo ? textWidth("D") + 5 : 0
            return demoWidth + textWidth("HBM\(percentage(hbm))") + 5 + textWidth(coreLabel(core)) + 2
        case .connecting, .failed:
            return 14 + 5 + textWidth("NPU") + 2
        case .disconnected:
            return textWidth("NPU") + 2
        }
    }

    @MainActor
    static func compactWidth(for monitor: MonitorStore?) -> CGFloat {
        guard let monitor else { return compactWidth(state: .disconnected) }
        return compactWidth(state: monitor.state, isDemo: monitor.isDemo,
                            hbm: monitor.snapshot?.hbmPercent, core: monitor.snapshot?.averageUtilization)
    }

    static func isFresh(state: ConnectionState, isPaused: Bool, lastUpdated: Date?, refreshInterval: Double, at date: Date) -> Bool {
        guard state == .connected, !isPaused, let lastUpdated else { return false }
        return date.timeIntervalSince(lastUpdated) <= max(10, refreshInterval * 3 + 2)
    }

    @MainActor
    static func contentHeight(for monitor: MonitorStore) -> CGFloat {
        guard monitor.state == .connected, let snapshot = monitor.snapshot else { return 84 }
        return 68 + networkSectionHeight(interfaceCount: monitor.networkRates.count) + 8
            + utilizationSectionHeight(deviceCount: snapshot.devices.count) + 8
            + rowHeight * CGFloat(max(1, min(visibleRows, snapshot.processes.count)))
    }

    static func networkSectionHeight(interfaceCount: Int) -> CGFloat {
        networkRowHeight * CGFloat(max(1, min(visibleNetworkRows, interfaceCount)))
    }

    static func networkSpeed(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value >= 1_000_000_000 { return String(format: "%.1f GB/s", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f KB/s", value / 1_000) }
        return String(format: "%.0f B/s", value)
    }

    static func utilizationSectionHeight(deviceCount: Int) -> CGFloat {
        utilizationHeaderHeight + utilizationHeaderSpacing
            + utilizationRowHeight * CGFloat(max(1, min(visibleDeviceRows, deviceCount)))
    }

    static func sortedDevices(_ devices: [NPUDevice]) -> [NPUDevice] {
        devices.sorted { ($0.npuID, $0.chipID) < ($1.npuID, $1.chipID) }
    }

    static func percentage(_ value: Double?) -> String {
        value.map { "\(Int(min(100, max(0, $0)).rounded()))%" } ?? "—%"
    }

    static func utilizationFraction(_ value: Double?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return CGFloat(min(100, max(0, value)) / 100)
    }
}

struct NPUClosedStatusView: View {
    @ObservedObject var monitor: MonitorStore
    let compactWidth: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let fresh = NPUIslandPresentation.isFresh(
                state: monitor.state, isPaused: monitor.isPaused,
                lastUpdated: monitor.lastUpdated, refreshInterval: monitor.refreshInterval, at: context.date
            )
            Group {
                if monitor.state == .connected {
                    HStack(spacing: 5) {
                        if monitor.isDemo { Text("D").foregroundStyle(.orange) }
                        Text("HBM\(NPUIslandPresentation.percentage(fresh ? monitor.snapshot?.hbmPercent : nil))")
                            .foregroundStyle(fresh ? .purple.opacity(0.95) : .white.opacity(0.4))
                        Text(NPUIslandPresentation.coreLabel(fresh ? monitor.snapshot?.averageUtilization : nil))
                            .foregroundStyle(fresh ? .cyan.opacity(0.95) : .white.opacity(0.4))
                    }
                } else {
                    HStack(spacing: 5) {
                        if monitor.state == .connecting {
                            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                        } else if monitor.state == .failed {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).frame(width: 14)
                        }
                        Text("NPU").foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: compactWidth, alignment: .leading)
            .help(LanguageManager.shared.t("npu.compact.help"))
            .accessibilityLabel(LanguageManager.shared.t("npu.compact.help"))
        }
    }
}

struct NPUOpenedStatusView: View {
    @ObservedObject var monitor: MonitorStore
    var onConnect: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let fresh = NPUIslandPresentation.isFresh(
                state: monitor.state, isPaused: monitor.isPaused,
                lastUpdated: monitor.lastUpdated, refreshInterval: monitor.refreshInterval, at: context.date
            )
            Button(action: onConnect) {
                HStack(spacing: 5) {
                    Text(monitor.state == .connected ? "NPU" : "SSH")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.74))
                    if monitor.state == .connected {
                        if monitor.isDemo {
                            Text("D").foregroundStyle(.orange)
                        }
                        Text("HBM\(NPUIslandPresentation.percentage(fresh ? monitor.snapshot?.hbmPercent : nil))")
                            .foregroundStyle(fresh ? .purple.opacity(0.95) : .white.opacity(0.4))
                        Text(NPUIslandPresentation.coreLabel(fresh ? monitor.snapshot?.averageUtilization : nil))
                            .foregroundStyle(fresh ? .cyan.opacity(0.95) : .white.opacity(0.4))
                    }
                }
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: IslandChromeMetrics.npuHeaderButtonWidth,
                       height: IslandChromeMetrics.openedHeaderChipHeight)
                .background(.white.opacity(0.055), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(LanguageManager.shared.t("npu.connection.title"))
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct NPUProcessPanel: View {
    @ObservedObject var monitor: MonitorStore
    @ObservedObject var persistence: NPUConnectionPersistence
    var onConnect: () -> Void
    private var lang: LanguageManager { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(lang.t("npu.processes.title")).font(.system(size: 10, weight: .semibold))
                    if monitor.isDemo { Text("DEMO").foregroundStyle(.orange) }
                    if let notice = persistence.credentialNoticeKey {
                        Button(action: onConnect) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        }
                        .help(lang.t(notice))
                        .accessibilityLabel(lang.t(notice))
                    }
                    Spacer(minLength: 0)
                    if monitor.state == .connected {
                        Text(monitor.endpointLabel)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.white.opacity(0.45))
                        Button { monitor.disconnect() } label: {
                            Image(systemName: "xmark.circle")
                        }.help(lang.t("npu.disconnect"))
                    } else {
                        Button("SSH", action: onConnect)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .buttonStyle(.plain)

                if monitor.state == .connected, let snapshot = monitor.snapshot {
                    let fresh = NPUIslandPresentation.isFresh(
                        state: monitor.state, isPaused: monitor.isPaused, lastUpdated: monitor.lastUpdated,
                        refreshInterval: monitor.refreshInterval, at: context.date
                    )
                    HStack {
                        Text(fresh ? "\(snapshot.devices.count) \(lang.t("npu.chips"))" : lang.t("npu.stale"))
                        Spacer()
                        if let date = monitor.lastUpdated {
                            Text(date.formatted(date: .omitted, time: .standard))
                        }
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(fresh ? .white.opacity(0.38) : .orange)

                    let networkFresh = NPUIslandPresentation.isFresh(
                        state: monitor.state, isPaused: monitor.isPaused, lastUpdated: monitor.networkLastUpdated,
                        refreshInterval: monitor.refreshInterval, at: context.date
                    )
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            if monitor.networkRates.isEmpty {
                                networkRow(nil, fresh: false)
                            } else {
                                ForEach(monitor.networkRates) { rate in
                                    networkRow(rate, fresh: networkFresh)
                                }
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(monitor.networkRates.count > NPUIslandPresentation.visibleNetworkRows ? .visible : .hidden)
                    .frame(height: NPUIslandPresentation.networkSectionHeight(interfaceCount: monitor.networkRates.count))

                    VStack(spacing: NPUIslandPresentation.utilizationHeaderSpacing) {
                        HStack(spacing: 16) {
                            Text("HBM · NPU:Chip").frame(maxWidth: .infinity, alignment: .leading)
                            Text("AIC · NPU:Chip").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(height: NPUIslandPresentation.utilizationHeaderHeight)

                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(NPUIslandPresentation.sortedDevices(snapshot.devices)) { device in
                                    HStack(spacing: 16) {
                                        utilizationBar("HBM", device: device,
                                                       value: fresh ? device.hbmPercent : nil, color: .purple)
                                        utilizationBar("AIC", device: device,
                                                       value: fresh ? device.utilization : nil, color: .cyan)
                                    }
                                    .frame(height: NPUIslandPresentation.utilizationRowHeight)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicators(snapshot.devices.count > NPUIslandPresentation.visibleDeviceRows ? .visible : .hidden)
                    }
                    .frame(height: NPUIslandPresentation.utilizationSectionHeight(deviceCount: snapshot.devices.count))

                    if snapshot.processes.isEmpty {
                        Text(lang.t("npu.processes.empty"))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                            .frame(height: NPUIslandPresentation.rowHeight)
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(snapshot.processes.sorted {
                                    if $0.npuID != $1.npuID { return $0.npuID < $1.npuID }
                                    if $0.chipID != $1.chipID { return $0.chipID < $1.chipID }
                                    return $0.pid < $1.pid
                                }) { process in
                                    processRow(process)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: NPUIslandPresentation.rowHeight * CGFloat(min(NPUIslandPresentation.visibleRows, snapshot.processes.count)))
                        .opacity(fresh ? 1 : 0.45)
                    }
                } else {
                    Text(statusMessage)
                        .font(.system(size: 11)).foregroundStyle(monitor.state == .failed ? .orange : .white.opacity(0.42))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .help(monitor.errorMessage ?? "")
                }
            }
            .padding(10)
            .frame(height: NPUIslandPresentation.contentHeight(for: monitor), alignment: .top)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.055), lineWidth: 1) }
        }
    }

    private var statusMessage: String {
        if monitor.isReconnecting { return lang.t("npu.reconnecting") }
        return switch monitor.state {
        case .connecting: lang.t("npu.connecting")
        case .failed: monitor.errorMessage ?? lang.t("npu.failed")
        case .disconnected: lang.t("npu.disconnected")
        case .connected: lang.t("npu.stale")
        }
    }

    private func networkRow(_ rate: NetworkInterfaceRate?, fresh: Bool) -> some View {
        let download = NPUIslandPresentation.networkSpeed(fresh ? rate?.receivedPerSecond : nil)
        let upload = NPUIslandPresentation.networkSpeed(fresh ? rate?.transmittedPerSecond : nil)
        return HStack(spacing: 8) {
            Text(lang.t("npu.network"))
                .foregroundStyle(.white.opacity(0.65))
            Text(rate?.name ?? "—")
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
            Text("↓ \(download)")
                .foregroundStyle(.cyan.opacity(fresh && rate?.receivedPerSecond != nil ? 0.9 : 0.4))
                .fixedSize(horizontal: true, vertical: false)
            Text("↑ \(upload)")
                .foregroundStyle(.white.opacity(fresh && rate?.transmittedPerSecond != nil ? 0.65 : 0.4))
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .frame(height: NPUIslandPresentation.networkRowHeight)
        .help(lang.t("npu.network.help"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lang.t("npu.network")) \(rate?.name ?? "—")")
        .accessibilityValue("\(lang.t("npu.network.download")) \(download), \(lang.t("npu.network.upload")) \(upload)")
    }

    private func utilizationBar(_ title: String, device: NPUDevice, value: Double?, color: Color) -> some View {
        let fraction = NPUIslandPresentation.utilizationFraction(value)
        return HStack(spacing: 6) {
            Text(device.id)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 36, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    if let fraction, fraction > 0 {
                        Capsule().fill(color.opacity(0.9))
                            .frame(width: geometry.size.width * fraction)
                    }
                }
            }
            .frame(height: 6)
            Text(NPUIslandPresentation.percentage(fraction == nil ? nil : value))
                .foregroundStyle(fraction == nil ? .white.opacity(0.4) : color.opacity(0.95))
                .frame(width: 34, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("NPU \(device.npuID), chip \(device.chipID), \(title)")
        .accessibilityValue(NPUIslandPresentation.percentage(fraction == nil ? nil : value))
    }

    private func processRow(_ process: NPUProcess) -> some View {
        HStack(spacing: 8) {
            Text("\(process.npuID):\(process.chipID)").frame(width: 28, alignment: .leading)
                .foregroundStyle(.cyan.opacity(0.8))
            Text(String(process.pid)).frame(width: 54, alignment: .leading)
                .foregroundStyle(.white.opacity(0.55))
            Text(process.name).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(process.memoryMB.map { "\(Int($0.rounded())) MiB" } ?? "— MiB")
                .foregroundStyle(.white.opacity(0.6))
        }
        .font(.system(size: 10, design: .monospaced))
        .frame(height: NPUIslandPresentation.rowHeight)
        .help("NPU \(process.npuID) · Chip \(process.chipID) · PID \(process.pid) · \(process.name)")
    }
}

@MainActor
final class NPUConnectionWindowController: NSWindowController, NSWindowDelegate {
    private let monitor: MonitorStore
    private let persistence: NPUConnectionPersistence
    private var allowsCredentialAutofill = true

    init(monitor: MonitorStore, persistence: NPUConnectionPersistence) {
        self.monitor = monitor
        self.persistence = persistence
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = LanguageManager.shared.t("npu.connection.title")
        window.identifier = NSUserInterfaceItemIdentifier("OpenIsland.NPUConnection")
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: NPUConnectionView(
            monitor: monitor, persistence: persistence,
            shouldLoadCredentials: { [weak self] in self?.allowsCredentialAutofill == true && self?.window?.isVisible == true }
        ))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(loadCredential: Bool = true) {
        allowsCredentialAutofill = loadCredential
        if loadCredential, window?.isVisible != true { persistence.prepareForDisplay() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        monitor.password = ""
        persistence.clearAutofill()
        if monitor.hostTrustRequest != nil { monitor.rejectHost() }
    }
}

private struct NPUConnectionView: View {
    @ObservedObject var monitor: MonitorStore
    @ObservedObject var persistence: NPUConnectionPersistence
    var shouldLoadCredentials: () -> Bool
    private enum Field { case address, password }
    @FocusState private var focusedField: Field?
    private var lang: LanguageManager { .shared }
    private var active: Bool { monitor.state == .connecting || monitor.state == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(lang.t("npu.connection.title")).font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.t("npu.address")).font(.caption).foregroundStyle(.secondary)
                TextField("ssh -p 22 user@host", text: Binding(
                    get: { monitor.connectionInput }, set: { persistence.updateAddress($0) }
                ))
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.plain).foregroundStyle(.white)
                    .padding(8).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(active).focused($focusedField, equals: .address)
                    .accessibilityLabel(lang.t("npu.address"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.t("npu.password")).font(.caption).foregroundStyle(.secondary)
                SecureField(lang.t("npu.password"), text: Binding(
                    get: { monitor.password }, set: { persistence.updatePassword($0) }
                ))
                    .textFieldStyle(.plain).foregroundStyle(.white)
                    .padding(8).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(active).focused($focusedField, equals: .password)
                    .onSubmit { if !active { persistence.connect() } }
            }
            Text(lang.t("npu.credentials.help"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(lang.t("npu.interval"))
                Picker("", selection: $monitor.refreshInterval) {
                    ForEach([1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { seconds in
                        Text("\(Int(seconds)) s").tag(seconds)
                    }
                }.labelsHidden().frame(width: 90)
                Spacer()
                if monitor.state == .connecting { ProgressView().controlSize(.small) }
                Button(active ? lang.t("npu.disconnect") : lang.t("npu.connect")) {
                    active ? monitor.disconnect() : persistence.connect()
                }
                .keyboardShortcut(.defaultAction)
            }
            if let notice = persistence.credentialNoticeKey {
                Text(lang.t(notice)).font(.caption).foregroundStyle(.orange)
            }
            if monitor.isReconnecting {
                Text(lang.t("npu.reconnecting")).font(.caption).foregroundStyle(.orange)
            } else if let error = monitor.errorMessage {
                ScrollView { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            } else {
                Text(monitor.state == .connected ? lang.t("npu.connected") : lang.t("npu.connection.help"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 460, height: 400)
        .preferredColorScheme(.dark)
        .onAppear { focusedField = monitor.connectionInput.isEmpty ? .address : .password }
        .onChange(of: monitor.connectionInput) { _, address in persistence.addressDidChange(address) }
        .onChange(of: monitor.state) { oldState, newState in
            persistence.connectionStateDidChange(from: oldState, to: newState, windowVisible: shouldLoadCredentials())
        }
        .sheet(item: $monitor.hostTrustRequest) { request in
            VStack(alignment: .leading, spacing: 18) {
                Text(lang.t("npu.trust.title")).font(.headline)
                ScrollView { Text(request.prompt).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    .frame(maxHeight: 180)
                HStack {
                    Spacer()
                    Button(lang.t("npu.cancel")) { monitor.rejectHost() }
                    Button(lang.t("npu.trust.confirm")) { monitor.approveHost() }
                }
            }
            .padding(24).frame(width: 460).interactiveDismissDisabled()
        }
    }
}
