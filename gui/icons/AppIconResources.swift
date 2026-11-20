import Foundation

/// Locates this target's resource bundle (the SVGs next to this file).
public enum AppIconResources {
    static let bundleName = "Transcribe_AppIconResources.bundle"

    /// Contents/Resources of the .app (where bundle.sh puts it), then SwiftPM's own lookup, which
    /// checks next to the executable (`swift run`, tests) and the build folder.
    public static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(bundleName), let b = Bundle(url: url) { return b }
        return Bundle.module
    }()
}
