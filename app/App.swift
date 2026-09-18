import SwiftUI

@main
struct SmartSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var switcher = Switcher.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Prefs.devModeKey) private var devMode = false

    var body: some Scene {
        MenuBarExtra("SmartSwitch", systemImage: "arrow.left.arrow.right.square") {
            if let last = switcher.last {
                Text(last.summary)
                Menu("Last Request") { MenuSections(sections: last.request) }
                    .help(last.requestText)
                Menu("Last Response") { MenuSections(sections: last.response) }
                    .help(last.responseText)
                Button("Copy Request & Response") { copyToPasteboard(last.raw) }
                    .help("Copies the full outcome JSON. Hover any row above for its exact text; click a row to copy just that.")
            } else {
                Text("⌘` switches to the predicted app")
            }
            Divider()
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",")
            if devMode {
                Button("Switch Now (test)") { switcher.trigger() }
            }
            Divider()
            Button("Quit SmartSwitch") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        Settings { SettingsView() }
    }
}

/// Rows grouped under optional headers, for use inside a menu. Hovering a row shows the exact
/// text behind it (the JSON fragment sent to or received from Jev); clicking copies that text.
private struct MenuSections: View {
    let sections: [LastPrediction.Section]

    var body: some View {
        ForEach(sections) { s in
            if s.title.isEmpty {
                lines(s)
            } else {
                Section(s.title) { lines(s) }
            }
        }
    }

    private func lines(_ s: LastPrediction.Section) -> some View {
        ForEach(s.lines) { line in
            Button(line.text) { copyToPasteboard(line.detail) }
                .help(line.detail)
        }
    }
}

private func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Switcher.shared.start()
        // First run without Accessibility: bring up Settings so the guided permission flow is one click away.
        if !HotkeyTap.trusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}
