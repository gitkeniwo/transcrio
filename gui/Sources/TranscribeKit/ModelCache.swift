import Foundation

/// Models the CLI may download into the Hugging Face cache on first use.
public enum CachedModel: String, Sendable, CaseIterable, Hashable {
    case asr1_7b = "Qwen/Qwen3-ASR-1.7B"
    case asr0_6b = "Qwen/Qwen3-ASR-0.6B"
    /// Downloaded lazily inside `stage=align` the first time SRT/VTT is requested.
    case aligner = "Qwen/Qwen3-ForcedAligner-0.6B"

    /// `models--Qwen--Qwen3-ASR-1.7B`
    public var cacheDirectoryName: String { "models--" + rawValue.replacingOccurrences(of: "/", with: "--") }

    public var shortName: String {
        switch self {
        case .asr1_7b: "Qwen3-ASR 1.7B"
        case .asr0_6b: "Qwen3-ASR 0.6B"
        case .aligner: "Qwen3-ForcedAligner 0.6B"
        }
    }

    /// Approximate download size, for "first run ≈4 GB" style hints.
    public var approximateDownload: String {
        switch self {
        case .asr1_7b: "≈4 GB"
        case .asr0_6b: "≈1.5 GB"
        case .aligner: "≈1.2 GB"
        }
    }
}

/// Probes the Hugging Face cache. A model counts as cached when
/// `<root>/hub/<models--…>/snapshots/*/` contains a `.safetensors` file.
public struct ModelCache: Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    /// Cache root: `hf_cache` from `doctor --json`, else `$HF_HOME`, else `~/.cache/huggingface`.
    public init(doctorHFCache: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: String = NSHomeDirectory()) {
        let path = doctorHFCache?.nilIfEmpty ?? environment["HF_HOME"]?.nilIfEmpty ?? "\(homeDirectory)/.cache/huggingface"
        root = URL(fileURLWithPath: path, isDirectory: true)
    }

    public func directory(for model: CachedModel) -> URL {
        root.appendingPathComponent("hub", isDirectory: true).appendingPathComponent(model.cacheDirectoryName, isDirectory: true)
    }

    public func isCached(_ model: CachedModel) -> Bool {
        let fm = FileManager.default
        let snapshots = directory(for: model).appendingPathComponent("snapshots", isDirectory: true)
        guard let revisions = try? fm.contentsOfDirectory(atPath: snapshots.path) else { return false }
        for rev in revisions {
            let files = (try? fm.contentsOfDirectory(atPath: snapshots.appendingPathComponent(rev).path)) ?? []
            if files.contains(where: { $0.hasSuffix(".safetensors") }) { return true }
        }
        return false
    }

    public func status() -> [CachedModel: Bool] {
        Dictionary(uniqueKeysWithValues: CachedModel.allCases.map { ($0, isCached($0)) })
    }
}
