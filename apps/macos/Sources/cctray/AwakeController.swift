import AppKit
import Foundation
import IOKit
import IOKit.pwr_mgt

private enum Clamshell {
    static func setSleepDisabled(_ disabled: Bool) {
        let root = IOServiceGetMatchingService(kIOMainPortDefault,
                                               IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(root) }
        var conn: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(root, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return }
        var input: UInt64 = disabled ? 1 : 0
        IOConnectCallScalarMethod(conn, 12, &input, 1, nil, nil)
        IOServiceClose(conn)
    }
}

@MainActor
final class AwakeController: ObservableObject {
    @Published var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            isOn ? start() : stop()
        }
    }
    private var assertions: [IOPMAssertionID] = []
    private var timer: Timer?

    init() {
        Clamshell.setSleepDisabled(false)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                if self?.isOn == true { Clamshell.setSleepDisabled(true) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Clamshell.setSleepDisabled(false) }
        }
    }

    private func start() {
        for type in ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"] {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "cctray Keep Mac Awake" as CFString,
                                           &id) == kIOReturnSuccess {
                assertions.append(id)
            }
        }
        Clamshell.setSleepDisabled(true)
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Clamshell.setSleepDisabled(true)
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        for id in assertions { IOPMAssertionRelease(id) }
        assertions.removeAll()
        Clamshell.setSleepDisabled(false)
    }
}
