import Foundation
import SwiftUI
import TranscribeKit

/// An Align Subtitles run: the worker force-aligns a saved transcript against its
/// source. Only the aligner loads, no ASR model.
struct AlignProgress: Equatable {
    /// 0…1 once the worker reports it; nil while waiting for the worker (or a running file).
    var fraction: Double?
    var label = "Waiting…"
}

enum AlignReply {
    case done(cueTiming: CueTiming?, notices: [Notice])
    case failed(String, cancelled: Bool)
}

extension AppModel {
    /// What the estimated-timing note and the row menu offer for this entry.
    func alignOffer(_ entry: LibraryEntry, timing: EstimatedTiming?) -> AlignOffer {
        AlignOffer.make(timing: timing, language: entry.language,
                        alignedLanguages: backends?.defaultBackend?.alignedLanguages ?? [],
                        sourceMissing: sourceMissing(entry))
    }

    /// Align Subtitles: real cue times replace the estimated ones in the master transcript.json;
    /// srt and vtt are made again on the next export (md and txt don't change).
    func alignSubtitles(_ id: LibraryEntry.ID) {
        guard let entry = library[id], aligning[id] == nil, !sourceMissing(entry), libraryUnavailable == nil else { return }
        let staging: URL
        do {
            staging = try library.makeAlignStaging()
        } catch {
            show(Toast(pane: .inspector, text: Toast.styled("Couldn’t align: \(error.localizedDescription)"), failed: true))
            return
        }
        let jobID = "align-\(UUID().uuidString.prefix(8).lowercased())"
        alignJobs[jobID] = id
        alignFailures[id] = nil
        aligning[id] = AlignProgress()
        let request = ServeAlign(id: jobID, transcript: library.transcriptURL(entry).path, source: entry.sourcePath, output: staging.path)
        Task {
            let reply = await runAlign(request)
            alignJobs[jobID] = nil
            aligning[id] = nil
            switch reply {
            case .done(let timing, let notices):
                do {
                    let count = FileResult(cueTiming: timing, warnings: [], notices: notices).noticeCount
                    if let updated = try library.commitAlignment(id, aligned: staging, cueTiming: timing, noticeCount: count) {
                        let text = updated.cueTiming == .aligned
                            ? "Aligned subtitles for **\(updated.title)**"
                            : "Aligned **\(updated.title)** · some cues are still estimated"
                        show(Toast(pane: .inspector, text: Toast.styled(text)))
                    }
                } catch {
                    alignFailures[id] = error.localizedDescription
                    show(Toast(pane: .inspector, text: Toast.styled("Couldn’t save the aligned transcript"), failed: true))
                }
            case .failed(let message, let cancelled):
                try? FileManager.default.removeItem(at: staging.deletingLastPathComponent())
                if !cancelled {
                    alignFailures[id] = message
                    show(Toast(pane: .inspector, text: Toast.styled("Couldn’t align **\(entry.title)**"), failed: true))
                }
            }
            pump()
        }
    }

    func cancelAlign(_ id: LibraryEntry.ID) {
        guard let job = alignJobs.first(where: { $0.value == id })?.key else { return }
        Task { await ensureWorker()?.send(ServeOp.cancel(id: job)) }
    }

    private func runAlign(_ request: ServeAlign) async -> AlignReply {
        guard let worker = await ensureWorker() else {
            return .failed("The transcribe command isn’t available.", cancelled: false)
        }
        return await withCheckedContinuation { c in
            alignWaiters[request.id] = c
            Task {
                if !(await worker.send(.align(request))) {
                    alignWaiters.removeValue(forKey: request.id)?.resume(returning: .failed("The transcribe worker quit.", cancelled: false))
                }
            }
        }
    }

    /// Worker events for align jobs; true when the event was one.
    func applyAlign(_ event: ServeEvent) -> Bool {
        switch event {
        case .aligned(let id, _, let timing, let notices):
            alignWaiters.removeValue(forKey: id)?.resume(returning: .done(cueTiming: timing, notices: notices))
        case .alignError(let id, let message, let cancelled):
            alignWaiters.removeValue(forKey: id)?.resume(returning: .failed(message, cancelled: cancelled))
        case .accepted(let id):
            guard let entry = alignJobs[id] else { return false }
            aligning[entry]?.label = "Starting…"
        case .progress(let id?, let p):
            guard let entry = alignJobs[id] else { return false }
            switch p.stage {
            case .decode: aligning[entry] = AlignProgress(fraction: nil, label: "Reading audio…")
            case .load: aligning[entry] = AlignProgress(fraction: nil, label: "Loading aligner…")
            default:
                let part = p.totalChunks.map { $0 > 1 ? " · part \(min(max(p.chunk ?? 1, 1), $0)) of \($0)" : "" } ?? ""
                aligning[entry] = AlignProgress(fraction: p.progress, label: "Aligning\(part)")
            }
        case .download(let id?, let d):
            guard let entry = alignJobs[id] else { return false }
            let f = d.totalBytes > 0 ? Double(d.downloadedBytes) / Double(d.totalBytes) : nil
            aligning[entry] = AlignProgress(fraction: f, label: "Downloading aligner…")
        default:
            return false
        }
        return true
    }

    /// The worker quit: every align waiting on it fails.
    func failAligns(_ message: String) {
        for (_, w) in alignWaiters { w.resume(returning: .failed(message, cancelled: false)) }
        alignWaiters = [:]
    }
}
