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

        for directory in directories {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            scannedAnyDirectory = true
            guard let listing = childNames(in: directory.path, maximum: 1_024) else {
                let issue = "Could not enumerate \(directory.path): \(String(cString: strerror(errno)))"
                if directory.isService { serviceReasons.append(issue) }
                else { startupReasons.append(issue) }
                continue
            }
            if listing.exceededLimit {
                if directory.isService { serviceReasons.append("\(directory.path) exceeded the 1,024-entry scan bound.") }
                else { startupReasons.append("\(directory.path) exceeded the 1,024-entry scan bound.") }
            }
            for name in listing.names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                    let url = URL(fileURLWithPath: directory.path, isDirectory: true).appendingPathComponent(name)
                    guard url.pathExtension == "plist" else { continue }
                    let data: Data
                    let propertyList: [String: Any]
                    do {
                        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else {
                            let issue = "Skipped \(url.path): plist exceeds the 1 MiB read bound."
                            if directory.isService { serviceReasons.append(issue) }
                            else { startupReasons.append(issue) }
                            continue
                        }
                        data = try Data(contentsOf: url, options: [.mappedIfSafe])
                        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                        guard let dictionary = value as? [String: Any] else { continue }
                        propertyList = dictionary
                    } catch {
                        let issue = "Could not read \(url.path): \(error.localizedDescription)"
                        if directory.isService { serviceReasons.append(issue) }
                        else { startupReasons.append(issue) }
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
            startupReasons.append("No startup-item directories were readable.")
            serviceReasons.append("No service directories were readable.")
        }
        return LaunchDiscoveryResult(
            startupItems: startup.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            services: services.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            startupCoverage: DiscoveryCoverage(complete: false, reasons: startupReasons),
            serviceCoverage: DiscoveryCoverage(complete: false, reasons: serviceReasons),
            programPaths: programPaths)
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
            guard !username.isEmpty, let account = getpwnam(username) else { continue }
            let uid = UInt32(account.pointee.pw_uid)
            let terminal = fixedString(record.ut_line)
            sessions[uid, default: []].insert(terminal.isEmpty ? "login-session" : terminal)
            names[uid] = String(cString: account.pointee.pw_name)
        }
        endutxent()

        let currentUID = UInt32(getuid())
        if let currentAccount = getpwuid(uid_t(currentUID)) {
            names[currentUID] = String(cString: currentAccount.pointee.pw_name)
        }
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
