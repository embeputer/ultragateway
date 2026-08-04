import SwiftUI
import AppKit
import Combine
import UserNotifications

final class NotificationQueueWatcher {
    private let queueFile: URL
    private let offsetFile: URL
    private var offset: UInt64 = 0
    private var timer: Timer?

    init(supportDir: URL) {
        queueFile = supportDir.appendingPathComponent("notify-queue.jsonl")
        offsetFile = supportDir.appendingPathComponent("notify-queue.offset")
        offset = Self.readOffset(offsetFile)
        if offset == 0, FileManager.default.fileExists(atPath: queueFile.path) {
            offset = Self.fileSize(queueFile)
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard FileManager.default.fileExists(atPath: queueFile.path) else { return }

        guard let handle = try? FileHandle(forReadingFrom: queueFile) else { return }
        defer { try? handle.close() }

        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        offset += UInt64(data.count)
        Self.writeOffset(offset, to: offsetFile)

        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(String(line).utf8)) as? [String: Any] else {
                continue
            }
            let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ultragateway"
            let body = (json["body"] as? String) ?? (json["message"] as? String) ?? ""
            let subtitle = (json["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let id = (json["id"] as? String) ?? UUID().uuidString

            let content = UNMutableNotificationContent()
            content.title = title.isEmpty ? "ultragateway" : title
            if !subtitle.isEmpty {
                content.subtitle = subtitle
            }
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "ultragateway.notify.\(id)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private static func readOffset(_ url: URL) -> UInt64 {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let value = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return value
    }

    private static func writeOffset(_ value: UInt64, to url: URL) {
        try? "\(value)".write(to: url, atomically: true, encoding: .utf8)
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let monitor = GatewayMonitor()
    private var notificationWatcher: NotificationQueueWatcher?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        notificationWatcher = NotificationQueueWatcher(supportDir: monitor.supportDir)
        notificationWatcher?.start()
        setupStatusItem()
        observeMonitor()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.handleStatusItemVisibilityFallback()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.button?.performClick(nil)
        return true
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "network", accessibilityDescription: "ultragateway")
            image?.isTemplate = true
            button.image = image
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func observeMonitor() {
        monitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.statusItem?.menu = self?.buildMenu()
            }
            .store(in: &cancellables)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        addDisabledItem("ultragateway", to: menu)
        addDisabledItem("Gateway: \(monitor.gatewayStatus.label)", to: menu)
        addDisabledItem("Tunnel: \(monitor.tunnelStatus.label)", to: menu)

        if let url = monitor.publicMcpURL {
            addDisabledItem(url, to: menu)
            menu.addItem(makeItem("Copy MCP URL for Poke", action: #selector(copyPublicURL)))
        } else {
            addDisabledItem("No public URL yet", to: menu)
        }

        menu.addItem(.separator())

        menu.addItem(makeItem("Open Poke Integrations", action: #selector(openPokeIntegrations)))
        menu.addItem(makeItem("Restart Gateway", action: #selector(restartGateway)))
        menu.addItem(makeItem("Restart Tunnel", action: #selector(restartTunnel)))
        menu.addItem(makeItem("Check for Updates", action: #selector(checkForUpdates)))

        menu.addItem(.separator())
        menu.addItem(makeItem("Quit ultragateway Menu", action: #selector(quit)))

        return menu
    }

    private func addDisabledItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func handleStatusItemVisibilityFallback() {
        guard let statusItem, !statusItem.isVisible else { return }

        NSApp.setActivationPolicy(.regular)

        let content = UNMutableNotificationContent()
        content.title = "ultragateway menu bar icon hidden"
        content.body = "Enable ultragateway in System Settings → Control Center → Menu Bar, then reopen the app."
        let request = UNNotificationRequest(
            identifier: "ultragateway.menu_bar_hidden",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    @objc private func copyPublicURL() { monitor.copyPublicURL() }
    @objc private func openPokeIntegrations() { monitor.openPokeIntegrations() }
    @objc private func restartGateway() { monitor.restartGateway() }
    @objc private func restartTunnel() { monitor.restartTunnel() }
    @objc private func checkForUpdates() { monitor.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
struct UltragatewayMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

enum ServiceStatus {
    case running
    case stopped
    case unknown

    var label: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .unknown: return "Unknown"
        }
    }
}

final class GatewayMonitor: ObservableObject {
    @Published var gatewayStatus: ServiceStatus = .unknown
    @Published var tunnelStatus: ServiceStatus = .unknown
    @Published var publicMcpURL: String?

    let supportDir: URL
    private let publicURLFile: URL
    private let restartScript: URL
    private let gatewayLabel: String
    private let tunnelLabel: String
    private let gatewayPort: Int
    private var timer: Timer?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        supportDir = home.appendingPathComponent("Library/Application Support/ultragateway")
        publicURLFile = supportDir.appendingPathComponent("public-mcp-url.txt")
        restartScript = supportDir.appendingPathComponent("restart-launchagent.sh")
        let labels = Self.readLaunchAgentLabels(supportDir: supportDir)
        gatewayLabel = labels.gateway
        tunnelLabel = labels.tunnel
        gatewayPort = Self.readGatewayPort(supportDir: supportDir)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        gatewayStatus = Self.launchdRunning(label: gatewayLabel)
            ? .running
            : .stopped
        tunnelStatus = Self.launchdRunning(label: tunnelLabel)
            ? .running
            : .stopped

        if let url = try? String(contentsOf: publicURLFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty {
            publicMcpURL = url
        } else {
            publicMcpURL = nil
        }

        if Self.localGatewayHealthy(port: gatewayPort) {
            gatewayStatus = .running
        }
    }

    func copyPublicURL() {
        guard let url = publicMcpURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    func openPokeIntegrations() {
        if let url = URL(string: "https://poke.com/integrations/new") {
            NSWorkspace.shared.open(url)
        }
    }

    func restartGateway() {
        restartService(label: gatewayLabel, displayName: "Gateway")
    }

    func restartTunnel() {
        restartService(label: tunnelLabel, displayName: "Tunnel")
    }

    func checkForUpdates() {
        let script = supportDir.appendingPathComponent("auto-update.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            postNotification(title: "ultragateway", subtitle: "Update", body: "Update script missing. Run install.sh from the ultragateway repo.")
            return
        }
        postNotification(title: "ultragateway", subtitle: "Update", body: "Checking for updates…")
        DispatchQueue.global(qos: .utility).async {
            let ok = self.runShell("\(self.shellQuote(script.path))")
            DispatchQueue.main.async {
                if ok {
                    self.postNotification(
                        title: "ultragateway",
                        subtitle: "Update",
                        body: "Update check finished. See ~/Library/Logs/ultragateway/update.log."
                    )
                } else {
                    self.postNotification(
                        title: "ultragateway",
                        subtitle: "Update",
                        body: "Update check failed. See ~/Library/Logs/ultragateway/update.log."
                    )
                }
                self.refresh()
            }
        }
    }

    private func restartService(label: String, displayName: String) {
        postNotification(title: "ultragateway", subtitle: displayName, body: "Restarting…")

        DispatchQueue.global(qos: .userInitiated).async {
            let restarted = self.performRestart(label: label, displayName: displayName)
            Thread.sleep(forTimeInterval: 2.0)

            let launchdUp = Self.launchdRunning(label: label)
            let gatewayUp = label == self.gatewayLabel && Self.localGatewayHealthy(port: self.gatewayPort)
            let isUp = label == self.gatewayLabel ? (launchdUp && gatewayUp) : launchdUp

            DispatchQueue.main.async {
                self.refresh()
                if restarted && isUp {
                    self.postNotification(title: "ultragateway", subtitle: displayName, body: "Started up.")
                } else if restarted {
                    self.postNotification(
                        title: "ultragateway",
                        subtitle: displayName,
                        body: "Restart sent but service is not healthy yet. Check ~/Library/Logs/ultragateway/."
                    )
                }
                // performRestart posts its own error notification on failure
            }
        }
    }

    @discardableResult
    private func performRestart(label: String, displayName: String) -> Bool {
        if FileManager.default.fileExists(atPath: restartScript.path) {
            if runShell("\(shellQuote(restartScript.path)) \(shellQuote(label))") {
                return true
            }
        }

        let uid = getuid()
        let domain = "gui/\(uid)"
        let target = "\(domain)/\(label)"
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")

        if runShell("launchctl kickstart -k \(shellQuote(target))") {
            return true
        }

        guard FileManager.default.fileExists(atPath: plist.path) else {
            postNotification(
                title: "ultragateway",
                subtitle: displayName,
                body: "Error: LaunchAgent missing. Run install.sh from the ultragateway repo."
            )
            return false
        }

        _ = runShell("launchctl bootout \(shellQuote(target))")
        if runShell("launchctl bootstrap \(shellQuote(domain)) \(shellQuote(plist.path))") {
            _ = runShell("launchctl kickstart -k \(shellQuote(target))")
            return true
        }

        postNotification(
            title: "ultragateway",
            subtitle: displayName,
            body: "Error: could not restart \(label). Try install.sh or check logs."
        )
        return false
    }

    private func runShell(_ command: String) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func postNotification(title: String, subtitle: String? = nil, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "ultragateway.ui.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static func readLaunchAgentLabels(supportDir: URL) -> (gateway: String, tunnel: String) {
        let defaults = (gateway: "com.ultragateway.em", tunnel: "com.ultragateway.em.tunnel")
        let labelsFile = supportDir.appendingPathComponent("launchagent-labels.env")
        guard let text = try? String(contentsOf: labelsFile, encoding: .utf8) else {
            return defaults
        }

        var gateway = defaults.gateway
        var tunnel = defaults.tunnel
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("GATEWAY_LABEL=") {
                let value = trimmed.replacingOccurrences(of: "GATEWAY_LABEL=", with: "")
                if !value.isEmpty { gateway = value }
            } else if trimmed.hasPrefix("TUNNEL_LABEL=") {
                let value = trimmed.replacingOccurrences(of: "TUNNEL_LABEL=", with: "")
                if !value.isEmpty { tunnel = value }
            }
        }
        return (gateway, tunnel)
    }

    private static func readGatewayPort(supportDir: URL) -> Int {
        let config = supportDir.appendingPathComponent("config.env")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return 8000 }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SUPERGATEWAY_PORT=") {
                let value = trimmed.replacingOccurrences(of: "SUPERGATEWAY_PORT=", with: "")
                if let port = Int(value) { return port }
            }
        }
        return 8000
    }

    private static func launchdRunning(label: String) -> Bool {
        let uid = getuid()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", "launchctl print gui/\(uid)/\(label) 2>/dev/null | grep -q 'state = running'"]
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func localGatewayHealthy(port: Int) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-z", "127.0.0.1", String(port)]
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
