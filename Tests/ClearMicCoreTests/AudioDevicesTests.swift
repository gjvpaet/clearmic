import XCTest
@testable import ClearMicCore

final class AudioDevicesTests: XCTestCase {
    func testListsNamedDevicesAndFindsThemByName() throws {
        let devices = allAudioDevices()
        let out = try XCTUnwrap(devices.first { $0.hasOutput }, "this Mac has no output device")
        XCTAssertFalse(out.name.isEmpty)
        XCTAssertEqual(findDevice(named: out.name, input: false)?.id, out.id)
        XCTAssertNil(findDevice(named: "no such device 123", input: false))
        if let id = defaultInputDeviceID() {
            XCTAssertTrue(devices.contains { $0.id == id && $0.hasInput })
        }
        if let id = defaultOutputDeviceID() {
            XCTAssertTrue(devices.contains { $0.id == id && $0.hasOutput })
        }
    }
}
