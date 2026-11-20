import Foundation

// The `transcribe serve` protocol: NDJSON ops on stdin, NDJSON events on stdout. See the
// "serve" section of the README. Job ids are the GUI's; events without an id belong to the
// worker (model downloads, preloads, idle/unload notices).

/// One paragraph of transcript with its audio span: a `segment` event while a file runs, or
/// an entry of `file_done.segments`.
public struct TranscriptSegment: Sendable, Equatable, Codable, Hashable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = (try? c.decode(Double.self, forKey: .start)) ?? 0
        end = (try? c.decode(Double.self, forKey: .end)) ?? start
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
    }
}

/// The `job` object of an `enqueue` op.
public struct ServeJob: Sendable, Equatable, Encodable {
    public var id: String
    public var input: String
    public var formats: [String]
    public var outputDir: String?
    public var timestamps: Bool
    public var language: String?
    public var context: String
    public var overwrite: Bool
    /// Catalog id (`1.7b`, `0.6b`) or repo id; nil = the worker's default.
    public var model: String?
    /// Align subtitle cues even when no cue format is asked for (the library's transcript.json
    /// keeps them for later exports). nil = not sent.
    public var align: Bool?
    /// Where the worker writes the full transcript (`Transcript.to_dict`); file_done then
    /// carries `transcript`. nil = not sent.
    public var transcriptPath: String?

    public init(id: String, input: String, formats: [String], outputDir: String? = nil, timestamps: Bool = false,
                language: String? = nil, context: String = "", overwrite: Bool = false, model: String? = nil,
                align: Bool? = nil, transcriptPath: String? = nil) {
        self.id = id
        self.input = input
        self.formats = formats
        self.outputDir = outputDir
        self.timestamps = timestamps
        self.language = language
        self.context = context
        self.overwrite = overwrite
        self.model = model
        self.align = align
        self.transcriptPath = transcriptPath
    }

    /// The job for one file with its own options.
    public init(id: String, url: URL, options: TranscribeOptions) {
        self.init(
            id: id, input: url.path,
            formats: OutputFormat.allCases.filter(options.formats.contains).map(\.rawValue),
            outputDir: options.outputDirectory?.path,
            timestamps: options.timestamps,
            language: options.language.flatMap { $0.lowercased() == "auto" || $0.isEmpty ? nil : $0 },
            context: options.contextTerms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: " "),
            overwrite: options.overwrite,
            model: options.model.rawValue)
    }

    enum CodingKeys: String, CodingKey {
        case id, input, formats, timestamps, language, context, overwrite, model, align
        case outputDir = "output_dir", transcriptPath = "transcript_path"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(input, forKey: .input)
        try c.encode(formats, forKey: .formats)
        try c.encodeIfPresent(outputDir, forKey: .outputDir)
        try c.encode(timestamps, forKey: .timestamps)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encode(context, forKey: .context)
        try c.encode(overwrite, forKey: .overwrite)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(align, forKey: .align)
        try c.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
    }
}

/// An `export` op: render formats from a saved transcript, no model (answered on the worker's
/// reader thread, so it never waits for a job).
public struct ServeExport: Sendable, Equatable {
    public var id: String
    /// transcript.json.
    public var transcript: String
    public var formats: [String]
    public var outputDir: String
    public var timestamps: Bool
    /// Output files are `<title>.<ext>`; nil = the transcript's source stem.
    public var title: String?

    public init(id: String, transcript: String, formats: [String], outputDir: String, timestamps: Bool = false,
                title: String? = nil) {
        self.id = id
        self.transcript = transcript
        self.formats = formats
        self.outputDir = outputDir
        self.timestamps = timestamps
        self.title = title
    }
}

/// An `align` op: re-time a saved transcript's subtitles with the forced aligner, without
/// transcribing again. It loads the aligner, so the worker queues it like a job.
public struct ServeAlign: Sendable, Equatable {
    public var id: String
    /// transcript.json to align.
    public var transcript: String
    /// The audio or video it was transcribed from.
    public var source: String
    /// Where the aligned transcript goes; nil = replace `transcript`.
    public var output: String?

    public init(id: String, transcript: String, source: String, output: String? = nil) {
        self.id = id
        self.transcript = transcript
        self.source = source
        self.output = output
    }
}

