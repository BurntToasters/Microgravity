import Darwin
import Foundation

struct NetworkInterfaceCounter: Equatable, Sendable {
    /// Name prefixes of loopback, tunnel, and virtual interfaces. Their traffic is either
    /// the same packets counted again on a physical interface (utun, bridge, gif, stf) or
    /// internal to the machine (lo, loopback-style links); they never count toward system totals.
    static let virtualNamePrefixes = ["lo", "utun", "gif", "stf", "anpi", "awdl", "llw", "bridge", "ap", "p2p"]

    // ifi_type values from net/if_types.h (IFT_LOOPBACK, IFT_GIF, IFT_STF, IFT_BRIDGE).
    static let virtualInterfaceTypes: Set<UInt8> = [0x18, 0x37, 0x39, 0xd1]

    let name: String
    let isUp: Bool
    let isLoopback: Bool
    let interfaceType: UInt8
    let receiveBytes: UInt64
    let transmitBytes: UInt64

    var includedInTotals: Bool {
        if isLoopback || Self.virtualInterfaceTypes.contains(interfaceType) { return false }
        return !Self.virtualNamePrefixes.contains { name.hasPrefix($0) }
    }
}

enum NetworkInterfaceReaderError: Error, Equatable, CustomStringConvertible {
    case sysctlFailed(Int32)
    case invalidLength
    case bufferTooLarge(Int)
    case routeListChanged
    case malformedMessage(offset: Int, reason: String)

    var description: String {
        switch self {
        case let .sysctlFailed(code): return "sysctl NET_RT_IFLIST2 failed with errno \(code)"
        case .invalidLength: return "sysctl NET_RT_IFLIST2 returned an empty or invalid buffer"
        case let .bufferTooLarge(size): return "sysctl NET_RT_IFLIST2 requires \(size) bytes; safety limit is 16777216 bytes"
        case .routeListChanged: return "network interface list changed repeatedly during collection"
        case let .malformedMessage(offset, reason): return "malformed network route message at byte \(offset): \(reason)"
        }
    }
}

enum NetworkInterfaceReader {
    private static let maximumBufferSize = 16 * 1024 * 1024
    private static let maximumReadAttempts = 3

    static func read() throws -> [NetworkInterfaceCounter] {
        try parse(routeListData(), interfaceName: interfaceName(for:))
    }

    static func parse(_ data: Data, interfaceName: (UInt16) -> String?) throws -> [NetworkInterfaceCounter] {
        guard !data.isEmpty else {
            throw NetworkInterfaceReaderError.malformedMessage(offset: 0, reason: "empty route buffer")
        }

        var records: [UInt16: NetworkInterfaceCounter] = [:]
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) throws in
            var offset = 0
            while offset < bytes.count {
                let remaining = bytes.count - offset
                guard remaining >= 4, let baseAddress = bytes.baseAddress else {
                    throw NetworkInterfaceReaderError.malformedMessage(offset: offset, reason: "truncated message header")
                }

                var rawMessageLength: UInt16 = 0
                memcpy(&rawMessageLength, baseAddress.advanced(by: offset), MemoryLayout<UInt16>.size)
                let messageLength = Int(rawMessageLength)
                guard messageLength > 0 else {
                    throw NetworkInterfaceReaderError.malformedMessage(offset: offset, reason: "zero-length message")
                }
                guard messageLength >= 4, messageLength <= remaining else {
                    throw NetworkInterfaceReaderError.malformedMessage(offset: offset, reason: "message length exceeds available bytes")
                }

                let messageType = bytes[offset + 3]
                if messageType == UInt8(RTM_IFINFO2) {
                    let headerSize = MemoryLayout<if_msghdr2>.size
                    guard messageLength >= headerSize else {
                        throw NetworkInterfaceReaderError.malformedMessage(offset: offset, reason: "truncated if_msghdr2")
                    }

                    var header = if_msghdr2()
                    withUnsafeMutableBytes(of: &header) { destination in
                        destination.copyMemory(from: UnsafeRawBufferPointer(
                            start: baseAddress.advanced(by: offset), count: headerSize))
                    }
                    guard header.ifm_version == UInt8(RTM_VERSION) else {
                        throw NetworkInterfaceReaderError.malformedMessage(offset: offset, reason: "unsupported route message version")
                    }

                    if header.ifm_index != 0, let name = interfaceName(header.ifm_index), !name.isEmpty {
                        records[header.ifm_index] = NetworkInterfaceCounter(
                            name: name,
                            isUp: header.ifm_flags & Int32(IFF_UP) != 0,
                            isLoopback: header.ifm_flags & Int32(IFF_LOOPBACK) != 0,
                            interfaceType: header.ifm_data.ifi_type,
                            receiveBytes: header.ifm_data.ifi_ibytes,
                            transmitBytes: header.ifm_data.ifi_obytes)
                    }
                }

                offset += messageLength
            }
        }

        return records.values.sorted { $0.name < $1.name }
    }

    private static func routeListData() throws -> Data {
        for attempt in 0..<maximumReadAttempts {
            var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
            var requiredLength = 0
            let sizeStatus = mib.withUnsafeMutableBufferPointer { buffer in
                sysctl(buffer.baseAddress, u_int(buffer.count), nil, &requiredLength, nil, 0)
            }
            guard sizeStatus == 0 else { throw NetworkInterfaceReaderError.sysctlFailed(errno) }
            guard requiredLength > 0 else { throw NetworkInterfaceReaderError.invalidLength }
            guard requiredLength <= maximumBufferSize else {
                throw NetworkInterfaceReaderError.bufferTooLarge(requiredLength)
            }

            var data = Data(count: requiredLength)
            var actualLength = requiredLength
            let readStatus = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                mib.withUnsafeMutableBufferPointer { mibBuffer in
                    sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count), buffer.baseAddress,
                           &actualLength, nil, 0)
                }
            }
            if readStatus == 0 {
                guard actualLength >= 0, actualLength <= data.count else {
                    if attempt + 1 < maximumReadAttempts { continue }
                    throw NetworkInterfaceReaderError.routeListChanged
                }
                guard actualLength > 0 else { throw NetworkInterfaceReaderError.invalidLength }
                data.removeSubrange(actualLength..<data.count)
                return data
            }

            let errorCode = errno
            if errorCode == ENOMEM, attempt + 1 < maximumReadAttempts { continue }
            throw NetworkInterfaceReaderError.sysctlFailed(errorCode)
        }

        throw NetworkInterfaceReaderError.routeListChanged
    }

    private static func interfaceName(for index: UInt16) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        guard if_indextoname(UInt32(index), &buffer) != nil else { return nil }
        return String(cString: buffer)
    }
}

