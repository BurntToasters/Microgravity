import XCTest
@testable import Microgravity

final class PowerTelemetryTests: XCTestCase {
    func testAppleSMCStructLayoutMatches80ByteKernelABI() {
        XCTAssertEqual(AppleSMCReader.paramStructSize, 80)
        XCTAssertEqual(AppleSMCReader.bytesOffset, 48)
    }

    func testAppleSMCDecodesNumericFormatsAndRejectsInvalidBytes() {
        let floatValue: Float = 23.5
        let floatBits = floatValue.bitPattern
        let floatBytes: [UInt8] = [
            UInt8(floatBits & 0xff),
            UInt8((floatBits >> 8) & 0xff),
            UInt8((floatBits >> 16) & 0xff),
            UInt8((floatBits >> 24) & 0xff)
        ]
        XCTAssertEqual(AppleSMCReader.decode(dataType: "flt ", bytes: floatBytes) ?? -1, 23.5, accuracy: 0.0001)
        XCTAssertNil(AppleSMCReader.decode(dataType: "flt ", bytes: [0x00, 0x00, 0xc0, 0x7f]), "NaN float must decode to nil")

        // sp78 signed 7.8 fixed point: 12.5 * 256 = 3200 = 0x0C80; -2.25 * 256 = -576 = 0xFDC0
        XCTAssertEqual(AppleSMCReader.decode(dataType: "sp78", bytes: [0x0c, 0x80]) ?? -1, 12.5, accuracy: 0.0001)
        XCTAssertEqual(AppleSMCReader.decode(dataType: "sp78", bytes: [0xfd, 0xc0]) ?? 1, -2.25, accuracy: 0.0001)

        // fpe2 unsigned 14.2 fixed point: 1.5 * 4 = 6 = 0x0006
        XCTAssertEqual(AppleSMCReader.decode(dataType: "fpe2", bytes: [0x00, 0x06]) ?? -1, 1.5, accuracy: 0.0001)

        XCTAssertEqual(AppleSMCReader.decode(dataType: "ui16", bytes: [0x01, 0x02]), 258)
        XCTAssertEqual(AppleSMCReader.decode(dataType: "ui32", bytes: [0x00, 0x01, 0x00, 0x00]), 65_536)

        XCTAssertNil(AppleSMCReader.decode(dataType: "flt ", bytes: [0x00, 0x01]))
        XCTAssertNil(AppleSMCReader.decode(dataType: "ui16", bytes: [0x01]))
        XCTAssertNil(AppleSMCReader.decode(dataType: "ui32", bytes: [0x01, 0x02]))
        XCTAssertNil(AppleSMCReader.decode(dataType: "xxxx", bytes: [0x01, 0x02]))
    }

    func testPowerTelemetryReconcileACWithSMCWithoutSMCAndBatteryDischarge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let interval = DateInterval(start: now.addingTimeInterval(-1), end: now)
        let smc = AppleSMCPowerReading(systemTotalWatts: 24.5, dcInWatts: 48.0, batteryWatts: 18.0)
        let components = ComponentPowerReadings(cpuWatts: 6.2, gpuWatts: 3.3, aneWatts: 0.8, dramWatts: 1.7,
                                                interval: interval, detail: "IOReport")
        let battery = SmartBatteryTelemetry(
            systemLoadWatts: 21.0,
            systemPowerInWatts: 46.0,
            adapterPowerWatts: 47.0,
            batteryPowerWatts: 17.0,
            externalConnected: true,
            isCharging: true,
            batteryPercent: 78,
            timeRemainingMinutes: 35,
            voltageMillivolts: 12_000,
            instantAmperageMilliamps: -1_500,
            adapterMaxWatts: 96
        )
        let psInfo = PowerSourceInfoSnapshot(powerSource: .ac, batteryPercent: 78,
                                             isCharging: true, timeRemainingMinutes: 35)

        let acWithSMC = PowerTelemetryCollector.reconcile(
            smc: smc, battery: battery, powerSourceInfo: psInfo,
            components: components, thermalState: .fair, timestamp: now
        )
        XCTAssertEqual(acWithSMC.systemPowerWatts?.value, 24.5)
        XCTAssertEqual(acWithSMC.primaryPowerWatts?.value, 24.5)
        XCTAssertEqual(acWithSMC.componentPowerWatts?.value ?? -1, 12.0, accuracy: 0.0001)
        XCTAssertEqual(acWithSMC.adapterPowerWatts?.value, 48.0)
        XCTAssertEqual(acWithSMC.batteryPowerWatts?.value, 18.0)
        XCTAssertEqual(acWithSMC.cpuPowerWatts?.value, 6.2)
        XCTAssertEqual(acWithSMC.gpuPowerWatts?.value, 3.3)
        XCTAssertEqual(acWithSMC.anePowerWatts?.value, 0.8)
        XCTAssertEqual(acWithSMC.dramPowerWatts?.value, 1.7)
        XCTAssertEqual(acWithSMC.powerSource, .ac)
        XCTAssertEqual(acWithSMC.thermalState, .fair)
        XCTAssertEqual(acWithSMC.batteryPercent, 78)
        XCTAssertEqual(acWithSMC.adapterMaxWatts, 96)

