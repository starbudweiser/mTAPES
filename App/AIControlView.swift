// mTAPES — fenêtre « Pilotage par IA » : activer, raccorder un client en un clic, serveur HTTP local, clients autorisés.
import SwiftUI

struct AIControlView: View {
    @ObservedObject var model: AppModel
    @State private var showToken = false

    var body: some View {
        ZStack(alignment: .top) {
            Socle.C.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Socle.M.space5) {
                Text(branded: "mTAPES").socle(Socle.T.display).foregroundStyle(Socle.C.textStrong)
                Text(L.t("ai.title")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
                Text(L.t("ai.intro")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
                Toggle(L.t("ai.enable"), isOn: $model.mcpEnabled).toggleStyle(.switch).accessibilityLabel(L.t("ai.enable")).socle(Socle.T.label).foregroundStyle(Socle.C.text)

                if model.mcpEnabled {
                    section(L.t("ai.clients")) { ConnectorRows() }

                    section(L.t("ai.http")) {
                        Toggle(L.t("ai.http.enable"), isOn: $model.mcpHTTPEnabled).toggleStyle(.switch).accessibilityLabel(L.t("ai.http.enable")).socle(Socle.T.label).foregroundStyle(Socle.C.text)
                        if model.mcpHTTPEnabled {
                            Text(RemoteControl.shared.httpURL).socle(Socle.T.mono).foregroundStyle(Socle.C.accentText).textSelection(.enabled)
                            Text(L.t("ai.http.hint")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: Socle.M.space2) {
                                Button(L.t("ai.copy.url")) { copy(RemoteControl.shared.httpURL) }.buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
                                Button(L.t("ai.copy.token")) { copy(RemoteControl.shared.httpToken) }.buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
                            }
                        }
                    }

                    section(L.t("ai.pending")) {
                        if model.pendingClients.isEmpty { Text(L.t("ai.none")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle) }
                        ForEach(model.pendingClients, id: \.self) { c in
                            HStack {
                                Text(c).socle(Socle.T.label).foregroundStyle(Socle.C.text)
                                Spacer()
                                Button(L.t("ai.allow")) { model.approve(c) }.buttonStyle(SocleButtonStyle(.action, height: 28)).fixedSize()
                            }
                        }
                    }
                    section(L.t("ai.approved")) {
                        if model.approvedClients.isEmpty { Text(L.t("ai.none")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle) }
                        ForEach(model.approvedClients, id: \.self) { c in
                            HStack {
                                Text(c).socle(Socle.T.label).foregroundStyle(Socle.C.text)
                                Spacer()
                                Button(L.t("ai.remove")) { model.revoke(c) }.buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
                            }
                        }
                    }
                }
            }
            .padding(Socle.M.space6)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            Text(title).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            content()
        }
        .padding(Socle.M.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radius))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Liste des IA détectées avec « Raccorder » : partagée par la fenêtre « Pilotage par IA » et l'assistant.
struct ConnectorRows: View {
    @State private var clients: [MCPClientInfo] = []
    @State private var message: String?
    private var cliPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mtapes-cli").path }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            ForEach(clients) { c in
                HStack {
                    Text(c.name).socle(Socle.T.label).foregroundStyle(Socle.C.text)
                    Spacer()
                    switch c.status {
                    case .notDetected: Text(L.t("ai.notfound")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                    case .connected: Text("✓ " + L.t("ai.connected")).socle(Socle.T.meta).foregroundStyle(Socle.C.success)
                    case .detected:
                        Button(L.t("ai.connect")) { connect(c) }.buttonStyle(SocleButtonStyle(.primary, height: 28)).fixedSize()
                    }
                }
            }
            if let message { Text(message).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear { clients = Connectors.list() }
    }

    private func connect(_ c: MCPClientInfo) {
        do {
            try Connectors.connect(id: c.id, cli: cliPath)
            message = L.t("ai.done", c.name)
        } catch {
            message = L.t("ai.failed", "\(error)")
        }
        clients = Connectors.list()
    }
}
