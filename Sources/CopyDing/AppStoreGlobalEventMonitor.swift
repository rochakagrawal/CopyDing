import AppKit
import CoreGraphics

#if APP_STORE
@MainActor
final class AppStoreGlobalEventMonitor {
    enum Event {
        case commandC
        case leftMouseDown(location: CGPoint)
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: @MainActor (Event) -> Void

    init(handler: @escaping @MainActor (Event) -> Void) {
        self.handler = handler
    }

    var hasInputMonitoringAccess: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    func requestInputMonitoringAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    func start(includeMouse: Bool) -> Bool {
        stop()

        let mask: CGEventMask
        if includeMouse {
            mask = (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.leftMouseDown.rawValue)
        } else {
            mask = 1 << CGEventType.keyDown.rawValue
        }

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
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
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
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
    }

    private nonisolated func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
            guard keyCode == 8, flags == .maskCommand else { return }
            Task { @MainActor [handler] in handler(.commandC) }

        case .leftMouseDown:
            let location = event.location
            Task { @MainActor [handler] in handler(.leftMouseDown(location: location)) }

        default:
            break
        }
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }
}
#endif
