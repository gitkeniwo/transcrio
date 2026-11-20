import Foundation

/// Pipeline stage named by `progress` events.
public enum Stage: String, Codable, Sendable, CaseIterable, Hashable {
    case decode, load, transcribe, align
}

/// How subtitle cue times were produced (`cue_timing`).
public enum CueTiming: String, Codable, Sendable, Hashable {
    case aligned, estimated, mixed
}

/// Output formats the CLI can write, in the order the UI lists them.
public enum OutputFormat: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case md, txt, srt, vtt, json
    public var id: String { rawValue }
    /// Subtitle formats need cue timing (and possibly the forced aligner).
    public var isCueFormat: Bool { self == .srt || self == .vtt }
}

public struct ProgressInfo: Sendable, Equatable {
    /// `nil` when the CLI sends a stage this app doesn't know yet.
    public var stage: Stage?
    public var stageName: String
    public var progress: Double
    public var chunk: Int?
    public var totalChunks: Int?

    public init(stage: Stage?, stageName: String? = nil, progress: Double, chunk: Int? = nil, totalChunks: Int? = nil) {
        self.stage = stage
        self.stageName = stageName ?? stage?.rawValue ?? ""
        self.progress = progress
        self.chunk = chunk
        self.totalChunks = totalChunks
    }
}

/// `progress stage=download`: a model is downloading into the Hugging Face cache. Counts only
/// the files still missing, so a resumed download starts above zero.
public struct DownloadInfo: Sendable, Equatable {
    /// Hugging Face repo id, e.g. `Qwen/Qwen3-ASR-1.7B`.
    public var model: String
    /// Catalog id (`1.7b`), when the CLI sends one (`serve`).
    public var modelID: String?
    public var downloadedBytes: Int64
    public var totalBytes: Int64

    public init(model: String, modelID: String? = nil, downloadedBytes: Int64, totalBytes: Int64) {
        self.model = model
        self.modelID = modelID
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }

    /// 0–1, or nil when the total is unknown.
    public var fraction: Double? {
        totalBytes > 0 ? min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1) : nil
    }

    public var cachedModel: CachedModel? { CachedModel(rawValue: model) }
}

/// A structured warning from `file_done` / the summary (`notices`). `warnings` carries the
/// same messages as plain text.
public struct Notice: Sendable, Equatable, Codable, Hashable {
    public enum Code: String, Sendable, Codable, Hashable {
        /// Output was cut short.
        case truncated
        /// The forced aligner failed for part of the audio.
        case alignmentFailed = "alignment_failed"
        /// Subtitle cue times were estimated (no aligner for the language, or alignment failed).
        case timingEstimated = "timing_estimated"
    }

    /// nil for a code this app doesn't know yet.
    public var code: Code?
    public var rawCode: String
    public var message: String
    /// Affected audio, in seconds. nil when the CLI doesn't say.
    public var spans: [ClosedRange<Double>]?

    public init(code: Code?, rawCode: String? = nil, message: String, spans: [ClosedRange<Double>]? = nil) {
        self.code = code
        self.rawCode = rawCode ?? code?.rawValue ?? ""
        self.message = message
        self.spans = spans
    }

    enum CodingKeys: String, CodingKey { case code, message, spans }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rawCode = (try? c.decodeIfPresent(String.self, forKey: .code)) ?? ""
        code = Code(rawValue: rawCode)
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? rawCode
        spans = (try? c.decodeIfPresent([[Double]].self, forKey: .spans))?.compactMap { pair in
            guard pair.count == 2, pair[0].isFinite, pair[1].isFinite else { return nil }
            return min(pair[0], pair[1])...max(pair[0], pair[1])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rawCode, forKey: .code)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(spans?.map { [$0.lowerBound, $0.upperBound] }, forKey: .spans)
    }
}

/// Payload of `file_done`; the same fields appear per result in the stdout summary.
public struct FileResult: Sendable, Equatable, Codable {
    public var outputs: [String: String]
    public var elapsed: Double?
    public var language: String?
    public var duration: Double?
    public var model: String?
    public var cueTiming: CueTiming?
    public var warnings: [String]
    public var notices: [Notice]
    /// `serve`'s `file_done.segments`: one paragraph per chunk with its audio span. Empty for
    /// the batch CLI, which doesn't send them.
    public var segments: [TranscriptSegment]
    /// `serve`'s `file_done.transcript`: where the job's `transcript_path` was written.
    public var transcript: String?

    public init(outputs: [String: String] = [:], elapsed: Double? = nil, language: String? = nil, duration: Double? = nil,
                model: String? = nil, cueTiming: CueTiming? = nil, warnings: [String] = [], notices: [Notice] = [],
                segments: [TranscriptSegment] = [], transcript: String? = nil) {
        self.outputs = outputs
        self.elapsed = elapsed
        self.language = language
        self.duration = duration
        self.model = model
        self.cueTiming = cueTiming
        self.warnings = warnings
        self.notices = notices
        self.segments = segments
        self.transcript = transcript
    }

