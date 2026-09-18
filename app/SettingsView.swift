import SwiftUI
import Combine
import PermissionFlow
import ServiceManagement
import UserNotifications

struct SettingsView: View {
    @State private var apiKey = Keychain.apiKey ?? ""
    @AppStorage(Prefs.devModeKey) private var devMode = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trusted = HotkeyTap.trusted
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("TypeSafe") {
                SecureField("API key", text: $apiKey)
                    .onChange(of: apiKey) { _, new in Keychain.apiKey = new }
                Link("Get a key at console.typesafe.ai", destination: URL(string: "https://console.typesafe.ai/settings/keys")!)
                    .font(.callout)
            }

            Section("Shortcuts") {
                LabeledContent("Switch app") { KeyCap("⌘ `") }
                LabeledContent("Switch tab") {
                    HStack(spacing: 6) {
                        KeyCap("⌃ `")
                        Text("coming soon").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Permissions") {
                // PermissionFlow opens the right privacy pane and floats a drag-to-authorize helper
                // next to System Settings; the button itself shows Granted / Grant live.
                LabeledContent {
                    PermissionFlowButton(
                        pane: .accessibility,
                        suggestedAppURLs: [Bundle.main.bundleURL],
                        configuration: .init(requiredAppURLs: [Bundle.main.bundleURL], promptForAccessibilityTrust: false)
                    )
                } label: {
                    Text(PermissionFlowResources.accessibilityNameResource)
                }
                Text(trusted ? "SmartSwitch can intercept ⌘` and see your ⌘Tab switches."
                             : "Required to intercept ⌘` and to see your ⌘Tab switches. Nothing else is read.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Toggle("Developer mode", isOn: $devMode)
                    .onChange(of: devMode) { _, on in
                        if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                    }
                Text("Notifies you when Jev is unavailable and the last-used app is chosen instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("SmartSwitch", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                LabeledContent("Author") {
                    Link("Rongxin", destination: URL(string: "mailto:rongxin@u.nus.edu")!)
                }
                LabeledContent("Source") {
                    Link("github.com/reycn/smart-switch", destination: URL(string: "https://github.com/reycn/smart-switch")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(poll) { _ in trusted = HotkeyTap.trusted }
    }
}

private struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(.body, design: .rounded).weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
