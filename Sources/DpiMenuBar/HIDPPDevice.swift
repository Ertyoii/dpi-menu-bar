import Foundation
import IOKit
import IOKit.hid

enum DpiFeature: Sendable {
    case adjustable(index: UInt8)
    case extended(index: UInt8, hasY: Bool, hasLod: Bool)
}

final class HIDPPDevice: Identifiable {
    let device: IOHIDDevice
    let id: UInt64
    let product: String
    let manufacturer: String
    let serialNumber: String
    let transport: String
    let vendorID: Int
    let productID: Int
    let maxInputReportSize: Int
    let maxOutputReportSize: Int

    var displayName: String {
        if !serialNumber.isEmpty {
            return "\(product) (\(serialNumber))"
        }
        return product
    }

    private let deviceNumber: UInt8 = 0x00
    private let fallbackDeviceNumber: UInt8 = 0xFF
    private let hidppShortReportID: UInt8 = 0x10
    private let hidppReportID: UInt8 = 0x11
    private var swID: UInt8 = 0x02
    private var isOpen = false
    private var shortReportType: IOHIDReportType = kIOHIDReportTypeOutput
    private var longReportType: IOHIDReportType = kIOHIDReportTypeOutput
    private var outputReportIDs: Set<Int> = []
    private var featureReportIDs: Set<Int> = []

    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputBufferSize: Int

    private let pendingStore = PendingRequestStore()

