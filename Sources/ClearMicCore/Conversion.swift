import AVFoundation

/// The format DeepFilterNet works in: 48 kHz, mono, 32-bit float.
public let workFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

/// Converts a PCM buffer of any format to 48 kHz mono samples.
public func toWorkSamples(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> [Float] {
    let ratio = workFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    let out = AVAudioPCMBuffer(pcmFormat: workFormat, frameCapacity: capacity)!
    var fed = false
    converter.convert(to: out, error: nil) { _, status in
        if fed { status.pointee = .noDataNow; return nil }
        fed = true
        status.pointee = .haveData
        return buffer
    }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

/// Reads an audio file, removes noise, writes a 48 kHz mono file.
public func cleanFile(input: URL, output: URL, denoiser: Denoiser) throws {
    let inFile = try AVAudioFile(forReading: input)
    let converter = AVAudioConverter(from: inFile.processingFormat, to: workFormat)!
    let outFile = try AVAudioFile(forWriting: output, settings: workFormat.settings)
    let chunk = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: 4800)!
    while inFile.framePosition < inFile.length {
        try inFile.read(into: chunk)
        if chunk.frameLength == 0 { break }  // a file shorter than its header claims would otherwise loop forever
        let cleaned = denoiser.clean(toWorkSamples(chunk, using: converter))
        if cleaned.isEmpty { continue }
        let out = AVAudioPCMBuffer(pcmFormat: workFormat, frameCapacity: AVAudioFrameCount(cleaned.count))!
        out.frameLength = out.frameCapacity
        cleaned.withUnsafeBufferPointer {
            out.floatChannelData![0].update(from: $0.baseAddress!, count: cleaned.count)
        }
        try outFile.write(from: out)
    }
}
