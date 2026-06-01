import SwiftUI

@main
struct TutorScribeApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        MenuBarExtra("TutorScribe", systemImage: "waveform") {
            MenuContentView()
                .environmentObject(app)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }
}
