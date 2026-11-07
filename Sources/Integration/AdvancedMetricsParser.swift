import CoreFoundation
import Foundation

// Schemas are intentionally narrow; absent or invalid measurements stay unavailable.
enum AdvancedMetricsParser {
    static let maximumBytes = 4 * 1024 * 1024
    private struct NettopSchema {
        let columnCount: Int
        let processIndex: Int
        let receiveIndex: Int
        let sendIndex: Int
    }
    struct NetworkTotals: Equatable {
        let received: UInt64
        let sent: UInt64
    }
    struct Power {
        let watts: Double?
        let gpuPercent: Double?
        let processGPUSeconds: [Int32: Double]
    }
    static func hasNettopHeader(_ input: String) -> Bool {
        guard input.utf8.count <= maximumBytes, let first = input.split(whereSeparator: \.isNewline).first else { return false }
        return nettopSchema(String(first)) != nil
    }
    static func nettop(_ input: String) -> [Int32: NetworkTotals] {
        guard input.utf8.count <= maximumBytes else { return [:] }
        let lines = input.split(whereSeparator: \.isNewline)
        guard let first = lines.first else { return [:] }
        guard let schema = nettopSchema(String(first)) else { return [:] }
        var result: [Int32: NetworkTotals] = [:]
        var ambiguous = Set<Int32>()
        var seen = Set<Int32>()
        for line in lines.dropFirst() {
            guard let columns = normalizedNettopRowColumns(csv(String(line)), expectedCount: schema.columnCount),
                  let suffix = columns[schema.processIndex].split(separator: ".").last,
                  let pid = Int32(suffix), pid > 0 else { continue }
            guard seen.insert(pid).inserted else {
                result.removeValue(forKey: pid); ambiguous.insert(pid); continue
            }
            guard !ambiguous.contains(pid), let received = UInt64(columns[schema.receiveIndex]),
                  let sent = UInt64(columns[schema.sendIndex]) else { continue }
            result[pid] = NetworkTotals(received: received, sent: sent)
        }
        return result
    }
    private static func nettopSchema(_ line: String) -> NettopSchema? {
        let header = normalizedNettopHeaderColumns(csv(line))
        guard !header.isEmpty else { return nil }
        if header[0].isEmpty {
            guard header == ["", "bytes_in", "bytes_out"] else { return nil }
            return NettopSchema(columnCount: header.count, processIndex: 0, receiveIndex: 1, sendIndex: 2)
        }
        guard header.allSatisfy({ !$0.isEmpty }), Set(header).count == header.count,
              let processIndex = header.firstIndex(of: "interface"),
              let receiveIndex = header.firstIndex(of: "bytes_in"),
              let sendIndex = header.firstIndex(of: "bytes_out") else { return nil }
        return NettopSchema(columnCount: header.count, processIndex: processIndex,
                            receiveIndex: receiveIndex, sendIndex: sendIndex)
    }
    private static func normalizedNettopHeaderColumns(_ columns: [String]) -> [String] {
        guard columns.last == "" else { return columns }
        return Array(columns.dropLast())
    }
    private static func normalizedNettopRowColumns(_ columns: [String], expectedCount: Int) -> [String]? {
        if columns.count == expectedCount { return columns }
        guard columns.count == expectedCount + 1, columns.last == "" else { return nil }
        return Array(columns.dropLast())
    }
    private static func csv(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var closed = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if quoted {
                if character == "\"" {
                    let next = line.index(after: index)
                    if next < line.endIndex && line[next] == "\"" { field.append("\""); index = next }
                    else { quoted = false; closed = true }
                } else { field.append(character) }
            } else if character == "," {
                fields.append(field); field = ""; closed = false
            } else if character == "\"" && field.isEmpty && !closed { quoted = true }
            else if closed || character == "\"" { return [] }
            else { field.append(character) }
            index = line.index(after: index)
        }
        guard !quoted else { return [] }
        fields.append(field)
        return fields
    }
    static func power(_ data: Data) -> Power {
        let empty = Power(watts: nil, gpuPercent: nil, processGPUSeconds: [:])
        guard data.count <= maximumBytes else { return empty }
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        guard let last = records.last,
              let object = try? PropertyListSerialization.propertyList(from: Data(last), options: [], format: nil),
              let root = object as? [String: Any] else { return empty }
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let result = value.doubleValue
            return result.isFinite && result >= 0 ? result : nil
        }
        let gpu = root["gpu"] as? [String: Any]
        let ratio = number(gpu?["idle_ratio"])
        let percent = ratio.flatMap { $0 <= 1 ? (1 - $0) * 100 : nil }
        let processor = root["processor"] as? [String: Any] ?? [:]
        var watts: Double?
        if let cpu = number(processor["cpu_power_mw"]), let gpu = number(processor["gpu_power_mw"]),
           let ane = number(processor["ane_power_mw"]), (cpu + gpu + ane).isFinite {
            watts = (cpu + gpu + ane) / 1000
        }
        var tasks: [Int32: Double] = [:]
        var seen = Set<Int32>()
        var ambiguous = Set<Int32>()
        for task in root["tasks"] as? [[String: Any]] ?? [] {
            guard let rawPID = number(task["pid"]), rawPID.rounded() == rawPID,
                  rawPID > 0, rawPID <= Double(Int32.max) else { continue }
            let pid = Int32(rawPID)
            guard seen.insert(pid).inserted else { tasks.removeValue(forKey: pid); ambiguous.insert(pid); continue }
            guard !(task["gpu_time_ms"] != nil && task["gpu_time_ns"] != nil) else { continue }
            let millis = number(task["gpu_time_ms"])
            let nanos = number(task["gpu_time_ns"])
            guard (millis == nil) != (nanos == nil), !ambiguous.contains(pid) else { continue }
            tasks[pid] = millis.map { $0 / 1_000 } ?? nanos.map { $0 / 1_000_000_000 }
        }
        return Power(watts: watts, gpuPercent: percent, processGPUSeconds: tasks)
    }
}
