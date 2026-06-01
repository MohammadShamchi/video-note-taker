import SwiftUI

/// The menu bar popover: start/stop, live status, last note, push, settings.
struct MenuContentView: View {
    @EnvironmentObject var app: AppState
    @State private var pushTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Button(action: app.toggle) {
                Label(primaryButtonTitle,
                      systemImage: primaryButtonIcon)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(app.isRunning ? .red : .accentColor)
            .disabled(app.isFinishing)

            statusRow

            if !app.isRunning, let file = app.lastTranscriptFile {
                Divider()
                transcriptSavedSection(file)
            }

            if let note = app.lastNote {
                Divider()
                Text("Last note").font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(note).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 120)
            }

            Divider()
            pushSection

            if let banner = app.banner {
                Text(banner).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func transcriptSavedSection(_ file: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcript saved").font(.caption).foregroundStyle(.secondary)
            Text((file.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button { app.openTranscript() } label: {
                Label("Open Transcript", systemImage: "doc.text")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform").foregroundStyle(.tint)
            Text("TutorScribe").font(.headline)
            Spacer()
            Circle()
                .fill(app.isFinishing ? .orange : (app.isRunning ? .green : .secondary))
                .frame(width: 8, height: 8)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            if app.isRunning && app.status != .idle {
                ProgressView().controlSize(.small)
            }
            Text(app.status.label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if app.segmentCount > 0 {
                Text("\(app.segmentCount) segment\(app.segmentCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var primaryButtonTitle: String {
        if app.isFinishing { return "Finishing" }
        return app.isRunning ? "Stop Transcript" : "Start Transcript"
    }

    private var primaryButtonIcon: String {
        if app.isFinishing { return "hourglass" }
        return app.isRunning ? "stop.circle.fill" : "record.circle"
    }

    private var pushSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(app.defaultNotionTitle, text: $pushTitle)
                .textFieldStyle(.roundedBorder)
            Button {
                app.pushToNotion(title: pushTitle.isEmpty ? app.defaultNotionTitle : pushTitle)
            } label: {
                Label("Push to Notion", systemImage: "arrow.up.doc")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!app.canPush)
            if !app.registry.notion.isConnected {
                Text("Connect Notion in Settings to enable.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
