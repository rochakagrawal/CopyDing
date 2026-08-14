import AppKit
import ApplicationServices
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let pasteboard = NSPasteboard.general
    private var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private var lastAccessibilityState = false
    private var pendingCheck: DispatchWorkItem?
    private var enabled = true
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

    private lazy var permissionItem = NSMenuItem(
        title: "Keyboard access: Checking…",
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
        lastAccessibilityState = AXIsProcessTrusted()
        startMonitoring()
        startPermissionPolling()
        updateMenuState()
        requestAccessibilityIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        permissionTimer?.invalidate()
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
        permissionItem.target = self
        loginItem.target = self

        let menu = NSMenu()
        menu.addItem(enabledItem)

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

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
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

    private func handle(_ event: NSEvent) {
        guard enabled, !event.isARepeat, event.keyCode == 8 else { return }

        let relevant = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard relevant == .command else { return }

        let oldChangeCount = pasteboard.changeCount
        pendingCheck?.cancel()

        let check = DispatchWorkItem { [weak self] in
            guard let self, self.enabled else { return }
            if self.pasteboard.changeCount == oldChangeCount {
                NSSound.beep()
            }
        }
        pendingCheck = check

        // A short grace period avoids false alerts from apps that update the clipboard asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + copyDelay, execute: check)
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
        if let items = statusItem.menu?.item(withTitle: "Alert Timing")?.submenu?.items {
            for item in items {
                guard let value = (item.representedObject as? NSNumber)?.doubleValue else { continue }
                item.state = abs(value - copyDelay) < 0.001 ? .on : .off
            }
        }
        permissionItem.title = AXIsProcessTrusted()
            ? "Keyboard access: Allowed"
            : "Keyboard access: Required…"

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

    @objc private func selectDelay(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        copyDelay = value
        UserDefaults.standard.set(value, forKey: "copyDelay")
        updateMenuState()
    }

    @objc private func testDing() {
        NSSound.beep()
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
