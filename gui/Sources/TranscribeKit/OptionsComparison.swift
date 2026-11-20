import Foundation

/// One option the inspector shows, for "changed from defaults" and Mixed markers.
public enum OptionField: Sendable, Hashable, CaseIterable {
    case formats, timestamps, outputDirectory, language, model, context, overwrite, copies

    public var label: String {
        switch self {
        case .formats: "Formats"
        case .timestamps: "Timestamps"
        case .outputDirectory: "Save to"
        case .language: "Language"
        case .model: "Model"
        case .context: "Context"
        case .overwrite: "Overwrite"
        case .copies: "Also save copies"
        }
    }
}

extension TranscribeOptions {
    /// Normalised language: nil for auto.
    public var languageCode: String? {
        guard let l = language?.trimmingCharacters(in: .whitespaces).lowercased(), !l.isEmpty, l != "auto" else { return nil }
        return l
    }

    var normalizedFormats: Set<OutputFormat> { Set(formats) }
    var normalizedContext: [String] {
        contextTerms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public func value(equals other: TranscribeOptions, for field: OptionField) -> Bool {
        switch field {
        case .formats: normalizedFormats == other.normalizedFormats
        case .timestamps: timestamps == other.timestamps
        case .outputDirectory: outputDirectory?.standardizedFileURL.path == other.outputDirectory?.standardizedFileURL.path
        case .language: languageCode == other.languageCode
        case .model: model == other.model
        case .context: normalizedContext == other.normalizedContext
        case .overwrite: overwrite == other.overwrite
        case .copies: copyMode == other.copyMode && (copyMode == .off || Set(copyFormats) == Set(other.copyFormats))
        }
    }

    /// Fields that differ from `defaults`, in inspector order.
    public func differences(from defaults: TranscribeOptions) -> [OptionField] {
        OptionField.allCases.filter { !value(equals: defaults, for: $0) }
    }

    /// Formats this file adds or drops relative to the defaults (format tiles get their own dot).
    public func formatDifferences(from defaults: TranscribeOptions) -> Set<OutputFormat> {
        normalizedFormats.symmetricDifference(defaults.normalizedFormats)
    }

    /// The row subtitle for Ready and Queued rows: `44:02 · md srt · zh`, plus the model when it
    /// isn't the default.
    public func summary(duration: Double?, defaultModel: ModelChoice = .accurate) -> String {
        var parts = [Formatting.clock(duration)]
        parts.append(OutputFormat.allCases.filter(formats.contains).map(\.rawValue).joined(separator: " "))
        parts.append(languageCode ?? "auto")
        if model != defaultModel { parts.append(model == .fast ? "0.6B" : "1.7B") }
        return parts.joined(separator: " · ")
    }

    /// Tooltip for the blue dot: "Differs from defaults: srt, Language (English)".
    public func differenceDescription(from defaults: TranscribeOptions) -> String? {
        let diffs = differences(from: defaults)
        guard !diffs.isEmpty else { return nil }
        let parts: [String] = diffs.map { field in
            switch field {
            case .formats:
                let added = OutputFormat.allCases.filter { formats.contains($0) && !defaults.formats.contains($0) }
                let removed = OutputFormat.allCases.filter { !formats.contains($0) && defaults.formats.contains($0) }
                return (added.map(\.rawValue) + removed.map { "no \($0.rawValue)" }).joined(separator: ", ")
            case .language: return "Language (\(Languages.name(for: languageCode)))"
            case .model: return "Model (\(model == .fast ? "0.6B" : "1.7B"))"
            case .timestamps: return timestamps ? "Timestamps on" : "Timestamps off"
            case .overwrite: return overwrite ? "Overwrite on" : "Overwrite off"
            case .outputDirectory: return "Save to (\(outputDirectory?.lastPathComponent ?? "next to source"))"
            case .context: return "Context"
            case .copies: return copyMode == .off ? "No copies" : "Copies (\(OutputFormat.ordered(copyFormats).map(\.rawValue).joined(separator: " ")))"
            }
        }
        return "Differs from defaults: " + parts.joined(separator: ", ")
    }
}

/// A value across several files: the same everywhere, or Mixed.
public enum Mixed<Value: Equatable & Sendable>: Equatable, Sendable {
    case same(Value)
    case mixed

    public var value: Value? { if case .same(let v) = self { v } else { nil } }
    public var isMixed: Bool { self == .mixed }

    static func of(_ values: [Value]) -> Mixed {
        guard let first = values.first else { return .mixed }
        return values.allSatisfy { $0 == first } ? .same(first) : .mixed
    }
}

/// The options of several files as the inspector shows them (purple scope band).
public struct MixedOptions: Equatable, Sendable {
    public var count: Int
    /// How many of the files have each format: "1 of 3" on a striped tile.
    public var formatCounts: [OutputFormat: Int]
    public var timestamps: Mixed<Bool>
    public var outputDirectory: Mixed<String?>
    public var language: Mixed<String?>
    public var model: Mixed<ModelChoice>
    public var context: Mixed<[String]>
    public var overwrite: Mixed<Bool>
    public var copyMode: Mixed<CopyMode>
    public var copyFormats: Mixed<Set<OutputFormat>>

    public init(_ options: [TranscribeOptions]) {
        count = options.count
        var counts: [OutputFormat: Int] = [:]
        for o in options { for f in Set(o.formats) { counts[f, default: 0] += 1 } }
        formatCounts = counts
        timestamps = .of(options.map(\.timestamps))
        outputDirectory = .of(options.map { $0.outputDirectory?.standardizedFileURL.path })
        language = .of(options.map(\.languageCode))
        model = .of(options.map(\.model))
        context = .of(options.map(\.normalizedContext))
        overwrite = .of(options.map(\.overwrite))
        copyMode = .of(options.map(\.copyMode))
        copyFormats = .of(options.map { Set($0.copyFormats) })
    }

    public enum FormatState: Equatable, Sendable {
        case on, off
        case mixed(count: Int, of: Int)
    }

    public func format(_ f: OutputFormat) -> FormatState {
        let n = formatCounts[f] ?? 0
        if n == 0 { return .off }
        if n == count { return .on }
        return .mixed(count: n, of: count)
    }

    public func isMixed(_ field: OptionField) -> Bool {
        switch field {
        case .formats: OutputFormat.allCases.contains { if case .mixed = format($0) { true } else { false } }
        case .timestamps: timestamps.isMixed
        case .outputDirectory: outputDirectory.isMixed
        case .language: language.isMixed
        case .model: model.isMixed
        case .context: context.isMixed
        case .overwrite: overwrite.isMixed
        case .copies: copyMode.isMixed || copyFormats.isMixed
        }
    }

    /// "k mixed" in the band: fields whose values differ between the files.
    public var mixedCount: Int { OptionField.allCases.filter(isMixed).count }

    /// A click on a format tile: on for all unless all already have it, then off for all.
    public func toggledFormat(_ f: OutputFormat) -> Bool { format(f) != .on }
}

/// Copy / Paste Options: the whole option set travels as JSON on the pasteboard.
public enum OptionsClipboard {
    /// The pasteboard type the app uses.
    public static let pasteboardType = "dev.transcribe.options+json"

    public static func encode(_ o: TranscribeOptions) -> Data? { try? JSONEncoder().encode(o) }
    public static func decode(_ d: Data) -> TranscribeOptions? { try? JSONDecoder().decode(TranscribeOptions.self, from: d) }
}
