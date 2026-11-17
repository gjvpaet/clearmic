import XCTest
@testable import ClearMicCore

final class FrameBufferTests: XCTestCase {
    func testPopReturnsNilUntilEnoughSamples() {
        let b = FrameBuffer()
        b.push([1, 2])
        XCTAssertNil(b.pop(3))
        XCTAssertEqual(b.count, 2)
    }

    func testPopKeepsOrderAndRemainder() {
        let b = FrameBuffer()
        b.push([1, 2, 3])
        b.push([4, 5])
        XCTAssertEqual(b.pop(2), [1, 2])
        XCTAssertEqual(b.pop(2), [3, 4])
        XCTAssertEqual(b.count, 1)
    }

    func testDropOldestKeepsNewest() {
        let b = FrameBuffer()
        b.push([1, 2, 3, 4, 5])
        XCTAssertEqual(b.dropOldest(downTo: 2), 3)
        XCTAssertEqual(b.pop(2), [4, 5])
        XCTAssertEqual(b.dropOldest(downTo: 2), 0)
    }
}
