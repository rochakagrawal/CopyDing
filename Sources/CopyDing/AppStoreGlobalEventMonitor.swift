import AppKit
import CoreGraphics
import OSLog

#if APP_STORE
struct AppStoreGlobalKeyEvent {
    let typeName: String
    let keyCode: Int64
    let flagsDescription: String
    let hasCommand: Bool
    let hasShift: Bool
    let hasControl: Bool
    let hasOption: Bool
    let hasSecondaryFn: Bool
    let isRepeat: Bool
    let isPhysicalCKey: Bool

    var isCommandC: Bool {
        isPhysicalCKey && hasCommand && !hasShift && !hasControl && !hasOption
    }
}

@MainActor
final class AppStoreGlobalEventMonitor {
    enum Event {
        case keyDown(AppStoreGlobalKeyEvent)
    }

    enum TapPlacement: String, CaseIterable {
        case sessionHead = "session/head"
        case sessionTail = "session/tail"
        case annotatedSessionHead = "annotated/head"

        var tapLocation: CGEventTapLocation {
            switch self {
            case .sessionHead, .sessionTail:
                return .cgSessionEventTap
            case .annotatedSessionHead:
                return .cgAnnotatedSessionEventTap
            }
        }

        var tapPlacement: CGEventTapPlacement {
            switch self {
            case .sessionHead, .annotatedSessionHead:
                return .headInsertEventTap
            case .sessionTail:
                return .tailAppendEventTap
            }
        }
    }

    struct StartResult {
        let isActive: Bool
        let placement: TapPlacement?
        let message: String
    }

    nonisolated private static let logger = Logger(
        subsystem: "com.copyding.utility",
        category: "InputMonitoring"
    )
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var activePlacement: TapPlacement?
    private let handler: @MainActor (Event) -> Void

    init(handler: @escaping @MainActor (Event) -> Void) {
        self.handler = handler
    }

    var hasInputMonitoringAccess: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    func requestInputMonitoringAccess() -> Bool {
        let granted = CGRequestListenEventAccess()
        log("Access request result: \(granted)")
        return granted
    }

    func start() -> StartResult {
        stop()

        guard hasInputMonitoringAccess else {
            let message = "Cannot start because access is not allowed"
            log(message)
            return StartResult(isActive: false, placement: nil, message: message)
        }

        var failures: [String] = []
        for placement in TapPlacement.allCases {
            if startTap(placement) {
                let message = "Started listen-only Command-C monitor at \(placement.rawValue)"
                log(message)
                return StartResult(isActive: true, placement: placement, message: message)
            }
            failures.append(placement.rawValue)
        }

        let message = "Failed to create listen-only event tap. Tried: \(failures.joined(separator: ", "))"
        log(message)
        return StartResult(isActive: false, placement: nil, message: message)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        activePlacement = nil
    }

    private func startTap(_ placement: TapPlacement) -> Bool {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: placement.tapLocation,
            place: placement.tapPlacement,
            options: .listenOnly,
            eventsOfInterest: (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.tapDisabledByTimeout.rawValue)
                | (1 << CGEventType.tapDisabledByUserInput.rawValue),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<AppStoreGlobalEventMonitor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: pointer
        ) else {
            log("Failed to create event tap at \(placement.rawValue)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        activePlacement = placement
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private nonisolated func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                guard let self, let eventTap else { return }
                Self.log("Event tap disabled by \(type.rawValue); re-enabling")
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        guard type == .keyDown else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let relevantFlags = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])
        let keyEvent = AppStoreGlobalKeyEvent(
            typeName: "keyDown",
            keyCode: keyCode,
            flagsDescription: Self.describe(flags: relevantFlags),
            hasCommand: relevantFlags.contains(.maskCommand),
            hasShift: relevantFlags.contains(.maskShift),
            hasControl: relevantFlags.contains(.maskControl),
            hasOption: relevantFlags.contains(.maskAlternate),
            hasSecondaryFn: relevantFlags.contains(.maskSecondaryFn),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            isPhysicalCKey: keyCode == 8
        )

        Task { @MainActor [handler] in handler(.keyDown(keyEvent)) }
    }

    nonisolated private static func describe(flags: CGEventFlags) -> String {
        var names: [String] = []
        if flags.contains(.maskCommand) { names.append("command") }
        if flags.contains(.maskShift) { names.append("shift") }
        if flags.contains(.maskControl) { names.append("control") }
        if flags.contains(.maskAlternate) { names.append("option") }
        if flags.contains(.maskSecondaryFn) { names.append("fn") }
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }

    nonisolated private static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        NSLog("[CopyDing Input Monitoring] \(message)")
    }

    private func log(_ message: String) {
        Self.log(message)
    }
}
#endif
