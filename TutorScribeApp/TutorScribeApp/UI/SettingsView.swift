import SwiftUI

/// Settings window: OpenAI key, connector rows (extensible), and tunables.
struct SettingsView: View {
    @EnvironmentObject var app: AppState

    @State private var openAIKey = Keychain.get(Config.kOpenAIKey) ?? ""
    @State private var chunkSecs = String(Config.chunkSecs)
    @State private var notesModel = Config.notesModel

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API key", text: $openAIKey)
                    .onChange(of: openAIKey) { _, v in Keychain.set(Config.kOpenAIKey, v) }
                TextField("Notes model", text: $notesModel)
                    .onChange(of: notesModel) { _, v in
                        UserDefaults.standard.set(v, forKey: Config.kNotesModel)
                    }
                TextField("Chunk seconds", text: $chunkSecs)
                    .onChange(of: chunkSecs) { _, v in
                        UserDefaults.standard.set(Int(v) ?? 60, forKey: Config.kChunkSecs)
                    }
            }

            Section("Connectors") {
                NotionConnectorRow(connector: app.registry.notion)
                // Future connectors: add one row per app here.
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
    }
}

/// One connector row — the reusable shape for any linked app's auth + config.
struct NotionConnectorRow: View {
    @ObservedObject var connector: NotionConnector

    @State private var token = ""
    @State private var selection: NotionPage?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(connector.displayName, systemImage: connector.iconSystemName)
                    .font(.headline)
                Spacer()
                if connector.isConnected {
                    Text(connector.workspaceName).font(.caption).foregroundStyle(.secondary)
                    Button("Disconnect") { connector.disconnect() }
                }
            }

            if !connector.isConnected {
                HStack(spacing: 6) {
                    SecureField("Paste integration token (ntn_…)", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { connect() }
                    Button {
                        if let s = NSPasteboard.general.string(forType: .string) { token = s }
                    } label: { Image(systemName: "doc.on.clipboard") }
                    .help("Paste from clipboard")
                    Button("Connect") { connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || token.isEmpty)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("How to get this:")
                    Text("1. Open notion.so/my-integrations → New integration → **Access token**.")
                    Text("2. Pick the workspace, Create connection, copy the token here.")
                    Text("3. Open the Notion page you want to push into → ••• → **Connections** → add this integration.")
                    Link("Open Notion integrations →", destination: URL(string: "https://www.notion.so/my-integrations")!)
                        .font(.caption2)
                }
                .font(.caption2).foregroundStyle(.secondary)
                .textSelection(.enabled)
            } else {
                HStack {
                    Picker("Parent page", selection: $selection) {
                        Text("Select…").tag(NotionPage?.none)
                        ForEach(connector.pages) { page in
                            Text(page.title).tag(NotionPage?.some(page))
                        }
                    }
                    .onChange(of: selection) { _, page in if let page { connector.setParent(page) } }
                    Button("Refresh") { loadPages() }.disabled(working)
                }
                if !connector.parentTitle.isEmpty {
                    Text("Pushes into: \(connector.parentTitle)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if working { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task { if connector.isConnected && connector.pages.isEmpty { loadPages() } }
    }

    private func connect() {
        working = true; error = nil
        Task {
            do { try await connector.connect(token: token); loadPages() }
            catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func loadPages() {
        working = true
        Task {
            do { try await connector.loadPages() }
            catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
