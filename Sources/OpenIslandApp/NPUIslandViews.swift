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
    static let sectionSpacing: CGFloat = 8

    static func utilizationRowsHeight(deviceCount: Int) -> CGFloat {
        utilizationRowHeight * CGFloat(min(visibleDeviceRows, deviceCount))
    }

    static func utilizationSectionHeight(deviceCount: Int) -> CGFloat {
        guard deviceCount > 0 else { return 0 }
        return utilizationHeaderHeight + utilizationHeaderSpacing + utilizationRowsHeight(deviceCount: deviceCount)
    }

    static func isFresh(state: ConnectionState, isPaused: Bool, lastUpdated: Date?, refreshInterval: Double, at date: Date) -> Bool {
        guard state == .connected, !isPaused, let lastUpdated else { return false }
        return date.timeIntervalSince(lastUpdated) <= max(10, refreshInterval * 3 + 2)
    }

    @MainActor
    static func contentHeight(for monitor: MonitorStore) -> CGFloat {
        guard monitor.state == .connected, let snapshot = monitor.snapshot else { return 84 }
        let utilization = utilizationSectionHeight(deviceCount: snapshot.devices.count)
        return 68 + (utilization > 0 ? utilization + sectionSpacing : 0)
            + rowHeight * CGFloat(max(1, min(visibleRows, snapshot.processes.count)))
    }

    static func utilizationFraction(_ value: Double?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return CGFloat(min(100, max(0, value)) / 100)
    }

    static func percentage(_ value: Double?) -> String {
        guard let fraction = utilizationFraction(value) else { return "—%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func utilizationDevices(_ devices: [NPUDevice]) -> [NPUDevice] {
        devices.sorted { ($0.npuID, $0.chipID) < ($1.npuID, $1.chipID) }
    }
}

struct NPUProcessPanel: View {
    @ObservedObject var monitor: MonitorStore
    var onConnect: () -> Void
    private var lang: LanguageManager { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            VStack(alignment: .leading, spacing: NPUIslandPresentation.sectionSpacing) {
                HStack(spacing: 6) {
                    Text(lang.t("npu.processes.title")).font(.system(size: 10, weight: .semibold))
                    if monitor.isDemo { Text("DEMO").foregroundStyle(.orange) }
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

                    if !snapshot.devices.isEmpty {
                        utilizationSection(snapshot.devices, fresh: fresh)
                    }

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

    private func utilizationSection(_ devices: [NPUDevice], fresh: Bool) -> some View {
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
                    ForEach(NPUIslandPresentation.utilizationDevices(devices)) { device in
                        HStack(spacing: 16) {
                            utilizationBar("HBM", device: device, value: fresh ? device.hbmPercent : nil, color: .purple)
                            utilizationBar("AIC", device: device, value: fresh ? device.utilization : nil, color: .cyan)
                        }
                        .frame(height: NPUIslandPresentation.utilizationRowHeight)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(devices.count > NPUIslandPresentation.visibleDeviceRows ? .visible : .hidden)
            .frame(height: NPUIslandPresentation.utilizationRowsHeight(deviceCount: devices.count))
        }
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
            Text(NPUIslandPresentation.percentage(value))
                .foregroundStyle(fraction == nil ? .white.opacity(0.4) : color.opacity(0.95))
                .frame(width: 34, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("NPU \(device.npuID), chip \(device.chipID), \(title)")
        .accessibilityValue(NPUIslandPresentation.percentage(value))
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

enum SSHMonitorTab: Hashable { case cpu, npu }

@MainActor
private final class SSHMonitorWindowSelection: ObservableObject {
    @Published var tab: SSHMonitorTab = .cpu
}

@MainActor
final class NPUConnectionWindowController: NSWindowController, NSWindowDelegate {
    private let monitor: MonitorStore
    private let persistence: NPUConnectionPersistence
    private let selection = SSHMonitorWindowSelection()
    private var allowsCredentialAutofill = false

    init(monitor: MonitorStore, cpuMonitor: CPUMonitorStore, persistence: NPUConnectionPersistence) {
        self.monitor = monitor
        self.persistence = persistence
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = LanguageManager.shared.t("ssh.monitor.title")
        window.minSize = NSSize(width: 620, height: 360)
        window.identifier = NSUserInterfaceItemIdentifier("OpenIsland.NPUConnection")
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SSHMonitorConnectionView(
            monitor: monitor, cpuMonitor: cpuMonitor, persistence: persistence, selection: selection,
            shouldLoadCredentials: { [weak self] in
                guard let self else { return false }
                return self.allowsCredentialAutofill && self.window?.isVisible == true && self.selection.tab == .npu
            }
        ))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(tab: SSHMonitorTab, loadCredential: Bool) {
        allowsCredentialAutofill = loadCredential
        selection.tab = tab
        if loadCredential, tab == .npu, window?.isVisible != true {
            persistence.prepareForDisplay()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        allowsCredentialAutofill = false
        persistence.clearPasswordField()
        if monitor.hostTrustRequest != nil { monitor.rejectHost() }
    }
}

private struct SSHMonitorConnectionView: View {
    @ObservedObject var monitor: MonitorStore
    @ObservedObject var cpuMonitor: CPUMonitorStore
    @ObservedObject var persistence: NPUConnectionPersistence
    @ObservedObject var selection: SSHMonitorWindowSelection
    let shouldLoadCredentials: () -> Bool
    private var lang: LanguageManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(lang.t("ssh.monitor.title")).font(.title3.weight(.semibold))
            Picker(lang.t("ssh.monitor.title"), selection: $selection.tab) {
                Text(lang.t("cpu.title")).tag(SSHMonitorTab.cpu)
                Text(lang.t("cpu.npuTab")).tag(SSHMonitorTab.npu)
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                if selection.tab == .cpu {
                    CPUConnectionView(monitor: cpuMonitor)
                } else {
                    NPUConnectionView(monitor: monitor, persistence: persistence, shouldLoadCredentials: shouldLoadCredentials)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preferredColorScheme(.dark)
        .onChange(of: selection.tab) { _, tab in
            if tab == .cpu { persistence.clearPasswordField() }
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

private struct NPUConnectionView: View {
    @ObservedObject var monitor: MonitorStore
    @ObservedObject var persistence: NPUConnectionPersistence
    let shouldLoadCredentials: () -> Bool
    private enum Field { case address, password }
    @FocusState private var focusedField: Field?
    private var lang: LanguageManager { .shared }
    private var active: Bool { monitor.state.isMonitoring }

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
        .frame(maxWidth: .infinity, minHeight: 282, alignment: .topLeading)
        .preferredColorScheme(.dark)
        .onAppear {
            if shouldLoadCredentials() { persistence.prepareForDisplay() }
            focusedField = monitor.connectionInput.isEmpty ? .address : .password
        }
        .onChange(of: monitor.state) { oldState, newState in
            persistence.connectionStateDidChange(from: oldState, to: newState, windowVisible: shouldLoadCredentials())
        }
    }
}
