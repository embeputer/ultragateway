import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - AgentCoverController

/// Full-screen attendant cover while an agent drives the Mac.
/// Session stays unlocked so cua-driver can work; real human HID input locks the Mac.
/// Not Apple Codex auth-plugin “Locked Use” — DIY cover + lock-on-human-input.
final class AgentCoverController: ObservableObject {
    static let shared = AgentCoverController()

    @Published private(set) var isActive = false

    private var coverWindows: [NSWindow] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var screenObserver: NSObjectProtocol?
    private var supportDir: URL?
    private var lockInProgress = false
    /// Ignore HID briefly after arming so residual agent events don't trip the lock.
    private var armedAt: Date?
    private let armGracePeriod: TimeInterval = 0.35

    private let stateFileName = "agent-cover-state.json"

    private init() {}

    func configure(supportDir: URL) {
        self.supportDir = supportDir
    }

    func startCover() {
        DispatchQueue.main.async { [weak self] in
            self?.startCoverOnMain()
        }
    }

    func stopCover(lock: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if lock {
                self.lockAndDismiss()
            } else {
                self.dismissCoverOnly()
            }
        }
    }

    // MARK: - Main-thread lifecycle

    private func startCoverOnMain() {
        guard !isActive else {
            writeState(active: true)
            return
        }
        isActive = true
        lockInProgress = false
        buildCoverWindows()
        armEventTap()
        writeState(active: true)
        NotificationCenter.default.post(name: .agentCoverDidChange, object: nil)

        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.isActive else { return }
                self.buildCoverWindows()
            }
        }
    }

    private func dismissCoverOnly() {
        disarmEventTap()
        tearDownWindows()
        isActive = false
        lockInProgress = false
        writeState(active: false)
        NotificationCenter.default.post(name: .agentCoverDidChange, object: nil)
    }

    private func lockAndDismiss() {
        guard !lockInProgress else { return }
        lockInProgress = true
        disarmEventTap()
        tearDownWindows()
        isActive = false
        writeState(active: false)
        NotificationCenter.default.post(name: .agentCoverDidChange, object: nil)
        Self.lockMacScreen()
        lockInProgress = false
    }

    // MARK: - Cover windows

    private func tearDownWindows() {
        for window in coverWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        coverWindows.removeAll()
    }

    private func buildCoverWindows() {
        tearDownWindows()
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(screen.frame, display: true)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .ignoresCycle,
                .fullScreenAuxiliary,
            ]
            // Pass clicks through so AX / apps under the shield still receive them.
            window.ignoresMouseEvents = true
            // Best-effort: exclude from screenshots / Screen Recording (Sonoma+ honored widely).
            window.sharingType = .none
            window.collectionBehavior.insert(.transient)
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false

            let hosting = NSHostingView(rootView: AgentCoverOverlayView())
            hosting.frame = CGRect(origin: .zero, size: screen.frame.size)
            window.contentView = hosting
            window.orderFrontRegardless()
            coverWindows.append(window)
        }
    }

    // MARK: - Event tap (human HID → lock)

    private func armEventTap() {
        disarmEventTap()
        armedAt = Date()

        let mask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
            | (1 << CGEventType.tabletPointer.rawValue)
            | (1 << CGEventType.tabletProximity.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let controller = Unmanaged<AgentCoverController>.fromOpaque(refcon).takeUnretainedValue()
                controller.handleTappedEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            NSLog("[ultragateway] Agent cover: CGEvent tap failed — grant Accessibility / Input Monitoring to ultragateway")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CGEvent.tapEnable(tap: tap, enable: true)

        let thread = Thread { [weak self] in
            guard let self, let source = self.runLoopSource else { return }
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
            self.tapRunLoop = nil
        }
        thread.name = "ultragateway.agent-cover.tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    private func disarmEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopSourceInvalidate(source)
        }
        if let rl = tapRunLoop {
            CFRunLoopStop(rl)
        }
        eventTap = nil
        runLoopSource = nil
        tapThread = nil
        tapRunLoop = nil
        armedAt = nil
    }

    private func handleTappedEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        guard isActive, !lockInProgress else { return }

        if let armedAt, Date().timeIntervalSince(armedAt) < armGracePeriod {
            return
        }

        guard Self.isLikelyHumanHID(event: event, type: type) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.lockAndDismiss()
        }
    }

    /// Filter programmatic / agent-injected CGEvents; real HID usually has unix PID 0
    /// and HID system state. AX clicks do not appear here.
    private static func isLikelyHumanHID(event: CGEvent, type: CGEventType) -> Bool {
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        if sourcePID != 0 {
            return false
        }

        let stateID = event.getIntegerValueField(.eventSourceStateID)
        // kCGEventSourceStatePrivate == -1
        if stateID == Int64(CGEventSourceStateID.privateState.rawValue) {
            return false
        }

        // Ignore pure mouse-move noise with zero delta (some synthetic streams).
        if type == .mouseMoved || type == .leftMouseDragged
            || type == .rightMouseDragged || type == .otherMouseDragged
        {
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            if abs(dx) < 0.5 && abs(dy) < 0.5 {
                return false
            }
        }

        // Ignore key repeats that somehow look empty — keyDown with no keycode is invalid.
        if type == .keyDown {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode < 0 { return false }
        }

        return true
    }

    // MARK: - Lock screen

    /// Prefer SACLockScreenImmediate (login.framework); fall back to ⌃⌘Q via System Events.
    static func lockMacScreen() {
        if lockViaSAC() { return }
        lockViaControlCommandQ()
    }

    private static func lockViaSAC() -> Bool {
        let path = "/System/Library/PrivateFrameworks/login.framework/login"
        guard let handle = dlopen(path, RTLD_LAZY) else { return false }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFn = @convention(c) () -> Void
        let lockFn = unsafeBitCast(sym, to: LockFn.self)
        lockFn()
        return true
    }

    private static func lockViaControlCommandQ() {
        let script = """
        tell application "System Events" to keystroke "q" using {control down, command down}
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        // Don't block the main thread long; lock is fire-and-forget.
    }

    // MARK: - State file

    private func writeState(active: Bool) {
        guard let supportDir else { return }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let url = supportDir.appendingPathComponent(stateFileName)
        let payload: [String: Any] = [
            "active": active,
            "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8)
        {
            try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Cover UI

private struct AgentCoverOverlayView: View {
    private let ink = Color(red: 0.92, green: 0.94, blue: 0.97)
    private let muted = Color.white.opacity(0.55)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.10),
                    Color(red: 0.08, green: 0.10, blue: 0.16),
                    Color(red: 0.06, green: 0.09, blue: 0.14),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Soft glass vignette
            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.18),
                    Color.clear,
                ],
                center: .center,
                startRadius: 40,
                endRadius: 520
            )

            VStack(spacing: 18) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white.opacity(0.95), Color.accentColor.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 18, y: 4)

                Text("ultragateway")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(muted)
                    .tracking(1.2)
                    .textCase(.uppercase)

                Text("An agent is working on this Mac")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 2)

                Text("Using the keyboard, mouse, or trackpad will lock this Mac.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(40)
            .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.35), .white.opacity(0.08), Color.accentColor.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

// MARK: - Command queue watcher

/// Polls `agent-cover-cmd.jsonl` (same offset pattern as notify-queue).
final class AgentCoverCommandWatcher {
    private let queueFile: URL
    private let offsetFile: URL
    private let supportDir: URL
    private var offset: UInt64 = 0
    private var partialLine = Data()
    private var timer: Timer?
    private let isAllowed: () -> Bool
    private let onStatusChange: () -> Void

    init(supportDir: URL, isAllowed: @escaping () -> Bool, onStatusChange: @escaping () -> Void) {
        self.supportDir = supportDir
        self.isAllowed = isAllowed
        self.onStatusChange = onStatusChange
        queueFile = supportDir.appendingPathComponent("agent-cover-cmd.jsonl")
        offsetFile = supportDir.appendingPathComponent("agent-cover-cmd.offset")
        offset = Self.readOffset(offsetFile)
        if offset == 0, FileManager.default.fileExists(atPath: queueFile.path) {
            offset = Self.fileSize(queueFile)
        }
        AgentCoverController.shared.configure(supportDir: supportDir)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
            handleCommand(from: Data(lineData))
        }

        if !buffer.isEmpty {
            partialLine = buffer
        }

        let consumedBytes = priorPartialCount + newData.count - partialLine.count
        offset += UInt64(consumedBytes)
        Self.writeOffset(offset, to: offsetFile)
    }

    private func handleCommand(from lineData: Data) {
        guard !lineData.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return
        }
        let cmd = ((json["cmd"] as? String) ?? (json["command"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch cmd {
        case "start":
            guard isAllowed() else {
                NSLog("[ultragateway] Agent cover start ignored (AGENT_COVER_ENABLED=false)")
                return
            }
            AgentCoverController.shared.startCover()
            onStatusChange()
        case "stop":
            let lock = (json["lock"] as? Bool)
                ?? ((json["lock"] as? String)?.lowercased()).map { ["1", "true", "yes", "on"].contains($0) }
                ?? false
            AgentCoverController.shared.stopCover(lock: lock)
            onStatusChange()
        default:
            break
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

extension Notification.Name {
    static let agentCoverDidChange = Notification.Name("ultragateway.agentCoverDidChange")
}
