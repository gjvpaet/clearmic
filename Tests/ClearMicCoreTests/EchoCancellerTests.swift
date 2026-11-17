import CNative
import XCTest

final class EchoCancellerTests: XCTestCase {
    func testNativeCancellerCanBeCreated() {
        let state = aec_create()
        XCTAssertNotNil(state)
        aec_free(state)
    }
}
