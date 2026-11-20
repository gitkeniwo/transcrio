import Foundation
import Testing
@testable import TranscribeKit

/// Run history and the "Left" estimate.
struct EstimateTests {
    let clock = ManualClock()
    let day = Date(timeIntervalSince1970: 1_800_000_000)

    func history(_ runs: [(String, Double, Double)]) -> RunHistory {
        var h = RunHistory()
        for (m, d, e) in runs { h.record(RunRecord(model: m, duration: d, elapsed: e, date: day)) }
        return h
    }

    @Test func speedIsTotalAudioOverTotalTime() {
        let h = history([("1.7b", 600, 60), ("1.7b", 60, 30)])
        #expect(h.speed(model: "1.7b") == 660.0 / 90.0)
        #expect(h.speed(model: "0.6b") == nil)
        #expect(h.recentSpeeds(model: "1.7b") == [10, 2])
        #expect(h.estimate(duration: 1200, model: "1.7b") == 1200 / (660.0 / 90.0))
    }

    @Test func keepsTheLast50PerModelAndSkipsTinyRuns() {
        var h = RunHistory()
        for i in 0..<60 { h.record(RunRecord(model: "0.6b", duration: Double(100 + i), elapsed: 10, date: day)) }
        h.record(RunRecord(model: "0.6b", duration: 2, elapsed: 1, date: day))  // too short to count
        h.record(RunRecord(model: "0.6b", duration: 100, elapsed: 0, date: day))
        #expect(h.runs["0.6b"]?.count == 50)
        #expect(h.runs["0.6b"]?.first?.duration == 110)
        // The average uses the last 10.
        let last10 = (50..<60).map { Double(100 + $0) }.reduce(0, +)
        #expect(h.speed(model: "0.6b") == last10 / 100)
        #expect(h.recentSpeeds(model: "0.6b", count: 6).count == 6)
    }

    @Test func saveAndLoad() throws {
        let tmp = try TempDir()
        let url = tmp.url.appendingPathComponent("Transcribe/history.json")
        #expect(RunHistory.load(from: url) == RunHistory())
        let h = history([("1.7b", 300, 30)])
        try h.save(to: url)
        #expect(RunHistory.load(from: url) == h)
        try Data("garbage".utf8).write(to: url)
        #expect(RunHistory.load(from: url) == RunHistory())
    }

    func queue() -> (QueueModel, [FileItem.ID]) {
        var q = QueueModel(clock: clock)
        let ids = q.add(["a", "b", "c", "d"].map { URL(fileURLWithPath: "/e/\($0).m4a") })
        for (id, d) in zip(ids, [600.0, 300, 120, 900]) { q.update(id) { $0.duration = d } }
        return (q, ids)
    }

    @Test func leftCountsNowAndUpNextButNotReady() throws {
        var (q, ids) = queue()
        q.queue([ids[0], ids[1]])
        q.setOptions([ids[1]]) { $0.model = .fast }
        let h = history([("1.7b", 100, 10), ("0.6b", 300, 10)])  // 10× and 30×
        #expect(QueueEstimate.remaining(q, history: h, now: clock.now()) == 600.0 / 10 + 300.0 / 30)
        #expect(QueueEstimate.upNext(q, history: h) == 600.0 / 10 + 300.0 / 30)

        let run = try q.next()
        q.apply(.segment(id: run.job.id, LiveSegment(index: 1, totalChunks: 2, segment: .init(start: 0, end: 300, text: "x"))))
        // Half of a is left; the live speed isn't measurable yet (no transcribe stage span).
        #expect(QueueEstimate.remaining(q, history: h, now: clock.now()) == 300.0 / 10 + 300.0 / 30)
        // Ready files (c, d) never count.
        #expect(QueueEstimate.upNext(q, history: h) == 300.0 / 30)
    }

    @Test func liveSpeedStandsInWithoutHistory() throws {
        var (q, ids) = queue()
        q.queue([ids[0], ids[2]])
        let run = try q.next()
        #expect(QueueEstimate.remaining(q, history: RunHistory(), now: clock.now()) == nil)
        q.apply(.progress(id: run.job.id, ProgressInfo(stage: .transcribe, progress: 0, chunk: 1, totalChunks: 4)))
        clock.advance(by: 30)
        q.apply(.progress(id: run.job.id, ProgressInfo(stage: .transcribe, progress: 0.25, chunk: 1, totalChunks: 4)))
        // 150 s of audio in 30 s: 5×. a has 450 s left, c (same model) 120 s.
        let left = try #require(QueueEstimate.remaining(q, history: RunHistory(), now: clock.now()))
        #expect(abs(left - (450.0 / 5 + 120.0 / 5)) < 0.001)
        #expect(QueueEstimate.liveSpeed(q, now: clock.now()) == 5)
    }

    @Test func formatting() {
        #expect(QueueEstimate.format(20) == "< 1 min")
        #expect(QueueEstimate.format(185) == "≈ 3 min")
        #expect(QueueEstimate.format(80 * 60) == "≈ 1 h 20 min")
    }
}
