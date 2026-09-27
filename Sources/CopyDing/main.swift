import AppKit
import ApplicationServices
import Carbon
import OSLog
import ServiceManagement

enum CopyControlClassifier {
    static func isCopyControl(role: String, commandCharacter: String?, labels: [String]) -> Bool {
        guard role == "AXMenuItem" else { return false }
        // A keyboard equivalent alone is not enough. Many unrelated menu rows
        // expose a "C" command character, so require an actual Copy label on
        // a context-menu item.
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
    private var pendingCheckID: UInt64 = 0
    private var pendingContextMenuCopy: (changeCount: Int, timestamp: Date)?
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

    #if APP_STORE
    private struct DiagnosticState {
        var launchedAt = Date()
        var launchPasteboardChangeCount = 0
        var monitorStartAttempts = 0
        var monitorStartSuccesses = 0
        var monitorStartFailures = 0
        var monitorLastMessage = "Not started"
        var monitorPlacement = "none"
        var monitorLastStartAt: Date?
        var rawKeyDownCount = 0
        var repeatKeyDownCount = 0
        var cKeyDownCount = 0
        var commandModifiedCCount = 0
        var exactCommandCCount = 0
        var handledCommandCCount = 0
        var ignoredKeyDownCount = 0
        var lastKeyEventSummary = "No key event seen"
        var lastKeyEventAt: Date?
        var lastCommandCAt: Date?
        var lastHandledCommandCAt: Date?
        var lastIgnoredReason = "None"
        var scheduledChecks = 0
        var completedChecks = 0
        var skippedChecks = 0
        var staleChecks = 0
        var successfulChecks = 0
        var failedChecks = 0
        var lastCheckSummary = "No copy check run"
        var lastCheckAt: Date?
        var clipboardChanges = 0
        var lastClipboardChangeAt: Date?
        var lastClipboardChangeCount = 0
        var successSounds = 0
        var failureBeeps = 0
        var visualAlertsShown = 0
        var copiedDiagnosticsAt: Date?
    }

    private static let diagnosticsLogger = Logger(
        subsystem: "com.copyding.utility",
        category: "Diagnostics"
    )
    private let entitlementManager = AppStoreEntitlementManager.shared
    private var entitlementTask: Task<Void, Never>?
    private var appStoreMonitorIsActive = false
    private var lastInputMonitoringState = false
    private var lastKeyboardCopyDetectionAt = Date.distantPast
    private var diagnostics = DiagnosticState()
    private var purchaseHostWindow: NSPanel?
    private var purchaseInProgress = false
    private lazy var appStoreGlobalMonitor = AppStoreGlobalEventMonitor { [weak self] event in
        self?.handleAppStoreEvent(event)
    }
    #endif

    private lazy var enabledItem = NSMenuItem(
        title: "Alert when Copy fails",
        action: #selector(toggleEnabled),
        keyEquivalent: ""
    )

    // Mouse-copy detection needs cross-app Accessibility inspection, which the
    // App Sandbox forbids. It is therefore a Developer ID build feature only and
    // is compiled out of the App Store flavour entirely.
    #if !APP_STORE
    private lazy var mouseFailureItem = NSMenuItem(
        title: "Alert for Mouse Copy Failures",
        action: #selector(toggleMouseFailureDetection),
        keyEquivalent: ""
    )
    #endif

    private lazy var visualFailureItem = NSMenuItem(
        title: "Visual Failure Alert",
        action: #selector(toggleVisualFailureAlert),
        keyEquivalent: ""
    )

    // Accessibility is a Developer ID build concern only. The App Store build
    // detects Command-C through Input Monitoring alone and must never request,
    // advertise or depend on Accessibility trust.
    #if !APP_STORE
    private lazy var permissionItem = NSMenuItem(
        title: "Accessibility access: Checking…",
        action: #selector(openAccessibilitySettings),
        keyEquivalent: ""
    )
    #endif

    #if APP_STORE
    private lazy var storeAccessItem = NSMenuItem(
        title: "CopyDing access: Checking…",
        action: nil,
        keyEquivalent: ""
    )
    private lazy var startTrialItem = NSMenuItem(
        title: "Start Free Trial",
        action: #selector(startTrial),
        keyEquivalent: ""
    )
    private lazy var upgradeItem = NSMenuItem(
        title: "Upgrade to CopyDing Pro",
        action: #selector(upgradeToPro),
        keyEquivalent: ""
    )
    private lazy var restorePurchasesItem = NSMenuItem(
        title: "Restore Purchases",
        action: #selector(restorePurchases),
        keyEquivalent: ""
    )
    private lazy var purchaseStatusItem = NSMenuItem(
        title: "",
        action: nil,
        keyEquivalent: ""
    )
    private lazy var inputMonitoringItem = NSMenuItem(
        title: "Input Monitoring: Checking…",
        action: #selector(openInputMonitoringSettings),
        keyEquivalent: ""
    )
    // Diagnostics and the other developer affordances are Debug-only. They were
    // invaluable while tracking down why ⌘C stopped being observed, but a
    // shipping App Store build must not expose sixteen counter rows, a
    // clipboard-dumping summary or pipeline test hooks to customers.
    #if DEBUG
    private lazy var diagnosticsRootItem = NSMenuItem(
        title: "Diagnostics",
        action: nil,
        keyEquivalent: ""
    )
    private lazy var diagnosticsStatusItems: [NSMenuItem] = (0..<16).map { _ in
        let item = NSMenuItem(title: "Diagnostics loading…", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
    private lazy var copyDiagnosticsItem = NSMenuItem(
        title: "Copy Diagnostics Summary",
        action: #selector(copyDiagnosticsSummary),
        keyEquivalent: ""
    )
    private lazy var resetDiagnosticsItem = NSMenuItem(
        title: "Reset Diagnostics Counters",
        action: #selector(resetDiagnosticsCounters),
        keyEquivalent: ""
    )
    private lazy var testFailurePipelineItem = NSMenuItem(
        title: "Test Failure Pipeline",
        action: #selector(testFailurePipeline),
        keyEquivalent: ""
    )
    private lazy var debugAllFeaturesItem = NSMenuItem(
        title: "Debug: All Features Enabled",
        action: #selector(toggleDebugAllFeatures),
        keyEquivalent: ""
    )
    private lazy var debugTrialExpiryItem = NSMenuItem(
        title: "Debug: Simulate Trial Expiry",
        action: #selector(simulateTrialExpiry),
        keyEquivalent: ""
    )
    #endif
    #endif

    /// Secure input is a system-wide kill switch for keyboard observation.
    /// While any process holds it, macOS withholds every key event from all
    /// event taps and global monitors, so ⌘C detection silently stops working
    /// no matter which permissions are granted. Password managers are the
    /// usual culprit. Surface it so a silent failure is never mistaken for a
    /// permission or sandbox problem. This affects both build flavours.
    private lazy var secureInputItem = NSMenuItem(
        title: "Secure Input: Checking…",
        action: nil,
        keyEquivalent: ""
    )

    private lazy var loginItem = NSMenuItem(
        title: "Launch at Login",
        action: #selector(toggleLaunchAtLogin),
        keyEquivalent: ""
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if APP_STORE
        diagnosticLog("Application did finish launching. Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")")
        #else
        print("[CopyDing] Application did finish launching. Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")")
        #endif
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        lastObservedClipboardChangeCount = pasteboard.changeCount
        #if APP_STORE
        diagnostics.launchPasteboardChangeCount = pasteboard.changeCount
        diagnostics.lastClipboardChangeCount = pasteboard.changeCount
        #endif
        startClipboardMonitoring()
        startPermissionPolling()
        updateMenuState()

        #if APP_STORE
        lastInputMonitoringState = appStoreGlobalMonitor.hasInputMonitoringAccess
        entitlementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await entitlementManager.prepare()
            updateMenuState()
            for await _ in entitlementManager.$accessState.values {
                updateMenuState()
            }
        }
        #else
        lastAccessibilityState = AXIsProcessTrusted()
        startMonitoring()
        requestAccessibilityIfNeeded()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if APP_STORE
        entitlementTask?.cancel()
        appStoreGlobalMonitor.stop()
        #else
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        #endif
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
        #if !APP_STORE
        mouseFailureItem.target = self
        permissionItem.target = self
        #endif
        visualFailureItem.target = self
        loginItem.target = self

        #if APP_STORE
        startTrialItem.target = self
        upgradeItem.target = self
        restorePurchasesItem.target = self
        #if DEBUG
        copyDiagnosticsItem.target = self
        resetDiagnosticsItem.target = self
        testFailurePipelineItem.target = self
        debugAllFeaturesItem.target = self
        debugTrialExpiryItem.target = self
        #endif
        #endif

        let menu = NSMenu()

        #if APP_STORE
        storeAccessItem.isEnabled = false
        purchaseStatusItem.isEnabled = false
        menu.addItem(storeAccessItem)
        menu.addItem(startTrialItem)
        menu.addItem(upgradeItem)
        menu.addItem(restorePurchasesItem)
        menu.addItem(purchaseStatusItem)
        menu.addItem(.separator())
        #endif

        menu.addItem(enabledItem)
        #if !APP_STORE
        mouseFailureItem.toolTip = "Detects standard Copy menu items and labelled Copy buttons"
        menu.addItem(mouseFailureItem)
        #endif
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

        #if APP_STORE
        inputMonitoringItem.target = self
        inputMonitoringItem.toolTip = "Required to observe ⌘C without changing the event"
        menu.addItem(inputMonitoringItem)
        #if DEBUG
        let diagnosticsMenu = NSMenu(title: "Diagnostics")
        for item in diagnosticsStatusItems {
            diagnosticsMenu.addItem(item)
        }
        diagnosticsMenu.addItem(.separator())
        diagnosticsMenu.addItem(copyDiagnosticsItem)
        diagnosticsMenu.addItem(resetDiagnosticsItem)
        diagnosticsMenu.addItem(testFailurePipelineItem)
        diagnosticsRootItem.submenu = diagnosticsMenu
        menu.addItem(diagnosticsRootItem)
        #endif
        #else
        permissionItem.toolTip = "Click to open Accessibility settings"
        menu.addItem(permissionItem)
        #endif
        secureInputItem.toolTip = "If another app enables secure input (usually a password manager), macOS stops delivering key events to every event tap and ⌘C cannot be observed until it is released"
        menu.addItem(secureInputItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())

        // Manual test hooks for the beep and the visual alert. Useful when
        // working on the Developer ID build, noise in a customer-facing menu.
        #if !APP_STORE
        let testItem = NSMenuItem(
            title: "Test Ding",
            action: #selector(testDing),
            keyEquivalent: ""
        )
        testItem.target = self
        menu.addItem(testItem)
        let testVisualAlertItem = NSMenuItem(
            title: "Test Visual Alert",
            action: #selector(testVisualAlert),
            keyEquivalent: ""
        )
        testVisualAlertItem.target = self
        menu.addItem(testVisualAlertItem)
        #endif

        let aboutItem = NSMenuItem(
            title: "About CopyDing",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        #if DEBUG && APP_STORE
        menu.addItem(.separator())
        menu.addItem(debugAllFeaturesItem)
        menu.addItem(debugTrialExpiryItem)
        #endif

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
        #if APP_STORE
        diagnostics.monitorStartAttempts += 1
        diagnostics.monitorLastStartAt = Date()
        diagnosticLog(
            "Starting monitor. enabled=\(enabled), featureAccess=\(hasAppStoreFeatureAccess), inputAccess=\(appStoreGlobalMonitor.hasInputMonitoringAccess), successMode=\(successSoundMode.rawValue), visual=\(visualFailureAlertEnabled), pasteboard=\(pasteboard.changeCount)"
        )
        guard hasAppStoreFeatureAccess, enabled else {
            appStoreGlobalMonitor.stop()
            appStoreMonitorIsActive = false
            diagnostics.monitorStartFailures += 1
            diagnostics.monitorLastMessage = "Blocked before start: enabled=\(enabled), featureAccess=\(hasAppStoreFeatureAccess)"
            diagnosticLog(diagnostics.monitorLastMessage)
            return
        }

        let hasInputMonitoring = appStoreGlobalMonitor.hasInputMonitoringAccess

        if hasInputMonitoring {
            let result = appStoreGlobalMonitor.start()
            appStoreMonitorIsActive = result.isActive
            diagnostics.monitorLastMessage = result.message
            diagnostics.monitorPlacement = result.placement?.rawValue ?? "none"
            if result.isActive {
                diagnostics.monitorStartSuccesses += 1
            } else {
                diagnostics.monitorStartFailures += 1
            }
            diagnosticLog("Input monitor start result. active=\(result.isActive), placement=\(diagnostics.monitorPlacement), message=\(result.message)")
        } else {
            appStoreGlobalMonitor.stop()
            appStoreMonitorIsActive = false
            diagnostics.monitorStartFailures += 1
            diagnostics.monitorLastMessage = "Input Monitoring not allowed"
            diagnostics.monitorPlacement = "none"
            diagnosticLog(diagnostics.monitorLastMessage)
        }

        if !hasInputMonitoring {
            diagnostics.monitorLastMessage = "Blocked: Input Monitoring not allowed"
            diagnosticLog(diagnostics.monitorLastMessage)
        }
        return
        #else
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
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                Task { @MainActor in self?.handleMouseDown(event) }
            }
        } else {
            mouseMonitor = nil
        }
        #endif
    }

    #if APP_STORE
    private var hasAppStoreFeatureAccess: Bool {
        #if DEBUG
        return entitlementManager.accessState.canUseCopyDing
            || entitlementManager.debugAllFeaturesEnabled
        #else
        return entitlementManager.accessState.canUseCopyDing
        #endif
    }

    #endif

    private func startPermissionPolling() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                #if APP_STORE
                let hasInputMonitoring = self.appStoreGlobalMonitor.hasInputMonitoringAccess
                if hasInputMonitoring != self.lastInputMonitoringState {
                    self.lastInputMonitoringState = hasInputMonitoring
                    self.diagnosticLog("Permission state changed. Input Monitoring allowed=\(hasInputMonitoring)")
                    if hasInputMonitoring {
                        self.startMonitoring()
                    } else {
                        self.pendingCheck?.cancel()
                        self.pendingCheck = nil
                        self.appStoreGlobalMonitor.stop()
                        self.appStoreMonitorIsActive = false
                        self.diagnostics.monitorLastMessage = "Stopped: Input Monitoring permission lost"
                    }
                }
                self.updateMenuState()
                #else
                let isTrusted = AXIsProcessTrusted()
                if isTrusted != self.lastAccessibilityState {
                    self.lastAccessibilityState = isTrusted
                    if isTrusted { self.startMonitoring() }
                }
                self.updateMenuState()
                #endif
            }
        }
    }

    private func startClipboardMonitoring() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        lastObservedClipboardChangeCount = pasteboard.changeCount

        #if APP_STORE
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForAnyClipboardChange() }
        }
        timer.tolerance = 0.1
        clipboardTimer = timer
        #else
        guard successSoundMode == .anyClipboardChange else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForAnyClipboardChange() }
        }
        timer.tolerance = 0.1
        clipboardTimer = timer
        #endif
    }

    private func checkForAnyClipboardChange() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastObservedClipboardChangeCount else { return }

        lastObservedClipboardChangeCount = currentChangeCount
        #if APP_STORE
        diagnostics.clipboardChanges += 1
        diagnostics.lastClipboardChangeAt = Date()
        diagnostics.lastClipboardChangeCount = currentChangeCount
        diagnosticLog(
            "Clipboard change observed. count=\(currentChangeCount), enabled=\(enabled), featureAccess=\(hasAppStoreFeatureAccess), successMode=\(successSoundMode.rawValue)"
        )
        if enabled && hasAppStoreFeatureAccess && successSoundMode == .anyClipboardChange {
            playSuccessSound()
        }
        #else
        if enabled {
            playSuccessSound()
        }
        #endif
    }

    #if APP_STORE
    private func handleKeyboardCopyAttempt(trigger: String) {
        let now = Date()
        guard now.timeIntervalSince(lastKeyboardCopyDetectionAt) > 0.12 else {
            diagnostics.ignoredKeyDownCount += 1
            diagnostics.lastIgnoredReason = "Duplicate Command-C from \(trigger)"
            diagnosticLog("Ignored duplicate Command-C from \(trigger)")
            return
        }
        lastKeyboardCopyDetectionAt = now
        diagnostics.handledCommandCCount += 1
        diagnostics.lastHandledCommandCAt = now
        diagnosticLog("Command-C accepted via \(trigger). Clipboard change count=\(pasteboard.changeCount)")
        scheduleFailureCheck(startingAt: pasteboard.changeCount, source: .keyboard)
    }
    #endif

    // NSEvent global monitors and the Accessibility-based mouse inspection they
    // feed are exclusive to the Developer ID build. The App Store build receives
    // keyboard events through the Input Monitoring event tap instead.
    #if !APP_STORE
    private func handleKeyDown(_ event: NSEvent) {
        guard enabled, !event.isARepeat, event.keyCode == 8 else { return }

        let relevant = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard relevant == .command else { return }

        scheduleFailureCheck(startingAt: pasteboard.changeCount, source: .keyboard)
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard enabled, mouseFailureDetectionEnabled, let mouseEvent = event.cgEvent else { return }

        switch event.type {
        case .rightMouseDown:
            pendingContextMenuCopy = (pasteboard.changeCount, Date())
        case .leftMouseDown:
            handleContextMenuCopySelection(at: mouseEvent.location)
        default:
            break
        }
    }
    #endif

    #if APP_STORE
    private func handleAppStoreEvent(_ event: AppStoreGlobalEventMonitor.Event) {
        guard case .keyDown(let keyEvent) = event else { return }
        processAppStoreKeyEvent(
            keyEvent,
            trigger: "Input Monitoring event tap \(appStoreGlobalMonitor.activePlacement?.rawValue ?? "unknown")"
        )
    }

    private func processAppStoreKeyEvent(_ keyEvent: AppStoreGlobalKeyEvent, trigger: String) {
        recordKeyEvent(keyEvent)

        guard enabled else {
            diagnostics.ignoredKeyDownCount += 1
            diagnostics.lastIgnoredReason = "CopyDing disabled"
            diagnosticLog("Ignored key event from \(trigger) because alerts are disabled")
            return
        }
        guard hasAppStoreFeatureAccess else {
            diagnostics.ignoredKeyDownCount += 1
            diagnostics.lastIgnoredReason = "Feature access unavailable"
            diagnosticLog("Ignored key event from \(trigger) because feature access is unavailable")
            return
        }
        guard !keyEvent.isRepeat else {
            diagnostics.ignoredKeyDownCount += 1
            diagnostics.lastIgnoredReason = "Repeat key event"
            diagnosticLog("Ignored repeat key event from \(trigger). \(keyEventSummary(keyEvent))")
            return
        }
        guard keyEvent.isCommandC else {
            diagnostics.ignoredKeyDownCount += 1
            diagnostics.lastIgnoredReason = "Not exact Command-C: \(keyEventSummary(keyEvent))"
            diagnosticLog("Ignored non Command-C key event from \(trigger). \(keyEventSummary(keyEvent))")
            return
        }

        handleKeyboardCopyAttempt(trigger: trigger)
    }
    #endif

    #if !APP_STORE
    private func handleContextMenuCopySelection(at location: CGPoint) {
        if NSApp.isActive {
            pendingContextMenuCopy = nil
            print("[CopyDing] Ignored click inside CopyDing's own menu")
            return
        }

        guard let pendingContextMenuCopy else { return }
        self.pendingContextMenuCopy = nil

        guard Date().timeIntervalSince(pendingContextMenuCopy.timestamp) <= 3 else {
            print("[CopyDing] Ignored expired context-menu click")
            return
        }
        guard mouseFailureDetectionEnabled else { return }
        guard AXIsProcessTrusted() else {
            print("[CopyDing] Ignored context-menu Copy check because Accessibility is not allowed")
            return
        }
        guard isCopyControl(at: location) else { return }

        print("[CopyDing] Context-menu Copy selected. Clipboard change count: \(pendingContextMenuCopy.changeCount)")
        scheduleFailureCheck(startingAt: pendingContextMenuCopy.changeCount, source: .mouse)
    }
    #endif

    private func scheduleFailureCheck(startingAt oldChangeCount: Int, source: CopyAttemptSource) {
        pendingCheck?.cancel()
        pendingCheckID &+= 1
        let checkID = pendingCheckID
        #if APP_STORE
        diagnostics.scheduledChecks += 1
        diagnostics.lastCheckSummary = "Scheduled \(source) check \(checkID), old count \(oldChangeCount), delay \(copyDelay)s"
        diagnostics.lastCheckAt = Date()
        diagnosticLog(diagnostics.lastCheckSummary)
        #else
        print("[CopyDing] Scheduling \(source) copy check at clipboard change count \(oldChangeCount) with delay \(copyDelay)s")
        #endif

        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.enabled else {
                #if APP_STORE
                self.diagnostics.skippedChecks += 1
                self.diagnostics.lastCheckSummary = "Skipped check \(checkID): CopyDing disabled"
                self.diagnosticLog(self.diagnostics.lastCheckSummary)
                #endif
                return
            }
            guard self.pendingCheckID == checkID else {
                #if APP_STORE
                self.diagnostics.staleChecks += 1
                self.diagnostics.lastCheckSummary = "Skipped stale check \(checkID)"
                self.diagnosticLog(self.diagnostics.lastCheckSummary)
                #else
                print("[CopyDing] Skipping stale copy check")
                #endif
                return
            }
            #if APP_STORE
            guard self.hasAppStoreFeatureAccess else {
                self.diagnostics.skippedChecks += 1
                self.diagnostics.lastCheckSummary = "Skipped check \(checkID): feature access unavailable"
                self.diagnosticLog(self.diagnostics.lastCheckSummary)
                return
            }
            #endif
            let copySucceeded = self.pasteboard.changeCount != oldChangeCount
            #if APP_STORE
            self.diagnostics.completedChecks += 1
            self.diagnostics.lastCheckAt = Date()
            if copySucceeded {
                self.diagnostics.successfulChecks += 1
            } else {
                self.diagnostics.failedChecks += 1
            }
            self.diagnostics.lastCheckSummary = "Completed \(source) check \(checkID): succeeded=\(copySucceeded), old=\(oldChangeCount), new=\(self.pasteboard.changeCount), visual=\(self.visualFailureAlertEnabled), soundMode=\(self.successSoundMode.rawValue)"
            self.diagnosticLog(self.diagnostics.lastCheckSummary)
            #else
            print("[CopyDing] Copy check completed. Source: \(source), succeeded: \(copySucceeded), old count: \(oldChangeCount), new count: \(self.pasteboard.changeCount), visual alert enabled: \(self.visualFailureAlertEnabled)")
            #endif
            if !copySucceeded {
                #if APP_STORE
                self.diagnostics.failureBeeps += 1
                self.diagnosticLog("Playing failure beep. visualEnabled=\(self.visualFailureAlertEnabled)")
                #endif
                NSSound.beep()
                if self.visualFailureAlertEnabled {
                    self.showVisualFailureAlert()
                }
            } else if self.successSoundMode == .commandCOnly, source == .keyboard {
                self.playSuccessSound()
            }
            if self.pendingCheckID == checkID {
                self.pendingCheck = nil
            }
        }
        pendingCheck = check

        // A short grace period avoids false alerts from apps that update the clipboard asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + copyDelay, execute: check)
    }

    private func playSuccessSound() {
        #if APP_STORE
        diagnostics.successSounds += 1
        diagnosticLog("Playing success sound. total=\(diagnostics.successSounds), mode=\(successSoundMode.rawValue)")
        #endif
        successSound?.stop()
        successSound?.currentTime = 0
        successSound?.play()
    }

    private func showVisualFailureAlert() {
        #if APP_STORE
        diagnostics.visualAlertsShown += 1
        diagnosticLog("Showing visual Copy failed alert. total=\(diagnostics.visualAlertsShown)")
        #else
        print("[CopyDing] Showing visual Copy failed alert")
        #endif
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
            }, completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    guard let self, let panel else { return }
                    panel.orderOut(nil)
                    if self.visualAlertPanel === panel {
                        self.visualAlertPanel = nil
                    }
                }
            })
        }
        visualAlertDismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: dismiss)
    }

    // Cross-app Accessibility inspection. A sandboxed App Store build cannot use
    // it, so the whole chain is compiled out of that flavour and kept for the
    // Developer ID build only.
    #if !APP_STORE
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

        if accessibilityElementBelongsToCopyDing(currentElement) {
            print("[CopyDing] Ignoring Copy-looking control inside CopyDing's own menu")
            return false
        }

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

    private func accessibilityElementBelongsToCopyDing(_ element: AXUIElement) -> Bool {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success else {
            return false
        }
        return processIdentifier == ProcessInfo.processInfo.processIdentifier
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
    #endif

    private func updateMenuState() {
        enabledItem.state = enabled ? .on : .off
        #if !APP_STORE
        mouseFailureItem.state = mouseFailureDetectionEnabled ? .on : .off
        #endif
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
        if IsSecureEventInputEnabled() {
            setPermissionTitle(
                secureInputItem,
                prefix: "Secure Input: ",
                status: "ON — ⌘C cannot be observed",
                suffix: "",
                color: .systemOrange,
                isAllowed: false
            )
        } else {
            setPermissionTitle(
                secureInputItem,
                prefix: "Secure Input: ",
                status: "Off",
                suffix: "",
                color: .systemGreen,
                isAllowed: true
            )
        }
        #if APP_STORE
        let accessState = entitlementManager.accessState
        switch accessState {
        case .loading:
            storeAccessItem.title = "CopyDing access: Checking…"
        case .trialNotStarted:
            storeAccessItem.title = entitlementManager.trialProduct == nil
                ? "Free Trial: Unavailable"
                : "Free Trial: Not started ($0 charge; ends after 14 days)"
        case .trialActive(let daysRemaining):
            storeAccessItem.title = "Free Trial: \(daysRemaining) days remaining"
        case .trialExpired:
            storeAccessItem.title = "Free Trial: Expired"
        case .pro:
            storeAccessItem.title = "CopyDing Pro ✓"
        }

        #if DEBUG
        let debugAllFeaturesEnabled = entitlementManager.debugAllFeaturesEnabled
        debugAllFeaturesItem.state = debugAllFeaturesEnabled ? .on : .off
        debugTrialExpiryItem.state = entitlementManager.debugTrialExpiryEnabled ? .on : .off
        #else
        let debugAllFeaturesEnabled = false
        #endif
        let canUseCopyDing = hasAppStoreFeatureAccess
        let hasInputMonitoring = appStoreGlobalMonitor.hasInputMonitoringAccess
        let inputMonitoringStatus: String
        let inputMonitoringColor: NSColor
        let inputMonitoringAllowed: Bool
        if !hasInputMonitoring {
            inputMonitoringStatus = "Required"
            inputMonitoringColor = .systemRed
            inputMonitoringAllowed = false
        } else if canUseCopyDing, enabled, appStoreMonitorIsActive {
            inputMonitoringStatus = "Active"
            inputMonitoringColor = .systemGreen
            inputMonitoringAllowed = true
        } else {
            inputMonitoringStatus = "Allowed"
            inputMonitoringColor = .systemGreen
            inputMonitoringAllowed = true
        }
        setPermissionTitle(
            inputMonitoringItem,
            prefix: "Input Monitoring: ",
            status: inputMonitoringStatus,
            suffix: "",
            color: inputMonitoringColor,
            isAllowed: inputMonitoringAllowed
        )
        startTrialItem.isHidden = accessState != .trialNotStarted
        // Keep the action clickable even if StoreKit failed to load the product.
        // The purchase path then exposes the concrete availability error in the menu
        // instead of silently presenting a disabled item.
        startTrialItem.isEnabled = accessState == .trialNotStarted
        upgradeItem.isHidden = accessState == .pro || accessState == .loading
        #if DEBUG
        upgradeItem.isEnabled = true
        #else
        upgradeItem.isEnabled = entitlementManager.proProduct != nil
        #endif
        upgradeItem.title = proProductTitle()
        restorePurchasesItem.isHidden = false
        purchaseStatusItem.title = entitlementManager.lastErrorMessage ?? ""
        purchaseStatusItem.isHidden = entitlementManager.lastErrorMessage == nil
        if !canUseCopyDing || !enabled {
            appStoreGlobalMonitor.stop()
            appStoreMonitorIsActive = false
        } else if !appStoreMonitorIsActive {
            startMonitoring()
        }
        #else
        permissionItem.title = AXIsProcessTrusted()
            ? "Accessibility access: Allowed"
            : "Accessibility access: Required…"
        #endif

        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem.isHidden = true
        }
        #if APP_STORE && DEBUG
        refreshDiagnosticsMenu()
        #endif
    }

    #if APP_STORE
    private func recordKeyEvent(_ event: AppStoreGlobalKeyEvent) {
        diagnostics.rawKeyDownCount += 1
        diagnostics.lastKeyEventAt = Date()
        diagnostics.lastKeyEventSummary = keyEventSummary(event)
        if event.isRepeat {
            diagnostics.repeatKeyDownCount += 1
        }
        if event.isPhysicalCKey {
            diagnostics.cKeyDownCount += 1
        }
        if event.isPhysicalCKey, event.hasCommand {
            diagnostics.commandModifiedCCount += 1
        }
        if event.isCommandC {
            diagnostics.exactCommandCCount += 1
            diagnostics.lastCommandCAt = Date()
        }
        diagnosticLog("Key event observed. \(diagnostics.lastKeyEventSummary)")
        #if DEBUG
        refreshDiagnosticsMenu()
        #endif
    }

    private func keyEventSummary(_ event: AppStoreGlobalKeyEvent) -> String {
        "type=\(event.typeName), keyCode=\(event.keyCode), flags=\(event.flagsDescription), repeat=\(event.isRepeat), physicalC=\(event.isPhysicalCKey), exactCommandC=\(event.isCommandC)"
    }

    private func diagnosticLog(_ message: String) {
        Self.diagnosticsLogger.notice("\(message, privacy: .public)")
        NSLog("[CopyDing Diagnostics] \(message)")
    }

    #if DEBUG
    private func refreshDiagnosticsMenu() {
        let lines = compactDiagnosticsLines()
        for (index, item) in diagnosticsStatusItems.enumerated() {
            item.title = index < lines.count ? lines[index] : ""
            item.isHidden = index >= lines.count
        }
    }

    private func compactDiagnosticsLines() -> [String] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let accessState = entitlementManager.accessState
        let hasInputMonitoring = appStoreGlobalMonitor.hasInputMonitoringAccess
        return [
            "Build: \(version) (\(build))",
            "Enabled: \(enabled ? "yes" : "no"), visual: \(visualFailureAlertEnabled ? "yes" : "no"), sound: \(successSoundMode.title)",
            "Access: \(accessStateDiagnosticText(accessState)), feature: \(hasAppStoreFeatureAccess ? "yes" : "no")",
            "Input: \(hasInputMonitoring ? "allowed" : "required"), monitor: \(appStoreMonitorIsActive ? "active" : "inactive")",
            "Monitor starts: \(diagnostics.monitorStartSuccesses)/\(diagnostics.monitorStartAttempts), placement: \(diagnostics.monitorPlacement)",
            "Last monitor: \(diagnostics.monitorLastMessage)",
            "Keys seen: \(diagnostics.rawKeyDownCount)",
            "C: \(diagnostics.cKeyDownCount), Cmd+C candidates: \(diagnostics.commandModifiedCCount)",
            "Exact Cmd+C: \(diagnostics.exactCommandCCount), handled: \(diagnostics.handledCommandCCount)",
            "Last key: \(shorten(diagnostics.lastKeyEventSummary, limit: 84))",
            "Clipboard changes: \(diagnostics.clipboardChanges), last count: \(diagnostics.lastClipboardChangeCount)",
            "Checks: scheduled \(diagnostics.scheduledChecks), done \(diagnostics.completedChecks), ok \(diagnostics.successfulChecks), failed \(diagnostics.failedChecks)",
            "Last check: \(shorten(diagnostics.lastCheckSummary, limit: 84))"
        ]
    }

    private func accessStateDiagnosticText(_ accessState: AppStoreEntitlementManager.AccessState) -> String {
        switch accessState {
        case .loading:
            return "loading"
        case .trialNotStarted:
            return "trial not started"
        case .trialActive(let daysRemaining):
            return "trial active \(daysRemaining)d"
        case .trialExpired:
            return "trial expired"
        case .pro:
            return "pro"
        }
    }

    private func diagnosticSummary() -> String {
        let lines: [String] = [
            "CopyDing Diagnostics",
            "Generated: \(formatDiagnosticDate(Date()))",
            "Launched: \(formatDiagnosticDate(diagnostics.launchedAt))",
            "Build: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"))",
            "Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")",
            "Enabled: \(enabled)",
            "Visual failure alert enabled: \(visualFailureAlertEnabled)",
            "Success sound mode: \(successSoundMode.rawValue)",
            "Copy delay: \(copyDelay)",
            "Feature access: \(hasAppStoreFeatureAccess)",
            "Store access: \(accessStateDiagnosticText(entitlementManager.accessState))",
            "Input Monitoring allowed: \(appStoreGlobalMonitor.hasInputMonitoringAccess)",
            "Secure input enabled: \(IsSecureEventInputEnabled())",
            "Monitor active: \(appStoreMonitorIsActive)",
            "Monitor placement: \(diagnostics.monitorPlacement)",
            "Monitor start attempts: \(diagnostics.monitorStartAttempts)",
            "Monitor start successes: \(diagnostics.monitorStartSuccesses)",
            "Monitor start failures: \(diagnostics.monitorStartFailures)",
            "Last monitor start: \(formatDiagnosticDate(diagnostics.monitorLastStartAt))",
            "Last monitor message: \(diagnostics.monitorLastMessage)",
            "Raw keyDown events: \(diagnostics.rawKeyDownCount)",
            "Repeat keyDown events: \(diagnostics.repeatKeyDownCount)",
            "Physical C key events: \(diagnostics.cKeyDownCount)",
            "Command plus C candidates: \(diagnostics.commandModifiedCCount)",
            "Exact Command-C events: \(diagnostics.exactCommandCCount)",
            "Handled Command-C events: \(diagnostics.handledCommandCCount)",
            "Ignored key events: \(diagnostics.ignoredKeyDownCount)",
            "Last key event at: \(formatDiagnosticDate(diagnostics.lastKeyEventAt))",
            "Last key event: \(diagnostics.lastKeyEventSummary)",
            "Last Command-C at: \(formatDiagnosticDate(diagnostics.lastCommandCAt))",
            "Last handled Command-C at: \(formatDiagnosticDate(diagnostics.lastHandledCommandCAt))",
            "Last ignored reason: \(diagnostics.lastIgnoredReason)",
            "Clipboard launch count: \(diagnostics.launchPasteboardChangeCount)",
            "Clipboard current count: \(pasteboard.changeCount)",
            "Clipboard observed changes: \(diagnostics.clipboardChanges)",
            "Last clipboard change at: \(formatDiagnosticDate(diagnostics.lastClipboardChangeAt))",
            "Scheduled checks: \(diagnostics.scheduledChecks)",
            "Completed checks: \(diagnostics.completedChecks)",
            "Skipped checks: \(diagnostics.skippedChecks)",
            "Stale checks: \(diagnostics.staleChecks)",
            "Successful checks: \(diagnostics.successfulChecks)",
            "Failed checks: \(diagnostics.failedChecks)",
            "Last check at: \(formatDiagnosticDate(diagnostics.lastCheckAt))",
            "Last check: \(diagnostics.lastCheckSummary)",
            "Success sounds played: \(diagnostics.successSounds)",
            "Failure beeps played: \(diagnostics.failureBeeps)",
            "Visual alerts shown: \(diagnostics.visualAlertsShown)",
            "Copied diagnostics at: \(formatDiagnosticDate(diagnostics.copiedDiagnosticsAt))"
        ]
        return lines.joined(separator: "\n")
    }

    private func formatDiagnosticDate(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func shorten(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let index = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<index]) + "..."
    }
    #endif

    #endif

    private func setPermissionTitle(
        _ item: NSMenuItem,
        prefix: String,
        status: String,
        suffix: String,
        color: NSColor,
        isAllowed: Bool
    ) {
        item.state = isAllowed ? .on : .off
        let title = NSMutableAttributedString(string: prefix)
        title.append(NSAttributedString(string: status, attributes: [.foregroundColor: color]))
        title.append(NSAttributedString(string: suffix))
        item.attributedTitle = title
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        pendingCheck?.cancel()
        #if APP_STORE
        diagnosticLog("User toggled CopyDing enabled=\(enabled)")
        #endif
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
        #if APP_STORE
        diagnosticLog("User toggled visual failure alert=\(visualFailureAlertEnabled)")
        #endif
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
        #if APP_STORE
        diagnosticLog("User selected copy delay=\(value)")
        #endif
        updateMenuState()
    }

    @objc private func selectSuccessSoundMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = SuccessSoundMode(rawValue: rawValue) else {
            return
        }
        successSoundMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "successSoundMode")
        #if APP_STORE
        diagnosticLog("User selected success sound mode=\(mode.rawValue)")
        #endif
        startClipboardMonitoring()
        updateMenuState()
    }

    @objc private func testDing() {
        NSSound.beep()
    }

    @objc private func testVisualAlert() {
        showVisualFailureAlert()
    }

    #if APP_STORE
    #if DEBUG
    @objc private func copyDiagnosticsSummary() {
        diagnostics.copiedDiagnosticsAt = Date()
        let summary = diagnosticSummary()
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
        lastObservedClipboardChangeCount = pasteboard.changeCount
        diagnostics.lastClipboardChangeCount = pasteboard.changeCount
        diagnosticLog("Copied diagnostics summary to clipboard. characters=\(summary.count)")
        refreshDiagnosticsMenu()
    }

    @objc private func resetDiagnosticsCounters() {
        let launchCount = diagnostics.launchPasteboardChangeCount
        diagnostics = DiagnosticState()
        diagnostics.launchPasteboardChangeCount = launchCount
        diagnostics.lastClipboardChangeCount = pasteboard.changeCount
        diagnostics.monitorPlacement = appStoreGlobalMonitor.activePlacement?.rawValue ?? "none"
        diagnostics.monitorLastMessage = appStoreMonitorIsActive ? "Counters reset; monitor active" : "Counters reset; monitor inactive"
        diagnosticLog("Diagnostics counters reset")
        updateMenuState()
    }

    @objc private func testFailurePipeline() {
        diagnosticLog("Manual failure pipeline test requested")
        scheduleFailureCheck(startingAt: pasteboard.changeCount, source: .keyboard)
        updateMenuState()
    }
    #endif

    private func proProductTitle() -> String {
        if let displayPrice = entitlementManager.proProduct?.displayPrice {
            return "Upgrade to CopyDing Pro (\(displayPrice))"
        }
        return "Upgrade to CopyDing Pro"
    }

    @objc private func startTrial() {
        print("[CopyDing StoreKit] Start trial menu action invoked")
        beginPurchase { [entitlementManager] window in
            await entitlementManager.startTrial(confirmingIn: window)
        }
    }

    @objc private func upgradeToPro() {
        print("[CopyDing StoreKit] Upgrade menu action invoked")
        beginPurchase { [entitlementManager] window in
            await entitlementManager.buyPro(confirmingIn: window)
        }
    }

    @objc private func restorePurchases() {
        purchaseStatusItem.title = "Restoring purchases…"
        purchaseStatusItem.isHidden = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            await entitlementManager.restorePurchases()
            updateMenuState()
            if entitlementManager.lastErrorMessage == nil {
                purchaseStatusItem.title = entitlementManager.accessState == .pro
                    ? "Purchases restored."
                    : "No active CopyDing purchase was found."
                purchaseStatusItem.isHidden = false
            }
        }
    }

    private func beginPurchase(_ operation: @escaping (NSWindow?) async -> Bool) {
        guard !purchaseInProgress else {
            print("[CopyDing StoreKit] Ignored purchase action because another purchase is already in progress")
            purchaseStatusItem.title = "A purchase is already in progress…"
            purchaseStatusItem.isHidden = false
            return
        }

        purchaseInProgress = true
        print("[CopyDing StoreKit] Beginning purchase operation")
        purchaseStatusItem.title = "Contacting the App Store…"
        purchaseStatusItem.isHidden = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let purchaseWindow = makePurchaseHostWindowIfNeeded()
            let succeeded = await operation(purchaseWindow)
            purchaseHostWindow?.orderOut(nil)
            purchaseHostWindow = nil
            purchaseInProgress = false
            print("[CopyDing StoreKit] Purchase operation finished. Success: \(succeeded), error: \(entitlementManager.lastErrorMessage ?? "none")")
            updateMenuState()
            if succeeded {
                purchaseStatusItem.title = "Purchase complete."
                purchaseStatusItem.isHidden = false
            } else if entitlementManager.lastErrorMessage == nil {
                purchaseStatusItem.title = "Purchase cancelled."
                purchaseStatusItem.isHidden = false
            }
        }
    }

    private func makePurchaseHostWindowIfNeeded() -> NSWindow? {
        guard #available(macOS 15.2, *) else { return nil }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "CopyDing Purchase"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentView = NSView()

        let label = NSTextField(labelWithString: "Confirming your CopyDing purchase…")
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor)
        ])

        purchaseHostWindow = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        print("[CopyDing StoreKit] Purchase host window presented")
        return panel
    }

    @objc private func openInputMonitoringSettings() {
        _ = appStoreGlobalMonitor.requestInputMonitoringAccess()
        openPrivacySettings(anchor: "Privacy_ListenEvent")
    }

    #if DEBUG
    @objc private func toggleDebugAllFeatures() {
        entitlementManager.setDebugAllFeaturesEnabled(!entitlementManager.debugAllFeaturesEnabled)
        updateMenuState()
        startMonitoring()
    }

    @objc private func simulateTrialExpiry() {
        entitlementManager.setDebugTrialExpired(!entitlementManager.debugTrialExpiryEnabled)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await entitlementManager.refreshEntitlements()
            updateMenuState()
        }
    }
    #endif
    #endif

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "CopyDing"
        alert.informativeText = "Version \(version)\nDeveloped by Rochak Agrawal"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    #if !APP_STORE
    @objc private func openAccessibilitySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }
    #endif

    private func openPrivacySettings(anchor: String) {
        let urlString: String
        if #available(macOS 13.0, *) {
            urlString = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        }

        guard let url = URL(string: urlString) else {
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
