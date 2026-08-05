import SwiftUI
import AppKit
import Combine
import IOKit.pwr_mgt
import Security
import UserNotifications

// MARK: - KeepAwakeController

/// Prevents idle **system** sleep while the menu bar app runs (display may still sleep).
/// Uses IOKit `PreventUserIdleSystemSleep` — equivalent to `caffeinate -i`, not `-d`.
final class KeepAwakeController {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    func setEnabled(_ enabled: Bool) {
        if enabled {
            startAssertion()
        } else {
            stopAssertion()
        }
    }

    private func startAssertion() {
        guard !isActive else { return }
        let reason = "ultragateway remote MCP access" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result == kIOReturnSuccess {
            isActive = true
        }
    }

    private func stopAssertion() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }

    deinit {
        stopAssertion()
    }
}

final class NotificationQueueWatcher {
    private let queueFile: URL
    private let offsetFile: URL
    private var offset: UInt64 = 0
    private var partialLine = Data()
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

        let fileSize = Self.fileSize(queueFile)
        if offset > fileSize {
            offset = 0
            partialLine = Data()
        }

        guard let handle = try? FileHandle(forReadingFrom: queueFile) else { return }
        defer { try? handle.close() }

        let priorPartialCount = partialLine.count
        try? handle.seek(toOffset: offset + UInt64(priorPartialCount))
        let newData = (try? handle.readToEnd()) ?? Data()
        guard !newData.isEmpty || priorPartialCount > 0 else { return }

