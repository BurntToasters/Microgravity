import Foundation
import IOKit

struct AppleSMCPowerReading: Equatable, Sendable {
    let systemTotalWatts: Double?
    let dcInWatts: Double?
    let batteryWatts: Double?
}

/// Safe read-only AppleSMC IOKit reader. Returns nil cleanly on VMs and unsupported Macs.
///
/// The connection and key caches live in one shared `AppleSMCSession`, so a tick does not open the
/// service or re-query key info. Any failed IOKit call closes the connection and clears the caches;
/// the next tick reopens.
enum AppleSMCReader {
    fileprivate static let kSMCUserClientOpen: UInt32 = 0
    fileprivate static let kSMCHandleYPCEvent: UInt32 = 2
    fileprivate static let kSMCReadKey: UInt8 = 5
    fileprivate static let kSMCGetKeyInfo: UInt8 = 9

    fileprivate static let sharedSession = AppleSMCSession(transport: IOKitAppleSMCTransport())

    struct KeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var pad0: UInt8 = 0
        var pad1: UInt8 = 0
        var pad2: UInt8 = 0
    }

    struct VersData {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
        var pad: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    /// Binary layout expected by the kernel `AppleSMC` user client (80 bytes).
    struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = VersData()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfoData()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var padAfterData8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    static var paramStructSize: Int { MemoryLayout<SMCParamStruct>.size }
    static var bytesOffset: Int? { MemoryLayout<SMCParamStruct>.offset(of: \.bytes) }

    static func readPower() -> AppleSMCPowerReading? {
        sharedSession.readPower()
    }

    static func fourCC(_ string: String) -> UInt32? {
        let utf8 = Array(string.utf8)
        guard utf8.count == 4 else { return nil }
        return (UInt32(utf8[0]) << 24)
            | (UInt32(utf8[1]) << 16)
            | (UInt32(utf8[2]) << 8)
            | UInt32(utf8[3])
    }

    static func decodeFourCC(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    static func decode(dataType: String, bytes: [UInt8]) -> Double? {
        let normalized = dataType.trimmingCharacters(in: .whitespaces)
        switch normalized {
        case "flt":
            guard bytes.count == 4 else { return nil }
            let bits = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil

        case "ui8":
            guard bytes.count == 1 else { return nil }
            return Double(bytes[0])

        case "ui16":
            guard bytes.count == 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))

        case "ui32":
            guard bytes.count == 4 else { return nil }
            let raw = (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
            return Double(raw)

        default:
            // Standard AppleSMC 16-bit big-endian fixed-point tokens: `spXY` (signed) and `fpXY` (unsigned).
            guard bytes.count == 2, normalized.count == 4 else { return nil }
            let chars = Array(normalized)
            let prefix = String(chars.prefix(2))
            guard prefix == "sp" || prefix == "fp",
                  let fracBits = Int(String(chars[3]), radix: 16),
                  fracBits >= 0 else { return nil }
            let scale = Double(1 << fracBits)
            let unsigned = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            if prefix == "sp" {
                let signed = Int16(bitPattern: unsigned)
                return Double(signed) / scale
            } else {
                return Double(unsigned) / scale
            }
        }
    }
}

/// Raw access to the AppleSMC user client. The IOKit implementation is the only production conformer;
/// tests substitute a fake to exercise the connection and cache logic without hardware.
protocol AppleSMCTransport: Sendable {
    /// Returns a valid connection, or nil when the AppleSMC service cannot be opened.
    func open() -> io_connect_t?
    func close(_ connection: io_connect_t)
    /// Returns the kernel output, or nil when the IOKit call itself failed. SMC-level status is in `result`.
    func call(_ connection: io_connect_t, input: AppleSMCReader.SMCParamStruct) -> AppleSMCReader.SMCParamStruct?
}

struct IOKitAppleSMCTransport: AppleSMCTransport {
    func open() -> io_connect_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, AppleSMCReader.kSMCUserClientOpen, &connection) == KERN_SUCCESS,
              connection != 0 else { return nil }
        return connection
    }

    func close(_ connection: io_connect_t) {
        IOServiceClose(connection)
    }

    func call(_ connection: io_connect_t, input: AppleSMCReader.SMCParamStruct) -> AppleSMCReader.SMCParamStruct? {
        var input = input
        var output = AppleSMCReader.SMCParamStruct()
        var outputSize = MemoryLayout<AppleSMCReader.SMCParamStruct>.size
        let status = IOConnectCallStructMethod(
            connection,
            AppleSMCReader.kSMCHandleYPCEvent,
            &input,
            MemoryLayout<AppleSMCReader.SMCParamStruct>.size,
            &output,
            &outputSize
        )
        guard status == KERN_SUCCESS else { return nil }
        return output
    }
}

