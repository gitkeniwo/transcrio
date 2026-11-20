import AppKit
import TranscribeKit

/// The Dock icon the user picked in Settings. Dock-only: the runtime icon resets on quit, so it
/// is applied again at launch, and the Finder icon stays the bundle's (writing it with
/// NSWorkspace.setIcon would modify the bundle and break its signature).
@MainActor
enum AppIcon {
    private static var dockCache: [String: NSImage] = [:]

    /// The stored choice; nil is Default (the bundle's own icon).
    static var stored: AppIconCatalog.Entry? {
        AppIconCatalog.resolve(UserDefaults.standard.string(forKey: SettingsKeys.appIcon))
    }

    /// The SVG as drawn, without a shadow (Settings tiles).
    static func image(_ id: String) -> NSImage? {
        AppIconCatalog.url(for: id).flatMap(NSImage.init(contentsOf:))
    }

    /// The icon the bundle ships (CFBundleIconFile); under `swift run` there is none, so the
    /// default design stands in for it.
    static var bundleImage: NSImage? {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let icon = Bundle.main.image(forResource: name) {
            return icon
        }
        return image(AppIconCatalog.defaultID)
    }

    /// The SVG drawn the way make-icon.swift draws the bundled icon: 1024 px with the standard
    /// macOS icon shadow, so alternates sit in the Dock like the bundled icon.
    static func dockImage(_ id: String) -> NSImage? {
        if let cached = dockCache[id] { return cached }
        guard let svg = image(id) else { return nil }
        let size: CGFloat = 1024, s = size / 1024
        let icon = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 20 * s
            shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
            shadow.set()
            svg.draw(in: rect)
            return true
        }
        dockCache[id] = icon
        return icon
    }

    /// Shows that icon in the Dock; nil (Default) restores the bundle's icon.
    static func apply(_ entry: AppIconCatalog.Entry?) {
        NSApplication.shared.applicationIconImage = entry.flatMap { dockImage($0.id) }
    }

    /// Stores a choice and shows it ("" is Default).
    static func choose(_ id: String) {
        UserDefaults.standard.set(id, forKey: SettingsKeys.appIcon)
        apply(AppIconCatalog.resolve(id))
    }
}