        var buffer = partialLine
        buffer.append(newData)
        partialLine = Data()

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            buffer = buffer[(newlineIndex + 1)...]
            deliverNotification(from: Data(lineData))
        }

        if !buffer.isEmpty {
            partialLine = buffer
        }

        let consumedBytes = priorPartialCount + newData.count - partialLine.count
        offset += UInt64(consumedBytes)
        Self.writeOffset(offset, to: offsetFile)
    }

    private func deliverNotification(from lineData: Data) {
        guard !lineData.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return
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
    let monitor = GatewayMonitor()
    private var notificationWatcher: NotificationQueueWatcher?
    private var agentCoverWatcher: AgentCoverCommandWatcher?
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        notificationWatcher = NotificationQueueWatcher(supportDir: monitor.supportDir)
        notificationWatcher?.start()
        agentCoverWatcher = AgentCoverCommandWatcher(
            supportDir: monitor.supportDir,
            isAllowed: { [weak self] in self?.monitor.agentCoverEnabled ?? true },
            onStatusChange: { [weak self] in
                DispatchQueue.main.async {
                    self?.monitor.syncAgentCoverActive()
                    self?.statusItem?.menu = self?.buildMenu()
                }
            }
        )
        agentCoverWatcher?.start()
        NotificationCenter.default.addObserver(
            forName: .agentCoverDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.monitor.syncAgentCoverActive()
            self?.statusItem?.menu = self?.buildMenu()
        }
        setupStatusItem()
        observeMonitor()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.handleStatusItemVisibilityFallback()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        monitor.refreshNotificationStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.releaseKeepAwake()
        AgentCoverController.shared.stopCover(lock: false)
        agentCoverWatcher?.stop()
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
        if monitor.agentCoverActive {
            addDisabledItem("Agent cover: On", to: menu)
        }

        if let url = monitor.publicMcpURL {
            addDisabledItem(url, to: menu)
            menu.addItem(makeItem("Copy MCP URL", action: #selector(copyPublicURL)))
        } else {
            addDisabledItem("No public URL yet", to: menu)
        }

        if !monitor.notificationsEnabled {
            menu.addItem(.separator())
            menu.addItem(makeItem("Notifications Disabled", action: #selector(enableNotifications)))
        }

        menu.addItem(.separator())

        menu.addItem(makeItem("Open Settings", action: #selector(openSettings), symbolName: "gearshape", keyEquivalent: ","))
        menu.addItem(makeItem("Sleep Display", action: #selector(sleepDisplay), symbolName: "moon.zzz", keyEquivalent: ""))
        menu.addItem(makeItem("Restart Gateway", action: #selector(restartGateway), symbolName: "arrow.clockwise"))
        menu.addItem(makeItem("Restart Tunnel", action: #selector(restartTunnel), symbolName: "network"))
        menu.addItem(makeItem("Check for Updates", action: #selector(checkForUpdates), symbolName: "arrow.down.circle"))

        menu.addItem(.separator())
        menu.addItem(makeItem("Quit ultragateway Menu", action: #selector(quit)))

        return menu
    }

    private func addDisabledItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func makeItem(
        _ title: String,
        action: Selector,
        symbolName: String? = nil,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if let symbolName {
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            image?.isTemplate = true
            item.image = image
        }
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
    @objc private func enableNotifications() { monitor.requestNotificationAccess() }
    @objc private func sleepDisplay() { monitor.sleepDisplay() }
    @objc private func restartGateway() { monitor.restartGateway() }
    @objc private func restartTunnel() { monitor.restartTunnel() }
    @objc private func checkForUpdates() { monitor.checkForUpdates() }
    @objc private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(monitor: monitor))
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            let window = NSWindow(contentViewController: hosting)
            window.title = "ultragateway Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.setContentSize(NSSize(width: 480, height: 640))
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct UltragatewayMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(monitor: appDelegate.monitor)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: GatewayMonitor
    @State private var appeared = false
    @State private var copiedFlash = false
    @State private var copiedKeyFlash = false
    @State private var showRegenerateConfirm = false

    private let ink = Color(red: 0.07, green: 0.10, blue: 0.14)
    private var accent: Color { .accentColor }

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    brandHero
                    statusGlass
                    apiKeyGlass
                    keepAwakeGlass
                    agentCoverGlass
                    if !monitor.notificationsEnabled {
                        notificationsGlass
                    }
                    actionsGlass
                }
                .padding(22)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
            }
        }
        .tint(accent)
        .frame(minWidth: 480, minHeight: 620)
        .onAppear {
            monitor.refresh()
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                appeared = true
            }
        }
        .alert("Regenerate API Key?", isPresented: $showRegenerateConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) {
                monitor.regenerateApiKey()
            }
        } message: {
            Text("A new key will be generated and the gateway will restart. Clients using the old key will stop working until updated.")
        }
    }

    private var background: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .opacity(0.8)
            .ignoresSafeArea()
    }

    private var brandHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ultragateway")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [ink, accent],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .shadow(color: .white.opacity(0.55), radius: 0, y: 1)

            Text("Local MCP gateway · tunnel · notifications")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(ink.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var statusGlass: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Status")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.opacity(0.45))
                .textCase(.uppercase)
                .tracking(1.1)

            HStack(spacing: 12) {
                statusChip(title: "Gateway", status: monitor.gatewayStatus)
                statusChip(title: "Tunnel", status: monitor.tunnelStatus)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Public MCP URL")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.45))

                HStack(spacing: 10) {
                    if let url = monitor.publicMcpURL {
                        Text(url)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(ink.opacity(0.85))
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            monitor.copyPublicURL()
                            withAnimation(.easeOut(duration: 0.2)) { copiedFlash = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                withAnimation { copiedFlash = false }
                            }
                        } label: {
                            Text(copiedFlash ? "Copied" : "Copy")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(copiedFlash ? accent.opacity(0.9) : ink.opacity(0.88), in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("No public URL yet")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(ink.opacity(0.4))
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                )
            }
        }
        .padding(18)
        .background(glassFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(glassStroke(radius: 22))
        .shadow(color: accent.opacity(0.12), radius: 18, y: 8)
    }

    private var apiKeyGlass: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Security")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.opacity(0.45))
                .textCase(.uppercase)
                .tracking(1.1)

            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "key.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("API key protection")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink)
                    Text("Require Bearer auth on the MCP HTTP surface.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: Binding(
                    get: { monitor.apiKeyProtectionEnabled },
                    set: { monitor.setApiKeyProtectionEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accent)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1)
            )

            if monitor.apiKeyProtectionEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("API Key")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.opacity(0.45))

                    HStack(spacing: 10) {
                        if let key = monitor.apiKey, !key.isEmpty {
                            Text(key)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(ink.opacity(0.85))
                                .lineLimit(2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                monitor.copyApiKey()
                                flashKeyCopied(true)
                            } label: {
                                Text(copiedKeyFlash ? "Copied" : "Copy")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        copiedKeyFlash ? accent.opacity(0.9) : ink.opacity(0.88),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("Generating…")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(ink.opacity(0.4))
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                    )

                    Button {
                        showRegenerateConfirm = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Regenerate Key")
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(monitor.apiKey?.isEmpty != false)
                }
            }
        }
        .padding(18)
        .background(glassFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(glassStroke(radius: 22))
        .shadow(color: accent.opacity(0.10), radius: 16, y: 7)
    }

    private func flashKeyCopied(_ flash: Bool) {
        guard flash else { return }
        withAnimation(.easeOut(duration: 0.2)) { copiedKeyFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { copiedKeyFlash = false }
        }
    }

    private var keepAwakeGlass: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Power")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.opacity(0.45))
                .textCase(.uppercase)
                .tracking(1.1)

            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Keep Mac awake")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink)
                    Text("Prevent idle system sleep for remote MCP access. Display may still sleep.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: Binding(
                    get: { monitor.keepAwakeEnabled },
                    set: { monitor.setKeepAwakeEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accent)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1)
            )
        }
        .padding(18)
        .background(glassFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(glassStroke(radius: 22))
        .shadow(color: accent.opacity(0.10), radius: 16, y: 7)
    }

    private var agentCoverGlass: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agent cover")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.opacity(0.45))
                .textCase(.uppercase)
                .tracking(1.1)

            HStack(alignment: .center, spacing: 14) {
                Image(systemName: monitor.agentCoverActive ? "shield.lefthalf.filled" : "shield")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(monitor.agentCoverActive ? "Cover active" : "Allow agent cover")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink)
                    Text("Attendant shield started by agents via MCP. Not Apple Locked Use — Mac stays unlocked until you touch the keyboard or mouse.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: Binding(
                    get: { monitor.agentCoverEnabled },
                    set: { monitor.setAgentCoverEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accent)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button {
                    monitor.testAgentCover()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "eye")
                        Text(monitor.agentCoverActive ? "Stop test cover" : "Test cover")
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!monitor.agentCoverEnabled && !monitor.agentCoverActive)
            }
        }
        .padding(18)
        .background(glassFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(glassStroke(radius: 22))
        .shadow(color: accent.opacity(0.10), radius: 16, y: 7)
    }

    private var notificationsGlass: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "bell.badge")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Notifications off")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                Text("Enable so gateway events show up in Notification Center.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(ink.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Enable") {
                monitor.requestNotificationAccess()
            }
            .buttonStyle(GlassAccentButtonStyle())
        }
        .padding(16)
        .background(glassFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(glassStroke(radius: 20))
        .shadow(color: accent.opacity(0.10), radius: 14, y: 6)
    }

    private var actionsGlass: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controls")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.opacity(0.45))
                .textCase(.uppercase)
                .tracking(1.1)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                actionTile(title: "Sleep Display", symbol: "moon.zzz") {
                    monitor.sleepDisplay()
                }
                actionTile(title: "Restart Gateway", symbol: "arrow.clockwise") {
                    monitor.restartGateway()
                }
                actionTile(title: "Restart Tunnel", symbol: "network") {
                    monitor.restartTunnel()
                }
                actionTile(title: "Check Updates", symbol: "arrow.down.circle") {
                    monitor.checkForUpdates()
                }
                actionTile(title: "Open Logs", symbol: "doc.text") {
                    monitor.openLogsFolder()
                }
            }

            Button {
                monitor.openSupportFolder()
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text("Open Support Folder")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.5)
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(glassFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(glassStroke(radius: 22))
        .shadow(color: accent.opacity(0.10), radius: 16, y: 7)
    }

    private func statusChip(title: String, status: ServiceStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(ink.opacity(0.5))
            HStack(spacing: 8) {
                Circle()
                    .fill(status.color)
                    .frame(width: 9, height: 9)
                    .shadow(color: status.color.opacity(0.55), radius: 4)
                Text(status.label)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.45), lineWidth: 1)
        )
    }

    private func actionTile(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var glassFill: some ShapeStyle {
        .ultraThinMaterial
    }

    private func glassStroke(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.65), .white.opacity(0.15), accent.opacity(0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.2
            )
    }
}

