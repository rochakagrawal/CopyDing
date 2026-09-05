import AppKit
import ApplicationServices
import ServiceManagement

enum CopyControlClassifier {
    static func isCopyControl(role: String, commandCharacter: String?, labels: [String]) -> Bool {
        guard role == "AXMenuItem" || role == "AXButton" else { return false }

        if role == "AXMenuItem", commandCharacter?.lowercased() == "c" {
            return true
        }

        return labels.contains(where: containsCopyLabel)
    }

    static func containsCopyLabel(_ value: String) -> Bool {
        value.range(
            of: #"(?i)(^|[^a-z])copy([^a-z]|$)|copybutton|copytoclipboard"#,
            options: .regularExpression
        ) != nil
    }
}

enum SuccessSoundMode: String, CaseIterable {
    case off
    case commandCOnly
    case anyClipboardChange

    var title: String {
        switch self {
        case .off: "Off"
        case .commandCOnly: "⌘C only"
        case .anyClipboardChange: "Any clipboard change"
        }
    }
}

enum CopyAttemptSource: Equatable {
    case keyboard
    case mouse
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let pasteboard = NSPasteboard.general
    private var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var mouseMonitor: Any?
    private var permissionTimer: Timer?
    private var clipboardTimer: Timer?
    private var lastAccessibilityState = false
    private var lastObservedClipboardChangeCount = 0
    private var pendingCheck: DispatchWorkItem?
    private var visualAlertDismissWorkItem: DispatchWorkItem?
    private var visualAlertPanel: NSPanel?
    private var enabled = true
    private var mouseFailureDetectionEnabled = UserDefaults.standard.bool(
        forKey: "mouseFailureDetectionEnabled"
    )
    private var visualFailureAlertEnabled: Bool = {
        if let saved = UserDefaults.standard.object(forKey: "visualFailureAlertEnabled") as? Bool {
            return saved
        }
        return true
    }()
    private var successSoundMode = SuccessSoundMode(
        rawValue: UserDefaults.standard.string(forKey: "successSoundMode") ?? ""
    ) ?? .off
    private lazy var successSound: NSSound? = {
        let sound = NSSound(named: NSSound.Name("Glass"))
        sound?.volume = 0.55
        return sound
    }()
    private var copyDelay: TimeInterval = {
        let saved = UserDefaults.standard.double(forKey: "copyDelay")
        return saved > 0 ? saved : 0.45
    }()
    private let delayPresets: [(title: String, value: TimeInterval)] = [
        ("Fast — 0.2 seconds", 0.2),
        ("Normal — 0.45 seconds", 0.45),
        ("Relaxed — 0.8 seconds", 0.8),
        ("Slow apps — 1.2 seconds", 1.2)
    ]

    private lazy var enabledItem = NSMenuItem(
        title: "Alert when Copy fails",
        action: #selector(toggleEnabled),
        keyEquivalent: ""
    )

    private lazy var mouseFailureItem = NSMenuItem(
        title: "Alert for Mouse Copy Failures",
        action: #selector(toggleMouseFailureDetection),
        keyEquivalent: ""
    )

    private lazy var visualFailureItem = NSMenuItem(
        title: "Visual Failure Alert",
        action: #selector(toggleVisualFailureAlert),
        keyEquivalent: ""
    )

    private lazy var permissionItem = NSMenuItem(
        title: "Accessibility access: Checking…",
        action: #selector(openAccessibilitySettings),
        keyEquivalent: ""
    )