/// An op written to the worker's stdin.
public enum ServeOp: Sendable, Equatable {
    case enqueue(ServeJob)
    /// A queued job is dropped (`file_stopped`, stopped_at 0); a running one stops at the next
    /// chunk boundary.
    case cancel(id: String)
    case cancelAll
    case configure(idleUnloadSec: Double)
    /// Load (downloading first if needed) a model now. nil = the default model.
    case preload(model: String?)
    case models
    case download(model: String)
    case cancelDownload(model: String)
    case removeModel(model: String)
    case export(ServeExport)
    case align(ServeAlign)
    case shutdown

    public var name: String {
        switch self {
        case .enqueue: "enqueue"
        case .cancel: "cancel"
        case .cancelAll: "cancel_all"
        case .configure: "configure"
        case .preload: "preload"
        case .models: "models"
        case .download: "download"
        case .cancelDownload: "cancel_download"
        case .removeModel: "remove_model"
        case .export: "export"
        case .align: "align"
        case .shutdown: "shutdown"
        }
    }

    /// One NDJSON line, newline included.
    public func encoded() -> Data {
        var obj: [String: Any] = ["op": name]
        switch self {
        case .enqueue(let job):
            let data = (try? JSONEncoder().encode(job)) ?? Data("{}".utf8)
            obj["job"] = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        case .cancel(let id): obj["id"] = id
        case .configure(let sec): obj["idle_unload_sec"] = sec
        case .preload(let model): if let model { obj["model"] = model }
        case .download(let m), .cancelDownload(let m), .removeModel(let m): obj["model"] = m
        case .export(let e):
            obj["id"] = e.id
            obj["transcript"] = e.transcript
            obj["formats"] = e.formats
            obj["output_dir"] = e.outputDir
            obj["timestamps"] = e.timestamps
            if let title = e.title { obj["title"] = title }
        case .align(let a):
            obj["id"] = a.id
            obj["transcript"] = a.transcript
            obj["source"] = a.source
            if let output = a.output { obj["output"] = output }
        case .cancelAll, .models, .shutdown: break
        }
        var line = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        line.append(0x0A)
        return line
    }
}

/// A `segment` event: one chunk's text, sent as soon as it is transcribed.
public struct LiveSegment: Sendable, Equatable {
    /// 1-based chunk number.
    public var index: Int
    public var totalChunks: Int
    public var segment: TranscriptSegment
    public var language: String?

    public init(index: Int, totalChunks: Int, segment: TranscriptSegment, language: String? = nil) {
        self.index = index
        self.totalChunks = totalChunks
        self.segment = segment
        self.language = language
    }
}

/// Why the worker unloaded its model (`unloaded.reason`).
public enum UnloadReason: String, Sendable, Equatable {
    case idle, `switch`, remove, shutdown, unknown
}

/// One stdout line from `transcribe serve`.
public enum ServeEvent: Sendable, Equatable {
    case accepted(id: String)
    /// `decode`/`load`/`transcribe`/`align`. `id` is nil for a preload's load progress.
    case progress(id: String?, ProgressInfo)
    /// Model download bytes: inside a job (`id` set) or from a `download`/`preload` op.
    case download(id: String?, DownloadInfo)
    case segment(id: String, LiveSegment)
    case fileDone(id: String, FileResult)
    case fileError(id: String, error: String)
    /// Cancelled (or shut down): `stoppedAt` is the audio time reached, 0 for a job that
    /// never started. Outputs are deleted.
    case fileStopped(id: String, stoppedAt: Double)
    /// The queue drained with a model loaded.
    case idle
    case models([ModelInfo])
    case configured(idleUnloadSec: Double)
    case unloaded(model: String?, reason: UnloadReason)
    case modelReady(model: String)
    case modelError(model: String?, error: String, cancelled: Bool)
    /// Followed by a `models` event with the new statuses.
    case modelRemoved(model: String, freedBytes: Int64)
    case log(id: String?, level: String, message: String)
    /// The answer to an `export` op: format → file written. `estimatedCues`: srt/vtt came from a
    /// transcript without cues.
    case exported(id: String, outputs: [String: String], estimatedCues: Bool)
    case exportError(id: String, message: String)
    /// The answer to an `align` op: the aligned transcript was written to `transcript`.
    case aligned(id: String, transcript: String, cueTiming: CueTiming?, notices: [Notice])
    case alignError(id: String, message: String, cancelled: Bool)
    case unknown(event: String)

    /// The job this event belongs to, if any.
    public var jobID: String? {
        switch self {
        case .accepted(let id), .segment(let id, _), .fileDone(let id, _), .fileError(let id, _),
             .fileStopped(let id, _): id
        case .progress(let id, _), .download(let id, _), .log(let id, _, _): id
        default: nil
        }
    }

