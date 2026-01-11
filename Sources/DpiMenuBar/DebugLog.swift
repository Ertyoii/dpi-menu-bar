import Foundation
import OSLog

enum DebugLog {
    static let enabled = ProcessInfo.processInfo.environment["DPI_DEBUG"] == "1"
    private static let logger = Logger(subsystem: "com.ertyoii.dpi", category: "hidpp")

    static func log(_ message: String) {
        guard enabled else { return }
        logger.debug("\(message, privacy: .public)")
    }
}

extension [UInt8] {
    func hexString() -> String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
