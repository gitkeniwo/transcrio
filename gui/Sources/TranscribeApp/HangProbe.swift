import Darwin
import Foundation

/// `TRANSCRIBE_HANG_LOG=/path.json`: measures main-thread responsiveness for the stall
/// investigation. A background thread posts a block to the main queue every
/// 5 ms and records how late it runs; a late block means the main thread was busy for that
/// long. The report is rewritten every second, so it survives however the app exits.
///
/// The report counts hangs (latency > 50 ms) overall and in the 15 s after Start, the worst
/// latency, and the process CPU use (user + system time ÷ wall time).
final class HangProbe: @unchecked Sendable {
    nonisolated(unsafe) static var shared: HangProbe?

    private let path: String
    private let lock = NSLock()
    private let origin = Date()
    private var hangs: [(at: Double, ms: Double)] = []
    private var maxLatency = 0.0
    private var samples = 0
    private var startedAt: Double?
    private var cpuAtStart: Double?
    private var cpuSeconds: [(at: Double, cpu: Double)] = []

    static func startIfRequested() {
        guard let path = DevSupport.environment["TRANSCRIBE_HANG_LOG"], shared == nil else { return }
        let probe = HangProbe(path: path)
        shared = probe
        probe.run()
    }

    private init(path: String) { self.path = path }

    /// Called when a batch starts: the 15 s window is measured from here.
    func markStart() {
        lock.withLock {
            guard startedAt == nil else { return }
            startedAt = Date().timeIntervalSince(origin)
            cpuAtStart = Self.cpuTime()
        }
    }

    private func run() {
        let ping = Thread { [self] in
            let done = DispatchSemaphore(value: 0)
            while true {
                let sent = Date()
                DispatchQueue.main.async {
                    let ms = Date().timeIntervalSince(sent) * 1000
                    self.record(ms, at: sent.timeIntervalSince(self.origin))
                    done.signal()
                }
                done.wait()
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        ping.qualityOfService = .userInteractive
        ping.start()
        let writer = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                lock.withLock { cpuSeconds.append((Date().timeIntervalSince(origin), Self.cpuTime())) }
                write()
            }
        }
        writer.start()
    }

    private func record(_ ms: Double, at t: Double) {
        lock.withLock {
            samples += 1
            maxLatency = max(maxLatency, ms)
            if ms > 50 { hangs.append((t, ms)) }
        }
    }

    private func write() {
        let report: [String: Any] = lock.withLock {
            let now = Date().timeIntervalSince(origin)
            var r: [String: Any] = [
                "seconds": round1(now),
                "samples": samples,
                "max_latency_ms": round1(maxLatency),
                "hangs_over_50ms": hangs.count,
                "hangs": hangs.map { ["at": round1($0.at), "ms": round1($0.ms)] },
                "cpu_percent_overall": round1(Self.cpuTime() / max(now, 0.001) * 100),
            ]
            if let s = startedAt, let c0 = cpuAtStart {
                let window = hangs.filter { $0.at >= s && $0.at < s + 15 }
                r["start_at"] = round1(s)
                r["first15s_hangs_over_50ms"] = window.count
                r["first15s_max_ms"] = round1(window.map(\.ms).max() ?? 0)
                r["first15s_hangs"] = window.map { ["at": round1($0.at - s), "ms": round1($0.ms)] }
                r["cpu_percent_since_start"] = round1((Self.cpuTime() - c0) / max(now - s, 0.001) * 100)
                // CPU per 10 s window since Start.
                var windows: [Double] = []
                var t = s
                while t + 10 <= now {
                    let a = cpuSeconds.last { $0.at <= t }?.cpu ?? c0
                    let b = cpuSeconds.last { $0.at <= t + 10 }?.cpu ?? a
                    windows.append(round1((b - a) / 10 * 100))
                    t += 10
                }
                r["cpu_percent_per_10s"] = windows
            }
            return r
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    /// User + system CPU seconds of this process.
    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }
}
