import AVFoundation
import CoreAudio

public struct AudioPipelineError: Error { public let message: String }

/// Live path: input device -> Denoiser -> output device.
public final class AudioPipeline {
    private let capture = AVAudioEngine()
    private let playback = AVAudioEngine()
    private let outQueue = FrameBuffer()
    private let denoiser: Denoiser
    /// Samples discarded because playback fell behind. Written on the audio thread, read for logging only.
    public private(set) var droppedSamples = 0

    public init(denoiser: Denoiser) { self.denoiser = denoiser }

    private func setDevice(_ id: AudioDeviceID, on node: AVAudioIONode) throws {
        var device = id
        let status = AudioUnitSetProperty(
            node.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw AudioPipelineError(message: "cannot select audio device (\(status))") }
    }

    /// `input` nil means the system default microphone.
    public func start(input: AudioDeviceID?, output: AudioDeviceID) throws {
        if let input { try setDevice(input, on: capture.inputNode) }
        try setDevice(output, on: playback.outputNode)

        let inFormat = capture.inputNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: workFormat) else {
            throw AudioPipelineError(message: "input device has no usable audio format")
        }
        let maxQueued = 14_400  // 300 ms at 48 kHz; beyond this we drop instead of adding delay
        // shortcut: an AVAudioEngine tap delivers ~100 ms blocks, so latency is ~100-200 ms;
        // switch to an AUHAL input callback when latency matters.
        capture.inputNode.installTap(onBus: 0, bufferSize: 480, format: inFormat) { [self] buffer, _ in
            outQueue.push(denoiser.clean(toWorkSamples(buffer, using: converter)))
            droppedSamples += outQueue.dropOldest(downTo: maxQueued)
        }

        let source = AVAudioSourceNode(format: workFormat) { [outQueue] _, _, frameCount, bufferList in
            let n = Int(frameCount)
            let dst = UnsafeMutableAudioBufferListPointer(bufferList)[0].mData!.assumingMemoryBound(to: Float.self)
            if let samples = outQueue.pop(n) {
                samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: n) }
            } else {
                dst.update(repeating: 0, count: n)  // nothing ready yet: silence
            }
            return noErr
        }
        playback.attach(source)
        // The mixer copies our mono signal to both BlackHole channels.
        playback.connect(source, to: playback.mainMixerNode, format: workFormat)

        try playback.start()
        try capture.start()
    }
}