        // AC without SMC PSTR and without SmartBattery SystemLoad falls back to components for primaryPowerWatts.
        let acNoSMC = PowerTelemetryCollector.reconcile(
            smc: nil, battery: nil, powerSourceInfo: psInfo,
            components: components, thermalState: .nominal, timestamp: now
        )
        XCTAssertNil(acNoSMC.systemPowerWatts)
        XCTAssertEqual(acNoSMC.componentPowerWatts?.value ?? -1, 12.0, accuracy: 0.0001)
        XCTAssertEqual(acNoSMC.primaryPowerWatts?.value ?? -1, 12.0, accuracy: 0.0001)

        // Battery without SMC uses voltage * instantAmperage discharge estimate (12V * 1.5A = 18W).
        let batteryPS = PowerSourceInfoSnapshot(powerSource: .battery, batteryPercent: 64,
                                                isCharging: false, timeRemainingMinutes: 210)
        let onBattery = SmartBatteryTelemetry(
            systemLoadWatts: nil, systemPowerInWatts: nil, adapterPowerWatts: nil, batteryPowerWatts: nil,
            externalConnected: false, isCharging: false, batteryPercent: 64, timeRemainingMinutes: 210,
            voltageMillivolts: 12_000, instantAmperageMilliamps: -1_500, adapterMaxWatts: nil
        )
        let discharged = PowerTelemetryCollector.reconcile(
            smc: nil, battery: onBattery, powerSourceInfo: batteryPS,
            components: components, thermalState: .serious, timestamp: now
        )
        XCTAssertEqual(discharged.systemPowerWatts?.value ?? -1, 18.0, accuracy: 0.0001)
        XCTAssertEqual(discharged.powerSource, .battery)
        XCTAssertEqual(discharged.thermalState, .serious)
        XCTAssertEqual(discharged.batteryTimeRemainingMinutes, 210)
    }

    func testAdvancedMetricsParserParsesAppleSiliconComponentRailsAndIntelPackageWatts() throws {
        let appleSiliconPlist: [String: Any] = [
            "gpu": ["idle_ratio": 0.25],
            "processor": [
                "cpu_power": 4_200.0,
                "gpu_power": 2_100.0,
                "ane_power": 600.0,
                "dram_power": 1_100.0,
                "combined_power": 8_500.0
            ]
        ]
        let asData = try PropertyListSerialization.data(fromPropertyList: appleSiliconPlist, format: .xml, options: 0)
        let parsedAS = AdvancedMetricsParser.power(asData)
        XCTAssertEqual(parsedAS.gpuPercent ?? -1, 75.0, accuracy: 0.001)
        XCTAssertEqual(parsedAS.watts ?? -1, 8.5, accuracy: 0.001)
        XCTAssertEqual(parsedAS.cpuWatts ?? -1, 4.2, accuracy: 0.001)
        XCTAssertEqual(parsedAS.gpuWatts ?? -1, 2.1, accuracy: 0.001)
        XCTAssertEqual(parsedAS.aneWatts ?? -1, 0.6, accuracy: 0.001)
        XCTAssertEqual(parsedAS.dramWatts ?? -1, 1.1, accuracy: 0.001)

        let intelPlist: [String: Any] = [
            "processor": ["package_watts": 19.75]
        ]
        let intelData = try PropertyListSerialization.data(fromPropertyList: intelPlist, format: .xml, options: 0)
        let parsedIntel = AdvancedMetricsParser.power(intelData)
        XCTAssertEqual(parsedIntel.watts ?? -1, 19.75, accuracy: 0.001)
        XCTAssertNil(parsedIntel.cpuWatts)
    }

    func testPositiveBatteryWattsAreNormalizedToDischargingOnBatteryPower() {
        let now = Date(timeIntervalSince1970: 1_800_000_500)
        let smc = AppleSMCPowerReading(systemTotalWatts: nil, dcInWatts: nil, batteryWatts: 16.4)
        let battery = SmartBatteryTelemetry(
            systemLoadWatts: nil, systemPowerInWatts: nil, adapterPowerWatts: nil, batteryPowerWatts: 16.4,
            externalConnected: false, isCharging: false, batteryPercent: 52, timeRemainingMinutes: 180,
            voltageMillivolts: 11_800, instantAmperageMilliamps: -1_400, adapterMaxWatts: nil
        )
        let psInfo = PowerSourceInfoSnapshot(powerSource: .battery, batteryPercent: 52,
                                             isCharging: false, timeRemainingMinutes: 180)

        let reconciled = PowerTelemetryCollector.reconcile(
            smc: smc, battery: battery, powerSourceInfo: psInfo,
            components: nil, thermalState: .nominal, timestamp: now
        )
        XCTAssertEqual(reconciled.powerSource, .battery)
        XCTAssertEqual(reconciled.batteryCharging, false)
        XCTAssertEqual(reconciled.batteryPowerWatts?.value ?? 0, -16.4, accuracy: 0.0001)
    }

    func testHardwareSpecReaderReturnsConsistentSnapshot() {
        let now = Date(timeIntervalSince1970: 1_800_000_500)
        let rate = MetricReading(value: 100, unit: .bytesPerSecond, timestamp: now)
        let total = MetricReading(value: 1_000, unit: .bytes, timestamp: now)
        let reader = HardwareSpecReader()
        let first = reader.read()
        let second = reader.read(primaryNetworkInterface: NetworkInterfaceSnapshot(
            name: "en0", isUp: true,
            receiveBytesPerSecond: rate, transmitBytesPerSecond: rate,
            receiveTotalBytes: total, transmitTotalBytes: total
        ))
        XCTAssertEqual(first.memorySummary, second.memorySummary)
        XCTAssertEqual(second.primaryNetworkInterface, "en0")
    }
}
