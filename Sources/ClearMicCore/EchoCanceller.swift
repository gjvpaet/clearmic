import CNative

public enum EchoCancellerError: Error { case creationFailed }

/// Removes from the microphone signal whatever was just played to the loudspeakers.
public final class EchoCanceller {
    public static let frameLength = 480
    private let state: OpaquePointer
    private let playedQueue = FrameBuffer()
    private let pending = FrameBuffer()

    public init() throws {
        guard let s = aec_create() else { throw EchoCancellerError.creationFailed }
        state = s
    }

    deinit { aec_free(state) }

    /// Call with the samples actually sent to the loudspeakers. Safe from any thread.
    public func played(_ samples: [Float]) {
        playedQueue.push(samples)
        _ = playedQueue.dropOldest(downTo: 48_000)  // never hold more than 1 s of reference
    }

    /// Call from one thread only. Accepts any number of microphone samples;
    /// returns the cleaned whole frames ready so far.
    public func clean(_ mic: [Float]) -> [Float] {
        pending.push(mic)
        // A reference older than the microphone audio is useless: the canceller must hear what was
        // played before it hears the echo. Tolerate 20 ms of slack so normal block jitter does not
        // shift the alignment on every call; beyond that, resync to the newest audio.
        if playedQueue.count > pending.count + 960 {
            _ = playedQueue.dropOldest(downTo: pending.count)
        }
        var out: [Float] = []
        while var frame = pending.pop(Self.frameLength) {
            // One played frame per microphone frame keeps the two streams aligned by sample count.
            if var ref = playedQueue.pop(Self.frameLength) { _ = aec_process_render(state, &ref) }
            _ = aec_process_capture(state, &frame)
            out += frame
        }
        return out
    }
}