private struct GlassAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
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

    var color: Color {
        switch self {
        case .running: return .green
        case .stopped: return .red
        case .unknown: return .secondary
        }
    }
}

final class GatewayMonitor: ObservableObject {
    @Published var gatewayStatus: ServiceStatus = .unknown
    @Published var tunnelStatus: ServiceStatus = .unknown
    @Published var publicMcpURL: String?
    @Published var notificationsEnabled = true
    @Published var apiKeyProtectionEnabled = false
    @Published var apiKey: String?
    @Published var keepAwakeEnabled = false
    @Published var agentCoverEnabled = true
    @Published var agentCoverActive = false

    let supportDir: URL
    private let keepAwakeController = KeepAwakeController()
    private let publicURLFile: URL
    private let restartScript: URL
    private let configEnvFile: URL
    private let gatewayLabel: String
    private let tunnelLabel: String
    private let gatewayPort: Int
    private var timer: Timer?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        supportDir = home.appendingPathComponent("Library/Application Support/ultragateway")
        publicURLFile = supportDir.appendingPathComponent("public-mcp-url.txt")
        restartScript = supportDir.appendingPathComponent("restart-launchagent.sh")
        configEnvFile = supportDir.appendingPathComponent("config.env")
        let labels = Self.readLaunchAgentLabels(supportDir: supportDir)
        gatewayLabel = labels.gateway
        tunnelLabel = labels.tunnel
        gatewayPort = Self.readGatewayPort(supportDir: supportDir)
        let keepAwake = Self.readConfigBool(key: "KEEP_AWAKE_ENABLED", from: configEnvFile) ?? false
        keepAwakeEnabled = keepAwake
        keepAwakeController.setEnabled(keepAwake)
        agentCoverEnabled = Self.readConfigBool(key: "AGENT_COVER_ENABLED", from: configEnvFile) ?? true
        AgentCoverController.shared.configure(supportDir: supportDir)
        apiKeyProtectionEnabled = Self.readConfigBool(key: "API_KEY_PROTECTION_ENABLED", from: configEnvFile) ?? false
        let storedKey = Self.readConfigValue(key: "API_KEY", from: configEnvFile)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = (storedKey?.isEmpty == false) ? storedKey : nil
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

