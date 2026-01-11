import Foundation
import IOKit.hid

final class HIDPPManager {
    private let manager: IOHIDManager

    var onDevicesChanged: (([HIDPPDevice]) -> Void)?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let mouseMatch: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x046D,
            kIOHIDPrimaryUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDPrimaryUsageKey as String: kHIDUsage_GD_Mouse,
        ]
        let pointerMatch: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x046D,
            kIOHIDPrimaryUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDPrimaryUsageKey as String: kHIDUsage_GD_Pointer,
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, [mouseMatch, pointerMatch] as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, HIDPPManager.handleDeviceChange, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, HIDPPManager.handleDeviceChange, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        refresh()
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func refresh() {
        notifyDevicesChanged()
    }

    private func notifyDevicesChanged() {
        let devices = snapshotDevices()
        assert(Thread.isMainThread)
        onDevicesChanged?(devices)
    }

    private func snapshotDevices() -> [HIDPPDevice] {
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }
        return deviceSet
            .map { HIDPPDevice(device: $0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static let handleDeviceChange: IOHIDDeviceCallback = { context, _, _, _ in
        guard let context else { return }
        let manager = Unmanaged<HIDPPManager>.fromOpaque(context).takeUnretainedValue()
        manager.notifyDevicesChanged()
    }
}
