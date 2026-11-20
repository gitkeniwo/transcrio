import Foundation

/// Model aliases the CLI accepts with `-m`.
public enum ModelChoice: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case accurate = "1.7b"
    case fast = "0.6b"
    public var id: String { rawValue }
    public var cacheModel: CachedModel { self == .accurate ? .asr1_7b : .asr0_6b }
}

/// Transcription options as chosen in the inspector; applied at the next Start.
public struct TranscribeOptions: Codable, Sendable, Equatable {
    public var formats: [OutputFormat]
    public var timestamps: Bool
    /// `nil` writes next to each source (no `-o`).
    public var outputDirectory: URL?
    /// ISO code from `languages.py`, or `nil` for auto-detect.
    public var language: String?
    public var model: ModelChoice
    public var contextTerms: [String]
    public var overwrite: Bool
    /// D2 "Also save copies": off, next to the source, or into `outputDirectory`.
    /// With copies on, `timestamps` and `overwrite` are the copies' own switches.
    public var copyMode: CopyMode
    /// Formats the copies write (at least one when copies are on).
    public var copyFormats: [OutputFormat]

    public init(formats: [OutputFormat] = [.md], timestamps: Bool = false, outputDirectory: URL? = nil,
                language: String? = nil, model: ModelChoice = .accurate, contextTerms: [String] = [],
                overwrite: Bool = false, copyMode: CopyMode = .off, copyFormats: [OutputFormat] = [.md]) {
        self.formats = formats
        self.timestamps = timestamps
        self.outputDirectory = outputDirectory
        self.language = language
        self.model = model
        self.contextTerms = contextTerms
        self.overwrite = overwrite
        self.copyMode = copyMode
        self.copyFormats = copyFormats
    }

    enum CodingKeys: String, CodingKey {
        case formats, timestamps, outputDirectory, language, model, contextTerms, overwrite, copyMode, copyFormats
    }

    /// Options saved before P2 have no copy fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(formats: try c.decode([OutputFormat].self, forKey: .formats),
                  timestamps: try c.decode(Bool.self, forKey: .timestamps),
                  outputDirectory: try c.decodeIfPresent(URL.self, forKey: .outputDirectory),
                  language: try c.decodeIfPresent(String.self, forKey: .language),
                  model: try c.decode(ModelChoice.self, forKey: .model),
                  contextTerms: try c.decode([String].self, forKey: .contextTerms),
                  overwrite: try c.decode(Bool.self, forKey: .overwrite),
                  copyMode: (try? c.decodeIfPresent(CopyMode.self, forKey: .copyMode)) ?? .off,
                  copyFormats: (try? c.decodeIfPresent([OutputFormat].self, forKey: .copyFormats)) ?? [.md])
    }

    /// True when SRT/VTT is requested, so the CLI will run the `align` stage.
    public var wantsCues: Bool { formats.contains(where: \.isCueFormat) }
}

public enum CommandBuilderError: Error, Equatable {
    case noFiles
    case noFormats
}

public enum CommandBuilder {
    /// `transcribe run FILE... -f md,srt [-o DIR] [-t] [-l xx] -m 1.7b [--context=…] [--overwrite] --json --progress ndjson`
    ///
    /// Files are passed as absolute, standardized paths; the CLI echoes them verbatim in the
    /// `file` key of every event, so these exact strings are what events are matched by.
    public static func arguments(files: [URL], options: TranscribeOptions) throws -> [String] {
        guard !files.isEmpty else { throw CommandBuilderError.noFiles }
        var formats: [OutputFormat] = []
        for f in options.formats where !formats.contains(f) { formats.append(f) }
        guard !formats.isEmpty else { throw CommandBuilderError.noFormats }

        // `run` explicitly, so a path can never be mistaken for a subcommand.
        var args = ["run"]
        args += files.map(eventPath(for:))
        args += ["-f", formats.map(\.rawValue).joined(separator: ",")]
        if let dir = options.outputDirectory {
            args += ["-o", dir.standardizedFileURL.path]
        }
        if options.timestamps { args.append("-t") }
        if let lang = options.language?.trimmingCharacters(in: .whitespaces), !lang.isEmpty, lang.lowercased() != "auto" {
            args += ["-l", lang]
        }
        args += ["-m", options.model.rawValue]
        let context = options.contextTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // `=` form so a value starting with "-" isn't parsed as a flag.
        if !context.isEmpty { args.append("--context=\(context)") }
        if options.overwrite { args.append("--overwrite") }
        args += ["--json", "--progress", "ndjson"]
        return args
    }

    /// The string the CLI will echo back as `file` for this input.
    public static func eventPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