/// An IOKit call failed, or an SMC read failed for a key whose info was already known.
fileprivate struct SMCConnectionFailure: Error {}

/// Owns one AppleSMC connection and the key caches that belong to it. Every access is guarded by a lock
/// because the power collector can run on more than one queue.
final class AppleSMCSession: @unchecked Sendable {
    private let transport: any AppleSMCTransport
    private let lock = NSLock()
    private var connection: io_connect_t?
    private var keyInfoCache: [String: AppleSMCReader.KeyInfoData] = [:]
    /// The battery key (`PB0R` or `PPBR`) that answered last time; nil until one does.
    private var batteryKey: String?

    init(transport: any AppleSMCTransport) {
        self.transport = transport
    }

    func readPower() -> AppleSMCPowerReading? {
        lock.lock()
        defer { lock.unlock() }
        guard AppleSMCReader.paramStructSize == 80 else { return nil }

        do {
            let connection = try openConnectionLocked()
            let systemTotal = try validatedValue(for: "PSTR", connection: connection)
            let dcIn = try validatedValue(for: "PDTR", connection: connection)
            let battery = try batteryValue(connection: connection)

            guard systemTotal != nil || dcIn != nil || battery != nil else { return nil }
            return AppleSMCPowerReading(systemTotalWatts: systemTotal, dcInWatts: dcIn, batteryWatts: battery)
        } catch {
            resetLocked()
            return nil
        }
    }

    private func openConnectionLocked() throws -> io_connect_t {
        if let connection { return connection }
        guard let opened = transport.open() else { throw SMCConnectionFailure() }
        connection = opened
        return opened
    }

    /// Closes the connection and forgets everything that was learned through it.
    private func resetLocked() {
        if let connection {
            transport.close(connection)
        }
        connection = nil
        keyInfoCache.removeAll()
        batteryKey = nil
    }

    private func batteryValue(connection: io_connect_t) throws -> Double? {
        let candidates = batteryKey.map { [$0] } ?? ["PB0R", "PPBR"]
        for key in candidates {
            if let value = try validatedValue(for: key, connection: connection) {
                batteryKey = key
                return value
            }
        }
        // The cached key stopped answering; probe both candidates again on the next tick.
        batteryKey = nil
        return nil
    }

    private func validatedValue(for key: String, connection: io_connect_t) throws -> Double? {
        guard let value = try numericValue(for: key, connection: connection),
              value.isFinite, abs(value) < 500 else { return nil }
        return value
    }

    private func numericValue(for key: String, connection: io_connect_t) throws -> Double? {
        guard let code = AppleSMCReader.fourCC(key) else { return nil }

        let info: AppleSMCReader.KeyInfoData
        if let cached = keyInfoCache[key] {
            info = cached
        } else {
            var infoInput = AppleSMCReader.SMCParamStruct()
            infoInput.key = code
            infoInput.data8 = AppleSMCReader.kSMCGetKeyInfo
            let infoOutput = try call(infoInput, connection: connection)
            // A non-zero SMC result means this Mac has no such key. That is normal (PB0R vs PPBR),
            // so it reports nil for this key without tearing down the connection.
            guard infoOutput.result == 0,
                  infoOutput.keyInfo.dataSize > 0,
                  infoOutput.keyInfo.dataSize <= 32 else { return nil }
            info = infoOutput.keyInfo
            keyInfoCache[key] = info
        }

        var readInput = AppleSMCReader.SMCParamStruct()
        readInput.key = code
        readInput.keyInfo.dataSize = info.dataSize
        readInput.data8 = AppleSMCReader.kSMCReadKey
        let readOutput = try call(readInput, connection: connection)
        // The key was known to exist, so a rejected read is a failed call.
        guard readOutput.result == 0 else { throw SMCConnectionFailure() }

        let dataType = AppleSMCReader.decodeFourCC(info.dataType)
        let size = Int(info.dataSize)
        let rawBytes = withUnsafeBytes(of: readOutput.bytes) { Array($0.prefix(size)) }
        return AppleSMCReader.decode(dataType: dataType, bytes: rawBytes)
    }

    private func call(_ input: AppleSMCReader.SMCParamStruct, connection: io_connect_t) throws -> AppleSMCReader.SMCParamStruct {
        guard let output = transport.call(connection, input: input) else { throw SMCConnectionFailure() }
        return output
    }
}
