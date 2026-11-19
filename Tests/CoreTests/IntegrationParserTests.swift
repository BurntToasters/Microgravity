import XCTest
@testable import Microgravity

final class IntegrationParserTests: XCTestCase {
    func testPowerMetricsRejectsMalformedAndMissingValues() {
        XCTAssertNil(AdvancedMetricsParser.power(Data("not plist".utf8)).watts)
        let data = try! PropertyListSerialization.data(fromPropertyList: ["GPU Power": 1250], format: .xml, options: 0)
        XCTAssertNil(AdvancedMetricsParser.power(data).watts)
        let empty = try! PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
        XCTAssertNil(AdvancedMetricsParser.power(empty).watts)
    }

    func testCombinedPowerIsConvertedFromMilliwatts() throws {
        XCTAssertEqual(try parsePower(processor: ["combined_power": 4500]).watts, 4.5)
        XCTAssertEqual(try parsePower(processor: ["combined_power": 0]).watts, 0)
    }

    func testCombinedPowerTakesPrecedenceOverComponents() throws {
        let processor: [String: Any] = ["combined_power": 4500, "cpu_power": 1000, "gpu_power": 2000, "ane_power": 500]
        XCTAssertEqual(try parsePower(processor: processor).watts, 4.5)
    }

    func testComponentPowerRequiresAllThreeMilliwattFields() throws {
        XCTAssertEqual(try parsePower(processor: ["cpu_power": 1000, "gpu_power": 2500, "ane_power": 500]).watts, 4)
        XCTAssertNil(try parsePower(processor: ["cpu_power": 1000, "gpu_power": 2500]).watts)
        XCTAssertNil(try parsePower(processor: ["cpu_power": 1000]).watts)
        XCTAssertNil(try parsePower(processor: [:]).watts)
    }

    func testPowerRejectsNegativeBooleanAndNonNumericValues() throws {
        XCTAssertNil(try parsePower(processor: ["combined_power": -1]).watts)
        XCTAssertNil(try parsePower(processor: ["combined_power": true]).watts)
        XCTAssertNil(try parsePower(processor: ["combined_power": "4500"]).watts)
        XCTAssertNil(try parsePower(processor: ["cpu_power": -1, "gpu_power": 0, "ane_power": 0]).watts)
        XCTAssertNil(try parsePower(processor: ["cpu_power": true, "gpu_power": 0, "ane_power": 0]).watts)
    }

    func testInvalidCombinedPowerDoesNotFallBackToComponents() throws {
        let processor: [String: Any] = ["combined_power": -1, "cpu_power": 1000, "gpu_power": 2000, "ane_power": 500]
        XCTAssertNil(try parsePower(processor: processor).watts)
    }

    func testLegacyMilliwattUnitKeysAreIgnored() throws {
        let processor: [String: Any] = ["cpu_power_mw": 1000, "gpu_power_mw": 2500, "ane_power_mw": 500]
        XCTAssertNil(try parsePower(processor: processor).watts)
    }

    func testTaskGPUTimeFieldsDoNotProduceGPUOrPowerReadings() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["tasks": [["pid": 42, "gpu_time_ms": 1250], ["pid": 43, "gpu_time_ns": 500_000_000]]],
            format: .xml, options: 0)
        let parsed = AdvancedMetricsParser.power(data)
        XCTAssertNil(parsed.watts)
        XCTAssertNil(parsed.gpuPercent)
    }

    private func parsePower(processor: [String: Any]) throws -> AdvancedMetricsParser.Power {
        let data = try PropertyListSerialization.data(fromPropertyList: ["processor": processor], format: .xml, options: 0)
        return AdvancedMetricsParser.power(data)
    }
}
