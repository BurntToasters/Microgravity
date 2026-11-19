import XCTest
@testable import Microgravity

final class AppleSMCReaderTests: XCTestCase {
    private func littleEndianFloat(_ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8(bits >> 24)]
    }

    func testReadPowerSucceedsOnConsecutiveTicksWhenSMCIsPresent() throws {
        guard AppleSMCReader.readPower() != nil else {
            throw XCTSkip("No AppleSMC power keys on this machine (VM or unsupported Mac)")
        }
        XCTAssertNotNil(AppleSMCReader.readPower(), "second consecutive tick must also succeed")
    }

    func testSessionKeepsConnectionAndKeyInfoAcrossTicks() {
        let fake = FakeSMCTransport(keys: [
            "PSTR": .init(dataType: "flt ", bytes: littleEndianFloat(24.5)),
            "PDTR": .init(dataType: "flt ", bytes: littleEndianFloat(48.0)),
            // sp78 18.0 W = 18 * 256 = 0x1200
            "PPBR": .init(dataType: "sp78", bytes: [0x12, 0x00])
        ])
        let session = AppleSMCSession(transport: fake)

        let first = session.readPower()
        let second = session.readPower()

        XCTAssertEqual(first, AppleSMCPowerReading(systemTotalWatts: 24.5, dcInWatts: 48.0, batteryWatts: 18.0))
        XCTAssertEqual(second, first)
        XCTAssertEqual(fake.opens, 1, "the connection must stay open between ticks")
        XCTAssertEqual(fake.closes, 0)
        XCTAssertEqual(fake.keyInfoQueries["PSTR"], 1, "key info is queried once per key")
        XCTAssertEqual(fake.keyInfoQueries["PPBR"], 1)
        XCTAssertEqual(fake.keyInfoQueries["PB0R"], 1, "PB0R is probed only until PPBR answers")
    }

    func testFailedCallClosesConnectionClearsCachesAndReopensNextTick() {
        let fake = FakeSMCTransport(keys: [
            "PSTR": .init(dataType: "flt ", bytes: littleEndianFloat(24.5))
        ])
        let session = AppleSMCSession(transport: fake)
        XCTAssertNotNil(session.readPower())
        XCTAssertEqual(fake.opens, 1)

        fake.failingCalls = 1
        XCTAssertNil(session.readPower(), "a failed IOKit call returns nil for this tick")
        XCTAssertEqual(fake.closes, 1, "the connection is closed after a failed call")

        let recovered = session.readPower()
        XCTAssertEqual(recovered?.systemTotalWatts, 24.5)
        XCTAssertEqual(fake.opens, 2, "the next tick reopens the connection")
        XCTAssertEqual(fake.keyInfoQueries["PSTR"], 2, "caches were cleared, so key info is queried again")
    }

    func testOpenFailureReturnsNilAndRetriesNextTick() {
        let fake = FakeSMCTransport(keys: [
            "PSTR": .init(dataType: "flt ", bytes: littleEndianFloat(24.5))
        ])
        fake.unavailable = true
        let session = AppleSMCSession(transport: fake)

        XCTAssertNil(session.readPower())
        XCTAssertEqual(fake.opens, 1)

        fake.unavailable = false
        XCTAssertEqual(session.readPower()?.systemTotalWatts, 24.5)
        XCTAssertEqual(fake.opens, 2)
    }
}

/// In-memory stand-in for the AppleSMC user client. Records opens, closes and key-info queries.
private final class FakeSMCTransport: AppleSMCTransport, @unchecked Sendable {
    struct Key {
        let dataType: String
        let bytes: [UInt8]
    }

    private static let handle: io_connect_t = 7
    private let lock = NSLock()
    private let keys: [String: Key]
    private var _opens = 0
    private var _closes = 0
    private var _keyInfoQueries: [String: Int] = [:]
    private var _failingCalls = 0
    private var _unavailable = false

    init(keys: [String: Key]) {
        self.keys = keys
    }

    var opens: Int { locked { _opens } }
    var closes: Int { locked { _closes } }
    var keyInfoQueries: [String: Int] { locked { _keyInfoQueries } }

    /// Number of upcoming `call` invocations that fail at the IOKit level.
    var failingCalls: Int {
        get { locked { _failingCalls } }
        set { locked { _failingCalls = newValue } }
    }

    var unavailable: Bool {
        get { locked { _unavailable } }
        set { locked { _unavailable = newValue } }
    }

    func open() -> io_connect_t? {
        locked {
            _opens += 1
            return _unavailable ? nil : Self.handle
        }
    }

    func close(_ connection: io_connect_t) {
        locked {
            XCTAssertEqual(connection, Self.handle)
            _closes += 1
        }
    }

    func call(_ connection: io_connect_t, input: AppleSMCReader.SMCParamStruct) -> AppleSMCReader.SMCParamStruct? {
        locked {
            guard connection == Self.handle else { return nil }
            if _failingCalls > 0 {
                _failingCalls -= 1
                return nil
            }

            let name = AppleSMCReader.decodeFourCC(input.key)
            var output = AppleSMCReader.SMCParamStruct()
            // 9 = kSMCGetKeyInfo, 5 = kSMCReadKey
            guard let key = keys[name] else {
                output.result = 0x84 // key not found
                if input.data8 == 9 { _keyInfoQueries[name, default: 0] += 1 }
                return output
            }
            switch input.data8 {
            case 9:
                _keyInfoQueries[name, default: 0] += 1
                output.keyInfo.dataSize = UInt32(key.bytes.count)
                output.keyInfo.dataType = AppleSMCReader.fourCC(key.dataType) ?? 0
            case 5:
                withUnsafeMutableBytes(of: &output.bytes) { raw in
                    for (index, byte) in key.bytes.enumerated() {
                        raw[index] = byte
                    }
                }
            default:
                output.result = 0x84
            }
            return output
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
