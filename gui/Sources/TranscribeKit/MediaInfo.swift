import AVFoundation
import Foundation

/// Native media facts the CLI doesn't report up front: duration, audio vs. video, and
/// waveform peaks. Read with AVFoundation off the main actor. No ASR happens here.
public struct MediaInfo: Sendable, Equatable {
    public var duration: Double?
    public var kind: MediaKind

    public init(duration: Double?, kind: MediaKind) {
        self.duration = duration
        self.kind = kind
    }

    /// Duration and kind. Formats AVFoundation can't open (ogg, mkv, …) return a `nil`
    /// duration; the CLI reports it later in `file_done`.
    public static func load(_ url: URL) async -> MediaInfo {
        let fallbackKind = MediaKind(pathExtension: url.pathExtension)
        return await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            var duration: Double?
            if let time = try? await asset.load(.duration), time.isNumeric, time.seconds > 0 {
                duration = time.seconds
            }
            var kind = fallbackKind
            if let video = try? await asset.loadTracks(withMediaType: .video) {
                kind = video.isEmpty ? (duration == nil ? fallbackKind : .audio) : .video
            }
            return MediaInfo(duration: duration, kind: kind)
        }.value
    }

    /// Loudness of the first audio track, mono, as `bins` RMS values (see `Waveform`).
    /// Returns `nil` when the file has no readable audio (callers draw flat bars).
    public static func waveform(_ url: URL, bins: Int = 1024) async -> Waveform? {
        await Task.detached(priority: .utility) {
            (try? await readRMS(url: url, bins: max(bins, 1))).map(Waveform.init(rms:))
        }.value
    }

    private static func readRMS(url: URL, bins: Int) async throws -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return nil }

        // The lowest rate AVFoundation allows (8 kHz) is plenty for loudness and keeps long files fast.
        let sampleRate = 8000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let totalSamples = max(Int(duration * sampleRate), bins)
        let perBin = Double(totalSamples) / Double(bins)
        var squares = [Double](repeating: 0, count: bins)
        var counts = [Int](repeating: 0, count: bins)
        var index = 0
        var bin = 0
        var nextBoundary = perBin

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            data.withUnsafeBytes { raw in
                for sample in raw.bindMemory(to: Int16.self) {
                    while Double(index) >= nextBoundary, bin < bins - 1 {
                        bin += 1
                        nextBoundary = perBin * Double(bin + 1)
                    }
                    let v = Double(sample) / Double(Int16.max)
                    squares[bin] += v * v
                    counts[bin] += 1
                    index += 1
                }
            }
        }
        guard reader.status == .completed, index > 0 else { return nil }
        return zip(squares, counts).map { s, c in c > 0 ? Float((s / Double(c)).squareRoot()) : 0 }
    }
}
