import AppKit
import XCTest
@testable import Microgravity

/// Points `ColorPreferences` at a throwaway defaults suite and puts the previous domain back on `restore()`.
@MainActor
private final class IsolatedColorDefaults {
    let defaults: UserDefaults
    private let suite: String
    private let priorOverride: UserDefaults?

    init() {
        suite = "ColorPreferencesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        priorOverride = ColorPreferences.defaultsOverride
        ColorPreferences.defaultsOverride = defaults
    }

    func restore() {
        ColorPreferences.defaultsOverride = priorOverride
        defaults.removePersistentDomain(forName: suite)
    }
}

/// sRGB components, so colors compare by value rather than by object identity.
private func srgbComponents(_ color: NSColor) -> [CGFloat]? {
    guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
    return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
}

private func assertSameColor(_ actual: NSColor, _ expected: NSColor, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
    guard let lhs = srgbComponents(actual), let rhs = srgbComponents(expected) else {
        XCTFail("colors must convert to sRGB \(message)", file: file, line: line)
        return
    }
    for (left, right) in zip(lhs, rhs) {
        XCTAssertEqual(left, right, accuracy: 0.005, message, file: file, line: line)
    }
}

private func view(withIdentifier identifier: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == identifier { return root }
    for subview in root.subviews {
        if let found = view(withIdentifier: identifier, in: subview) { return found }
    }
    return nil
}

@MainActor
final class ColorPreferencesTests: XCTestCase {
    func testEveryRoleDefaultsToItsSystemColorUntilCustomized() {
        let isolated = IsolatedColorDefaults()
        defer { isolated.restore() }

        XCTAssertEqual(ColorRole.allCases.count, 9)
        for role in ColorRole.allCases {
            XCTAssertFalse(ColorPreferences.isCustomized(role), "\(role)")
            assertSameColor(ColorPreferences.color(for: role), role.defaultColor, "\(role)")
        }
        XCTAssertNil(isolated.defaults.object(forKey: ColorPreferences.defaultsKey))
        assertSameColor(ColorRole.cpu.defaultColor, .systemBlue)
        assertSameColor(ColorRole.superCores.defaultColor, .systemPink)
        assertSameColor(ColorRole.efficiencyCores.defaultColor, .systemGreen)
    }

    func testRoleTitlesAndIdentifierSuffixesAreStable() {
        XCTAssertEqual(ColorRole.allCases.map(\.title), [
            "CPU", "Memory", "Disk", "Network", "GPU", "Energy",
            "Super cores", "Performance cores", "Efficiency cores"
        ])
        XCTAssertEqual(ColorRole.allCases.map(\.identifierSuffix), [
            "cpu", "memory", "disk", "network", "gpu", "energy",
            "super-cores", "performance-cores", "efficiency-cores"
        ])
    }

