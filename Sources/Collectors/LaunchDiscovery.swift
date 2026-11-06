import Darwin
import Foundation

struct LaunchDiscoveryResult {
    let startupItems: [DiscoveredEntrySnapshot]
    let services: [DiscoveredEntrySnapshot]
    let startupCoverage: DiscoveryCoverage
    let serviceCoverage: DiscoveryCoverage
    let programPaths: [String: String]
}

enum LaunchDiscovery {
    private struct DirectorySpec {
        let path: String
        let kind: DiscoveredEntryKind
        let isService: Bool
    }

    static func collect(processes: [ProcessSnapshot]) -> LaunchDiscoveryResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [
            DirectorySpec(path: "/System/Library/LaunchAgents", kind: .launchAgent, isService: false),
            DirectorySpec(path: "/Library/LaunchAgents", kind: .launchAgent, isService: false),
            DirectorySpec(path: "\(home)/Library/LaunchAgents", kind: .loginItem, isService: false),
            DirectorySpec(path: "/Library/StartupItems", kind: .loginItem, isService: false),
            DirectorySpec(path: "/System/Library/LaunchDaemons", kind: .launchDaemon, isService: true),
            DirectorySpec(path: "/Library/LaunchDaemons", kind: .launchDaemon, isService: true),
        ]
        let runningPaths = Set(processes.compactMap(\.executablePath))
        var startup: [DiscoveredEntrySnapshot] = []
        var services: [DiscoveredEntrySnapshot] = []
        var startupReasons = ["Launchd loaded/idle state is not exposed by this read-only plist scan.",
                              "Background Task Management login items are not available through a public inventory API."]
        var serviceReasons = ["Launchd loaded/idle state is not exposed by this read-only plist scan."]
        var programPaths: [String: String] = [:]
        var scannedAnyDirectory = false
        var startupHadFailure = false
        var serviceHadFailure = false

        func recordFailure(_ issue: String, isService: Bool) {
            if isService {
                serviceHadFailure = true
                serviceReasons.append(issue)
            } else {
                startupHadFailure = true
                startupReasons.append(issue)
            }
        }

        for directory in directories {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            scannedAnyDirectory = true
            guard let listing = childNames(in: directory.path, maximum: 1_024) else {
                recordFailure("Could not enumerate \(directory.path): \(String(cString: strerror(errno)))",
                              isService: directory.isService)
                continue
            }
            if listing.exceededLimit {
                recordFailure("\(directory.path) exceeded the 1,024-entry scan bound.",
                              isService: directory.isService)
            }
            for name in listing.names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                guard isPropertyListName(name) else { continue }
                let url = URL(fileURLWithPath: directory.path, isDirectory: true).appendingPathComponent(name)
                let data: Data
                let propertyList: [String: Any]
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else {
                        recordFailure("Skipped \(url.path): plist exceeds the 1 MiB read bound.",
                                      isService: directory.isService)
                        continue
                    }
                    data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    guard let dictionary = value as? [String: Any] else {
                        recordFailure("Could not parse \(url.path) as a property-list dictionary.",
                                      isService: directory.isService)
                        continue
                    }
                    propertyList = dictionary
                } catch {
                    recordFailure("Could not read \(url.path): \(error.localizedDescription)",
                                  isService: directory.isService)
                    continue
                }

