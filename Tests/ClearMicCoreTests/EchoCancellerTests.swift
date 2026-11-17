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
}
