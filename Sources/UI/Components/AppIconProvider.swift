import AppKit
import UniformTypeIdentifiers

/// Cached 16 pt icons for process and application rows.
///
/// App bundles resolve to their own icon through `NSWorkspace`; everything else (plain
/// executables, unknown paths) shares one generic executable icon. Results are cached per path.
@MainActor
enum AppIconProvider {
    /// Side length, in points, of every icon returned by this provider.
    static let pointSize: CGFloat = 16

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()

    /// Icon for an application bundle path, or the generic executable icon when the path is nil or empty.
    static func icon(forBundlePath path: String?) -> NSImage {
        guard let path, !path.isEmpty else { return genericExecutableIcon() }
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = sized(NSWorkspace.shared.icon(forFile: path))
        cache.setObject(icon, forKey: key)
        return icon
    }

    /// The system icon for an unspecified Unix executable.
    static func genericExecutableIcon() -> NSImage {
        let key = "public.unix-executable" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = sized(NSWorkspace.shared.icon(for: .unixExecutable))
        cache.setObject(icon, forKey: key)
        return icon
    }

    private static func sized(_ image: NSImage) -> NSImage {
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }
}
