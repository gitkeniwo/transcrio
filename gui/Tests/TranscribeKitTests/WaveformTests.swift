import Foundation
import Testing
@testable import TranscribeKit

@Suite struct WaveformTests {
    @Test func percentileIsNearestRank() {
        let values = (1...100).map(Float.init)
        #expect(Waveform.percentile(values, 0.95) == 95)
        #expect(Waveform.percentile([3], 0.95) == 3)
        #expect(Waveform.percentile([], 0.95) == 0)
    }

    @Test func oneLoudSpikeDoesNotFlattenTheRest() {
        // 99 bins of speech at 0.1 and one click at 1.0: max-normalising would draw the speech at 10%.
        var rms = [Float](repeating: 0.1, count: 99)
        rms.append(1)
        let w = Waveform(rms: rms)
        #expect(w.reference == Float(0.1))
        #expect(w.levels(count: 100)[0] == 1)
        #expect(w.levels(count: 100)[99] == 1) // above the reference clamps
    }

    @Test func logScale() {
        #expect(Waveform.level(0.5, reference: 0.5) == 1)
        #expect(abs(Waveform.level(0.05, reference: 0.5, range: 40) - 0.5) < 0.0001) // −20 dB of 40
        #expect(Waveform.level(0.005, reference: 0.5, range: 40) == 0)     // −40 dB
        #expect(abs(Waveform.level(0.05, reference: 0.5) - 1.0 / 3) < 0.0001) // default range is 30 dB
        #expect(Waveform.level(0, reference: 0.5) == 0)
        #expect(Waveform.level(0.1, reference: 0) == 0)
    }

    @Test func poolingIsRMS() {
        let pooled = Waveform.pool([0.3, 0.4, 0, 0], count: 2)
        #expect(abs(pooled[0] - (0.125 as Float).squareRoot()) < 0.0001)
        #expect(pooled[1] == 0)
        // Up-sampling repeats bins; a sub-range only sees its own bins.
        #expect(Waveform.pool([0.2, 0.6], count: 4) == [0.2, 0.2, 0.6, 0.6])
        #expect(Waveform.pool([0.1, 0.2, 0.3, 0.4], count: 2, from: 0.5, to: 1) == [0.3, 0.4])
        #expect(Waveform.pool([], count: 3) == [0, 0, 0])
        #expect(Waveform.pool([0.5], count: 0).isEmpty)
    }
}

@Suite struct RowWaveformProgressTests {
    @Test func failedAndStoppedKeepHowFarTheyGot() {
        var q = QueueModel(clock: ManualClock())
        let id = q.add([URL(fileURLWithPath: "/tmp/a.m4a")])[0]
        q.queue([id])
        let job = q.startNext()!.job.id
        q.apply(.progress(id: job, ProgressInfo(stage: .transcribe, progress: 0.4, chunk: 3, totalChunks: 8)))
        #expect(q[id]!.waveformProgress(.transcribing(percent: 0.4, chunk: 3, totalChunks: 8)).fraction == 0.4)
        q.apply(.fileError(id: job, error: "boom"))
        let p = q[id]!.waveformProgress(.failed("boom"))
        #expect(p.fraction == 0.4 && p.tone == .failed)
        #expect(q[id]!.waveformProgress(.queued(ordinal: 1)).fraction == 0)
    }
}