    enum CodingKeys: String, CodingKey {
        case outputs, elapsed, language, duration, model, warnings, notices, segments, transcript
        case cueTiming = "cue_timing"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputs = (try? c.decodeIfPresent([String: String].self, forKey: .outputs)) ?? [:]
        elapsed = try? c.decodeIfPresent(Double.self, forKey: .elapsed)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        // An unknown timing value is treated as "not reported" rather than failing the event.
        cueTiming = (try? c.decodeIfPresent(String.self, forKey: .cueTiming)).flatMap(CueTiming.init(rawValue:))
        warnings = (try? c.decodeIfPresent([String].self, forKey: .warnings)) ?? []
        notices = (try? c.decodeIfPresent([Notice].self, forKey: .notices)) ?? []
        segments = (try? c.decodeIfPresent([TranscriptSegment].self, forKey: .segments)) ?? []
        transcript = try? c.decodeIfPresent(String.self, forKey: .transcript)
    }

    /// Output paths keyed by known format, in display order.
    public var orderedOutputs: [(format: OutputFormat, path: String)] {
        OutputFormat.allCases.compactMap { f in outputs[f.rawValue].map { (f, $0) } }
    }

    /// Structured notices; for a CLI without `notices`, the plain warnings, plus a timing
    /// notice when cues were estimated but nothing said so.
    public var effectiveNotices: [Notice] {
        if !notices.isEmpty { return notices }
        if !warnings.isEmpty { return warnings.map { Notice(code: nil, rawCode: "", message: $0) } }
        switch cueTiming {
        case .estimated:
            return [Notice(code: .timingEstimated, message: "Word timing isn’t available for this language. Subtitle cues are estimated.")]
        case .mixed:
            return [Notice(code: .timingEstimated, message: "Alignment failed in places. Some subtitle cues are estimated.")]
        default: return []
        }
    }

    public var noticeCount: Int { effectiveNotices.count }

    /// Audio whose subtitle timing is estimated: the `timing_estimated` spans; the whole file
    /// when timing is `estimated` and no spans were given.
    public func estimatedSpans(duration: Double) -> [ClosedRange<Double>] {
        let spans = notices.filter { $0.code == .timingEstimated }.compactMap(\.spans).flatMap { $0 }
        if !spans.isEmpty { return spans.sorted { $0.lowerBound < $1.lowerBound } }
        if cueTiming == .estimated, duration > 0 { return [0...duration] }
        return []
    }
}

/// One stderr NDJSON line from `--progress ndjson`.
public enum CLIEvent: Sendable, Equatable {
    case progress(file: String, ProgressInfo)
    /// `progress stage=download`, sent after `load` (ASR model) or inside `align` (aligner).
    case download(file: String, DownloadInfo)
    case log(file: String, message: String)
    case fileDone(file: String, FileResult)
    case fileError(file: String, error: String)
    /// SIGTERM/SIGINT: sent for the interrupted file and every file not started yet.
    case fileStopped(file: String)
    /// An event type this app doesn't know (forward compatibility). Ignored by the queue.
    case unknown(file: String?, event: String)

    public var file: String? {
        switch self {
        case .progress(let f, _), .download(let f, _), .log(let f, _), .fileDone(let f, _), .fileError(let f, _), .fileStopped(let f): f
        case .unknown(let f, _): f
        }
    }

    /// Decodes one line. Returns `nil` for text that isn't a JSON object with an `event`
    /// (e.g. a stray library warning on stderr).
    public static func decode(_ line: String) -> CLIEvent? {
        guard let data = line.data(using: .utf8),
              let header = try? JSONDecoder().decode(Header.self, from: data),
              let event = header.event
        else { return nil }
        let file = header.file ?? ""
        switch event {
        case "progress":
            guard let p = try? JSONDecoder().decode(ProgressPayload.self, from: data) else {
                return .unknown(file: header.file, event: event)
            }
            if p.stage == "download" {
                return .download(file: file, DownloadInfo(model: p.model ?? "", downloadedBytes: p.downloaded_bytes ?? 0,
                                                         totalBytes: p.total_bytes ?? 0))
            }
            return .progress(file: file, ProgressInfo(
                stage: p.stage.flatMap(Stage.init(rawValue:)), stageName: p.stage,
                progress: min(max(p.progress ?? 0, 0), 1), chunk: p.chunk, totalChunks: p.total_chunks))
        case "log":
            let p = try? JSONDecoder().decode(LogPayload.self, from: data)
            return .log(file: file, message: p?.message ?? "")
        case "file_done":
            guard let r = try? JSONDecoder().decode(FileResult.self, from: data) else {
                return .unknown(file: header.file, event: event)
            }
            return .fileDone(file: file, r)
        case "file_error":
            let p = try? JSONDecoder().decode(ErrorPayload.self, from: data)
            return .fileError(file: file, error: p?.error ?? "Unknown error")
        case "file_stopped":
            return .fileStopped(file: file)
        default:
            return .unknown(file: header.file, event: event)
        }
    }

