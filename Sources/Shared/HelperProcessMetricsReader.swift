import Darwin
import Foundation

/// Read-only privileged reader running inside `MicrogravityHelper` for non-caller PIDs.
enum HelperProcessMetricsReader {
    static let maximumPIDCount = 4096

    static func collect(excludingUID: uid_t?, maximumCount: Int = maximumPIDCount) -> HelperProcessMetricsPayload {
        guard let entries = readProcessTable(maximumCount: maximumCount) else {
            return HelperProcessMetricsPayload(entries: [])
        }
        var timebaseInfo = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebaseInfo) == KERN_SUCCESS, timebaseInfo.denom > 0 else {
            return HelperProcessMetricsPayload(entries: [])
        }
        let timebase = (numer: UInt64(timebaseInfo.numer), denom: UInt64(timebaseInfo.denom))

        var results: [HelperProcessMetricEntry] = []
        results.reserveCapacity(entries.count)

        for entry in entries {
            let pid = entry.kp_proc.p_pid
            guard pid > 0, Int32(entry.kp_proc.p_stat) != SZOMB else { continue }
            let uid = entry.kp_eproc.e_ucred.cr_uid
            if let excludingUID, uid == excludingUID { continue }

            let startSeconds = Int64(entry.kp_proc.p_un.__p_starttime.tv_sec)
            let startMicroseconds = Int32(entry.kp_proc.p_un.__p_starttime.tv_usec)

            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let taskBytes = withUnsafeMutablePointer(to: &task) {
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, taskSize)
            }
            let hasTask = taskBytes == taskSize

            var usage = rusage_info_v4()
            let rusageStatus = withUnsafeMutableBytes(of: &usage) { bytes in
                proc_pid_rusage(pid, RUSAGE_INFO_V4,
                                bytes.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
            }
            let hasUsage = rusageStatus == 0

            let path = processPath(pid)

            // Revalidate start time after inspecting the PID so metrics cannot cross PID reuse.
            guard revalidate(pid: pid, expectedSeconds: startSeconds, expectedMicroseconds: startMicroseconds) else {
                continue
            }
            guard hasTask || hasUsage || path != nil else { continue }

            let cpuNanos: UInt64? = hasTask
                ? nanoseconds(fromMachTicks: task.pti_total_user &+ task.pti_total_system, timebase: timebase)
                : nil

            results.append(HelperProcessMetricEntry(
                pid: pid,
                startSeconds: startSeconds,
                startMicroseconds: startMicroseconds,
                cpuTotalNanoseconds: cpuNanos,
                memoryBytes: hasUsage ? usage.ri_phys_footprint : (hasTask ? task.pti_resident_size : nil),
                diskReadBytes: hasUsage ? usage.ri_diskio_bytesread : nil,
                diskWriteBytes: hasUsage ? usage.ri_diskio_byteswritten : nil,
                threadCount: hasTask ? task.pti_threadnum : nil,
                executablePath: path
            ))
        }

        return HelperProcessMetricsPayload(entries: results)
    }

    private static func readProcessTable(maximumCount: Int) -> [kinfo_proc]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let entrySize = MemoryLayout<kinfo_proc>.stride
        for attempt in 1...4 {
            var estimatedBytes = 0
            let sizeStatus = mib.withUnsafeMutableBufferPointer { name in
                sysctl(name.baseAddress, u_int(name.count), nil, &estimatedBytes, nil, 0)
            }
            guard sizeStatus == 0 else { return nil }
            let estimated = estimatedBytes / entrySize
            let capacity = min(max(estimated + estimated / 8 + 64, 64), min(max(1, maximumCount), maximumPIDCount))
            var table = Array(repeating: kinfo_proc(), count: capacity)
            var bytes = capacity * entrySize
            let readStatus = table.withUnsafeMutableBytes { buffer in
                mib.withUnsafeMutableBufferPointer { name in
                    sysctl(name.baseAddress, u_int(name.count), buffer.baseAddress, &bytes, nil, 0)
                }
            }
            if readStatus != 0 {
                if errno == ENOMEM, attempt < 4 { continue }
                return nil
            }
            let filled = min(bytes / entrySize, capacity)
            return Array(table.prefix(filled))
        }
        return nil
    }

    private static func revalidate(pid: pid_t, expectedSeconds: Int64, expectedMicroseconds: Int32) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var entry = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let status = mib.withUnsafeMutableBufferPointer { name in
            sysctl(name.baseAddress, u_int(name.count), &entry, &size, nil, 0)
        }
        guard status == 0, size == MemoryLayout<kinfo_proc>.size, entry.kp_proc.p_pid == pid else { return false }
        return Int64(entry.kp_proc.p_un.__p_starttime.tv_sec) == expectedSeconds
            && Int32(entry.kp_proc.p_un.__p_starttime.tv_usec) == expectedMicroseconds
    }

    private static func processPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let size = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard size > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
    }

    private static func nanoseconds(fromMachTicks ticks: UInt64, timebase: (numer: UInt64, denom: UInt64)) -> UInt64 {
        let whole = ticks / timebase.denom
        let remainder = ticks % timebase.denom
        let (wholeNanos, wholeOverflow) = whole.multipliedReportingOverflow(by: timebase.numer)
        let (remainderNanos, remainderOverflow) = remainder.multipliedReportingOverflow(by: timebase.numer)
        guard !wholeOverflow, !remainderOverflow else { return UInt64.max }
        let (total, totalOverflow) = wholeNanos.addingReportingOverflow(remainderNanos / timebase.denom)
        return totalOverflow ? UInt64.max : total
    }
}
