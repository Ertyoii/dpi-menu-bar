import Foundation
import IOKit

@MainActor
final class DpiViewModel: ObservableObject {
    @Published var devices: [HIDPPDevice] = []
    @Published var selectedDeviceID: UInt64? {
        didSet {
            persistSelectedDeviceID(selectedDeviceID)
            guard selectedDeviceID != oldValue else { return }
            if !devices.isEmpty {
                reloadSelection()
            }
        }
    }
    @Published var dpiChoices: [Int] = []
    @Published var dpiIndex: Double = 0
    @Published var status: String = ""
    @Published var isDpiAvailable: Bool = false

    var selectedDpi: Int? {
        guard !dpiChoices.isEmpty else { return nil }
        let index = min(max(Int(dpiIndex), 0), dpiChoices.count - 1)
        return dpiChoices[index]
    }

    private static let selectedDeviceKey = "selectedDeviceID"
    private static let lastDpiKey = "lastDpi"

    private let manager: HIDPPManager
    private let defaults: UserDefaults
    private let deviceWorker = HIDDeviceWorker()

    private var activeDevice: HIDPPDevice?
    private var activeFeature: DpiFeature?

    private var selectionTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?

    init() {
        defaults = .standard
        manager = HIDPPManager()
        selectedDeviceID = Self.loadSelectedDeviceID(from: defaults)
        manager.onDevicesChanged = { [weak self] devices in
            self?.handleDevicesUpdate(devices)
        }
        manager.refresh()
    }

    func refresh() {
        status = "Scanning devices..."
        manager.refresh()
    }

    func reloadSelection() {
        selectionTask?.cancel()
        commitTask?.cancel()

        let selectedID = selectedDeviceID
        let devicesSnapshot = devices
        let oldDevice = activeDevice
        activeDevice = nil
        activeFeature = nil

        resetDpiState(message: selectedID == nil ? "No device selected" : "Connecting...")

        guard let selectedID else {
            if let oldDevice {
                Task {
                    await deviceWorker.close(device: oldDevice)
                }
            }
            resetDpiState(message: "No device selected")
            return
        }

        guard let device = devicesSnapshot.first(where: { $0.id == selectedID }) else {
            if let oldDevice {
                Task {
                    await deviceWorker.close(device: oldDevice)
                }
            }
            resetDpiState(message: "No device selected")
            return
        }

        selectionTask = Task { [weak self] in
            guard let self else { return }
            let result = await deviceWorker.openAndLoad(device: device, oldDevice: oldDevice)

            if Task.isCancelled {
                if case .success = result {
                    await deviceWorker.close(device: device)
                }
                return
            }

            switch result {
            case .openError(let result):
                self.resetDpiState(message: self.openErrorMessage(result))
            case .noFeature:
                self.resetDpiState(message: "DPI feature not found")
            case .cancelled:
                return
            case .success(let feature, let list, let current):
                self.activeDevice = device
                self.activeFeature = feature
                self.applyDpiList(list, current: current)
            }
        }
    }

    func commitDpi() {
        guard let targetDpi = selectedDpi else { return }
        status = "Setting DPI..."

        let device = activeDevice
        let feature = activeFeature

        commitTask?.cancel()
        commitTask = Task { [weak self] in
            guard let self else { return }
            guard let device, let feature else {
                self.status = "No active device"
                return
            }

            let result = await deviceWorker.updateDpi(device: device, feature: feature, targetDpi: targetDpi)
            guard !Task.isCancelled else { return }

            if result.success {
                self.status = "DPI updated"
            } else {
                self.status = "DPI update failed"
            }

            if let current = result.current, let index = self.dpiChoices.firstIndex(of: current) {
                self.dpiIndex = Double(index)
            }
            if let current = result.current {
                self.persistLastDpi(current)
            }
        }
    }

    private func handleDevicesUpdate(_ devices: [HIDPPDevice]) {
        self.devices = devices

        if devices.isEmpty {
            selectionTask?.cancel()
            commitTask?.cancel()
            closeActiveDevice()
            selectedDeviceID = nil
            resetDpiState(message: "No Logitech mouse found")
            return
        }

        let previousSelection = selectedDeviceID
        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first?.id
        }