    func testSetColorStoresSRGBHexUnderOneKeyAndReadsItBack() {
        let isolated = IsolatedColorDefaults()
        defer { isolated.restore() }

        ColorPreferences.setColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), for: .cpu)
        ColorPreferences.setColor(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1), for: .disk)

        XCTAssertEqual(isolated.defaults.dictionary(forKey: "appearance.colors") as? [String: String],
                       ["cpu": "#FF0000", "disk": "#00FF00"])
        XCTAssertTrue(ColorPreferences.isCustomized(.cpu))
        XCTAssertFalse(ColorPreferences.isCustomized(.memory))
        assertSameColor(ColorPreferences.color(for: .cpu), NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        assertSameColor(ColorPreferences.color(for: .disk), NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
    }

    func testResetColorRemovesOnlyThatRole() {
        let isolated = IsolatedColorDefaults()
        defer { isolated.restore() }
        ColorPreferences.setColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), for: .cpu)
        ColorPreferences.setColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), for: .memory)

        ColorPreferences.resetColor(for: .cpu)

        XCTAssertFalse(ColorPreferences.isCustomized(.cpu))
        assertSameColor(ColorPreferences.color(for: .cpu), ColorRole.cpu.defaultColor)
        XCTAssertTrue(ColorPreferences.isCustomized(.memory))
        XCTAssertEqual(isolated.defaults.dictionary(forKey: "appearance.colors") as? [String: String], ["memory": "#0000FF"])
    }

    func testResetAllRemovesEveryCustomColorAndTheStoredKey() {
        let isolated = IsolatedColorDefaults()
        defer { isolated.restore() }
        for role in ColorRole.allCases {
            ColorPreferences.setColor(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1), for: role)
        }
        XCTAssertTrue(ColorRole.allCases.allSatisfy(ColorPreferences.isCustomized))

        ColorPreferences.resetAll()

        XCTAssertFalse(ColorRole.allCases.contains(where: ColorPreferences.isCustomized))
        XCTAssertNil(isolated.defaults.object(forKey: ColorPreferences.defaultsKey))
        for role in ColorRole.allCases {
            assertSameColor(ColorPreferences.color(for: role), role.defaultColor, "\(role)")
        }
    }

    func testMalformedEntriesAreIgnoredAndFallBackToDefaults() {
        let isolated = IsolatedColorDefaults()
        defer { isolated.restore() }
        isolated.defaults.set([
            "cpu": "not-a-color",
            "memory": "#12",
            "disk": 42,
            "network": "#0A0B0C",
            "not-a-role": "#FFFFFF"
        ] as [String: Any], forKey: ColorPreferences.defaultsKey)

        XCTAssertFalse(ColorPreferences.isCustomized(.cpu))
        assertSameColor(ColorPreferences.color(for: .cpu), ColorRole.cpu.defaultColor)
        assertSameColor(ColorPreferences.color(for: .memory), ColorRole.memory.defaultColor)
        assertSameColor(ColorPreferences.color(for: .disk), ColorRole.disk.defaultColor)
        XCTAssertTrue(ColorPreferences.isCustomized(.network))
        assertSameColor(ColorPreferences.color(for: .network), NSColor(srgbRed: 10 / 255, green: 11 / 255, blue: 12 / 255, alpha: 1))

        // Writing one color keeps the valid entry and drops the malformed ones.
        ColorPreferences.setColor(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), for: .gpu)
        XCTAssertEqual(isolated.defaults.dictionary(forKey: ColorPreferences.defaultsKey) as? [String: String],
                       ["network": "#0A0B0C", "gpu": "#FFFFFF"])
    }

    func testOpaqueColorsOmitAlphaAndTranslucentColorsKeepIt() throws {
        let isolated = IsolatedColorDefaults()
        defer { isolated.restore() }

        ColorPreferences.setColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), for: .energy)
        XCTAssertEqual(isolated.defaults.dictionary(forKey: ColorPreferences.defaultsKey)?["energy"] as? String, "#0000FF")

        ColorPreferences.setColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5), for: .energy)
        XCTAssertEqual(isolated.defaults.dictionary(forKey: ColorPreferences.defaultsKey)?["energy"] as? String, "#0000FF80")
        let alpha = try XCTUnwrap(srgbComponents(ColorPreferences.color(for: .energy)))[3]
        XCTAssertEqual(alpha, 128 / 255, accuracy: 0.002)
    }

    func testChangesPostTheColorNotificationAndNoOpResetsDoNot() {
        let isolated = IsolatedColorDefaults()
        defer { isolated.restore() }

        let set = expectation(forNotification: .colorPreferencesDidChange, object: nil)
        ColorPreferences.setColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), for: .cpu)
        wait(for: [set], timeout: 1)

        let reset = expectation(forNotification: .colorPreferencesDidChange, object: nil)
        ColorPreferences.resetColor(for: .cpu)
        wait(for: [reset], timeout: 1)

        let quiet = expectation(forNotification: .colorPreferencesDidChange, object: nil)
        quiet.isInverted = true
        ColorPreferences.resetColor(for: .cpu)
        ColorPreferences.resetAll()
        wait(for: [quiet], timeout: 0.2)

        let all = expectation(forNotification: .colorPreferencesDidChange, object: nil)
        ColorPreferences.setColor(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), for: .disk)
        ColorPreferences.resetAll()
        wait(for: [all], timeout: 1)
    }

    func testHexEncodingRoundTripsAndNormalizesCase() {
        XCTAssertEqual(ColorPreferences.hexString(for: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)), "#FF8000")
        XCTAssertEqual(ColorPreferences.hexString(for: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)), "#00000000")
        XCTAssertEqual(ColorPreferences.hexString(for: NSColor(srgbRed: 0x12 / 255, green: 0xAB / 255, blue: 0xEF / 255, alpha: 1)),
                       "#12ABEF")

        for hex in ["#FF8000", "#00FF7F", "#12ABEF", "#FF800080", "#00000000", "#FFFFFF10"] {
            let color = ColorPreferences.color(hex: hex)
            XCTAssertNotNil(color, hex)
            XCTAssertEqual(color.flatMap(ColorPreferences.hexString(for:)), hex, "round trip of \(hex)")
        }
        XCTAssertEqual(ColorPreferences.color(hex: "#ff8000").flatMap(ColorPreferences.hexString(for:)), "#FF8000")
        XCTAssertEqual(ColorPreferences.color(hex: "#FF8000ff").flatMap(ColorPreferences.hexString(for:)), "#FF8000",
                       "an opaque alpha byte is written back as six digits")
    }

    func testHexDecodingRejectsMalformedInput() {
        for hex in ["", "#", "FF8000", "#FFF", "#FF80", "#FF800", "#FF80000", "#FF800000F", "#GG8000",
                    "#FF8000 ", " #FF8000", "##FF8000", "#FF8000G0", "#FF80+0", "rgb(1,2,3)", "#\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}"] {
            XCTAssertNil(ColorPreferences.color(hex: hex), "\(hex.debugDescription) must be rejected")
        }
    }

    func testAlphaRoundTripsThroughDefaultsStorage() {
        let isolated = IsolatedColorDefaults()
        defer { isolated.restore() }
        ColorPreferences.setColor(NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 0.25), for: .network)

        let stored = isolated.defaults.dictionary(forKey: ColorPreferences.defaultsKey)?["network"] as? String
        XCTAssertEqual(stored, "#4080BF40")
        let read = ColorPreferences.color(for: .network)
        assertSameColor(read, NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 0.25))
    }
}