        refreshApiKeySettings()
        refreshKeepAwakeSettings()
        refreshAgentCoverSettings()
        syncAgentCoverActive()
        refreshNotificationStatus()
    }

    func refreshApiKeySettings() {
        let enabled = Self.readConfigBool(key: "API_KEY_PROTECTION_ENABLED", from: configEnvFile) ?? false
        let key = Self.readConfigValue(key: "API_KEY", from: configEnvFile)
        let trimmedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey = (trimmedKey?.isEmpty == false) ? trimmedKey : nil

        if apiKeyProtectionEnabled != enabled {
            apiKeyProtectionEnabled = enabled
        }
        if apiKey != resolvedKey {
            apiKey = resolvedKey
        }
    }

    func setApiKeyProtectionEnabled(_ enabled: Bool) {
        let currentEnabled = Self.readConfigBool(key: "API_KEY_PROTECTION_ENABLED", from: configEnvFile) ?? false
        guard enabled != currentEnabled else { return }

        if enabled {
            let existing = Self.readConfigValue(key: "API_KEY", from: configEnvFile)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = existing.isEmpty ? Self.generateApiKey() : existing
            Self.writeConfigValues(
                [
                    "API_KEY_PROTECTION_ENABLED": "true",
                    "API_KEY": key,
                ],
                to: configEnvFile
            )
            apiKeyProtectionEnabled = true
            apiKey = key
        } else {
            Self.writeConfigValues(
                [
                    "API_KEY_PROTECTION_ENABLED": "false",
                    "API_KEY": "",
                ],
                to: configEnvFile
            )
            apiKeyProtectionEnabled = false
            apiKey = nil
        }
        restartGateway()
    }

    func refreshKeepAwakeSettings() {
        let enabled = Self.readConfigBool(key: "KEEP_AWAKE_ENABLED", from: configEnvFile) ?? false
        if keepAwakeEnabled != enabled {
            keepAwakeEnabled = enabled
            keepAwakeController.setEnabled(enabled)
        } else if enabled && !keepAwakeController.isActive {
            keepAwakeController.setEnabled(true)
        }
    }

    func setKeepAwakeEnabled(_ enabled: Bool) {
        Self.writeConfigValues(
            ["KEEP_AWAKE_ENABLED": enabled ? "true" : "false"],
            to: configEnvFile
        )
        keepAwakeEnabled = enabled
        keepAwakeController.setEnabled(enabled)
    }

    func releaseKeepAwake() {
        keepAwakeController.setEnabled(false)
    }

    func refreshAgentCoverSettings() {
        let enabled = Self.readConfigBool(key: "AGENT_COVER_ENABLED", from: configEnvFile) ?? true
        if agentCoverEnabled != enabled {
            agentCoverEnabled = enabled
            if !enabled && AgentCoverController.shared.isActive {
                AgentCoverController.shared.stopCover(lock: false)
            }
        }
    }

    func setAgentCoverEnabled(_ enabled: Bool) {
        Self.writeConfigValues(
            ["AGENT_COVER_ENABLED": enabled ? "true" : "false"],
            to: configEnvFile
        )
        agentCoverEnabled = enabled
        if !enabled && AgentCoverController.shared.isActive {
            AgentCoverController.shared.stopCover(lock: false)
        }
        syncAgentCoverActive()
    }

    func syncAgentCoverActive() {
        let active = AgentCoverController.shared.isActive
        if agentCoverActive != active {
            agentCoverActive = active
        }
    }

    func testAgentCover() {
        if AgentCoverController.shared.isActive {
            AgentCoverController.shared.stopCover(lock: false)
        } else {
            guard agentCoverEnabled else { return }
            AgentCoverController.shared.startCover()
        }
        syncAgentCoverActive()
    }

    func regenerateApiKey() {
        guard apiKeyProtectionEnabled else { return }
        let key = Self.generateApiKey()
        Self.writeConfigValues(
            [
                "API_KEY_PROTECTION_ENABLED": "true",
                "API_KEY": key,
            ],
            to: configEnvFile
        )
        apiKey = key
        restartGateway()
    }

    func copyApiKey() {
        guard let key = apiKey, !key.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                let enabled = settings.authorizationStatus == .authorized
                    && settings.alertSetting == .enabled
                if self.notificationsEnabled != enabled {
                    self.notificationsEnabled = enabled
                }
            }
        }
    }

    func requestNotificationAccess() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                switch settings.authorizationStatus {
                case .notDetermined:
                    // Accessory (LSUIElement) apps fail requestAuthorization with UNError 1
                    // unless activated as a regular app first. Bundle must also be codesigned
                    // with Info.plist bound to CFBundleIdentifier.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
                            DispatchQueue.main.async {
                                self.refreshNotificationStatus()
                                if let error, (error as NSError).domain == "UNErrorDomain", (error as NSError).code == 1 {
                                    self.openNotificationSettings()
                                    let alert = NSAlert()
                                    alert.messageText = "Enable Notifications"
                                    alert.informativeText = "macOS blocked the permission prompt (often due to app signing). Turn on notifications for ultragateway in System Settings, then click Enable again."
                                    alert.alertStyle = .informational
                                    alert.addButton(withTitle: "OK")
                                    alert.runModal()
                                }
                                if !NSApp.windows.contains(where: \.isVisible) {
                                    NSApp.setActivationPolicy(.accessory)
                                }
                            }
                        }
                    }
                case .authorized where settings.alertSetting == .enabled:
                    self.refreshNotificationStatus()
                default:
                    self.openNotificationSettings()
                }
            }
        }
    }

    func copyPublicURL() {
        guard let url = publicMcpURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    private static func generateApiKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Extremely unlikely; fall back to combining two UUIDs as entropy.
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func readConfigValue(key: String, from url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var last: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard trimmed.hasPrefix("\(key)=") else { continue }
            var value = String(trimmed.dropFirst(key.count + 1))
            if value.count >= 2 {
                let first = value.first!
                let lastChar = value.last!
                if (first == "\"" && lastChar == "\"") || (first == "'" && lastChar == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            last = value
        }
        return last
    }

    private static func readConfigBool(key: String, from url: URL) -> Bool? {
        guard let raw = readConfigValue(key: key, from: url)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func writeConfigValues(_ updates: [String: String], to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if text.isEmpty {
            text = ""
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found = Set<String>()

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            for (key, value) in updates {
                if trimmed.hasPrefix("\(key)=") {
                    lines[index] = "\(key)=\(value)"
                    found.insert(key)
                    break
                }
            }
        }

        let missing = updates.keys.filter { !found.contains($0) }.sorted()
        if !missing.isEmpty {
            if let last = lines.last, !last.isEmpty {
                lines.append("")
            }
            for key in missing {
                lines.append("\(key)=\(updates[key] ?? "")")
            }
        }

        var output = lines.joined(separator: "\n")
        if !output.hasSuffix("\n") {
            output += "\n"
        }
        try? output.write(to: url, atomically: true, encoding: .utf8)
    }

    func openLogsFolder() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ultragateway")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logsDir)
    }

    func openSupportFolder() {
        NSWorkspace.shared.open(supportDir)
    }

    func restartGateway() {
        restartService(label: gatewayLabel, displayName: "Gateway")
    }

    /// Put displays to sleep without sleeping the system (MCP/tunnel keep running).
    func sleepDisplay() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        do {
            try task.run()
        } catch {
            NSLog("ultragateway: failed to sleep display: \(error.localizedDescription)")
        }
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
            let isUp = self.waitForServiceHealthy(label: label)

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

    private func waitForServiceHealthy(label: String) -> Bool {
        var delay: TimeInterval = 2.0
        let maxDelay: TimeInterval = 15.0
        let deadline = Date().addingTimeInterval(120.0)

        while Date() < deadline {
            Thread.sleep(forTimeInterval: delay)

            let launchdUp = Self.launchdRunning(label: label)
            let gatewayUp = label == self.gatewayLabel && Self.localGatewayHealthy(port: self.gatewayPort)
            let isUp = label == self.gatewayLabel ? (launchdUp && gatewayUp) : launchdUp
            if isUp {
                return true
            }

            delay = min(delay * 1.5, maxDelay)
        }

        return false
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

    private func openNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ultragateway.em"
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)",
        ]
        for urlString in candidates {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return
            }
        }
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
