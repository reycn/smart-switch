import AppKit
import SSCore
import UserNotifications
import os

/// What the menu shows about the most recent prediction.
struct LastPrediction {
    /// One menu row: `text` is shown, `detail` is the exact text behind it (tooltip / copied on click).
    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let detail: String
    }
    struct Section: Identifiable {
        let id = UUID()
        let title: String
        let lines: [Line]
    }
    var summary: String
    var request: [Section]
    var requestText: String
    var response: [Section]
    var responseText: String
    var raw: String
}

/// Records app activations into the Rust core and performs the ⌘` switch.
final class Switcher: ObservableObject {
    static let shared = Switcher()
    static let devTrigger = Notification.Name("dev.rongxin.smartswitch.trigger")

    @Published private(set) var last: LastPrediction?

    private let log = Logger(subsystem: "dev.rongxin.smartswitch", category: "switch")
    private let queue = DispatchQueue(label: "dev.rongxin.smartswitch.predict")
    private var tap: HotkeyTap?
    private var inFlight = false
    private var cmdTabAt: Date?        // last ⌘Tab press seen by the tap
    private var smartTarget: String?   // bundle id we just activated ourselves

    func start() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartSwitch", isDirectory: true)
        ss_init(dir.appendingPathComponent("history.json").path)

        let ownID = Bundle.main.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular,
                  let id = app.bundleIdentifier, id != ownID
            else { return }
            let source: String
            if id == self.smartTarget {
                source = "smart"
                self.smartTarget = nil
            } else if let t = self.cmdTabAt, Date().timeIntervalSince(t) < 3 {
                source = "cmd_tab"
                self.cmdTabAt = nil
            } else {
                source = "other"
            }
            ss_record(id, app.localizedName ?? id, source)
        }

        tap = HotkeyTap(onSwitch: { [weak self] in self?.trigger() },
                        onCmdTab: { [weak self] in self?.cmdTabAt = Date() })
        tap?.start()

        // Dev hook: trigger a switch from a shell without the hotkey / Accessibility.
        DistributedNotificationCenter.default().addObserver(
            forName: Self.devTrigger, object: nil, queue: .main
        ) { [weak self] _ in
            if Prefs.devMode { self?.trigger() }
        }
    }

    func trigger() {
        guard !inFlight else { return }
        inFlight = true
        let key = Keychain.apiKey ?? ""
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
        let runningJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: running)) ?? Data("[]".utf8), as: UTF8.self)

        queue.async { [self] in
            let raw = ss_predict(key, 1000, runningJSON)
            defer { ss_free(raw) }
            let data = raw.map { Data(String(cString: $0).utf8) } ?? Data()
            let outcome = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                self.inFlight = false
                self.apply(outcome)
            }
        }
    }

    private func apply(_ o: [String: Any]) {
        let name = o["name"] as? String
        let via = o["via"] as? String ?? "none"
        let error = o["error"] as? String
        let elapsed = o["elapsed_ms"] as? Int ?? 0
        log.info("via=\(via, privacy: .public) target=\(name ?? "-", privacy: .public) p=\(o["probability"] as? Double ?? -1) conf=\(o["confidence"] as? Double ?? -1) candidates=\(o["candidates"] as? Int ?? 0) \(elapsed)ms error=\(error ?? "-", privacy: .public)")
        last = Self.describe(o)

        guard let id = o["id"] as? String,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        else { return }
        smartTarget = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.smartTarget == id { self?.smartTarget = nil }
        }
        app.activate()

        if via == "last_used", Prefs.devMode {
            notify(title: "Fell back to last used app",
                   body: "\(error ?? "unknown error") — switched to \(name ?? id) after \(elapsed) ms")
        }
    }

    // MARK: - Menu content

    static func describe(_ o: [String: Any]) -> LastPrediction {
        typealias Line = LastPrediction.Line
        typealias Section = LastPrediction.Section
        func json(_ v: Any, pretty: Bool = false) -> String {
            var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
            if pretty { opts.insert(.prettyPrinted) }
            guard JSONSerialization.isValidJSONObject(v),
                  let d = try? JSONSerialization.data(withJSONObject: v, options: opts) else { return "\(v)" }
            return String(decoding: d, as: UTF8.self)
        }
        let name = o["name"] as? String ?? "–"
        let via = o["via"] as? String ?? "none"
        let error = o["error"] as? String
        let elapsed = o["elapsed_ms"] as? Int ?? 0
        let pct = { (v: Any?) -> String in (v as? Double).map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }

        let summary: String
        switch via {
        case "jev": summary = "→ \(name) · Jev \(pct(o["probability"])) · \(elapsed) ms"
        case "last_used": summary = "→ \(name) · last used, Jev failed · \(elapsed) ms"
        case "only_candidate": summary = "→ \(name) · only candidate"
        default: summary = "Nothing to switch to yet"
        }

        // Request: every row carries the exact JSON fragment that was sent, as its detail.
        var request: [Section] = []
        let req = o["request"] as? [String: Any]
        if let req, let state = req["state"] as? [String: Any] {
            let now = state["now"] ?? "", front = state["foreground_app"] ?? ""
            request.append(Section(title: "", lines: [
                Line(text: "\(now) · in \(front)", detail: json(["now": now, "foreground_app": front])),
            ]))
            if let sw = state["recent_switches"] as? [[String: Any]] {
                request.append(Section(title: "Recent switches", lines: sw.map {
                    Line(text: "\($0["switched_at"] ?? "")   \($0["app"] ?? "") · \($0["stayed_seconds"] ?? 0) s", detail: json($0))
                }))
            }
            if let m = state["recent_manual_cmd_tab_switches"] as? [[String: Any]], !m.isEmpty {
                request.append(Section(title: "Manual ⌘Tab switches", lines: m.map {
                    Line(text: "\($0["at"] ?? "")   \($0["from"] ?? "") → \($0["to"] ?? "")", detail: json($0))
                }))
            }
            if let q = (req["questions"] as? [String: Any])?["next_app"] as? [String: Any] {
                if let instructions = q["instructions"] as? String {
                    let short = instructions.count > 72 ? String(instructions.prefix(70)) + "…" : instructions
                    request.append(Section(title: "Question", lines: [Line(text: short, detail: instructions)]))
                }
                if let criteria = q["criteria"] as? [String: String] {
                    request.append(Section(title: "Candidates", lines: criteria.keys.sorted().map {
                        Line(text: "\($0) — \(criteria[$0] ?? "")", detail: json([$0: criteria[$0] ?? ""]))
                    }))
                }
            }
        } else {
            request.append(Section(title: "", lines: [Line(text: "No request sent: \(error ?? via)", detail: error ?? via)]))
        }
        let requestText = req.map { json($0, pretty: true) } ?? "No request was sent."

        var response: [Section] = []
        let resp = o["response"] as? [String: Any]
        if let resp, let a = (resp["answers"] as? [String: Any])?["next_app"] as? [String: Any] {
            response.append(Section(title: "", lines: [
                Line(text: "\(resp["model"] ?? "jev") · confidence \(pct(a["confidence"])) · \(elapsed) ms",
                     detail: json(["model": resp["model"] ?? "", "choice": a["choice"] ?? "",
                                   "confidence": a["confidence"] ?? 0, "usage": resp["usage"] ?? [:]])),
            ]))
            if let probs = a["probabilities"] as? [String: Double] {
                response.append(Section(title: "Probabilities", lines: probs.sorted { $0.value > $1.value }.map {
                    Line(text: "\(pct($0.value))   \($0.key)", detail: json([$0.key: $0.value]))
                }))
            }
        }
        if let error {
            response.append(Section(title: "", lines: [
                Line(text: "Error: \(error)", detail: error),
                Line(text: "Fell back to \(name)", detail: "via=\(via) → \(name)"),
            ]))
        }
        if response.isEmpty { response.append(Section(title: "", lines: [Line(text: "No response", detail: "No response")])) }
        let responseText = resp.map { json($0, pretty: true) } ?? (error ?? "No response.")

        return LastPrediction(summary: summary, request: request, requestText: requestText,
                              response: response, responseText: responseText, raw: json(o, pretty: true))
    }

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
