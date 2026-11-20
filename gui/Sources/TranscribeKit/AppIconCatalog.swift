import AppIconResources
import Foundation

/// The app icons a user can pick for the Dock (gui/icons, shipped as resources of this module).
public enum AppIconCatalog {
    public struct Entry: Sendable, Equatable, Identifiable {
        /// The SVG's basename, also the stored setting.
        public let id: String
        public let name: String
    }

    /// The bundled icon's design; the first entry.
    public static let defaultID = "a3b-lcd-clay"

    /// Names follow gui/icons/README.md.
    public static let all: [Entry] = [
        Entry(id: "a3b-lcd-clay", name: "LCD Clay"),
        Entry(id: "a3b-crt-gold", name: "CRT Gold"),
        Entry(id: "a3b-ribbon-ivory", name: "Ribbon Ivory"),
        Entry(id: "a3b-led-navy", name: "LED Navy"),
        Entry(id: "a3d-bars", name: "Waveform Bars"),
        Entry(id: "h3-olive", name: "Scan Olive"),
        Entry(id: "h3b", name: "Scan Low Seam"),
        Entry(id: "h5", name: "Electronic"),
    ]

    public static func entry(_ id: String) -> Entry? { all.first { $0.id == id } }

    /// The icon a stored value asks for. nil means Default (the bundle's own icon): an empty or
    /// missing value, "default", or an id this build doesn't know (e.g. from a newer version).
    public static func resolve(_ stored: String?) -> Entry? {
        guard let stored, !stored.isEmpty, stored != "default" else { return nil }
        return entry(stored)
    }

    /// The SVG file for an icon id, or nil if it isn't in the resources.
    public static func url(for id: String) -> URL? {
        guard entry(id) != nil else { return nil }
        let url = resourceDirectory.appendingPathComponent("\(id).svg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var resourceDirectory: URL { AppIconResources.bundle.resourceURL ?? AppIconResources.bundle.bundleURL }
}
