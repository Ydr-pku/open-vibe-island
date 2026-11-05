import SwiftUI
import OpenIslandCore

struct CodexRemoteUsageSettingsSection: View {
    var model: AppModel
    @State private var hostID = ""
    @State private var sshAlias = ""
    @State private var codexHome = ""
    @State private var hostIDs: [String] = []
    @State private var configurationError: String?

    private var lang: LanguageManager { model.lang }

    var body: some View {
        Section(lang.t("settings.remoteUsage.title")) {
            Text(lang.t("settings.remoteUsage.description"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.hooks.codexRemoteUsageSources, id: \.hostID) { source in
                HStack {
                    Label(source.sshAlias, systemImage: "server.rack")
                    Spacer()
                    Button(lang.t("settings.remoteUsage.remove")) {
                        do { try model.hooks.removeCodexRemoteUsageSource(hostID: source.hostID) }
                        catch { configurationError = error.localizedDescription }
                    }
                }
            }
            if hostIDs.isEmpty {
                Text(lang.t("settings.remoteUsage.noHost"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker(lang.t("settings.remoteUsage.host"), selection: $hostID) {
                    ForEach(hostIDs, id: \.self) { id in
                        Text(id.replacingOccurrences(of: "remote-control:", with: "")).tag(id)
                    }
                }
                .onChange(of: hostID) { _, value in loadSource(value) }
                TextField(lang.t("settings.remoteUsage.sshAlias"), text: $sshAlias)
                    .autocorrectionDisabled()
                TextField(lang.t("settings.remoteUsage.codexHome"), text: $codexHome)
                    .autocorrectionDisabled()
                HStack {
                    Button(lang.t("settings.remoteUsage.save")) {
                        do {
                            let home = codexHome.trimmingCharacters(in: .whitespacesAndNewlines)
                            let source = CodexRemoteUsageSource(
                                hostID: hostID, sshAlias: sshAlias.trimmingCharacters(in: .whitespacesAndNewlines),
                                codexHome: home.isEmpty ? nil : home
                            )
                            try model.hooks.saveCodexRemoteUsageSource(source)
                            model.showCodexUsage = true
                            configurationError = nil
                        } catch { configurationError = error.localizedDescription }
                    }
                    .disabled(hostID.isEmpty || sshAlias.isEmpty || model.hooks.isCodexRemoteUsageSyncing)
                    Spacer()
                    Button(lang.t("settings.remoteUsage.sync")) {
                        model.hooks.refreshCodexRemoteUsageHistory()
                    }
                    .disabled(model.hooks.codexRemoteUsageSources.isEmpty || model.hooks.isCodexRemoteUsageSyncing)
                }
            }
            if model.hooks.isCodexRemoteUsageSyncing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(lang.t("settings.remoteUsage.syncing"))
                }
            }
            if let date = model.hooks.codexRemoteUsageLastSyncAt {
                HStack {
                    Text(lang.t("settings.remoteUsage.lastSync"))
                    Text(date, style: .date)
                    Text(date, style: .time)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let error = configurationError ?? model.hooks.codexRemoteUsageError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear {
            hostIDs = Array(Set(CodexDesktopThreadDiscovery.loadRemote().map(\.hostID)
                + model.hooks.codexRemoteUsageSources.map(\.hostID))).sorted()
            hostID = model.hooks.codexRemoteUsageSources.first?.hostID ?? hostIDs.first ?? ""
            loadSource(hostID)
        }
    }

    private func loadSource(_ id: String) {
        let source = model.hooks.codexRemoteUsageSources.first { $0.hostID == id }
        sshAlias = source?.sshAlias ?? ""
        codexHome = source?.codexHome ?? ""
    }
}