struct NetworkInterfaceCollection {
    let receiveRate: MetricReading
    let transmitRate: MetricReading
    let interfaces: [NetworkInterfaceSnapshot]
}

struct NetworkInterfaceCounterTracker {
    private enum CounterKey: Hashable {
        case receive(String)
        case transmit(String)
    }

    private var counters = CounterDeltaTracker<CounterKey>()

    mutating func collect(_ records: [NetworkInterfaceCounter], at timestamp: Date) -> NetworkInterfaceCollection {
        let byName = Dictionary(records.map { ($0.name, $0) }, uniquingKeysWith: { _, newest in newest })
        let activeNames = Set(byName.keys)
        let activeKeys = Set(activeNames.flatMap { [CounterKey.receive($0), CounterKey.transmit($0)] })
        counters.retain(activeKeys)

        guard !byName.isEmpty else {
            counters.removeAll()
            let unavailable = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                            reason: .collectionFailed, detail: "No network interface counters found")
            return NetworkInterfaceCollection(receiveRate: unavailable, transmitRate: unavailable, interfaces: [])
        }

        let interfaces = byName.keys.sorted().map { name -> NetworkInterfaceSnapshot in
            let data = byName[name]!
            let receiveResult = counters.update(data.receiveBytes, for: .receive(name), at: timestamp)
            let transmitResult = counters.update(data.transmitBytes, for: .transmit(name), at: timestamp)
            return NetworkInterfaceSnapshot(
                name: name, isUp: data.isUp,
                receiveBytesPerSecond: receiveResult.reading(unit: .bytesPerSecond, timestamp: timestamp) {
                    Double($0) / $1
                },
                transmitBytesPerSecond: transmitResult.reading(unit: .bytesPerSecond, timestamp: timestamp) {
                    Double($0) / $1
                },
                receiveTotalBytes: MetricReading(value: Double(data.receiveBytes), unit: .bytes, timestamp: timestamp),
                transmitTotalBytes: MetricReading(value: Double(data.transmitBytes), unit: .bytes, timestamp: timestamp),
                includedInTotals: data.includedInTotals)
        }
        let totalled = interfaces.filter(\.includedInTotals)
        guard !totalled.isEmpty else {
            let unavailable = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                            reason: .collectionFailed,
                                            detail: "No physical network interfaces found for system totals")
            return NetworkInterfaceCollection(receiveRate: unavailable, transmitRate: unavailable,
                                              interfaces: interfaces)
        }
        let receiveRate = SystemMonitorCollector.combineRates(totalled.map(\.receiveBytesPerSecond),
                                                             unit: .bytesPerSecond, timestamp: timestamp)
        let transmitRate = SystemMonitorCollector.combineRates(totalled.map(\.transmitBytesPerSecond),
                                                              unit: .bytesPerSecond, timestamp: timestamp)
        return NetworkInterfaceCollection(receiveRate: receiveRate, transmitRate: transmitRate,
                                          interfaces: interfaces)
    }

    mutating func clear() {
        counters.removeAll()
    }
}
