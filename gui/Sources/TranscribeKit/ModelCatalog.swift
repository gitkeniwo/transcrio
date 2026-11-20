import Foundation

/// One entry of the worker's `models` event: catalog facts plus the cache state.
public struct ModelInfo: Sendable, Equatable, Decodable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case asr, aligner, other
    }

    public enum Status: String, Sendable, Equatable, Hashable {
        case notDownloaded = "not_downloaded"
        case partial
        case downloaded
    }

    /// Catalog id: `1.7b`, `0.6b`, `aligner`.
    public var id: String
    public var repo: String
    public var kind: Kind
    public var name: String
    public var params: String
    /// Full download size.
    public var sizeBytes: Int64
    public var ramGB: Double?
    public var languages: [String]
    public var alignedLanguages: [String]
    public var license: String?
    public var url: URL?
    public var notes: String?
    public var status: Status
    public var bytesOnDisk: Int64
    /// In the worker's memory right now.
    public var loaded: Bool

    public init(id: String, repo: String, kind: Kind = .asr, name: String, params: String = "", sizeBytes: Int64,
                ramGB: Double? = nil, languages: [String] = [], alignedLanguages: [String] = [], license: String? = nil,
                url: URL? = nil, notes: String? = nil, status: Status = .notDownloaded, bytesOnDisk: Int64 = 0,
                loaded: Bool = false) {
        self.id = id
        self.repo = repo
        self.kind = kind
        self.name = name
        self.params = params
        self.sizeBytes = sizeBytes
        self.ramGB = ramGB
        self.languages = languages
        self.alignedLanguages = alignedLanguages
        self.license = license
        self.url = url
        self.notes = notes
        self.status = status
        self.bytesOnDisk = bytesOnDisk
        self.loaded = loaded
    }

    enum CodingKeys: String, CodingKey {
        case id, repo, kind, name, params, languages, license, url, notes, status, loaded
        case sizeBytes = "size_bytes"
        case ramGB = "ram_gb"
        case alignedLanguages = "aligned_languages"
        case bytesOnDisk = "bytes_on_disk"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repo = (try? c.decode(String.self, forKey: .repo)) ?? id
        kind = Kind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") ?? .other
        name = (try? c.decode(String.self, forKey: .name)) ?? repo
        params = (try? c.decode(String.self, forKey: .params)) ?? ""
        sizeBytes = (try? c.decode(Int64.self, forKey: .sizeBytes)) ?? 0
        ramGB = try? c.decodeIfPresent(Double.self, forKey: .ramGB)
        languages = (try? c.decode([String].self, forKey: .languages)) ?? []
        alignedLanguages = (try? c.decode([String].self, forKey: .alignedLanguages)) ?? []
        license = try? c.decodeIfPresent(String.self, forKey: .license)
        url = (try? c.decodeIfPresent(String.self, forKey: .url)).flatMap(URL.init(string:))
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        status = Status(rawValue: (try? c.decode(String.self, forKey: .status)) ?? "") ?? .notDownloaded
        bytesOnDisk = (try? c.decode(Int64.self, forKey: .bytesOnDisk)) ?? 0
        loaded = (try? c.decode(Bool.self, forKey: .loaded)) ?? false
    }

    public var isSpeechModel: Bool { kind == .asr }
    public var modelChoice: ModelChoice? { ModelChoice(rawValue: id) }
}

/// The GUI's view of every model: the worker's last `models` event plus the downloads it is
/// running now. Folding events in here keeps the Models window and the inspector in step.
public struct ModelCatalog: Sendable, Equatable {
    /// The five states the Models window shows.
    public enum DisplayState: Sendable, Equatable {
        case notDownloaded
        case downloading(fraction: Double?, downloaded: Int64, total: Int64)
        case partial(bytes: Int64)
        case downloaded
        case loaded
    }

    public var models: [ModelInfo]
    /// Active downloads by catalog id.
    public var downloads: [String: DownloadInfo]
    /// The last error per catalog id (cleared by a new download or success).
    public var errors: [String: String]
    /// Downloads that happen inside a job, by job id; they end with the job.
    private var jobDownloads: [String: String] = [:]

    public init(models: [ModelInfo] = [], downloads: [String: DownloadInfo] = [:], errors: [String: String] = [:]) {
        self.models = models
        self.downloads = downloads
        self.errors = errors
    }

    public subscript(id: String) -> ModelInfo? { models.first { $0.id == id || $0.repo == id } }