    init(device: IOHIDDevice) {
        self.device = device
        self.product = device.stringProperty(kIOHIDProductKey) ?? "Logitech Mouse"
        self.manufacturer = device.stringProperty(kIOHIDManufacturerKey) ?? ""
        self.serialNumber = device.stringProperty(kIOHIDSerialNumberKey) ?? ""
        self.transport = device.stringProperty(kIOHIDTransportKey) ?? ""
        self.vendorID = device.intProperty(kIOHIDVendorIDKey) ?? 0
        self.productID = device.intProperty(kIOHIDProductIDKey) ?? 0
        self.maxInputReportSize = device.intProperty(kIOHIDMaxInputReportSizeKey) ?? 0
        self.maxOutputReportSize = device.intProperty(kIOHIDMaxOutputReportSizeKey) ?? 0
        if let registryID = device.registryID() {
            self.id = registryID
        } else {
            self.id = UInt64(bitPattern: Int64(ObjectIdentifier(device).hashValue))
        }

        let preferredSize = max(64, maxInputReportSize)
        self.inputBufferSize = preferredSize
        self.inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: preferredSize)
        self.inputBuffer.initialize(repeating: 0, count: preferredSize)
    }

    deinit {
        close()
        inputBuffer.deinitialize(count: inputBufferSize)
        inputBuffer.deallocate()
    }

    func open() -> IOReturn {
        if isOpen {
            return kIOReturnSuccess
        }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        DebugLog.log("Open device \(displayName) result=\(result)")
        guard result == kIOReturnSuccess else { return result }

        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputBuffer,
            inputBufferSize,
            HIDPPDevice.handleInputReport,
            Unmanaged.passUnretained(self).toOpaque()
        )
        scheduleOnMainRunLoop()
        updateReportCapabilities()
        isOpen = true
        return result
    }

    func close() {
        guard isOpen else { return }
        unscheduleFromMainRunLoop()
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = false
    }

    func detectDpiFeature() async -> DpiFeature? {
        DebugLog.log("Detecting DPI feature for \(displayName)")
        if let index = await featureIndex(0x2202) {
            DebugLog.log("Found EXTENDED_ADJUSTABLE_DPI feature index \(String(format: "0x%02X", index))")
            let caps = await featureRequest(featureIndex: index, function: 0x10, params: [0x00])
            let flags: UInt8
            if let caps, caps.count > 2 {
                flags = caps[2]
            } else {
                flags = 0
            }
            let hasY = (flags & 0x01) != 0
            let hasLod = (flags & 0x02) != 0
            DebugLog.log("Extended DPI caps flags=\(String(format: "0x%02X", flags)) y=\(hasY) lod=\(hasLod)")
            return .extended(index: index, hasY: hasY, hasLod: hasLod)
        }
        if let index = await featureIndex(0x2201) {
            DebugLog.log("Found ADJUSTABLE_DPI feature index \(String(format: "0x%02X", index))")
            return .adjustable(index: index)
        }
        DebugLog.log("No DPI feature found for \(displayName)")
        return nil
    }

    func fetchDpiList(feature: DpiFeature) async -> [Int] {
        switch feature {
        case .adjustable(let index):
            let bytes = await collectDpiBytes(featureIndex: index, function: 0x10, ignoreBytes: 1, direction: 0)
            return parseDpiList(bytes)
        case .extended(let index, _, _):
            let bytes = await collectDpiBytes(featureIndex: index, function: 0x20, ignoreBytes: 3, direction: 0)
            return parseDpiList(bytes)
        }
    }

    func readDpi(feature: DpiFeature) async -> Int? {
        switch feature {
        case .adjustable(let index):
            guard let reply = await featureRequest(featureIndex: index, function: 0x20, params: []), reply.count >= 5 else {
                return nil
            }
            let current = (Int(reply[1]) << 8) | Int(reply[2])
            let fallback = (Int(reply[3]) << 8) | Int(reply[4])
            return current == 0 ? fallback : current
        case .extended(let index, _, _):
            guard let reply = await featureRequest(featureIndex: index, function: 0x50, params: []), reply.count >= 5 else {
                return nil
            }
            let current = (Int(reply[1]) << 8) | Int(reply[2])
            let fallback = (Int(reply[3]) << 8) | Int(reply[4])
            return current == 0 ? fallback : current
        }
    }

    func setDpi(feature: DpiFeature, dpi: Int) async -> Bool {
        let hi = UInt8((dpi >> 8) & 0xFF)
        let lo = UInt8(dpi & 0xFF)
        switch feature {
        case .adjustable(let index):
            let reply = await featureRequest(featureIndex: index, function: 0x30, params: [0x00, hi, lo])
            return reply != nil
        case .extended(let index, _, _):
            let reply = await featureRequest(featureIndex: index, function: 0x60, params: [0x00, 0x00, hi, lo])
            return reply != nil
        }
    }

    private func featureIndex(_ featureID: UInt16) async -> UInt8? {
        let hi = UInt8((featureID >> 8) & 0xFF)
        let lo = UInt8(featureID & 0xFF)
        DebugLog.log("Feature index request for \(String(format: "0x%04X", featureID))")
        guard let reply = await sendRequest(0x0000, params: [hi, lo]) else { return nil }
        DebugLog.log("Feature index reply for \(String(format: "0x%04X", featureID)) bytes=\(reply.hexString())")
        guard let index = reply.first, index != 0 else { return nil }
        return index
    }

    private func featureRequest(featureIndex: UInt8, function: UInt8, params: [UInt8]) async -> [UInt8]? {
        let fn = function & 0xF0
        let requestID = (UInt16(featureIndex) << 8) | UInt16(fn)
        return await sendRequest(requestID, params: params)
    }

    private func collectDpiBytes(featureIndex: UInt8, function: UInt8, ignoreBytes: Int, direction: UInt8) async -> [UInt8] {
        var dpiBytes: [UInt8] = []
        for i in 0..<256 {
            guard let reply = await featureRequest(
                featureIndex: featureIndex,
                function: function,
                params: [0x00, direction, UInt8(i)]
            ) else {
                break
            }
            if reply.count > ignoreBytes {
                dpiBytes.append(contentsOf: reply.dropFirst(ignoreBytes))
            }
            if dpiBytes.count >= 2, dpiBytes.suffix(2) == [0x00, 0x00] {
                break
            }
        }
        return dpiBytes
    }

    private func parseDpiList(_ bytes: [UInt8]) -> [Int] {
        var list: [Int] = []
        var i = 0
        while i + 1 < bytes.count {
            let value = (Int(bytes[i]) << 8) | Int(bytes[i + 1])
            if value == 0 {
                break
            }
            if (value >> 13) == 0b111 {
                let step = value & 0x1FFF
                if i + 3 >= bytes.count {
                    break
                }
                let last = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
                if let previous = list.last {
                    var v = previous + step
                    while v <= last {
                        list.append(v)
                        v += step
                    }
                }
                i += 4
            } else {
                list.append(value)
                i += 2
            }
        }
        return list
    }

    private func sendRequest(_ requestID: UInt16, params: [UInt8], timeout: TimeInterval = 1.5) async -> [UInt8]? {
        guard isOpen else { return nil }
        if params.count <= 3 {
            if supportsReportID(hidppShortReportID, type: shortReportType) {
                if let reply = await sendRequestInternal(requestID, params: params, reportID: hidppShortReportID, reportType: shortReportType, dataLength: 5, deviceNumber: deviceNumber, timeout: timeout) {
                    return reply
                }
            }
            if supportsReportID(hidppShortReportID, type: shortReportType), deviceNumber != fallbackDeviceNumber {
                if let reply = await sendRequestInternal(requestID, params: params, reportID: hidppShortReportID, reportType: shortReportType, dataLength: 5, deviceNumber: fallbackDeviceNumber, timeout: timeout) {
                    return reply
                }
            }
            if supportsReportID(hidppShortReportID, type: kIOHIDReportTypeFeature) {
                if let reply = await sendRequestInternal(requestID, params: params, reportID: hidppShortReportID, reportType: kIOHIDReportTypeFeature, dataLength: 5, deviceNumber: deviceNumber, timeout: timeout) {
                    return reply
                }
            }
            if supportsReportID(hidppShortReportID, type: kIOHIDReportTypeFeature), deviceNumber != fallbackDeviceNumber {
                if let reply = await sendRequestInternal(requestID, params: params, reportID: hidppShortReportID, reportType: kIOHIDReportTypeFeature, dataLength: 5, deviceNumber: fallbackDeviceNumber, timeout: timeout) {
                    return reply
                }
            }
        }
        if supportsReportID(hidppReportID, type: longReportType) {
            if let reply = await sendRequestInternal(requestID, params: params, reportID: hidppReportID, reportType: longReportType, dataLength: 18, deviceNumber: deviceNumber, timeout: timeout) {
                return reply
            }
            if deviceNumber != fallbackDeviceNumber {
                return await sendRequestInternal(requestID, params: params, reportID: hidppReportID, reportType: longReportType, dataLength: 18, deviceNumber: fallbackDeviceNumber, timeout: timeout)
            }
            return nil
        }
        if supportsReportID(hidppReportID, type: kIOHIDReportTypeFeature) {
            if let reply = await sendRequestInternal(requestID, params: params, reportID: hidppReportID, reportType: kIOHIDReportTypeFeature, dataLength: 18, deviceNumber: deviceNumber, timeout: timeout) {
                return reply
            }
            if deviceNumber != fallbackDeviceNumber {
                return await sendRequestInternal(requestID, params: params, reportID: hidppReportID, reportType: kIOHIDReportTypeFeature, dataLength: 18, deviceNumber: fallbackDeviceNumber, timeout: timeout)
            }
            return nil
        }
        DebugLog.log("No supported report ID found for request \(String(format: "0x%04X", requestID))")
        return nil
    }

    private func sendRequestInternal(
        _ requestID: UInt16,
        params: [UInt8],
        reportID: UInt8,
        reportType: IOHIDReportType,
        dataLength: Int,
        deviceNumber: UInt8,
        timeout: TimeInterval
    ) async -> [UInt8]? {
        let requestIDWithSW = withSoftwareID(requestID)

        DebugLog.log("Send reportID=\(String(format: "0x%02X", reportID)) type=\(reportType) dev=\(String(format: "0x%02X", deviceNumber)) req=\(String(format: "0x%04X", requestIDWithSW)) params=\(params.hexString())")

        var data = [UInt8](repeating: 0, count: dataLength)
        data[0] = UInt8((requestIDWithSW >> 8) & 0xFF)
        data[1] = UInt8(requestIDWithSW & 0xFF)
        let copyCount = min(params.count, max(0, dataLength - 2))
        if copyCount > 0 {
            for idx in 0..<copyCount {
                data[2 + idx] = params[idx]
            }
        }

        var report = [UInt8]()
        report.reserveCapacity(2 + dataLength)
        report.append(reportID)
        report.append(deviceNumber)
        report.append(contentsOf: data)

        let response = await withCheckedContinuation { continuation in
            Task { [report, reportType, reportID, requestIDWithSW, timeout, pendingStore, self] in
                await pendingStore.register(requestID: requestIDWithSW, continuation: continuation)

                var mutableReport = report
                let setResult = mutableReport.withUnsafeMutableBufferPointer { buffer -> IOReturn in
                    guard let baseAddress = buffer.baseAddress else { return kIOReturnError }
                    return IOHIDDeviceSetReport(
                        self.device,
                        reportType,
                        CFIndex(reportID),
                        baseAddress,
                        buffer.count
                    )
                }

                guard setResult == kIOReturnSuccess else {
                    await pendingStore.fail(requestID: requestIDWithSW, sendResult: setResult)
                    return
                }

                let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
                Task.detached { [pendingStore] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    await pendingStore.timeout(requestID: requestIDWithSW)
                }
            }
        }

        if let sendResult = response.sendResult {
            DebugLog.log("Send failed IOReturn=\(sendResult) req=\(String(format: "0x%04X", requestIDWithSW))")
            return nil
        }
        if response.timedOut {
            DebugLog.log("Timeout waiting for req=\(String(format: "0x%04X", requestIDWithSW))")
            return nil
        }
        if let error = response.error {
            DebugLog.log("Device error for req=\(String(format: "0x%04X", requestIDWithSW)) code=\(error)")
            return nil
        }
        if let responseBytes = response.response {
            DebugLog.log("Reply for req=\(String(format: "0x%04X", requestIDWithSW)) bytes=\(responseBytes.hexString())")
        }
        return response.response
    }

    private func withSoftwareID(_ requestID: UInt16) -> UInt16 {
        let sw = nextSoftwareID()
        return (requestID & 0xFFF0) | UInt16(sw)
    }

    private func nextSoftwareID() -> UInt8 {
        if swID < 0x0F {
            swID += 1
        } else {
            swID = 0x02
        }
        return swID
    }

    private static let handleInputReport: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
        guard result == kIOReturnSuccess else { return }
        guard let context else { return }
        let device = Unmanaged<HIDPPDevice>.fromOpaque(context).takeUnretainedValue()
        device.handleInputReport(reportID: UInt8(reportID), report: report, reportLength: reportLength)
    }

    private func handleInputReport(reportID: UInt8, report: UnsafeMutablePointer<UInt8>, reportLength: CFIndex) {
        let length = Int(reportLength)
        guard length >= 2 else { return }
        guard reportID == hidppReportID || reportID == hidppShortReportID else { return }

        var data = Array(UnsafeBufferPointer(start: report, count: length))
        if data.first == reportID {
            data.removeFirst()
        }
        DebugLog.log("Input reportID=\(String(format: "0x%02X", reportID)) len=\(length) bytes=\(data.hexString())")
        if data.count >= 4, data[1] == 0xFF {
            let requestID = (UInt16(data[2]) << 8) | UInt16(data[3])
            let errorCode = data.count > 4 ? data[4] : 0
            Task {
                await pendingStore.complete(requestID: requestID, response: nil, error: errorCode)
            }
            return
        }

        guard data.count >= 3 else { return }
        let requestID = (UInt16(data[1]) << 8) | UInt16(data[2])
        let response = Array(data.dropFirst(3))
        Task {
            await pendingStore.complete(requestID: requestID, response: response, error: nil)
        }
    }

    private func updateReportCapabilities() {
        outputReportIDs.removeAll()
        featureReportIDs.removeAll()

        guard let elements = IOHIDDeviceCopyMatchingElements(
            device,
            nil,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else {
            DebugLog.log("No HID elements found")
            return
        }

        var typeCounts: [IOHIDElementType: Int] = [:]
        for element in elements {
            let type = IOHIDElementGetType(element)
            typeCounts[type, default: 0] += 1
            let reportID = Int(IOHIDElementGetReportID(element))
            switch type {
            case kIOHIDElementTypeOutput:
                outputReportIDs.insert(reportID)
            case kIOHIDElementTypeFeature:
                featureReportIDs.insert(reportID)
            default:
                break
            }
        }

        if outputReportIDs.contains(Int(hidppShortReportID)) {
            shortReportType = kIOHIDReportTypeOutput
        } else if featureReportIDs.contains(Int(hidppShortReportID)) {
            shortReportType = kIOHIDReportTypeFeature
        }

        if outputReportIDs.contains(Int(hidppReportID)) {
            longReportType = kIOHIDReportTypeOutput
        } else if featureReportIDs.contains(Int(hidppReportID)) {
            longReportType = kIOHIDReportTypeFeature
        }

        if DebugLog.enabled {
            let outputList = outputReportIDs.map { String(format: "0x%02X", $0) }.sorted().joined(separator: ", ")
            let featureList = featureReportIDs.map { String(format: "0x%02X", $0) }.sorted().joined(separator: ", ")
            DebugLog.log("Output report IDs: [\(outputList)]")
            DebugLog.log("Feature report IDs: [\(featureList)]")
            let counts = typeCounts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            DebugLog.log("Element type counts: \(counts)")
            DebugLog.log("Selected report types short=\(shortReportType) long=\(longReportType)")
        }
    }

    private func supportsReportID(_ reportID: UInt8, type: IOHIDReportType) -> Bool {
        let id = Int(reportID)
        switch type {
        case kIOHIDReportTypeOutput:
            return outputReportIDs.contains(id)
        case kIOHIDReportTypeFeature:
            return featureReportIDs.contains(id)
        default:
            return false
        }
    }

    private func scheduleOnMainRunLoop() {
        onMainSync {
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
    }

    private func unscheduleFromMainRunLoop() {
        onMainSync {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
    }

    private func onMainSync(_ block: () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync {
                block()
            }
        }
    }
}

private struct PendingResponse: Sendable {
    let response: [UInt8]?
    let error: UInt8?
    let timedOut: Bool
    let sendResult: IOReturn?
}

private actor PendingRequestStore {
    private var pending: [UInt16: CheckedContinuation<PendingResponse, Never>] = [:]

    func register(requestID: UInt16, continuation: CheckedContinuation<PendingResponse, Never>) {
        pending[requestID] = continuation
    }

    func fail(requestID: UInt16, sendResult: IOReturn) {
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: PendingResponse(response: nil, error: nil, timedOut: false, sendResult: sendResult))
    }

    func timeout(requestID: UInt16) {
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: PendingResponse(response: nil, error: nil, timedOut: true, sendResult: nil))
    }

    func complete(requestID: UInt16, response: [UInt8]?, error: UInt8?) {
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: PendingResponse(response: response, error: error, timedOut: false, sendResult: nil))
    }
}

extension HIDPPDevice: @unchecked Sendable {}

private extension IOHIDDevice {
    func intProperty(_ key: String) -> Int? {
        guard let value = IOHIDDeviceGetProperty(self, key as CFString) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    func uint64Property(_ key: String) -> UInt64? {
        guard let value = IOHIDDeviceGetProperty(self, key as CFString) else { return nil }
        return (value as? NSNumber)?.uint64Value
    }

    func stringProperty(_ key: String) -> String? {
        guard let value = IOHIDDeviceGetProperty(self, key as CFString) else { return nil }
        return value as? String
    }

    func registryID() -> UInt64? {
        let service = IOHIDDeviceGetService(self)
        guard service != 0 else { return nil }
        var entryID: UInt64 = 0
        let result = IORegistryEntryGetRegistryEntryID(service, &entryID)
        return result == KERN_SUCCESS ? entryID : nil
    }
}
