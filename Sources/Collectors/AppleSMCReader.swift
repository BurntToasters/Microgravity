import Foundation
import IOKit

struct AppleSMCPowerReading: Equatable, Sendable {
    let systemTotalWatts: Double?
    let dcInWatts: Double?
    let batteryWatts: Double?
}

/// Safe read-only AppleSMC IOKit reader. Returns nil cleanly on VMs and unsupported Macs.
enum AppleSMCReader {
    private static let kSMCUserClientOpen: UInt32 = 0
    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCGetKeyInfo: UInt8 = 9

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
        guard MemoryLayout<SMCParamStruct>.size == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, kSMCUserClientOpen, &connection) == KERN_SUCCESS,
              connection != 0 else { return nil }
        defer { IOServiceClose(connection) }

        let systemTotal = firstValidKey(["PSTR"], on: connection)
        let dcIn = firstValidKey(["PDTR"], on: connection)
        let battery = firstValidKey(["PB0R", "PPBR"], on: connection)

        guard systemTotal != nil || dcIn != nil || battery != nil else { return nil }
        return AppleSMCPowerReading(systemTotalWatts: systemTotal, dcInWatts: dcIn, batteryWatts: battery)
    }

    private static func firstValidKey(_ keys: [String], on connection: io_connect_t) -> Double? {
        for key in keys {
            if let value = readNumericKey(key, on: connection), value.isFinite, abs(value) < 500 {
                return value
            }
        }
        return nil
    }

    private static func readNumericKey(_ key: String, on connection: io_connect_t) -> Double? {
        guard let code = fourCC(key) else { return nil }

        var infoInput = SMCParamStruct()
        infoInput.key = code
        infoInput.data8 = kSMCGetKeyInfo
        guard let infoOutput = callSMC(&infoInput, on: connection),
              infoOutput.keyInfo.dataSize > 0,
              infoOutput.keyInfo.dataSize <= 32 else { return nil }

        var readInput = SMCParamStruct()
        readInput.key = code
        readInput.keyInfo.dataSize = infoOutput.keyInfo.dataSize
        readInput.data8 = kSMCReadKey
        guard let readOutput = callSMC(&readInput, on: connection) else { return nil }

        let dataType = decodeFourCC(infoOutput.keyInfo.dataType)
        let size = Int(infoOutput.keyInfo.dataSize)
        let rawBytes = withUnsafeBytes(of: readOutput.bytes) { Array($0.prefix(size)) }
        return decode(dataType: dataType, bytes: rawBytes)
    }

    private static func callSMC(_ input: inout SMCParamStruct, on connection: io_connect_t) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        let status = IOConnectCallStructMethod(
            connection,
            kSMCHandleYPCEvent,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        )
        guard status == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
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
