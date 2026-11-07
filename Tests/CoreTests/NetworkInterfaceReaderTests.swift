import Darwin
import Foundation
import XCTest
@testable import Microgravity

final class NetworkInterfaceReaderTests: XCTestCase {
    func testReadsUInt64CountersAboveFourGiBAndTracksContinuousRates() throws {
        let firstReceive: UInt64 = 5 * 1_024 * 1_024 * 1_024 + 17
        let nextReceive = firstReceive + 400
        let first = try readInterface(index: 7, receive: firstReceive, transmit: firstReceive + 1,
                                      isUp: true)
        let next = try readInterface(index: 7, receive: nextReceive, transmit: firstReceive + 601,
                                     isUp: true)
        XCTAssertEqual(first.receiveBytes, firstReceive)
        XCTAssertTrue(first.isUp)

        var tracker = NetworkInterfaceCounterTracker()
        let start = Date()
        let baseline = tracker.collect([first], at: start)
        XCTAssertEqual(baseline.interfaces.first?.receiveBytesPerSecond.unavailableReason, .warmingUp)

        let continuous = tracker.collect([next], at: start.addingTimeInterval(2))
        XCTAssertEqual(continuous.interfaces.first?.receiveBytesPerSecond.value, 200)
        XCTAssertEqual(continuous.interfaces.first?.transmitBytesPerSecond.value, 300)
        XCTAssertEqual(continuous.interfaces.first?.receiveBytesPerSecond.measurementInterval,
                       DateInterval(start: start, end: start.addingTimeInterval(2)))
        XCTAssertEqual(continuous.interfaces.first?.receiveTotalBytes.value, Double(nextReceive))
    }

    func testCounterResetIsReportedAndRebaselined() throws {
        let first = try readInterface(index: 7, receive: 9_000_000_000, transmit: 9_000_000_000,
                                      isUp: true)
        let reset = try readInterface(index: 7, receive: 2_000_000_000, transmit: 2_000_000_000,
                                      isUp: false)
        var tracker = NetworkInterfaceCounterTracker()
        let start = Date()
        _ = tracker.collect([first], at: start)

        let resetSnapshot = tracker.collect([reset], at: start.addingTimeInterval(1))
        XCTAssertEqual(resetSnapshot.interfaces.first?.receiveBytesPerSecond.unavailableReason, .counterReset)
        XCTAssertFalse(resetSnapshot.interfaces.first?.isUp ?? true)

        let afterReset = try readInterface(index: 7, receive: 2_000_000_100, transmit: 2_000_000_200,
                                           isUp: true)
        let recovered = tracker.collect([afterReset], at: start.addingTimeInterval(2))
        XCTAssertEqual(recovered.interfaces.first?.receiveBytesPerSecond.value, 100)
        XCTAssertEqual(recovered.interfaces.first?.transmitBytesPerSecond.value, 200)
    }

    func testDisappearingInterfaceLosesItsBaselineAndEmptyCollectionIsUnavailable() throws {
        let en0 = try readInterface(index: 7, receive: 1_000, transmit: 2_000, isUp: true)
        let en1 = try readInterface(index: 8, receive: 10_000, transmit: 20_000, isUp: true)
        var tracker = NetworkInterfaceCounterTracker()
        let start = Date()
        _ = tracker.collect([en0, en1], at: start)

        let en1Only = try readInterface(index: 8, receive: 10_100, transmit: 20_200, isUp: true)
        let missing = tracker.collect([en1Only], at: start.addingTimeInterval(1))
        XCTAssertEqual(missing.interfaces.map(\.name), ["en8"])
        XCTAssertEqual(missing.interfaces.first?.receiveBytesPerSecond.value, 100)

        let en0Returns = try readInterface(index: 7, receive: 1_500, transmit: 2_500, isUp: true)
        let returned = tracker.collect([en0Returns], at: start.addingTimeInterval(2))
        XCTAssertEqual(returned.interfaces.first?.receiveBytesPerSecond.unavailableReason, .warmingUp)
        XCTAssertEqual(returned.interfaces.first?.transmitBytesPerSecond.unavailableReason, .warmingUp)

        let unavailable = tracker.collect([], at: start.addingTimeInterval(3))
        XCTAssertEqual(unavailable.interfaces, [])
        XCTAssertEqual(unavailable.receiveRate.unavailableReason, .collectionFailed)
        XCTAssertEqual(unavailable.transmitRate.unavailableReason, .collectionFailed)
    }

    func testParserRejectsZeroLengthTruncatedAndShortInterfaceMessages() {
        let nameResolver: (UInt16) -> String? = { _ in "en0" }
        for data in [Data([0, 0, 0, 0]), Data([8, 0, 0]), Data([8, 0, 0, 0])] {
            XCTAssertThrowsError(try NetworkInterfaceReader.parse(data, interfaceName: nameResolver))
        }

        var shortHeader = if_msghdr2()
        shortHeader.ifm_msglen = 4
        shortHeader.ifm_version = UInt8(RTM_VERSION)
        shortHeader.ifm_type = UInt8(RTM_IFINFO2)
        let shortMessage = withUnsafeBytes(of: &shortHeader) { Data($0.prefix(4)) }
        XCTAssertThrowsError(try NetworkInterfaceReader.parse(shortMessage, interfaceName: nameResolver))
    }

    private func readInterface(index: UInt16, receive: UInt64, transmit: UInt64,
                               isUp: Bool) throws -> NetworkInterfaceCounter {
        let data = routeMessage(index: index, receive: receive, transmit: transmit, isUp: isUp)
        let interfaces = try NetworkInterfaceReader.parse(data) { "en\($0)" }
        guard let interface = interfaces.first else {
            XCTFail("expected an interface record")
            throw NetworkInterfaceReaderError.invalidLength
        }
        return interface
    }

    private func routeMessage(index: UInt16, receive: UInt64, transmit: UInt64,
                              isUp: Bool) -> Data {
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_version = UInt8(RTM_VERSION)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_flags = isUp ? Int32(IFF_UP) : 0
        header.ifm_index = index
        header.ifm_data.ifi_ibytes = receive
        header.ifm_data.ifi_obytes = transmit
        return withUnsafeBytes(of: &header) { Data($0) }
    }
}