    private struct Header: Decodable { var file: String?; var event: String? }
    private struct ProgressPayload: Decodable {
        var stage: String?
        var progress: Double?
        var chunk: Int?
        var total_chunks: Int?
        var model: String?
        var downloaded_bytes: Int64?
        var total_bytes: Int64?
    }
    private struct LogPayload: Decodable { var message: String? }
    private struct ErrorPayload: Decodable { var error: String? }
}

// MARK: - stdout summary and helper commands

/// The `--json` summary printed on stdout when the run ends, also after SIGTERM/SIGINT.
public struct CLISummary: Sendable, Equatable, Decodable {
    public struct Result: Sendable, Equatable, Decodable {
        public var input: String
        public var error: String?
        public var backend: String?
        /// Stopped by SIGTERM/SIGINT before it finished (`outputs` is empty).
        public var stopped: Bool
        public var result: FileResult

        enum CodingKeys: String, CodingKey { case input, error, backend, stopped }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            input = try c.decode(String.self, forKey: .input)
            error = try? c.decodeIfPresent(String.self, forKey: .error)
            backend = try? c.decodeIfPresent(String.self, forKey: .backend)
            stopped = (try? c.decodeIfPresent(Bool.self, forKey: .stopped)) ?? false
            result = try FileResult(from: decoder)
        }
    }

    public var results: [Result]

    public static func decode(_ data: Data) -> CLISummary? {
        try? JSONDecoder().decode(CLISummary.self, from: data)
    }
}

/// `transcribe doctor --json`.
public struct DoctorReport: Sendable, Equatable, Decodable {
    public var ok: Bool
    public var ffmpeg: String?
    public var ffprobe: String?
    public var appleSilicon: Bool
    public var hfCache: String?
    public var mlxDevice: String?
    public var mlxError: String?

    enum CodingKeys: String, CodingKey {
        case ok, ffmpeg, ffprobe
        case appleSilicon = "apple_silicon"
        case hfCache = "hf_cache"
        case mlxDevice = "mlx_device"
        case mlxError = "mlx_error"
    }

    public init(ok: Bool, ffmpeg: String?, ffprobe: String? = nil, appleSilicon: Bool = true, hfCache: String? = nil,
                mlxDevice: String? = nil, mlxError: String? = nil) {
        self.ok = ok
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.appleSilicon = appleSilicon
        self.hfCache = hfCache
        self.mlxDevice = mlxDevice
        self.mlxError = mlxError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        ffmpeg = try? c.decodeIfPresent(String.self, forKey: .ffmpeg)
        ffprobe = try? c.decodeIfPresent(String.self, forKey: .ffprobe)
        appleSilicon = (try? c.decode(Bool.self, forKey: .appleSilicon)) ?? false
        hfCache = try? c.decodeIfPresent(String.self, forKey: .hfCache)
        mlxDevice = try? c.decodeIfPresent(String.self, forKey: .mlxDevice)
        mlxError = try? c.decodeIfPresent(String.self, forKey: .mlxError)
    }
}

/// `transcribe backends --json`.
public struct BackendsReport: Sendable, Equatable, Decodable {
    public struct Backend: Sendable, Equatable, Decodable {
        public var name: String
        public var description: String?
        public var defaultModel: String?
        public var modelAliases: [String: String]
        public var alignedLanguages: [String]
        public var isDefault: Bool

        enum CodingKeys: String, CodingKey {
            case name, description
            case defaultModel = "default_model"
            case modelAliases = "model_aliases"
            case alignedLanguages = "aligned_languages"
            case isDefault = "default"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            description = try? c.decodeIfPresent(String.self, forKey: .description)
            defaultModel = try? c.decodeIfPresent(String.self, forKey: .defaultModel)
            modelAliases = (try? c.decodeIfPresent([String: String].self, forKey: .modelAliases)) ?? [:]
            alignedLanguages = (try? c.decodeIfPresent([String].self, forKey: .alignedLanguages)) ?? []
            isDefault = (try? c.decode(Bool.self, forKey: .isDefault)) ?? false
        }
    }

    public var backends: [Backend]

    public var defaultBackend: Backend? { backends.first(where: \.isDefault) ?? backends.first }
}
