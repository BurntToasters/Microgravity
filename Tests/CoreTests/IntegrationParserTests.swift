import XCTest
@testable import Microgravity

final class IntegrationParserTests: XCTestCase {
    func testNettopRejectsMalformedAndAcceptsQuotedProcessNames() {
        let data = "time,interface,state,bytes_in,bytes_out\n12:00,\"hello, world.42\",,100,200\n"
        XCTAssertEqual(AdvancedMetricsParser.nettop(data)[42]?.received, 100)
        XCTAssertEqual(AdvancedMetricsParser.nettop(data)[42]?.sent, 200)
        XCTAssertTrue(AdvancedMetricsParser.nettop("time,interface,bytes_in,bytes_out\n12,bad,wat,2\n").isEmpty)
    }
    func testPowerMetricsRejectsMalformedAndMissingValues() {
        XCTAssertNil(AdvancedMetricsParser.power(Data("not plist".utf8)).watts)
        let data = try! PropertyListSerialization.data(fromPropertyList: ["GPU Power": 1250], format: .xml, options: 0)
        XCTAssertNil(AdvancedMetricsParser.power(data).watts)
        let empty = try! PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
        XCTAssertNil(AdvancedMetricsParser.power(empty).watts)
    }
}