@MainActor
final class ColorCustomizationSurfaceTests: XCTestCase {
    func testPerformanceMetricColorFollowsItsCustomizedRole() {
        let isolated = IsolatedColorDefaults()
        defer { isolated.restore() }
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

        ColorPreferences.setColor(red, for: .cpu)

        assertSameColor(PerformanceMetric.cpu.color, red)
        assertSameColor(PerformanceMetric.memory.color, ColorRole.memory.defaultColor)
        assertSameColor(PerformanceMetric.energy.color, ColorRole.energy.defaultColor)

        ColorPreferences.resetColor(for: .cpu)
        assertSameColor(PerformanceMetric.cpu.color, ColorRole.cpu.defaultColor)
    }

    func testProcessHeatColorFollowsItsCustomizedRoleAndOtherColumnsStayOrange() {
        let isolated = IsolatedColorDefaults()
        defer { isolated.restore() }
        let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

        ColorPreferences.setColor(green, for: .memory)
        ColorPreferences.setColor(blue, for: .network)

        assertSameColor(ProcessColumn.memory.heatColor, green)
        assertSameColor(ProcessColumn.network.heatColor, blue)
        assertSameColor(ProcessColumn.cpu.heatColor, ColorRole.cpu.defaultColor)
        assertSameColor(ProcessColumn.disk.heatColor, ColorRole.disk.defaultColor)
        assertSameColor(ProcessColumn.gpu.heatColor, .systemOrange)
        assertSameColor(ProcessColumn.name.heatColor, .systemOrange)
    }

    func testSettingsShowsColorWellsWithStoredValuesAndWritesChangesBack() throws {
        let isolated = IsolatedColorDefaults()
        defer { isolated.restore() }
        let configuration = FixtureConfiguration(arguments: [])
        let settings = SettingsViewController(dependencies: PageDependencies(
            monitoringStore: FixtureMonitoringStore(configuration: configuration),
            processActions: FixtureProcessActioner(configuration: configuration),
            integrations: UnavailableSystemIntegrationAPI(),
            fixtureMode: true
        ))
        settings.loadViewIfNeeded()

        for role in ColorRole.allCases {
            let well = try XCTUnwrap(view(withIdentifier: "settings.color.\(role.identifierSuffix)", in: settings.view) as? NSColorWell,
                                     "missing well for \(role)")
            let reset = try XCTUnwrap(view(withIdentifier: "settings.color.\(role.identifierSuffix).reset", in: settings.view) as? NSButton,
                                      "missing reset for \(role)")
            XCTAssertFalse(reset.isEnabled, "\(role) has no custom color yet")
            assertSameColor(well.color, role.defaultColor, "\(role) well shows its default")
        }
        let restore = try XCTUnwrap(view(withIdentifier: "settings.colors.reset-all", in: settings.view) as? NSButton)
        XCTAssertFalse(restore.isEnabled)

        // A user picks a color in the well: the preference is written and the reset button enables.
        let cpuWell = try XCTUnwrap(view(withIdentifier: "settings.color.cpu", in: settings.view) as? NSColorWell)
        let cpuReset = try XCTUnwrap(view(withIdentifier: "settings.color.cpu.reset", in: settings.view) as? NSButton)
        cpuWell.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        _ = cpuWell.sendAction(cpuWell.action, to: cpuWell.target)
        XCTAssertEqual(ColorPreferences.hexString(for: ColorPreferences.color(for: .cpu)), "#FF0000")
        XCTAssertTrue(cpuReset.isEnabled)
        XCTAssertTrue(restore.isEnabled)

        // A change made elsewhere shows up in the well without reopening Settings.
        ColorPreferences.setColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), for: .superCores)
        let superWell = try XCTUnwrap(view(withIdentifier: "settings.color.super-cores", in: settings.view) as? NSColorWell)
        XCTAssertEqual(ColorPreferences.hexString(for: superWell.color), "#0000FF")

        // Reset on one row restores only that role.
        cpuReset.performClick(nil)
        XCTAssertFalse(ColorPreferences.isCustomized(.cpu))
        XCTAssertFalse(cpuReset.isEnabled)
        assertSameColor(cpuWell.color, ColorRole.cpu.defaultColor)
        XCTAssertTrue(ColorPreferences.isCustomized(.superCores))

        restore.performClick(nil)
        XCTAssertFalse(ColorRole.allCases.contains(where: ColorPreferences.isCustomized))
        XCTAssertFalse(restore.isEnabled)
        assertSameColor(superWell.color, ColorRole.superCores.defaultColor)
    }
}