                let label = propertyList["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
                let program = programPath(from: propertyList)
                let isRunning = program.map(runningPaths.contains) ?? false
                if let program { programPaths[url.path] = program }
                let entry = DiscoveredEntrySnapshot(
                    id: url.path, kind: directory.kind, name: label, path: url.path,
                    ownerUID: ownerUID(at: url.path),
                    state: isRunning ? .running : .unknown,
                    detail: program == nil ? "Program path is not declared." : nil)
                if directory.isService { services.append(entry) }
                else { startup.append(entry) }
            }
        }

        if !scannedAnyDirectory {
            startupReasons.append("No startup-item directories were found.")
            serviceReasons.append("No service directories were found.")
        }
        return LaunchDiscoveryResult(
            startupItems: startup.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            services: services.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            startupCoverage: coverage(hadFailure: startupHadFailure, reasons: startupReasons),
            serviceCoverage: coverage(hadFailure: serviceHadFailure, reasons: serviceReasons),
            programPaths: programPaths)
    }

    static func isPropertyListName(_ name: String) -> Bool {
        (name as NSString).pathExtension.caseInsensitiveCompare("plist") == .orderedSame
    }

    static func coverage(hadFailure: Bool, reasons: [String]) -> DiscoveryCoverage {
        DiscoveryCoverage(complete: !hadFailure, reasons: reasons)
    }

    private static func programPath(from dictionary: [String: Any]) -> String? {
        let program = dictionary["Program"] as? String
        let firstArgument = (dictionary["ProgramArguments"] as? [String])?.first
        guard let value = program ?? firstArgument, value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private static func ownerUID(at path: String) -> UInt32? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return nil }
        return UInt32(metadata.st_uid)
    }

    private static func childNames(in path: String, maximum: Int) -> (names: [String], exceededLimit: Bool)? {
        guard let directory = path.withCString({ opendir($0) }) else { return nil }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = fixedCString(entry.pointee.d_name)
            guard name != ".", name != ".." else { continue }
            names.append(name)
            if names.count > maximum { return (Array(names.prefix(maximum)), true) }
        }
        return (names, false)
    }

    private static func fixedCString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }
}

struct UserDiscoveryResult {
    let users: [UserSessionSnapshot]
    let coverage: DiscoveryCoverage
}

enum PasswordDatabase {
    static func name(for uid: UInt32) -> String? {
        var account = passwd()
        var entry: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: bufferSize)
        return buffer.withUnsafeMutableBufferPointer { bytes -> String? in
            guard let baseAddress = bytes.baseAddress,
                  getpwuid_r(uid_t(uid), &account, baseAddress, bytes.count, &entry) == 0,
                  let entry else { return nil }
            return String(cString: entry.pointee.pw_name)
        }
    }

    static func uid(for name: String) -> UInt32? {
        return name.withCString { username -> UInt32? in
            var account = passwd()
            var entry: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let status = buffer.withUnsafeMutableBufferPointer { bytes -> Int32 in
                guard let baseAddress = bytes.baseAddress else { return ERANGE }
                return getpwnam_r(username, &account, baseAddress, bytes.count, &entry)
            }
            guard status == 0, entry != nil else { return nil }
            return UInt32(account.pw_uid)
        }
    }

    private static var bufferSize: Int {
        let suggested = sysconf(_SC_GETPW_R_SIZE_MAX)
        return suggested > 0 ? min(max(Int(suggested), 4_096), 1_048_576) : 4_096
    }
}

enum UserDiscovery {
    static func collect() -> UserDiscoveryResult {
        var sessions: [UInt32: Set<String>] = [:]
        var names: [UInt32: String] = [:]
        var scannedRecords = 0
        let sessionRecordLimit = 4_096
        setutxent()
        while let entry = getutxent() {
            scannedRecords += 1
            if scannedRecords > sessionRecordLimit { break }
            let record = entry.pointee
            guard record.ut_type == USER_PROCESS else { continue }
            let username = fixedString(record.ut_user)
            guard !username.isEmpty, let uid = PasswordDatabase.uid(for: username),
                  let name = PasswordDatabase.name(for: uid) else { continue }
            let terminal = fixedString(record.ut_line)
            sessions[uid, default: []].insert(terminal.isEmpty ? "login-session" : terminal)
            names[uid] = name
        }
        endutxent()

        let currentUID = UInt32(getuid())
        if let currentName = PasswordDatabase.name(for: currentUID) { names[currentUID] = currentName }
        if sessions[currentUID] == nil { sessions[currentUID] = [] }

        let users = sessions.keys.sorted().compactMap { uid -> UserSessionSnapshot? in
            guard let name = names[uid] else { return nil }
            return UserSessionSnapshot(uid: uid, shortName: name, isCurrentUser: uid == currentUID,
                                       loginSessions: (sessions[uid] ?? []).sorted())
        }
        var reasons = ["utmpx reports terminal login sessions; Fast User Switching and GUI session state may be incomplete."]
        if scannedRecords > sessionRecordLimit { reasons.append("utmpx scan reached the 4,096-record bound.") }
        return UserDiscoveryResult(users: users, coverage: DiscoveryCoverage(complete: false, reasons: reasons))
    }

    private static func fixedString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }
}
