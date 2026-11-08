import XCTest
@testable import Microgravity

final class IntegrationParserTests: XCTestCase {
    func testNettopAcceptsObservedUnlabeledProcessColumnWithOptionalTrailingColumn() {
        let observed = ",bytes_in,bytes_out,\nsyslogd.149,0,141299,\n"
        XCTAssertTrue(AdvancedMetricsParser.hasNettopHeader(observed))
        XCTAssertEqual(AdvancedMetricsParser.nettop(observed)[149],
                       AdvancedMetricsParser.NetworkTotals(received: 0, sent: 141_299))

        let withoutTrailingColumn = ",bytes_in,bytes_out\nsyslogd.149,0,141299\n"
        XCTAssertTrue(AdvancedMetricsParser.hasNettopHeader(withoutTrailingColumn))
        XCTAssertEqual(AdvancedMetricsParser.nettop(withoutTrailingColumn)[149]?.sent, 141_299)
    }

    func testNettopRetainsLabeledSchemaAndAcceptsQuotedProcessNames() {
        let data = "time,interface,state,bytes_in,bytes_out\n12:00,\"hello, world.42\",,100,200\n"
        XCTAssertEqual(AdvancedMetricsParser.nettop(data)[42]?.received, 100)
        XCTAssertEqual(AdvancedMetricsParser.nettop(data)[42]?.sent, 200)
    }

    func testNettopPreservesAnEmptyLabeledFinalColumnAndRejectsExtraColumns() {
        let emptyState = "interface,bytes_in,bytes_out,state\np.42,1,2,\n"
        XCTAssertEqual(AdvancedMetricsParser.nettop(emptyState)[42]?.received, 1)
        XCTAssertEqual(AdvancedMetricsParser.nettop(emptyState)[42]?.sent, 2)

        XCTAssertNil(AdvancedMetricsParser.nettop(
            "interface,bytes_in,bytes_out,state\np.42,1,2,,extra\n")[42])
        XCTAssertNil(AdvancedMetricsParser.nettop(
            "interface,bytes_in,bytes_out,state\np.42,1,2,,,\n")[42])
    }

    func testNettopRejectsMalformedOrDuplicateHeadersRowsAndPIDs() {
        let duplicateHeader = "interface,bytes_in,bytes_out,bytes_in\na.42,1,2,3\n"
        XCTAssertFalse(AdvancedMetricsParser.hasNettopHeader(duplicateHeader))
        XCTAssertTrue(AdvancedMetricsParser.nettop(duplicateHeader).isEmpty)
        XCTAssertFalse(AdvancedMetricsParser.hasNettopHeader(",bytes_in,unknown\na.42,1,2\n"))
        XCTAssertTrue(AdvancedMetricsParser.nettop("time,interface,bytes_in,bytes_out\n12,bad,wat,2\n").isEmpty)
        XCTAssertTrue(AdvancedMetricsParser.nettop("time,interface,bytes_in,bytes_out\n12,a.42,1\n").isEmpty)

        let duplicatePID = ",bytes_in,bytes_out\na.42,1,2\nb.42,3,4\n"
        XCTAssertNil(AdvancedMetricsParser.nettop(duplicatePID)[42])
        XCTAssertTrue(AdvancedMetricsParser.nettop(",bytes_in,bytes_out\n\"open.45,1,2\n").isEmpty)
    }

    func testNettopEnforcesMaximumUTF8ByteCount() {
        let header = ",bytes_in,bytes_out\n"
        let rowSuffix = ".149,1,2\n"
        let fillerCount = AdvancedMetricsParser.maximumBytes - header.utf8.count - rowSuffix.utf8.count
        let exactLimit = header + String(repeating: "p", count: fillerCount) + rowSuffix
        XCTAssertEqual(exactLimit.utf8.count, AdvancedMetricsParser.maximumBytes)
        XCTAssertEqual(AdvancedMetricsParser.nettop(exactLimit)[149]?.sent, 2)

        let overLimit = exactLimit + " "
        XCTAssertTrue(AdvancedMetricsParser.nettop(overLimit).isEmpty)
        XCTAssertFalse(AdvancedMetricsParser.hasNettopHeader(overLimit))
    }

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
