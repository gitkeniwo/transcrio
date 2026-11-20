import Foundation
import Observation
import TranscribeKit

/// Full-text search across History. The index is built the
/// first time Text scope searches, off the main thread, and kept current by each entry's
/// search stamp (Transcribe Again and Align Subtitles rewrite transcript.json).
@MainActor
@Observable
final class TranscriptSearcher {
    /// Transcripts still being read (the History header says "Reading transcripts…").
    private(set) var pending = 0
    /// Bumped when the index changes, so cached hits are recomputed.
    private(set) var version = 0
    @ObservationIgnored private var index = TranscriptSearchIndex()
    @ObservationIgnored private var loading = false
    /// The library changed while transcripts were being read: sync again afterwards.
    @ObservationIgnored private var resync: LibraryStore?
    @ObservationIgnored private var cache: (query: String, version: Int, hits: [String: SearchSnippet])?

    /// Reads the transcripts that are new or changed since they were indexed; drops removed ones.
    func sync(_ library: LibraryStore) {
        guard !loading else { resync = library; return }
        var stamps: [String: String] = [:]
        var urls: [String: URL] = [:]
        for entry in library.entries {
            stamps[entry.id] = library.searchStamp(entry)
            urls[entry.id] = library.transcriptURL(entry)
        }
        let before = index.count
        index.prune(keeping: Set(stamps.keys))
        if index.count != before { version += 1 }
        let stale = index.stale(stamps)
        guard !stale.isEmpty else { return }
        loading = true
        pending = stale.count
        Task {
            // A few at a time, so the first hits show while a large library is still being read.
            for batch in stride(from: 0, to: stale.count, by: 32).map({ Array(stale[$0..<min($0 + 32, stale.count)]) }) {
                let jobs = batch.map { ($0, stamps[$0] ?? "", urls[$0]!) }
                let loaded = await Task.detached(priority: .userInitiated) {
                    jobs.map { id, stamp, url in
                        (id, stamp, (try? Data(contentsOf: url)).flatMap(TranscriptSearchIndex.searchableText(transcriptJSON:)) ?? "")
                    }
                }.value
                for (id, stamp, text) in loaded { index.set(id, stamp: stamp, text: text) }
                pending = max(pending - batch.count, 0)
                version += 1
            }
            loading = false
            pending = 0
            if let next = resync {
                resync = nil
                sync(next)
            }
        }
    }

    /// Entry id → snippet for every transcript containing `query`.
    func hits(_ query: String) -> [String: SearchSnippet] {
        if let cache, cache.query == query, cache.version == version { return cache.hits }
        let hits = index.search(query)
        cache = (query, version, hits)
        return hits
    }
}

extension AppModel {
    /// The trimmed search text.
    var searchQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    /// Text scope with something typed: History matches transcript text.
    var searchingText: Bool { searchScope == .text && !searchQuery.isEmpty }

    /// The snippet for a History row in Text scope.
    func searchSnippet(_ id: LibraryEntry.ID) -> SearchSnippet? {
        searchingText ? searcher.hits(searchQuery)[id] : nil
    }

    /// Text scope needs the index: read what changed since it was last used.
    func syncSearchIndex() {
        guard searchingText else { return }
        searcher.sync(library)
    }
}
