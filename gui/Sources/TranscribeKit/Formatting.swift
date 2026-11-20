import Foundation

public enum Formatting {
    /// `1:02:03`, or `24:05` under an hour.
    public static func clock(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–:––" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Always `h:mm:ss`, for the Total audio chip.
    public static func longClock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// `[hh:mm:ss]`-style stamp without brackets, as the CLI writes in md/txt.
    public static func stamp(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// `3m 12s`, `45s`, `1h 4m`.
    public static func took(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// `12.4×` (audio seconds per processing second).
    public static func speed(duration: Double?, elapsed: Double?) -> String {
        guard let duration, let elapsed, elapsed > 0, duration > 0 else { return "–" }
        let x = duration / elapsed
        return x >= 10 ? String(format: "%.0f×", x) : String(format: "%.1f×", x)
    }

    /// `1.2 MB`
    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// `62%`
    public static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }
}