    private lazy var loginItem = NSMenuItem(
        title: "Launch at Login",
        action: #selector(toggleLaunchAtLogin),
        keyEquivalent: ""
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        lastObservedClipboardChangeCount = pasteboard.changeCount
        lastAccessibilityState = AXIsProcessTrusted()
        startMonitoring()
        startClipboardMonitoring()
        startPermissionPolling()
        updateMenuState()
        requestAccessibilityIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        permissionTimer?.invalidate()
        clipboardTimer?.invalidate()
        visualAlertDismissWorkItem?.cancel()
        visualAlertPanel?.orderOut(nil)
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "CopyDing"
            )
            button.toolTip = "CopyDing"
        }

        enabledItem.target = self
        mouseFailureItem.target = self
        visualFailureItem.target = self
        permissionItem.target = self
        loginItem.target = self

        let menu = NSMenu()
        menu.addItem(enabledItem)
        mouseFailureItem.toolTip = "Detects standard Copy menu items and labelled Copy buttons"
        menu.addItem(mouseFailureItem)
        visualFailureItem.toolTip = "Shows a small Copy failed alert beside the pointer"
        menu.addItem(visualFailureItem)

        let sensitivityItem = NSMenuItem(title: "Alert Timing", action: nil, keyEquivalent: "")
        let sensitivityMenu = NSMenu(title: "Alert Timing")
        for preset in delayPresets {
            let item = NSMenuItem(
                title: preset.title,
                action: #selector(selectDelay(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: preset.value)
            sensitivityMenu.addItem(item)
        }
        sensitivityItem.submenu = sensitivityMenu
        menu.addItem(sensitivityItem)

        let successSoundItem = NSMenuItem(title: "Success Sound", action: nil, keyEquivalent: "")
        let successSoundMenu = NSMenu(title: "Success Sound")
        for mode in SuccessSoundMode.allCases {
            let item = NSMenuItem(
                title: mode.title,
                action: #selector(selectSuccessSoundMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            successSoundMenu.addItem(item)
        }
        successSoundItem.submenu = successSoundMenu
        menu.addItem(successSoundItem)
        menu.addItem(.separator())

        permissionItem.toolTip = "Click to open Accessibility settings"
        menu.addItem(permissionItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let testItem = NSMenuItem(
            title: "Test Ding",
            action: #selector(testDing),
            keyEquivalent: ""
        )
        testItem.target = self
        menu.addItem(testItem)

        let aboutItem = NSMenuItem(
            title: "About CopyDing",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit CopyDing",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func startMonitoring() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handleKeyDown(event) }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }

        if mouseFailureDetectionEnabled {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                Task { @MainActor in self?.handleMouseDown(event) }
            }
        } else {
            mouseMonitor = nil
        }
    }

    private func startPermissionPolling() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let isTrusted = AXIsProcessTrusted()
                if isTrusted != self.lastAccessibilityState {
                    self.lastAccessibilityState = isTrusted
                    if isTrusted { self.startMonitoring() }
                }
                self.updateMenuState()
            }
        }
    }

    private func startClipboardMonitoring() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        lastObservedClipboardChangeCount = pasteboard.changeCount

        guard successSoundMode == .anyClipboardChange else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForAnyClipboardChange() }
        }
        timer.tolerance = 0.1
        clipboardTimer = timer
    }

    private func checkForAnyClipboardChange() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastObservedClipboardChangeCount else { return }

        lastObservedClipboardChangeCount = currentChangeCount
        if enabled {
            playSuccessSound()
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard enabled, !event.isARepeat, event.keyCode == 8 else { return }

        let relevant = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard relevant == .command else { return }

        scheduleFailureCheck(startingAt: pasteboard.changeCount, source: .keyboard)
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard enabled, mouseFailureDetectionEnabled, let mouseEvent = event.cgEvent else { return }

        let oldChangeCount = pasteboard.changeCount
        guard isCopyControl(at: mouseEvent.location) else { return }

        scheduleFailureCheck(startingAt: oldChangeCount, source: .mouse)
    }

    private func scheduleFailureCheck(startingAt oldChangeCount: Int, source: CopyAttemptSource) {
        pendingCheck?.cancel()

        let check = DispatchWorkItem { [weak self] in
            guard let self, self.enabled else { return }
            let copySucceeded = self.pasteboard.changeCount != oldChangeCount
            if !copySucceeded {
                NSSound.beep()
                if self.visualFailureAlertEnabled {
                    self.showVisualFailureAlert()
                }
            } else if self.successSoundMode == .commandCOnly, source == .keyboard {
                self.playSuccessSound()
            }
        }
        pendingCheck = check

        // A short grace period avoids false alerts from apps that update the clipboard asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + copyDelay, execute: check)
    }

    private func playSuccessSound() {
        successSound?.stop()
        successSound?.currentTime = 0
        successSound?.play()
    }

    private func showVisualFailureAlert() {
        visualAlertDismissWorkItem?.cancel()
        visualAlertPanel?.orderOut(nil)

        let label = NSTextField(labelWithString: "Copy failed")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.92).cgColor
        container.layer?.cornerRadius = 9
        container.layer?.masksToBounds = true
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7)
        ])

        let panelSize = NSSize(width: 94, height: 32)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0

        let pointer = NSEvent.mouseLocation
        var origin = NSPoint(x: pointer.x + 14, y: pointer.y - panelSize.height - 10)
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
        if let visibleFrame = targetScreen?.visibleFrame {
            origin.x = min(max(origin.x, visibleFrame.minX + 6), visibleFrame.maxX - panelSize.width - 6)
            origin.y = min(max(origin.y, visibleFrame.minY + 6), visibleFrame.maxY - panelSize.height - 6)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        visualAlertPanel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().alphaValue = 1
        }

        let dismiss = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                if self.visualAlertPanel === panel {
                    self.visualAlertPanel = nil
                }
            })
        }
        visualAlertDismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: dismiss)
    }

    private func isCopyControl(at point: CGPoint) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, 0.1)

        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        )
        guard result == .success, var currentElement = hitElement else { return false }

        // Some apps expose an image or text child inside the actual button.
        // Check a few ancestors so properly labelled parent controls are still detected.
        for _ in 0..<4 {
            if accessibilityElementLooksLikeCopyControl(currentElement) {
                return true
            }
            guard let parent = accessibilityElementAttribute("AXParent", of: currentElement) else {
                break
            }
            currentElement = parent
        }
        return false
    }

    private func accessibilityElementLooksLikeCopyControl(_ element: AXUIElement) -> Bool {
        let role = accessibilityStringAttribute("AXRole", of: element) ?? ""
        let searchableAttributes = ["AXTitle", "AXDescription", "AXHelp", "AXIdentifier", "AXValue"]
        let labels = searchableAttributes.compactMap {
            accessibilityStringAttribute($0, of: element)
        }
        return CopyControlClassifier.isCopyControl(
            role: role,
            commandCharacter: accessibilityStringAttribute("AXMenuItemCmdChar", of: element),
            labels: labels
        )
    }

    private func accessibilityStringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func accessibilityElementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.updateMenuState()
        }
    }

    private func updateMenuState() {
        enabledItem.state = enabled ? .on : .off
        mouseFailureItem.state = mouseFailureDetectionEnabled ? .on : .off
        visualFailureItem.state = visualFailureAlertEnabled ? .on : .off
        if let items = statusItem.menu?.item(withTitle: "Alert Timing")?.submenu?.items {
            for item in items {
                guard let value = (item.representedObject as? NSNumber)?.doubleValue else { continue }
                item.state = abs(value - copyDelay) < 0.001 ? .on : .off
            }
        }
        if let items = statusItem.menu?.item(withTitle: "Success Sound")?.submenu?.items {
            for item in items {
                let rawValue = item.representedObject as? String
                item.state = rawValue == successSoundMode.rawValue ? .on : .off
            }
        }
        permissionItem.title = AXIsProcessTrusted()
            ? "Accessibility access: Allowed"
            : "Accessibility access: Required…"

        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem.isHidden = true
        }
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        pendingCheck?.cancel()
        updateMenuState()
    }

    @objc private func toggleMouseFailureDetection() {
        mouseFailureDetectionEnabled.toggle()
        UserDefaults.standard.set(mouseFailureDetectionEnabled, forKey: "mouseFailureDetectionEnabled")
        pendingCheck?.cancel()
        startMonitoring()
        updateMenuState()
    }

    @objc private func toggleVisualFailureAlert() {
        visualFailureAlertEnabled.toggle()
        UserDefaults.standard.set(visualFailureAlertEnabled, forKey: "visualFailureAlertEnabled")
        if !visualFailureAlertEnabled {
            visualAlertDismissWorkItem?.cancel()
            visualAlertPanel?.orderOut(nil)
            visualAlertPanel = nil
        }
        updateMenuState()
    }

    @objc private func selectDelay(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        copyDelay = value
        UserDefaults.standard.set(value, forKey: "copyDelay")
        updateMenuState()
    }

    @objc private func selectSuccessSoundMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = SuccessSoundMode(rawValue: rawValue) else {
            return
        }
        successSoundMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "successSoundMode")
        startClipboardMonitoring()
        updateMenuState()
    }

    @objc private func testDing() {
        NSSound.beep()
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "CopyDing"
        alert.informativeText = "Version \(version) (\(build))\nDeveloped by Rochak Agrawal"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }

        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(
                title: "Couldn’t change Launch at Login",
                message: error.localizedDescription
            )
        }
        updateMenuState()
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
