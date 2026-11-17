import CNative
import XCTest
@testable import ClearMicCore

final class EchoCancellerTests: XCTestCase {
    func testNativeCancellerCanBeCreated() {
        let state = aec_create()
        XCTAssertNotNil(state)
        aec_free(state)
    }

    func testRemovesDelayedCopyOfPlayedSignal() throws {
        let ec = try EchoCanceller()
        let n = 48_000 * 5
        let delay = 1_920  // 40 ms
        let ref = (0..<n).map { _ in Float.random(in: -0.3...0.3) }
        let mic = (0..<n).map { $0 >= delay ? ref[$0 - delay] * 0.5 : 0 }
        var out: [Float] = []
        for start in stride(from: 0, to: n, by: 480) {
            ec.played(Array(ref[start..<start + 480]))
            out += ec.clean(Array(mic[start..<start + 480]))
        }
        XCTAssertEqual(out.count, n)
        // Skip the first 3 seconds while the canceller adapts.
        let from = 48_000 * 3
        let dropDb = 20 * log10(max(rms(out[from...]), 1e-9) / rms(mic[from...]))
        XCTAssertLessThan(dropDb, -15)
    }

    func testRemovesEchoWithBurstyMicAndPlaybackBacklog() throws {
        let ec = try EchoCanceller()
        let n = 48_000 * 6
        let delay = 1_920   // 40 ms from loudspeaker to microphone
        let backlog = 14_400  // playback ran for 300 ms before the microphone started
        let ref = (0..<n).map { _ in Float.random(in: -0.3...0.3) }
        // Microphone sample i is taken at playback time backlog + i.
        let mic = (0..<(n - backlog)).map { ref[backlog + $0 - delay] * 0.5 }
        var playedUpTo = 0
        var out: [Float] = []
        for start in stride(from: 0, to: mic.count - 4_800 + 1, by: 4_800) {
            // Everything played up to the end of this microphone burst arrives first, in 512-sample blocks.
            while playedUpTo + 512 <= backlog + start + 4_800 {
                ec.played(Array(ref[playedUpTo..<playedUpTo + 512]))
                playedUpTo += 512
            }
            out += ec.clean(Array(mic[start..<start + 4_800]))
        }
        // Skip the first 3 seconds while the canceller adapts.
        let from = 48_000 * 3
        let dropDb = 20 * log10(max(rms(out[from...]), 1e-9) / rms(mic[from..<out.count]))
        XCTAssertLessThan(dropDb, -15)
    }
}
