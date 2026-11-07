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

    func testTotalsExcludeLoopbackAndVirtualInterfaces() throws {
        let names: [UInt16: String] = [1: "lo0", 4: "gif0", 5: "stf0", 6: "utun3", 7: "en0", 8: "awdl0",
                                       9: "bridge100"]
        var data = Data()
        data.append(routeMessage(index: 1, receive: 50_000, transmit: 50_000, isUp: true, loopback: true, type: 0x18))
        data.append(routeMessage(index: 4, receive: 4_000, transmit: 4_000, isUp: true, type: 0x37))
        data.append(routeMessage(index: 5, receive: 4_000, transmit: 4_000, isUp: true, type: 0x39))
        data.append(routeMessage(index: 6, receive: 3_000, transmit: 3_000, isUp: true, type: 6))
        data.append(routeMessage(index: 7, receive: 1_000, transmit: 2_000, isUp: true, type: 6))
        data.append(routeMessage(index: 8, receive: 3_000, transmit: 3_000, isUp: true, type: 6))
        data.append(routeMessage(index: 9, receive: 3_000, transmit: 3_000, isUp: true, type: 0xd1))

        let records = try NetworkInterfaceReader.parse(data) { names[$0] }
        XCTAssertEqual(records.map(\.name), ["awdl0", "bridge100", "en0", "gif0", "lo0", "stf0", "utun3"])
        let loopback = try XCTUnwrap(records.first { $0.name == "lo0" })
        XCTAssertTrue(loopback.isLoopback)
        XCTAssertFalse(loopback.includedInTotals)
        let physical = try XCTUnwrap(records.first { $0.name == "en0" })
        XCTAssertFalse(physical.isLoopback)
        XCTAssertTrue(physical.includedInTotals)
        for name in ["awdl0", "bridge100", "gif0", "stf0", "utun3"] {
            XCTAssertFalse(try XCTUnwrap(records.first { $0.name == name }).includedInTotals, name)
        }

        var tracker = NetworkInterfaceCounterTracker()
        let start = Date()
        _ = tracker.collect(records, at: start)
        var next = Data()
        next.append(routeMessage(index: 1, receive: 60_000, transmit: 60_000, isUp: true, loopback: true, type: 0x18))
        next.append(routeMessage(index: 4, receive: 5_000, transmit: 5_000, isUp: true, type: 0x37))
        next.append(routeMessage(index: 5, receive: 5_000, transmit: 5_000, isUp: true, type: 0x39))
        next.append(routeMessage(index: 6, receive: 3_500, transmit: 3_500, isUp: true, type: 6))
        next.append(routeMessage(index: 7, receive: 1_100, transmit: 2_300, isUp: true, type: 6))
        next.append(routeMessage(index: 8, receive: 3_200, transmit: 3_200, isUp: true, type: 6))
        next.append(routeMessage(index: 9, receive: 3_200, transmit: 3_200, isUp: true, type: 0xd1))
        let updated = try NetworkInterfaceReader.parse(next) { names[$0] }
        let result = tracker.collect(updated, at: start.addingTimeInterval(1))

        XCTAssertEqual(result.receiveRate.value, 100, "only en0 counts toward receive totals")
        XCTAssertEqual(result.transmitRate.value, 300, "only en0 counts toward transmit totals")
        XCTAssertEqual(result.interfaces.count, 7, "excluded interfaces stay in the per-interface list")
        XCTAssertEqual(result.interfaces.filter(\.includedInTotals).map(\.name), ["en0"])
        XCTAssertEqual(result.interfaces.first { $0.name == "lo0" }?.receiveBytesPerSecond.value, 10_000)
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
                              isUp: Bool, loopback: Bool = false, type: UInt8 = 6) -> Data {
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_version = UInt8(RTM_VERSION)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_flags = (isUp ? Int32(IFF_UP) : 0) | (loopback ? Int32(IFF_LOOPBACK) : 0)
        header.ifm_index = index
        header.ifm_data.ifi_type = type
        header.ifm_data.ifi_ibytes = receive
        header.ifm_data.ifi_obytes = transmit
        return withUnsafeBytes(of: &header) { Data($0) }
    }
}