    /// Whether this event ends its job.
    public var isTerminal: Bool {
        switch self {
        case .fileDone, .fileError, .fileStopped: true
        default: false
        }
    }

    /// Decodes one line; nil for anything that isn't a JSON object with an `event`.
    public static func decode(_ line: String) -> ServeEvent? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = obj["event"] as? String
        else { return nil }
        let id = obj["id"] as? String
        func num(_ key: String) -> Double? { (obj[key] as? NSNumber)?.doubleValue }
        func int(_ key: String) -> Int? { (obj[key] as? NSNumber)?.intValue }
        func str(_ key: String) -> String? { obj[key] as? String }

        switch event {
        case "accepted":
            guard let id else { return .unknown(event: event) }
            return .accepted(id: id)
        case "progress":
            let stage = str("stage")
            if stage == "download" {
                // Job downloads: `model` is the repo, `model_id` the catalog id. Download-op
                // events: `model` is the catalog id, `repo` the repo.
                let repo = str("repo") ?? str("model") ?? ""
                let modelID = str("model_id") ?? (str("repo") != nil ? str("model") : nil)
                let downloaded = Int64(num("downloaded_bytes") ?? 0)
                let total = Int64(num("total_bytes") ?? 0)
                return .download(id: id, DownloadInfo(model: repo, modelID: modelID, downloadedBytes: downloaded,
                                                      totalBytes: total))
            }
            return .progress(id: id, ProgressInfo(
                stage: stage.flatMap(Stage.init(rawValue:)), stageName: stage,
                progress: min(max(num("progress") ?? 0, 0), 1), chunk: int("chunk"), totalChunks: int("total_chunks")))
        case "segment":
            guard let id else { return .unknown(event: event) }
            let start = num("start") ?? 0
            return .segment(id: id, LiveSegment(
                index: int("index") ?? 0, totalChunks: int("total_chunks") ?? 0,
                segment: TranscriptSegment(start: start, end: num("end") ?? start, text: str("text") ?? ""),
                language: str("language")))
        case "file_done":
            guard let id, let r = try? JSONDecoder().decode(FileResult.self, from: data) else {
                return .unknown(event: event)
            }
            return .fileDone(id: id, r)
        case "file_error":
            guard let id else { return .unknown(event: event) }
            return .fileError(id: id, error: str("error") ?? "Unknown error")
        case "file_stopped":
            guard let id else { return .unknown(event: event) }
            return .fileStopped(id: id, stoppedAt: num("stopped_at") ?? 0)
        case "idle":
            return .idle
        case "models":
            guard let list = obj["models"],
                  let raw = try? JSONSerialization.data(withJSONObject: list),
                  let models = try? JSONDecoder().decode([ModelInfo].self, from: raw)
            else { return .unknown(event: event) }
            return .models(models)
        case "configured":
            return .configured(idleUnloadSec: num("idle_unload_sec") ?? 0)
        case "unloaded":
            return .unloaded(model: str("model"), reason: UnloadReason(rawValue: str("reason") ?? "") ?? .unknown)
        case "model_ready":
            return .modelReady(model: str("model") ?? "")
        case "model_error":
            return .modelError(model: str("model"), error: str("error") ?? "Unknown error",
                               cancelled: (obj["cancelled"] as? Bool) ?? false)
        case "model_removed":
            return .modelRemoved(model: str("model") ?? "", freedBytes: Int64(num("freed_bytes") ?? 0))
        case "log":
            return .log(id: id, level: str("level") ?? "info", message: str("message") ?? "")
        case "exported":
            guard let id else { return .unknown(event: event) }
            return .exported(id: id, outputs: (obj["outputs"] as? [String: String]) ?? [:],
                             estimatedCues: (obj["estimated_cues"] as? Bool) ?? false)
        case "export_error":
            guard let id else { return .unknown(event: event) }
            return .exportError(id: id, message: str("message") ?? "Export failed")
        case "aligned":
            guard let id else { return .unknown(event: event) }
            let notices = (obj["notices"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode([Notice].self, from: $0) } ?? []
            return .aligned(id: id, transcript: str("transcript") ?? "", cueTiming: str("cue_timing").flatMap(CueTiming.init(rawValue:)),
                            notices: notices)
        case "align_error":
            guard let id else { return .unknown(event: event) }
            return .alignError(id: id, message: str("message") ?? "Alignment failed", cancelled: (obj["cancelled"] as? Bool) ?? false)
        default:
            return .unknown(event: event)
        }
    }
}
