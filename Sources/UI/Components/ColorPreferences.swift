import AppKit

extension Notification.Name {
    /// Posted after a customized color is set, reset, or restored to defaults. Performance, Processes and Settings observe it.
    static let colorPreferencesDidChange = Notification.Name("Microgravity.colorPreferencesDidChange")
}

/// A hue the user can customize. Metric roles tint graphs, rail sparklines and Processes heat fills.
/// Processor-type roles name the core clusters in CPU detail.
enum ColorRole: String, CaseIterable {
    case cpu
    case memory
    case disk
    case network
    case gpu
    case energy
    case superCores
    case performanceCores
    case efficiencyCores

    var title: String {
        switch self {
        case .cpu: return String(localized: "CPU")
        case .memory: return String(localized: "Memory")
        case .disk: return String(localized: "Disk")
        case .network: return String(localized: "Network")
        case .gpu: return String(localized: "GPU")
        case .energy: return String(localized: "Energy")
        case .superCores: return String(localized: "Super cores")
        case .performanceCores: return String(localized: "Performance cores")
        case .efficiencyCores: return String(localized: "Efficiency cores")
        }
    }

    /// Lowercase, hyphenated suffix for accessibility identifiers such as `settings.color.super-cores`. Never localized.
    var identifierSuffix: String {
        switch self {
        case .superCores: return "super-cores"
        case .performanceCores: return "performance-cores"
        case .efficiencyCores: return "efficiency-cores"
        default: return rawValue
        }
    }

    /// The dynamic system color used until the user picks one, so Light and Dark still adapt.
    var defaultColor: NSColor {
        switch self {
        case .cpu: return .systemBlue
        case .memory: return .systemPurple
        case .disk: return .systemGreen
        case .network: return .systemOrange
        case .gpu: return .systemTeal
        case .energy: return .systemYellow
        case .superCores: return .systemPink
        case .performanceCores: return .systemBlue
        case .efficiencyCores: return .systemGreen
        }
    }
}

/// User-chosen colors for graphs, heat maps and processor types.
///
/// Custom colors live under one defaults key as `[role rawValue: "#RRGGBB" or "#RRGGBBAA"]`, in sRGB.
/// Unknown roles and malformed hex values are ignored, so a bad entry falls back to the default color.
@MainActor
enum ColorPreferences {
    static let defaultsKey = "appearance.colors"

    /// Tests assign an isolated suite here and restore the previous value when they finish. Nil uses the app domain.
    static var defaultsOverride: UserDefaults?

    /// Same domain choice as `AppearancePreference`: the fixture suite in DEBUG fixture runs, otherwise `.standard`.
    private static var defaults: UserDefaults {
        defaultsOverride ?? appDefaults
    }

    private static var appDefaults: UserDefaults {
        #if DEBUG
        if let suite = AppComposition.fixtureDefaultsSuiteForCleanup,
           let fixtureDefaults = UserDefaults(suiteName: suite) {
            return fixtureDefaults
        }
        #endif
        return .standard
    }

    /// The custom color when one is stored, otherwise the role's dynamic system default.
    static func color(for role: ColorRole) -> NSColor {
        guard let hex = storedHexStrings()[role], let color = color(hex: hex) else { return role.defaultColor }
        return color
    }

    static func isCustomized(_ role: ColorRole) -> Bool {
        storedHexStrings()[role] != nil
    }

    /// Stores `color` as sRGB. A color that cannot be converted to sRGB (for example a pattern) is ignored.
    static func setColor(_ color: NSColor, for role: ColorRole) {
        guard let hex = hexString(for: color) else { return }
        var entries = storedHexStrings()
        entries[role] = hex
        save(entries)
    }

    static func resetColor(for role: ColorRole) {
        var entries = storedHexStrings()
        guard entries.removeValue(forKey: role) != nil else { return }
        save(entries)
    }

    /// Removes every custom color, including malformed entries left in the defaults key.
    static func resetAll() {
        guard defaults.object(forKey: defaultsKey) != nil else { return }
        save([:])
    }

    // MARK: Hex

    /// "#RRGGBB" when opaque, "#RRGGBBAA" otherwise. Components are rounded to the nearest byte.
    static func hexString(for color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let red = byte(srgb.redComponent)
        let green = byte(srgb.greenComponent)
        let blue = byte(srgb.blueComponent)
        let alpha = byte(srgb.alphaComponent)
        let rgb = "#" + hexByte(red) + hexByte(green) + hexByte(blue)
        return alpha == 255 ? rgb : rgb + hexByte(alpha)
    }

    /// Parses "#RRGGBB" or "#RRGGBBAA" (either case). Anything else returns nil.
    static func color(hex: String) -> NSColor? {
        guard hex.hasPrefix("#") else { return nil }
        let digits = String(hex.dropFirst())
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit) else { return nil }
        var components: [CGFloat] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let value = UInt8(digits[index..<next], radix: 16) else { return nil }
            components.append(CGFloat(value) / 255)
            index = next
        }
        let alpha = components.count == 4 ? components[3] : 1
        return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: alpha)
    }

    private static func byte(_ component: CGFloat) -> Int {
        Int((min(max(component, 0), 1) * 255).rounded())
    }

    private static func hexByte(_ value: Int) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return text.count == 1 ? "0" + text : text
    }

    // MARK: Storage

    /// Valid stored entries only. Unknown roles, non-string values and malformed hex are dropped.
    private static func storedHexStrings() -> [ColorRole: String] {
        guard let raw = defaults.dictionary(forKey: defaultsKey) else { return [:] }
        var entries: [ColorRole: String] = [:]
        for (key, value) in raw {
            guard let role = ColorRole(rawValue: key), let hex = value as? String, color(hex: hex) != nil else { continue }
            entries[role] = hex
        }
        return entries
    }

    private static func save(_ entries: [ColorRole: String]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            var raw: [String: String] = [:]
            for (role, hex) in entries { raw[role.rawValue] = hex }
            defaults.set(raw, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: .colorPreferencesDidChange, object: nil)
    }
}
