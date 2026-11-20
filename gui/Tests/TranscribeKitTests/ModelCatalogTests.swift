import Foundation
import Testing
@testable import TranscribeKit

struct ModelCatalogTests {
    @Test func recordedDownloadSessionWalksTheStates() throws {
        var catalog = ModelCatalog()
        var seen: [ModelCatalog.DisplayState] = []
        for e in try Fixtures.serveEvents("serve-download") {
            catalog.apply(e)
            let s = catalog.state(of: "0.6b")
            let kind: ModelCatalog.DisplayState = switch s {
            case .downloading: .downloading(fraction: nil, downloaded: 0, total: 0)
            case .partial: .partial(bytes: 0)
            default: s
            }
            if seen.last != kind { seen.append(kind) }
        }
        #expect(seen == [.notDownloaded, .downloading(fraction: nil, downloaded: 0, total: 0), .partial(bytes: 0),
                         .downloading(fraction: nil, downloaded: 0, total: 0), .partial(bytes: 0)])
        // Byte counts come from the last `models` event, not the download counter.
        #expect(catalog.state(of: "0.6b") == .partial(bytes: 4_468_999))
        #expect(catalog.errors.isEmpty)  // a cancel isn't an error
    }

    func sample() -> ModelCatalog {
        ModelCatalog(models: [
            ModelInfo(id: "1.7b", repo: "Qwen/Qwen3-ASR-1.7B", name: "1.7B", sizeBytes: 4_000, status: .downloaded,
                      bytesOnDisk: 4_000, loaded: true),
            ModelInfo(id: "0.6b", repo: "Qwen/Qwen3-ASR-0.6B", name: "0.6B", sizeBytes: 1_800),
            ModelInfo(id: "aligner", repo: "Qwen/Qwen3-ForcedAligner-0.6B", kind: .aligner, name: "Aligner",
                      sizeBytes: 1_200, status: .partial, bytesOnDisk: 300),
        ])
    }

    @Test func fiveStates() {
        var c = sample()
        #expect(c.state(of: "1.7b") == .loaded)
        #expect(c.state(of: "Qwen/Qwen3-ASR-1.7B") == .loaded)
        #expect(c.state(of: "0.6b") == .notDownloaded)
        #expect(c.state(of: "aligner") == .partial(bytes: 300))
        c.apply(.unloaded(model: "Qwen/Qwen3-ASR-1.7B", reason: .idle))
        #expect(c.state(of: "1.7b") == .downloaded)
        c.beginDownload("0.6b")
        #expect(c.state(of: "0.6b") == .downloading(fraction: 0, downloaded: 0, total: 1_800))
        c.apply(.download(id: nil, DownloadInfo(model: "Qwen/Qwen3-ASR-0.6B", modelID: "0.6b", downloadedBytes: 900,
                                                totalBytes: 1_800)))
        #expect(c.state(of: "0.6b") == .downloading(fraction: 0.5, downloaded: 900, total: 1_800))
        c.apply(.modelReady(model: "0.6b"))
        #expect(c.state(of: "0.6b") == .downloaded)
        #expect(c.totalBytesOnDisk == 4_000 + 1_800 + 300)
    }

    @Test func jobDownloadsAreMatchedByRepo() {
        var c = sample()
        c.apply(.download(id: "f1", DownloadInfo(model: "Qwen/Qwen3-ForcedAligner-0.6B", downloadedBytes: 600,
                                                 totalBytes: 1_200)))
        #expect(c.state(of: "aligner") == .downloading(fraction: 0.5, downloaded: 600, total: 1_200))
    }

    @Test func errorsAndRemoval() {
        var c = sample()
        c.beginDownload("0.6b")
        c.apply(.modelError(model: "0.6b", error: "offline", cancelled: false))
        #expect(c.errors["0.6b"] == "offline")
        #expect(c.state(of: "0.6b") == .notDownloaded)
        c.beginDownload("0.6b")
        #expect(c.errors["0.6b"] == nil)

        c.apply(.modelRemoved(model: "1.7b", freedBytes: 4_000))
        #expect(c.state(of: "1.7b") == .notDownloaded)
        #expect(c["1.7b"]?.bytesOnDisk == 0)
    }

    @Test func markLoadedKeepsOneSpeechModel() {
        var c = sample()
        c.markLoaded("Qwen/Qwen3-ASR-0.6B")
        #expect(c["0.6b"]?.loaded == true)
        #expect(c["1.7b"]?.loaded == false)
        #expect(c["aligner"]?.loaded == false)
    }
}
