import AVFoundation
import Foundation
import Testing
@testable import TranscribeKit

@Suite struct MediaInfoTests {
    static let ffmpegPath = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// 2 s of 440 Hz sine, loud in the first second and quiet in the second.
    func writeSineWAV(to url: URL) throws {
        let rate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(rate * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let amp: Float = i < Int(rate) ? 0.8 : 0.2
            data[i] = amp * sin(2 * .pi * 440 * Float(i) / Float(rate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func runFFmpeg(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.ffmpegPath!)
        p.arguments = ["-loglevel", "error", "-y"] + args
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func durationAndWaveformOfAudio() async throws {
        let tmp = try TempDir()
        let wav = tmp.url.appendingPathComponent("sine.wav")
        try writeSineWAV(to: wav)
        let info = await MediaInfo.load(wav)
        #expect(info.kind == .audio)
        #expect(abs((info.duration ?? 0) - 2) < 0.05)

        let wave = try #require(await MediaInfo.waveform(wav, bins: 200))
        #expect(wave.rms.count == 200)
        // RMS of a sine is amplitude / √2.
        let loud = wave.rms[10..<90].reduce(0, +) / 80, quiet = wave.rms[110..<190].reduce(0, +) / 80
        #expect(abs(Double(loud) - 0.8 / 2.squareRoot()) < 0.02)
        #expect(abs(Double(quiet) - 0.2 / 2.squareRoot()) < 0.01)
        // The loud half is the reference (full height); the quiet half is 12 dB down.
        let levels = wave.levels(count: 20)
        #expect(levels[2] > 0.99)
        #expect(abs(levels[15] - (30 - 12.04) / 30) < 0.02)
    }

    @Test(.enabled(if: ffmpegPath != nil)) func audioAndVideoContainers() async throws {
        let tmp = try TempDir()
        let wav = tmp.url.appendingPathComponent("sine.wav")
        try writeSineWAV(to: wav)
        let m4a = tmp.url.appendingPathComponent("sine.m4a")
        let mp4 = tmp.url.appendingPathComponent("sine.mp4")
        try runFFmpeg(["-i", wav.path, m4a.path])
        try runFFmpeg(["-f", "lavfi", "-i", "color=c=red:s=64x64:r=10:d=2", "-i", wav.path, "-shortest",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", mp4.path])

        let a = await MediaInfo.load(m4a)
        #expect(a.kind == .audio)
        #expect(abs((a.duration ?? 0) - 2) < 0.1)
        let v = await MediaInfo.load(mp4)
        #expect(v.kind == .video)
        #expect(abs((v.duration ?? 0) - 2) < 0.15)

        for url in [m4a, mp4] {
            let levels = try #require(await MediaInfo.waveform(url, bins: 50)).levels(count: 50)
            #expect(levels[5..<20].allSatisfy { $0 > 0.95 })
            #expect(levels[30..<45].allSatisfy { $0 < 0.7 && $0 > 0.5 })
        }
    }

    @Test(.enabled(if: ffmpegPath != nil)) func videoWithoutAudioHasNoWaveform() async throws {
        let tmp = try TempDir()
        let mp4 = tmp.url.appendingPathComponent("silent.mp4")
        try runFFmpeg(["-f", "lavfi", "-i", "color=c=red:s=64x64:r=10:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", mp4.path])
        #expect(await MediaInfo.load(mp4).kind == .video)
        #expect(await MediaInfo.waveform(mp4) == nil)
    }

    @Test func unreadableFile() async throws {
        let tmp = try TempDir()
        let junk = try tmp.file("junk.ogg", contents: "not audio")
        let info = await MediaInfo.load(junk)
        #expect(info.duration == nil)
        #expect(info.kind == .audio)
        #expect(await MediaInfo.waveform(junk) == nil)
        #expect(await MediaInfo.load(tmp.url.appendingPathComponent("gone.mkv")).kind == .video)
    }
}
