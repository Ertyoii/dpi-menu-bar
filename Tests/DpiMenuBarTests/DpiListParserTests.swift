@testable import DpiMenuBar
import XCTest

final class DpiListParserTests: XCTestCase {
    func testParseExplicitValues() {
        let bytes: [UInt8] = [
            0x01, 0x90, // 400
            0x03, 0x20, // 800
            0x06, 0x40, // 1600
            0x00, 0x00,
        ]

        XCTAssertEqual(DpiListParser.parse(bytes), [400, 800, 1600])
    }

    func testParseStopsAtZero() {
        let bytes: [UInt8] = [
            0x00, 0x64, // 100
            0x00, 0x00,
            0x00, 0xC8, // ignored
        ]

        XCTAssertEqual(DpiListParser.parse(bytes), [100])
    }

    func testParseStepRange() {
        let bytes: [UInt8] = [
            0x01, 0x90, // 400
            0xE0, 0xC8, // step=200
            0x03, 0xE8, // last=1000
            0x00, 0x00,
        ]

        XCTAssertEqual(DpiListParser.parse(bytes), [400, 600, 800, 1000])
    }
}
