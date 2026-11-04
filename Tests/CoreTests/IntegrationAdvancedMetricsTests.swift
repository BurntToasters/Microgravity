import XCTest
@testable import Microgravity

final class IntegrationAdvancedMetricsTests: XCTestCase {
    func testNetworkRejectsDuplicateAndMalformedRowsAndParsesQuotedNames() {
        let csv = "time,interface,bytes_in,bytes_out\n0,\"comma, name.42\",0,12\n0,a.43,20,30\n0,b.43,1,2\n0,broken.44,-1,2\n0,\"open.45,1,2\n"
        let parsed = AdvancedMetricsParser.nettop(csv)
        XCTAssertEqual(parsed[42]?.received, 0)
        XCTAssertEqual(parsed[42]?.sent, 12)
        XCTAssertNil(parsed[43])
        XCTAssertNil(parsed[44])
        XCTAssertNil(parsed[45])
        XCTAssertTrue(AdvancedMetricsParser.nettop("time,interface,bytes_in\n0,x.42,1").isEmpty)
    }

    func testPowerParsesOnlyKnownGPUIdleRatioAcrossNULTerminatedRecords() throws {
        func plist(_ object: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        }
        var data = try plist(["gpu": ["idle_ratio": 0.25]])
        data.append(0)
        data.append(try plist(["gpu": ["idle_ratio": 0.5]]))
        data.append(0)
        XCTAssertEqual(AdvancedMetricsParser.power(data).gpuPercent, 50)
        XCTAssertNil(AdvancedMetricsParser.power(try plist(["gpu": ["idle_ratio": -0.1]])).gpuPercent)
        XCTAssertNil(AdvancedMetricsParser.power(try plist(["gpu": ["idle_ratio": 1.1]])).gpuPercent)
        XCTAssertNil(AdvancedMetricsParser.power(try plist(["gpu": ["idle_ratio": true]])).gpuPercent)
        XCTAssertNil(AdvancedMetricsParser.power(Data(repeating: 65, count: 4 * 1024 * 1024 + 1)).gpuPercent)
        XCTAssertNil(AdvancedMetricsParser.power(Data("not plist".utf8)).gpuPercent)
    }
    func testEstimatedComponentPowerRequiresAllThreeKnownMilliwattFields() throws {
        func parse(_ fields: [String: Any]) throws -> AdvancedMetricsParser.Power {
            let data = try PropertyListSerialization.data(fromPropertyList: ["processor": fields], format: .xml, options: 0)
            return AdvancedMetricsParser.power(data)
        }
        XCTAssertEqual(try parse(["cpu_power_mw": 1000, "gpu_power_mw": 2500, "ane_power_mw": 500]).watts, 4)
        XCTAssertNil(try parse(["cpu_power_mw": 1000, "gpu_power_mw": 0]).watts)
        XCTAssertNil(try parse(["cpu_power_mw": -1, "gpu_power_mw": 0, "ane_power_mw": 0]).watts)
        XCTAssertNil(try parse(["cpu_power_mw": true, "gpu_power_mw": 0, "ane_power_mw": 0]).watts)
    }

    func testProcessGPURequiresExplicitTimeUnitsAndRejectsDuplicates() throws {
        let tasks: [[String: Any]] = [
            ["pid": 42, "gpu_time_ms": 1250], ["pid": 43, "gpu_time_ns": 500_000_000],
            ["pid": 44, "gpu_time": 99], ["pid": 45, "gpu_time_ms": -1],
            ["pid": 46, "gpu_time_ms": 2], ["pid": 46, "gpu_time_ms": 3]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: ["tasks": tasks], format: .xml, options: 0)
        let parsed = AdvancedMetricsParser.power(data)
        XCTAssertEqual(parsed.processGPUSeconds[42], 1.25)
        XCTAssertEqual(parsed.processGPUSeconds[43], 0.5)
        XCTAssertNil(parsed.processGPUSeconds[44])
        XCTAssertNil(parsed.processGPUSeconds[45])
        XCTAssertNil(parsed.processGPUSeconds[46])
    }

    func testNetworkRatesRequireStableIdentityAndRejectReset() {
        let old = ProcessIdentity(pid: 42, startTime: .init(secondsSinceEpoch: 100, microseconds: 0))
        let replacement = ProcessIdentity(pid: 42, startTime: .init(secondsSinceEpoch: 200, microseconds: 0))
        let t = Date(timeIntervalSince1970: 1_000)
        var accumulator = AdvancedNetworkAccumulator()
        let first = accumulator.update([42: .init(received: 100, sent: 200)], before: [42: old], after: [42: old], at: t)
        XCTAssertEqual(first[old]?[.processNetwork]?.unavailableReason, .warmingUp)
        let second = accumulator.update([42: .init(received: 150, sent: 300)], before: [42: old], after: [42: old], at: t.addingTimeInterval(5))
        XCTAssertEqual(second[old]?[.processNetwork]?.value, 30)
        let reused = accumulator.update([42: .init(received: 200, sent: 400)], before: [42: old], after: [42: replacement], at: t.addingTimeInterval(10))
        XCTAssertTrue(reused.isEmpty)
        let new = accumulator.update([42: .init(received: 2, sent: 3)], before: [42: replacement], after: [42: replacement], at: t.addingTimeInterval(15))
        XCTAssertEqual(new[replacement]?[.processNetwork]?.unavailableReason, .warmingUp)
        let reset = accumulator.update([42: .init(received: 1, sent: 1)], before: [42: replacement], after: [42: replacement], at: t.addingTimeInterval(20))
        XCTAssertEqual(reset[replacement]?[.processNetwork]?.unavailableReason, .counterReset)
    }

}