        status = ""
        if previousSelection == selectedDeviceID,
           activeDevice == nil || activeDevice?.id != selectedDeviceID {
            reloadSelection()
        }
    }

    private func applyDpiList(_ list: [Int], current: Int?) {
        dpiChoices = list
        isDpiAvailable = !list.isEmpty
        let target = current ?? lastSavedDpi()
        if let target, let index = list.firstIndex(of: target) {
            dpiIndex = Double(index)
        } else {
            dpiIndex = 0
        }
        status = list.isEmpty ? "No DPI list returned" : ""
        if let current {
            persistLastDpi(current)
        }
    }

    private func closeActiveDevice() {
        let device = activeDevice
        activeDevice = nil
        activeFeature = nil

        if let device {
            Task {
                await deviceWorker.close(device: device)
            }
        }
    }

    private func resetDpiState(message: String) {
        dpiChoices = []
        dpiIndex = 0
        isDpiAvailable = false
        status = message
    }

    private func openErrorMessage(_ result: IOReturn) -> String {
        switch result {
        case kIOReturnNotPermitted:
            return "Input Monitoring permission required"
        case kIOReturnExclusiveAccess:
            return "Device is in use by another app"
        default:
            return "Failed to open device (IOReturn \(result))"
        }
    }

    private func persistSelectedDeviceID(_ id: UInt64?) {
        if let id {
            defaults.set(String(id), forKey: Self.selectedDeviceKey)
        } else {
            defaults.removeObject(forKey: Self.selectedDeviceKey)
        }
    }

    private static func loadSelectedDeviceID(from defaults: UserDefaults) -> UInt64? {
        if let value = defaults.string(forKey: Self.selectedDeviceKey), let id = UInt64(value) {
            return id
        }
        if let number = defaults.object(forKey: Self.selectedDeviceKey) as? NSNumber {
            return number.uint64Value
        }
        return nil
    }

    private func persistLastDpi(_ dpi: Int?) {
        if let dpi {
            defaults.set(dpi, forKey: Self.lastDpiKey)
        } else {
            defaults.removeObject(forKey: Self.lastDpiKey)
        }
    }

    private func lastSavedDpi() -> Int? {
        guard defaults.object(forKey: Self.lastDpiKey) != nil else { return nil }
        return defaults.integer(forKey: Self.lastDpiKey)
    }

}

private enum SelectionResult: Sendable {
    case openError(IOReturn)
    case noFeature
    case cancelled
    case success(feature: DpiFeature, list: [Int], current: Int?)
}

private struct CommitResult: Sendable {
    let success: Bool
    let current: Int?
}

private actor HIDDeviceWorker {
    func openAndLoad(device: HIDPPDevice, oldDevice: HIDPPDevice?) async -> SelectionResult {
        if Task.isCancelled {
            return .cancelled
        }

        oldDevice?.close()
        if Task.isCancelled {
            return .cancelled
        }

        let openResult = device.open()
        guard openResult == kIOReturnSuccess else {
            return .openError(openResult)
        }
        var shouldClose = true
        defer {
            if shouldClose {
                device.close()
            }
        }
        guard let feature = await device.detectDpiFeature() else {
            return .noFeature
        }

        if Task.isCancelled {
            return .cancelled
        }

        let list = await device.fetchDpiList(feature: feature)
        let current = await device.readDpi(feature: feature)
        if Task.isCancelled {
            return .cancelled
        }

        shouldClose = false
        return .success(feature: feature, list: list, current: current)
    }

    func updateDpi(device: HIDPPDevice, feature: DpiFeature, targetDpi: Int) async -> CommitResult {
        if Task.isCancelled {
            return CommitResult(success: false, current: nil)
        }

        let success = await device.setDpi(feature: feature, dpi: targetDpi)
        if Task.isCancelled {
            return CommitResult(success: false, current: nil)
        }

        let current = success ? await device.readDpi(feature: feature) : nil
        return CommitResult(success: success, current: current)
    }

    func close(device: HIDPPDevice) {
        device.close()
    }
}
