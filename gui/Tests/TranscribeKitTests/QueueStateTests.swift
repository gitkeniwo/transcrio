import Foundation
import Testing
@testable import TranscribeKit

/// The queue state machine: every row state, scheduling, drag, queue and unqueue, fed with
/// events recorded from the real `transcribe serve`.
struct QueueStateTests {
    let clock = ManualClock()

    func queue(_ names: [String] = ["a.m4a", "b.mp3", "c.wav"], options: TranscribeOptions = TranscribeOptions())
        -> (QueueModel, [FileItem.ID]) {
        var q = QueueModel(clock: clock)
        let ids = q.add(names.map { URL(fileURLWithPath: "/tmp/q/\($0)") }, options: options)
        for id in ids { q.update(id) { $0.duration = 150.02 } }
        return (q, ids)
    }

    /// Recorded events of one fixture job, re-addressed to `jobID`.
    func recorded(_ fixture: String, job: String, as jobID: String) throws -> [ServeEvent] {
        try Fixtures.serveSession(fixture).filter { $0.dir == "out" }.compactMap { line -> ServeEvent? in
            guard line.line.contains("\"id\":\"\(job)\"") else { return nil }
            return ServeEvent.decode(line.line.replacingOccurrences(of: "\"id\":\"\(job)\"", with: "\"id\":\"\(jobID)\""))
        }
    }

    func status(_ q: QueueModel, _ id: FileItem.ID, cached: Bool = true) -> RowStatus {
        q.status(of: q[id]!, isCached: { _ in cached })
    }

    // MARK: States

    @Test func addedFilesAreReadyWithTheirOwnOptions() {
        let (q, ids) = queue(options: TranscribeOptions(formats: [.srt]))
        #expect(ids.count == 3)
        #expect(ids.allSatisfy { status(q, $0) == .ready })
        #expect(q[ids[0]]?.options.formats == [.srt])
        #expect(q.sections().map(\.ids) == [[], [], ids, []])
        #expect(!q.hasWork)
    }

    @Test func addWithAutoQueueGoesToUpNext() {
        var q = QueueModel(clock: clock)
        let ids = q.add([URL(fileURLWithPath: "/x/a.m4a"), URL(fileURLWithPath: "/x/b.m4a")], queue: true)
        #expect(q.upNext == ids)
        #expect(status(q, ids[1]) == .queued(ordinal: 2))
        // The same path again is skipped while it isn't finished.
        #expect(q.add([URL(fileURLWithPath: "/x/a.m4a")]).isEmpty)
    }

    @Test func recordedJobWalksDecodeLoadTranscribeDone() throws {
        var (q, ids) = queue(["podcast-zh.m4a"])
        q.queue(ids)
        #expect(status(q, ids[0]) == .queued(ordinal: 1))
        let (id, job) = try q.next()
        #expect(id == ids[0])
        #expect(job.input == "/tmp/q/podcast-zh.m4a")
        #expect(status(q, id) == .decoding)
        #expect(q.currentID == id && q.upNext.isEmpty)
        #expect(q.startNext() == nil)  // one job at a time

        var seen: [String] = []
        for e in try recorded("serve-jobs", job: "j1", as: job.id) {
            clock.advance(by: 0.5)
            q.apply(e)
            let s: String = switch status(q, id) {
            case .decoding: "decode"
            case .loadingModel: "load"
            case .transcribing: "transcribe"
            case .done: "done"
            case .doneWithNotices: "notices"
            default: "other \(status(q, id))"
            }
            if seen.last != s { seen.append(s) }
        }
        #expect(seen.first == "decode")
        #expect(seen.contains("load"))
        #expect(seen.contains("transcribe"))
        #expect(seen.last == "done" || seen.last == "notices")
        #expect(!seen.contains { $0.hasPrefix("other") }, "per-chunk align must not flip the row: \(seen)")
        let item = try #require(q[id])
        #expect(item.liveSegments.count == 8)
        #expect(item.segments.count == 8)
        #expect(item.alignedChunks == 8)
        #expect(item.stages[.load] != nil && item.stages[.transcribe] != nil && item.stages[.align] != nil)
        // Decode opens when the job is sent and closes when the model starts loading.
        #expect(item.stages[.decode]?.end != nil)
        #expect(!item.modelWasWarm)
        #expect(q.currentID == nil)
        #expect(q.sections().first { $0.section == .finished }?.ids == [id])
        #expect(item.ranWith == item.options)
    }

