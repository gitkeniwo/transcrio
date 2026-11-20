import Foundation

/// The `-l` codes the CLI accepts, mirroring `CODES` in `src/transcribe/languages.py`
/// (aliases such as `cn` and `jp` left out).
public enum Languages {
    public struct Language: Sendable, Hashable, Identifiable {
        public let code: String
        public let name: String
        public var id: String { code }
    }

    /// Most common first, as in the design spec's pop-up, then the rest alphabetically.
    public static let all: [Language] = {
        let leading = ["zh", "en", "ja", "es", "de", "fr", "ko", "yue"]
        let rest = names.keys.filter { !leading.contains($0) }.sorted { names[$0]! < names[$1]! }
        return (leading + rest).map { Language(code: $0, name: names[$0]!) }
    }()

    public static let names: [String: String] = [
        "zh": "Chinese", "en": "English", "ja": "Japanese", "ko": "Korean", "es": "Spanish",
        "de": "German", "fr": "French", "it": "Italian", "pt": "Portuguese", "ru": "Russian",
        "yue": "Cantonese", "ar": "Arabic", "nl": "Dutch", "pl": "Polish", "tr": "Turkish",
        "vi": "Vietnamese", "th": "Thai", "id": "Indonesian", "ms": "Malay", "hi": "Hindi",
        "sv": "Swedish", "da": "Danish", "fi": "Finnish", "cs": "Czech", "el": "Greek",
        "hu": "Hungarian", "ro": "Romanian", "fa": "Persian", "fil": "Filipino", "mk": "Macedonian",
    ]

    /// Display name for a code; unknown codes are shown as given.
    public static func name(for code: String?) -> String {
        guard let code else { return "Auto-detect" }
        return names[code.lowercased()] ?? code
    }

    /// Canonical name ("Chinese") back to its code, for `aligned_languages`, which
    /// `backends --json` may report as names or codes.
    public static func code(for nameOrCode: String) -> String {
        let lower = nameOrCode.lowercased()
        if names[lower] != nil { return lower }
        return names.first { $0.value.lowercased() == lower }?.key ?? nameOrCode
    }
}
