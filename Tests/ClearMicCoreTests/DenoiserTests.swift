import AVFoundation
import XCTest
@testable import ClearMicCore

let testModelPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("vendor/DeepFilterNet/models/DeepFilterNet3_onnx.tar.gz").path

func rms(_ s: ArraySlice<Float>) -> Float {
    (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
}

final class DenoiserTests: XCTestCase {
    func testMissingModelThrows() {
        XCTAssertThrowsError(try Denoiser(modelPath: "/no/such/model.tar.gz"))
    }

    func testCleanRegroupsOddChunksIntoWholeFrames() throws {
        let d = try Denoiser(modelPath: testModelPath)
        XCTAssertEqual(d.frameLength, 480)
        var total = 0
        for size in [100, 700, 333, 1000] {
            total += d.clean([Float](repeating: 0, count: size)).count
        }
        XCTAssertEqual(total, (2133 / 480) * 480)
    }

    func testCleanFileRemovesWhiteNoise() throws {
        let dir = FileManager.default.temporaryDirectory
        let inURL = dir.appendingPathComponent("clearmic-noise-in.wav")
        let outURL = dir.appendingPathComponent("clearmic-noise-out.wav")
        // 3 seconds of white noise at 44.1 kHz, so conversion to 48 kHz is exercised too.
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 132_300)!
        buf.frameLength = buf.frameCapacity
        for i in 0..<Int(buf.frameLength) { buf.floatChannelData![0][i] = Float.random(in: -0.1...0.1) }
        do { try AVAudioFile(forWriting: inURL, settings: fmt.settings).write(from: buf) }

        try cleanFile(input: inURL, output: outURL, denoiser: try Denoiser(modelPath: testModelPath))

        let outFile = try AVAudioFile(forReading: outURL)
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFile.processingFormat, frameCapacity: AVAudioFrameCount(outFile.length))!
        try outFile.read(into: outBuf)
        let out = Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
        XCTAssertGreaterThan(out.count, 96_000)
        // Skip the first second while the model adapts. Input RMS of uniform ±0.1 noise is 0.0577.
        let dropDb = 20 * log10(max(rms(out[48_000...]), 1e-9) / 0.0577)
        XCTAssertLessThan(dropDb, -20)
    }
}