    @Test func transcribingPercentFollowsSegmentsAndChunks() throws {
        var (q, ids) = queue(["podcast-zh.m4a"])
        q.queue(ids)
        let job = try q.next().job
        let events = try recorded("serve-jobs", job: "j1", as: job.id)
        let thirdSegment = try #require(events.firstIndex {
            if case .segment(_, let s) = $0 { s.index == 3 } else { false }
        })
        for e in events[...thirdSegment] { q.apply(e) }
        guard case .transcribing(let pct, let chunk, let total) = status(q, ids[0]) else {
            Issue.record("transcribing expected, got \(status(q, ids[0]))"); return
        }
        #expect(abs(pct - 48.27 / 150.02) < 0.01)
        #expect(chunk == 3 && total == 8)
        let ranges = q[ids[0]]!.chunkRanges(total: 8)
        #expect(abs(ranges[1].lowerBound - 14.53 / 150.02) < 0.001)
        #expect(abs(ranges[2].upperBound - 48.27 / 150.02) < 0.001)
        let wf = q[ids[0]]!.waveformProgress(status(q, ids[0]))
        #expect(wf.tone == .working && abs(wf.fraction - pct) < 0.001)
    }

    @Test func warmModelSkipsLoad() throws {
        var (q, ids) = queue(["chapter-en.mp3"])
        q.queue(ids)
        let job = try q.next().job
        // j2 in the recording switched models (load); drop its load events to simulate warm.
        for e in try recorded("serve-jobs", job: "j2", as: job.id) {
            if case .progress(_, let p) = e, p.stage == .load { continue }
            q.apply(e)
        }
        #expect(q[ids[0]]?.modelWasWarm == true)
        #expect(q[ids[0]]?.result != nil)
    }

    @Test func stoppingThenStopped() throws {
        var (q, ids) = queue(["podcast-zh.m4a"])
        q.queue(ids)
        let job = try q.next().job
        let events = try recorded("serve-jobs", job: "j3", as: job.id)
        let cut = try #require(events.firstIndex { if case .segment(_, let s) = $0 { s.index == 2 } else { false } })
        for e in events[...cut] { q.apply(e) }
        #expect(q.requestStop(ids[0]) == job.id)
        guard case .stopping(let pct) = status(q, ids[0]) else { Issue.record("stopping"); return }
        #expect(pct > 0.2)
        #expect(q.requestStop(ids[0]) == job.id)  // asking again is harmless
        for e in events[(cut + 1)...] { q.apply(e) }
        #expect(status(q, ids[0]) == .stopped(at: 48.27))
        #expect(abs(q[ids[0]]!.reachedFraction - 48.27 / 150.02) < 0.001)
        #expect(q.currentID == nil)
        #expect(q[ids[0]]!.waveformProgress(status(q, ids[0])).tone == .finished)
    }

    @Test func failedFromFileError() throws {
        var (q, ids) = queue(["missing.m4a"])
        q.queue(ids)
        let job = try q.next().job
        for e in try recorded("serve-jobs", job: "j4", as: job.id) { q.apply(e) }
        guard case .failed(let msg) = status(q, ids[0]) else { Issue.record("failed"); return }
        #expect(msg.contains("no such file"))
        #expect(q.currentID == nil)
        #expect(status(q, ids[0]).isIssue)
    }

    @Test func doneWithNotices() throws {
        var (q, ids) = queue(["a.m4a"])
        q.queue(ids)
        let job = try q.next().job
        q.apply(.fileDone(id: job.id, FileResult(duration: 60, cueTiming: .estimated)))
        #expect(status(q, ids[0]) == .doneWithNotices(1))
        let wf = q[ids[0]]!.waveformProgress(status(q, ids[0]))
        #expect(wf.estimated == [0...1])
        #expect(q[ids[0]]?.duration == 60)
    }

    @Test func realDownloadPercentThenStop() throws {
        var (q, ids) = queue(["chapter-en.mp3"])
        q.queue(ids)
        let job = try q.next().job
        let events = try recorded("serve-download", job: "d1", as: job.id)
        let lastDownload = try #require(events.lastIndex { if case .download = $0 { true } else { false } })
        for e in events[...lastDownload] { clock.advance(by: 0.5); q.apply(e) }
        guard case .preparingModel(let model, let progress?) = status(q, ids[0], cached: false) else {
            Issue.record("preparing with bytes, got \(status(q, ids[0]))"); return
        }
        #expect(model == .asr0_6b)
        #expect(progress.info.totalBytes > 1_000_000_000)
        #expect(progress.info.fraction! > 0)
        #expect(progress.bytesPerSecond != nil)
        for e in events[(lastDownload + 1)...] { q.apply(e) }
        #expect(status(q, ids[0]) == .stopped(at: 0))
    }

    @Test func preparingModelFallbackWithoutBytes() throws {
        var (q, ids) = queue(["a.m4a"])
        q.queue(ids)
        let job = try q.next().job
        q.apply(.progress(id: job.id, ProgressInfo(stage: .decode, progress: 0)))
        q.apply(.progress(id: job.id, ProgressInfo(stage: .load, progress: 0)))
        #expect(status(q, ids[0], cached: false) == .loadingModel)
        clock.advance(by: 4)
        #expect(status(q, ids[0], cached: true) == .loadingModel)
        #expect(status(q, ids[0], cached: false) == .preparingModel(.asr1_7b, nil))
    }

    @Test func alignerDownloadShowsAligningStatePreparing() throws {
        var (q, ids) = queue(["a.m4a"], options: TranscribeOptions(formats: [.srt]))
        q.queue(ids)
        let job = try q.next().job
        q.apply(.progress(id: job.id, ProgressInfo(stage: .transcribe, progress: 0.1, chunk: 1, totalChunks: 4)))
        q.apply(.download(id: job.id, DownloadInfo(model: CachedModel.aligner.rawValue, modelID: "aligner",
                                                   downloadedBytes: 10, totalBytes: 100)))
        guard case .preparingModel(.aligner, let d?) = status(q, ids[0]) else { Issue.record("aligner"); return }
        #expect(d.info.fraction == 0.1)
    }

    @Test func workerCrashFailsTheRunningFileAndKeepsUpNext() throws {
        var (q, ids) = queue()
        q.queue(ids)
        let job = try q.next().job
        q.apply(.progress(id: job.id, ProgressInfo(stage: .transcribe, progress: 0.3, chunk: 1, totalChunks: 3)))
        q.workerExited(.crashed(code: 1))
        guard case .failed(let msg) = status(q, ids[0]) else { Issue.record("failed"); return }
        #expect(msg.contains("quit unexpectedly"))
        #expect(q.currentID == nil)
        #expect(q.upNext == [ids[1], ids[2]])
        // Late events from the dead job are ignored.
        q.apply(.fileDone(id: job.id, FileResult()))
        #expect(q[ids[0]]?.result == nil)
        // The next Start continues with the next file.
        #expect(q.startNext()?.id == ids[1])
    }

    @Test func quitCountsAsStopped() throws {
        var (q, ids) = queue(["a.m4a"])
        q.queue(ids)
        _ = try q.next()
        q.workerExited(.requested)
        #expect(q[ids[0]]?.state.isStopped == true)
    }

    @Test func eventsForOtherJobsAreIgnored() throws {
        var (q, ids) = queue(["a.m4a"])
        q.queue(ids)
        _ = try q.next()
        #expect(q.apply(.fileDone(id: "someone-else", FileResult())) == nil)
        #expect(q.apply(.idle) == nil)
        #expect(q[ids[0]]?.state.isRunning == true)
    }

    // MARK: Scheduling

    @Test func queueOrderRunNextAndUnqueue() {
        var (q, ids) = queue(["a", "b", "c", "d"])
        q.queue([ids[2], ids[0], ids[2]])
        #expect(q.upNext == [ids[2], ids[0]])
        q.runNext([ids[3], ids[1]])
        #expect(q.upNext == [ids[3], ids[1], ids[2], ids[0]])
        #expect(status(q, ids[2]) == .queued(ordinal: 3))
        q.runNext([ids[0]])
        #expect(q.upNext == [ids[0], ids[3], ids[1], ids[2]])
        q.unqueue([ids[3]])
        #expect(q.upNext == [ids[0], ids[1], ids[2]])
        #expect(status(q, ids[3]) == .ready)
        #expect(q.readyIDs == [ids[3]])
        q.unqueueAll()
        #expect(q.upNext.isEmpty && q.readyIDs == ids)
    }

    @Test func startSendsFilesInUpNextOrder() throws {
        var (q, ids) = queue()
        q.queue([ids[2], ids[0]])
        let first = try q.next()
        #expect(first.id == ids[2])
        q.apply(.fileDone(id: first.job.id, FileResult()))
        #expect(q.startNext()?.id == ids[0])
        q.queue([ids[1]])  // added during a run
        #expect(q.upNext == [ids[1]])
    }

    @Test func dragReordersUpNext() {
        var (q, ids) = queue(["a", "b", "c", "d"])
        q.queue(ids)
        q.moveUpNext(fromOffsets: [0], toOffset: 3)  // a after c
        #expect(q.upNext == [ids[1], ids[2], ids[0], ids[3]])
        q.moveUpNext(fromOffsets: [2, 3], toOffset: 0)
        #expect(q.upNext == [ids[0], ids[3], ids[1], ids[2]])
        q.moveUpNext(fromOffsets: [1], toOffset: 4)
        #expect(q.upNext == [ids[0], ids[1], ids[2], ids[3]])
        #expect(status(q, ids[3]) == .queued(ordinal: 4))
    }

    @Test func dragReadyIntoUpNextQueuesAndBackUnqueues() throws {
        var (q, ids) = queue(["a", "b", "c"])
        q.queue([ids[0], ids[1]])
        q.drop([ids[2]], into: .upNext, at: 1)
        #expect(q.upNext == [ids[0], ids[2], ids[1]])
        #expect(status(q, ids[2]) == .queued(ordinal: 2))
        q.drop([ids[0]], into: .upNext, at: 3)  // a queued row moves
        #expect(q.upNext == [ids[2], ids[1], ids[0]])
        q.drop([ids[1]], into: .ready)
        #expect(q.upNext == [ids[2], ids[0]])
        #expect(status(q, ids[1]) == .ready)
        // Running and Done rows can't be dragged into Up next.
        let run = try q.next()
        q.drop([run.id], into: .upNext, at: 0)
        #expect(q.upNext == [ids[0]])
        q.apply(.fileDone(id: run.job.id, FileResult()))
        q.drop([run.id], into: .upNext)
        #expect(q.upNext == [ids[0]])
        #expect(q[run.id]?.result != nil)
    }

    @Test func retryStoppedAndFailedStartsOver() throws {
        var (q, ids) = queue(["a", "b"])
        q.queue(ids)
        let a = try q.next()
        q.apply(.segment(id: a.job.id, LiveSegment(index: 1, totalChunks: 2, segment: .init(start: 0, end: 70, text: "x"))))
        q.apply(.fileStopped(id: a.job.id, stoppedAt: 70))
        let b = try q.next()
        q.apply(.fileError(id: b.job.id, error: "boom"))
        q.queue([ids[1], ids[0]])
        #expect(q.upNext == [ids[1], ids[0]])
        let item = try #require(q[ids[0]])
        #expect(item.state == .queued && item.liveSegments.isEmpty && item.reachedFraction == 0 && item.jobID == nil)
        // A new run gets a new job id.
        let again = try q.next()
        #expect(again.job.id != b.job.id)
    }

    @Test func stopAllUnqueuesAndStopsCurrent() throws {
        var (q, ids) = queue()
        q.queue(ids)
        let run = try q.next()
        #expect(q.requestStopAll() == run.job.id)
        #expect(q.upNext.isEmpty)
        #expect(q.readyIDs == [ids[1], ids[2]])
        #expect(q[ids[0]]?.isStopping == true)
        // Stop on a queued file just unqueues it.
        q.queue([ids[1]])
        #expect(q.requestStop(ids[1]) == nil)
        #expect(status(q, ids[1]) == .ready)
    }

    @Test func removeKeepsTheRunningFile() throws {
        var (q, ids) = queue()
        q.queue(ids)
        let run = try q.next()
        q.remove(Set(ids))
        #expect(q.items.map(\.id) == [run.id])
        #expect(q.upNext.isEmpty)
    }

    @Test func finishedNewestFirstAndClear() throws {
        var (q, ids) = queue()
        q.queue(ids)
        for _ in ids {
            clock.advance(by: 1)
            let run = try q.next()
            q.apply(.fileDone(id: run.job.id, FileResult()))
        }
        #expect(q.finishedIDs == ids.reversed())
        #expect(q.doneCount == 3)
        q.clearFinished()
        #expect(q.items.isEmpty)
    }

    @Test func displayOrderFollowsSections() throws {
        var (q, ids) = queue(["a", "b", "c", "d"])
        q.queue([ids[3], ids[1]])
        let run = try q.next()  // d runs
        #expect(run.id == ids[3])
        #expect(q.displayOrder == [ids[3], ids[1], ids[0], ids[2]])
        #expect(q.section(of: q[ids[1]]!) == .upNext)
    }

    // MARK: Options

    @Test func optionsAreReadOnlyWhileRunningAndDone() throws {
        var (q, ids) = queue(["a", "b"])
        q.queue([ids[0]])
        q.setOptions([ids[0]]) { $0.formats = [.srt] }
        #expect(q[ids[0]]?.options.formats == [.srt])  // Queued is editable
        let run = try q.next()
        #expect(run.job.formats == ["srt"])
        q.setOptions([ids[0], ids[1]]) { $0.language = "en" }
        #expect(q[ids[0]]?.options.language == nil)
        #expect(q[ids[1]]?.options.language == "en")
        // P2: no prepared formats is allowed (the library keeps transcript.json).
        q.setOptions([ids[1]]) { $0.formats = [] }
        #expect(q[ids[1]]?.options.formats == [])
    }

    @Test func defaultsChangeFollowsUncustomisedFiles() {
        let old = TranscribeOptions()
        var (q, ids) = queue(["a", "b"], options: old)
        q.setOptions([ids[1]]) { $0.timestamps = true }
        var new = old
        new.formats = [.md, .txt]
        q.defaultsChanged(from: old, to: new)
        #expect(q[ids[0]]?.options == new)
        #expect(q[ids[1]]?.options.formats == [.md])
    }

    @Test func runAgainWithChangesCopiesWithOverwrite() throws {
        var (q, ids) = queue(["a", "b"], options: TranscribeOptions(formats: [.srt], language: "zh"))
        q.queue([ids[0]])
        let run = try q.next()
        q.apply(.fileDone(id: run.job.id, FileResult(outputs: ["srt": "/tmp/q/a.srt"], duration: 150.02)))
        let made = q.duplicateForRerun(ids[0])
        let copy = try #require(made)
        let item = try #require(q[copy])
        #expect(item.state == .ready)
        #expect(item.url == q[ids[0]]!.url)
        #expect(item.options.formats == [.srt] && item.options.language == "zh" && item.options.overwrite)
        #expect(q.items.map(\.id) == [ids[0], copy, ids[1]])
        #expect(q[ids[0]]?.result != nil)  // the original stays
        #expect(q.add([URL(fileURLWithPath: "/tmp/q/a")]).isEmpty)  // still guarded against duplicates
    }
}
