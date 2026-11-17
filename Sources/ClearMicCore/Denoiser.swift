import CDeepFilter
import Foundation

public enum DenoiserError: Error { case modelNotFound(String) }

/// Removes noise from 48 kHz mono audio with DeepFilterNet.
public final class Denoiser {
    private let state: OpaquePointer
    private let pending = FrameBuffer()
    public let frameLength: Int

    public init(modelPath: String) throws {
        // df_create aborts the whole process on a bad path, so check before calling it.
        guard FileManager.default.isReadableFile(atPath: modelPath),
              let s = df_create(modelPath, 100, nil) else {
            throw DenoiserError.modelNotFound(modelPath)
        }
        state = s
        frameLength = df_get_frame_length(s)
    }

    deinit { df_free(state) }

    /// Cleans exactly one frame of `frameLength` samples.
    public func process(_ frame: [Float]) -> [Float] {
        precondition(frame.count == frameLength)
        var input = frame
        var output = [Float](repeating: 0, count: frameLength)
        _ = df_process_frame(state, &input, &output)
        return output
    }

    /// Accepts any number of samples; returns the cleaned whole frames ready so far.
    public func clean(_ samples: [Float]) -> [Float] {
        pending.push(samples)
        var out: [Float] = []
        while let frame = pending.pop(frameLength) { out += process(frame) }
        return out
    }
}
