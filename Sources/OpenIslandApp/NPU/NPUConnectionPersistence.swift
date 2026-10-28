import Combine
import Foundation

/// Keeps the user's monitoring intent and Keychain credentials separate from
/// the transport's in-memory connection lifecycle.
@MainActor
final class NPUConnectionPersistence: ObservableObject {
    static let resumeMonitoringKey = "npuMonitor.resumeMonitoring"
    static let successfulAddressKey = "npuMonitor.lastSuccessfulAddress"

    @Published private(set) var credentialNoticeKey: String?
    var onHostTrustRequired: (() -> Void)?
    private let monitor: MonitorStore
    private let credentials: any NPUCredentialStore
    private let defaults: UserDefaults
    private var passwordEndpoint: SSHEndpoint?
    private var trustObserver: AnyCancellable?

    init(monitor: MonitorStore, credentials: any NPUCredentialStore = NPUKeychainCredentialStore(),
         defaults: UserDefaults = .standard) {
        self.monitor = monitor
        self.credentials = credentials
        self.defaults = defaults
        monitor.onConnectionEstablished = { [weak self] endpoint, password in
            self?.saveSuccessfulConnection(endpoint: endpoint, password: password)
        }
        monitor.onUserDisconnect = { [weak self] in self?.stopRestoringOnLaunch() }
        monitor.onPermanentFailure = { [weak self] in self?.stopRestoringOnLaunch() }
        trustObserver = monitor.$hostTrustRequest.dropFirst().compactMap { $0 }.sink { [weak self] request in
            Task { @MainActor [weak self] in
                guard let self, self.monitor.hostTrustRequest?.id == request.id else { return }
                self.onHostTrustRequired?()
            }
        }
    }

    /// Called only on a normal application launch, not in a visual harness.
    func restoreIfNeeded() {
        guard defaults.bool(forKey: Self.resumeMonitoringKey),
              let address = defaults.string(forKey: Self.successfulAddressKey),
              let endpoint = try? EndpointParser.parse(address),
              monitor.state == .disconnected else { return }
        do {
            guard let password = try credentials.password(for: endpoint), !password.isEmpty else {
                credentialNoticeKey = "npu.credentials.missing"
                return
            }
            credentialNoticeKey = nil
            monitor.connectionInput = address
            monitor.password = password
            monitor.connect(retryingKnownEndpoint: true)
        } catch {
            credentialNoticeKey = "npu.credentials.readFailed"
        }
    }

    func prepareForDisplay() {
        guard monitor.state != .connecting, monitor.state != .connected,
              monitor.password.isEmpty,
              let endpoint = try? EndpointParser.parse(monitor.connectionInput) else { return }
        do {
            if let password = try credentials.password(for: endpoint), !password.isEmpty {
                passwordEndpoint = endpoint
                monitor.password = password
                credentialNoticeKey = nil
            }
        } catch {
            credentialNoticeKey = "npu.credentials.readFailed"
        }
    }

    /// Bind any entered password to its host, even if the user later edits it.
    func updatePassword(_ password: String) {
        monitor.password = password
        if password.isEmpty {
            passwordEndpoint = nil
        } else if passwordEndpoint == nil {
            passwordEndpoint = try? EndpointParser.parse(monitor.connectionInput)
        }
    }

    func updateAddress(_ address: String) {
        addressDidChange(address)
        monitor.connectionInput = address
    }

    /// Never carry a password associated with another host or user.
    func addressDidChange(_ address: String) {
        guard let passwordEndpoint,
              (try? EndpointParser.parse(address)) != passwordEndpoint else { return }
        monitor.password = ""
        clearAutofill()
    }

    func connect() {
        // View updates can be delayed, so check the binding again before SSH.
        addressDidChange(monitor.connectionInput)
        // Do not resume an older successful host if the user tries a different
        // address and closes the app before the new connection succeeds.
        stopRestoringOnLaunch()
        clearAutofill()
        monitor.connect()
    }

    func clearAutofill() {
        passwordEndpoint = nil
    }

    private func saveSuccessfulConnection(endpoint: SSHEndpoint, password: String) {
        do {
            try credentials.save(password, for: endpoint)
            defaults.set(monitor.connectionInput.trimmingCharacters(in: .whitespacesAndNewlines),
                         forKey: Self.successfulAddressKey)
            defaults.set(true, forKey: Self.resumeMonitoringKey)
            credentialNoticeKey = nil
        } catch {
            // Continue reconnecting in this app session using the in-memory
            // credential, but do not claim that relaunch recovery is available.
            stopRestoringOnLaunch()
            credentialNoticeKey = "npu.credentials.saveFailed"
        }
        clearAutofill()
    }

    private func stopRestoringOnLaunch() {
        defaults.set(false, forKey: Self.resumeMonitoringKey)
    }
}