    /// The catalog id for a catalog id or a repo id.
    public func catalogID(for spec: String) -> String? { self[spec]?.id }

    public func state(of id: String) -> DisplayState {
        guard let m = self[id] else { return .notDownloaded }
        if let d = downloads[m.id] {
            return .downloading(fraction: d.fraction, downloaded: d.downloadedBytes, total: d.totalBytes)
        }
        if m.loaded { return .loaded }
        switch m.status {
        case .downloaded: return .downloaded
        case .partial: return .partial(bytes: m.bytesOnDisk)
        case .notDownloaded: return .notDownloaded
        }
    }

    public func isDownloaded(_ id: String) -> Bool { self[id]?.status == .downloaded }

    /// Bytes all models take on disk.
    public var totalBytesOnDisk: Int64 { models.reduce(0) { $0 + $1.bytesOnDisk } }

    /// A model is downloading: marks it before the first byte arrives.
    public mutating func beginDownload(_ id: String) {
        guard let m = self[id] else { return }
        errors[m.id] = nil
        if downloads[m.id] == nil {
            downloads[m.id] = DownloadInfo(model: m.repo, modelID: m.id, downloadedBytes: m.bytesOnDisk,
                                           totalBytes: m.sizeBytes)
        }
    }

    /// Folds one worker event in. Returns true when something changed.
    @discardableResult
    public mutating func apply(_ event: ServeEvent) -> Bool {
        switch event {
        case .models(let list):
            models = list
            // A model that is now complete can't still be downloading.
            for m in list where m.status == .downloaded { downloads[m.id] = nil }
            return true
        case .download(let job, let info):
            guard let id = info.modelID.flatMap(catalogID(for:)) ?? catalogID(for: info.model) else { return false }
            downloads[id] = info
            errors[id] = nil
            if let job { jobDownloads[job] = id }
            return true
        case .progress(let job?, let p) where p.stage == .load || p.stage == .transcribe:
            // Loading starts once the download is complete.
            guard let id = jobDownloads.removeValue(forKey: job) else { return false }
            downloads[id] = nil
            if let i = models.firstIndex(where: { $0.id == id }) { models[i].status = .downloaded }
            return true
        case .fileDone(let job, _), .fileError(let job, _), .fileStopped(let job, _):
            guard let id = jobDownloads.removeValue(forKey: job) else { return false }
            if let d = downloads.removeValue(forKey: id), let i = models.firstIndex(where: { $0.id == id }),
               models[i].status != .downloaded {
                models[i].status = models[i].bytesOnDisk > 0 || d.downloadedBytes > 0 ? .partial : .notDownloaded
            }
            return true
        case .modelReady(let model):
            guard let id = catalogID(for: model) else { return false }
            downloads[id] = nil
            if let i = models.firstIndex(where: { $0.id == id }) {
                models[i].status = .downloaded
                if models[i].bytesOnDisk < models[i].sizeBytes { models[i].bytesOnDisk = models[i].sizeBytes }
            }
            return true
        case .modelError(let model, let error, let cancelled):
            guard let model, let id = catalogID(for: model) else { return false }
            if let d = downloads.removeValue(forKey: id), let i = models.firstIndex(where: { $0.id == id }),
               models[i].status != .downloaded {
                // The next `models` event has the real size on disk; the byte counter
                // includes staging that a cancel throws away.
                models[i].status = models[i].bytesOnDisk > 0 || d.downloadedBytes > 0 ? .partial : .notDownloaded
            }
            if !cancelled { errors[id] = error }
            return true
        case .unloaded(let model, _):
            guard let model, let id = catalogID(for: model), let i = models.firstIndex(where: { $0.id == id }) else {
                return false
            }
            models[i].loaded = false
            return true
        case .modelRemoved(let model, _):
            guard let id = catalogID(for: model), let i = models.firstIndex(where: { $0.id == id }) else { return false }
            models[i].status = .notDownloaded
            models[i].bytesOnDisk = 0
            models[i].loaded = false
            return true
        default:
            return false
        }
    }

    /// Marks the model a job or preload just loaded (the worker holds one ASR model at a time).
    public mutating func markLoaded(_ spec: String) {
        guard let id = catalogID(for: spec) else { return }
        for i in models.indices where models[i].isSpeechModel {
            models[i].loaded = models[i].id == id
            if models[i].id == id { models[i].status = .downloaded }
        }
    }
}
