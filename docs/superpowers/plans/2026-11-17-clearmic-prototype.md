# ClearMic Prototype Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS command-line tool that cleans the microphone in real time with DeepFilterNet3 and plays the result into BlackHole 2ch, so meeting apps can select it as a microphone.

**Architecture:** A SwiftPM package. `CDeepFilter` exposes DeepFilterNet's Rust static library (`libdf.a`) through a C header. `ClearMicCore` holds the sample queue, the denoiser, format conversion, device lookup and the live pipeline (two `AVAudioEngine`s: one captures, one plays). `clearmic` is the executable.

**Tech Stack:** Swift 6.1 toolchain in Swift 5 language mode, SwiftPM, XCTest, AVFoundation, CoreAudio, DeepFilterNet `libDF` (Rust, `capi` feature) pinned at commit `7b14b895fe7fc42cab72b4a4c1e49c982bd6404b`.

**Spec:** `docs/superpowers/specs/2026-11-17-clearmic-prototype-design.md`

## Notes for every task

- Prerequisite, done by the user: `brew install rust` (Task 1) and `brew install blackhole-2ch` (Task 5 only).
- All tasks run **one after another in the same worktree**. `vendor/` is git-ignored, so a second worktree would have no `libdf.a` and could not build. No parallel wave.
- Run only the named test filter, one test process at a time: `swift test --filter <Name>`.
- Commits carry no `Co-Authored-By:` line.
- Deviations from the spec, on purpose (smaller): `FrameBuffer` exposes `pop(n)` instead of `popFrame()` because the playback side asks for varying sizes; `df_set_atten_lim` is not declared because nothing calls it.

## File map

| File | Responsibility |
|---|---|
| `scripts/build-libdf.sh` | Fetch DeepFilterNet at the pinned commit, build `vendor/lib/libdf.a` |
| `Package.swift` | Three targets + tests, links `libdf.a` |
| `Sources/CDeepFilter/include/df.h`, `shim.c` | C declarations of the four `df_*` functions |
| `Sources/ClearMicCore/FrameBuffer.swift` | Thread-safe sample FIFO |
| `Sources/ClearMicCore/Denoiser.swift` | Owns the model; `process(frame)` and `clean(samples)` |
| `Sources/ClearMicCore/Conversion.swift` | `workFormat`, `toWorkSamples`, `cleanFile` |
| `Sources/ClearMicCore/AudioDevices.swift` | List devices, find one by name |
| `Sources/ClearMicCore/AudioPipeline.swift` | Live mic → denoiser → output device |
| `Sources/clearmic/main.swift` | Arguments, exit codes, the three modes |

---

### Task 1: Build libdf, package skeleton, FrameBuffer

**Depends on:** none

**Files:**
- Create: `scripts/build-libdf.sh`, `Package.swift`, `Sources/CDeepFilter/include/df.h`, `Sources/CDeepFilter/shim.c`, `Sources/ClearMicCore/FrameBuffer.swift`, `Sources/clearmic/main.swift`
- Test: `Tests/ClearMicCoreTests/FrameBufferTests.swift`

- [ ] **Step 1: Write the build script**

`scripts/build-libdf.sh`:

```bash
#!/bin/bash
# Fetches DeepFilterNet at a pinned commit and builds its static library.
set -euo pipefail
cd "$(dirname "$0")/.."
REV=7b14b895fe7fc42cab72b4a4c1e49c982bd6404b
MODEL=vendor/DeepFilterNet/models/DeepFilterNet3_onnx.tar.gz
command -v cargo >/dev/null || { echo "cargo missing: run 'brew install rust'" >&2; exit 1; }
mkdir -p vendor/lib
[ -d vendor/DeepFilterNet ] || git clone https://github.com/Rikorose/DeepFilterNet vendor/DeepFilterNet
git -C vendor/DeepFilterNet checkout -q "$REV"
# A tiny file here means git stored a Git LFS pointer instead of the model.
[ "$(stat -f%z "$MODEL")" -gt 100000 ] || { echo "$MODEL is not a real model file (Git LFS pointer?)" >&2; exit 1; }
cargo build --release --manifest-path vendor/DeepFilterNet/libDF/Cargo.toml --no-default-features --features capi
cp "$(find vendor/DeepFilterNet -name libdf.a -path '*release*' | head -1)" vendor/lib/libdf.a
echo "built vendor/lib/libdf.a"
```

- [ ] **Step 2: Run it**

Run: `chmod +x scripts/build-libdf.sh && scripts/build-libdf.sh` (first build takes roughly 5–10 minutes; run it in the background and wait)
Expected: last line `built vendor/lib/libdf.a`, and `nm vendor/lib/libdf.a 2>/dev/null | grep -c ' T _df_create'` prints `1`.

- [ ] **Step 3: Write the package manifest and C module**

`Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "clearmic",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CDeepFilter",
            linkerSettings: [
                .unsafeFlags(["-L", "vendor/lib"]),
                .linkedLibrary("df"),
                // System libraries the Rust static library needs.
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("iconv"),
                .linkedLibrary("resolv"),
            ]),
        .target(name: "ClearMicCore", dependencies: ["CDeepFilter"]),
        .executableTarget(name: "clearmic", dependencies: ["ClearMicCore"]),
        .testTarget(name: "ClearMicCoreTests", dependencies: ["ClearMicCore"]),
    ]
)
```

`Sources/CDeepFilter/include/df.h`:

```c
#ifndef CLEARMIC_DF_H
#define CLEARMIC_DF_H
#include <stddef.h>

// Declarations for DeepFilterNet's C interface (libDF/src/capi.rs).
typedef struct DFState DFState;
DFState *df_create(const char *path, float atten_lim, const char *log_level);
size_t df_get_frame_length(DFState *st);
float df_process_frame(DFState *st, float *input, float *output);
void df_free(DFState *st);

#endif
```

`Sources/CDeepFilter/shim.c`:

```c
#include "df.h"
```

`Sources/clearmic/main.swift` (replaced in Task 4):

```swift
print("clearmic: not built yet")
```

- [ ] **Step 4: Write the failing FrameBuffer tests**

`Tests/ClearMicCoreTests/FrameBufferTests.swift`:

```swift
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
```

- [ ] **Step 5: Run the tests to see them fail**

Run: `swift test --filter FrameBufferTests`
Expected: build error, `cannot find 'FrameBuffer' in scope`.

- [ ] **Step 6: Implement FrameBuffer**

`Sources/ClearMicCore/FrameBuffer.swift`:

```swift
import Foundation

/// Thread-safe first-in-first-out queue of audio samples.
public final class FrameBuffer {
    private var samples: [Float] = []
    private let lock = NSLock()

    public init() {}

    public var count: Int { lock.withLock { samples.count } }

    public func push(_ new: [Float]) {
        lock.withLock { samples.append(contentsOf: new) }
    }

    /// Returns exactly `n` samples, or nil if fewer are queued.
    public func pop(_ n: Int) -> [Float]? {
        lock.withLock {
            guard samples.count >= n else { return nil }
            let out = Array(samples.prefix(n))
            samples.removeFirst(n)
            return out
        }
    }

    /// Drops the oldest samples until at most `max` remain. Returns how many were dropped.
    public func dropOldest(downTo max: Int) -> Int {
        lock.withLock {
            let extra = samples.count - max
            guard extra > 0 else { return 0 }
            samples.removeFirst(extra)
            return extra
        }
    }
}
```

- [ ] **Step 7: Run the tests to see them pass**

Run: `swift test --filter FrameBufferTests`
Expected: `Executed 3 tests, with 0 failures`. This also proves `libdf.a` links. If the linker reports `library 'df' not found`, replace `"vendor/lib"` in `Package.swift` with the absolute path printed by `echo "$PWD/vendor/lib"` and report that in your summary.

- [ ] **Step 8: Commit**

```bash
git add scripts Package.swift Sources Tests
git commit -m "Add libdf build script, package skeleton and FrameBuffer"
```

---

### Task 2: Denoiser, conversion and file cleaning

**Depends on:** 1

**Files:**
- Create: `Sources/ClearMicCore/Denoiser.swift`, `Sources/ClearMicCore/Conversion.swift`
- Test: `Tests/ClearMicCoreTests/DenoiserTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/ClearMicCoreTests/DenoiserTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --filter DenoiserTests`
Expected: build error, `cannot find 'Denoiser' in scope`.

- [ ] **Step 3: Implement Denoiser**

`Sources/ClearMicCore/Denoiser.swift`:

```swift
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
```

- [ ] **Step 4: Implement conversion and file cleaning**

`Sources/ClearMicCore/Conversion.swift`:

```swift
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
```

- [ ] **Step 5: Run to see them pass**

Run: `swift test --filter DenoiserTests`
Expected: `Executed 3 tests, with 0 failures`. If only `testCleanFileRemovesWhiteNoise` fails on the −20 dB check, print `dropDb` and report the number; do not loosen the threshold yourself.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClearMicCore/Denoiser.swift Sources/ClearMicCore/Conversion.swift Tests/ClearMicCoreTests/DenoiserTests.swift
git commit -m "Add Denoiser, format conversion and file cleaning"
```

---

### Task 3: Audio device lookup

**Depends on:** 1

**Files:**
- Create: `Sources/ClearMicCore/AudioDevices.swift`
- Test: `Tests/ClearMicCoreTests/AudioDevicesTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/ClearMicCoreTests/AudioDevicesTests.swift`:

```swift
import XCTest
@testable import ClearMicCore

final class AudioDevicesTests: XCTestCase {
    func testListsNamedDevicesAndFindsThemByName() throws {
        let devices = allAudioDevices()
        let out = try XCTUnwrap(devices.first { $0.hasOutput }, "this Mac has no output device")
        XCTAssertFalse(out.name.isEmpty)
        XCTAssertEqual(findDevice(named: out.name, input: false)?.id, out.id)
        XCTAssertNil(findDevice(named: "no such device 123", input: false))
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter AudioDevicesTests`
Expected: build error, `cannot find 'allAudioDevices' in scope`.

- [ ] **Step 3: Implement**

`Sources/ClearMicCore/AudioDevices.swift`:

```swift
import CoreAudio

public struct AudioDevice {
    public let id: AudioDeviceID
    public let name: String
    public let hasInput: Bool
    public let hasOutput: Bool
}

private func address(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func hasStreams(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
    var addr = address(kAudioDevicePropertyStreams, scope)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
}

private func deviceName(_ id: AudioDeviceID) -> String {
    var addr = address(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
    }
    guard status == noErr, let name else { return "" }
    return name.takeRetainedValue() as String
}

public func allAudioDevices() -> [AudioDevice] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map {
        AudioDevice(id: $0, name: deviceName($0),
                    hasInput: hasStreams($0, kAudioObjectPropertyScopeInput),
                    hasOutput: hasStreams($0, kAudioObjectPropertyScopeOutput))
    }
}

/// Finds a device by exact name that can do input (`input: true`) or output.
public func findDevice(named name: String, input: Bool) -> AudioDevice? {
    allAudioDevices().first { $0.name == name && (input ? $0.hasInput : $0.hasOutput) }
}
```

- [ ] **Step 4: Run to see it pass**

Run: `swift test --filter AudioDevicesTests`
Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClearMicCore/AudioDevices.swift Tests/ClearMicCoreTests/AudioDevicesTests.swift
git commit -m "Add audio device listing and lookup"
```

---

### Task 4: Live pipeline and the clearmic command

**Depends on:** 2, 3

**Files:**
- Create: `Sources/ClearMicCore/AudioPipeline.swift`
- Modify: `Sources/clearmic/main.swift` (replace the whole file)

No new unit test: this task is wiring to real audio hardware. Its checks are the command runs in Steps 3–5 and the live verification in Task 5. The queue and drop logic it relies on is already tested in `FrameBufferTests`.

- [ ] **Step 1: Implement the pipeline**

`Sources/ClearMicCore/AudioPipeline.swift`:

```swift
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
```

- [ ] **Step 2: Implement the command**

`Sources/clearmic/main.swift`:

```swift
import AVFoundation
import ClearMicCore
import Foundation

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func printDevices() {
    for d in allAudioDevices() {
        print("\(d.hasInput ? "in " : "   ") \(d.hasOutput ? "out" : "   ")  \(d.name)")
    }
}

let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("--list") {
    printDevices()
    exit(0)
}

let modelPath = ProcessInfo.processInfo.environment["CLEARMIC_MODEL"]
    ?? "vendor/DeepFilterNet/models/DeepFilterNet3_onnx.tar.gz"
let denoiser: Denoiser
do {
    denoiser = try Denoiser(modelPath: modelPath)
} catch {
    fail("Cannot load the model at \(modelPath). Run scripts/build-libdf.sh from the project folder, or set CLEARMIC_MODEL.", 4)
}

if let i = args.firstIndex(of: "--file") {
    guard i + 2 < args.count else { fail("usage: clearmic --file in.wav out.wav", 2) }
    do {
        try cleanFile(input: URL(fileURLWithPath: args[i + 1]), output: URL(fileURLWithPath: args[i + 2]), denoiser: denoiser)
    } catch {
        fail("Could not clean the file: \(error)", 1)
    }
    exit(0)
}

// Live mode.
if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
    let done = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in done.signal() }
    done.wait()
}
guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
    fail("Microphone access is denied. Allow it for your terminal app in System Settings > Privacy & Security > Microphone.", 3)
}

let outName = option("--out") ?? "BlackHole 2ch"
guard let outDevice = findDevice(named: outName, input: false) else {
    printDevices()
    fail("No output device named \"\(outName)\". Devices are listed above.", 2)
}
var inID: AudioDeviceID?
if let inName = option("--in") {
    guard let inDevice = findDevice(named: inName, input: true) else {
        printDevices()
        fail("No input device named \"\(inName)\". Devices are listed above.", 2)
    }
    inID = inDevice.id
}

let pipeline = AudioPipeline(denoiser: denoiser)
do {
    try pipeline.start(input: inID, output: outDevice.id)
} catch {
    fail("Could not start audio: \(error)", 1)
}
print("ClearMic is running. Select \"\(outName)\" as the microphone in your meeting app. Press Ctrl-C to stop.")

var reported = 0
while true {
    sleep(10)
    let dropped = pipeline.droppedSamples
    if dropped > reported {
        print("dropped \(dropped - reported) samples in the last 10 s")
        reported = dropped
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: Check the list and error paths**

Run: `.build/debug/clearmic --list`
Expected: one line per audio device, each with `in` and/or `out` and a name.

Run: `.build/debug/clearmic --out "no such device"; echo "exit=$?"`
Expected: the device list, the line `No output device named "no such device".`, then `exit=2`. (If microphone access was never granted to the terminal this may print the microphone message and `exit=3` instead; report which.)

Run: `CLEARMIC_MODEL=/nope .build/debug/clearmic --file a.wav b.wav; echo "exit=$?"`
Expected: `Cannot load the model at /nope.` and `exit=4`.

- [ ] **Step 5: Check file mode end to end**

Run:
```bash
ffmpeg -loglevel error -y -f lavfi -i "anoisesrc=d=3:c=white:a=0.1" -ar 44100 -ac 1 "$TMPDIR"clearmic-in.wav
.build/debug/clearmic --file "$TMPDIR"clearmic-in.wav "$TMPDIR"clearmic-out.wav; echo "exit=$?"
ffmpeg -hide_banner -i "$TMPDIR"clearmic-in.wav -af volumedetect -f null - 2>&1 | grep mean_volume
ffmpeg -hide_banner -ss 1 -i "$TMPDIR"clearmic-out.wav -af volumedetect -f null - 2>&1 | grep mean_volume
```
Expected: `exit=0`, and the second `mean_volume` at least 20 dB lower than the first.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClearMicCore/AudioPipeline.swift Sources/clearmic/main.swift
git commit -m "Add live audio pipeline and clearmic command"
```

---

### Task 5: Live verification (run by the main agent, not a sub-agent)

**Depends on:** 4, and the user having run `brew install blackhole-2ch`

**Files:** none

- [ ] **Step 1: Confirm BlackHole is present**

Run: `.build/debug/clearmic --list | grep -c "BlackHole 2ch"`
Expected: `1`. If `0`, ask the user to run `brew install blackhole-2ch` and, if it still does not appear, log out and back in.

- [ ] **Step 2: Run live and record what a meeting app would receive**

Run `.build/debug/clearmic` in a Terminal tab (microphone permission is asked once). Then, in another shell:

```bash
ffmpeg -loglevel error -y -f avfoundation -i ":BlackHole 2ch" -t 8 "$TMPDIR"clearmic-live.wav
ffmpeg -hide_banner -i "$TMPDIR"clearmic-live.wav -af volumedetect -f null - 2>&1 | grep -E "mean_volume|max_volume"
```

Expected: the recording is not silent while someone speaks (`max_volume` above −40 dB), and `clearmic` prints no steady stream of `dropped` lines. If macOS denies microphone access to the process that the agent launches, hand this step to the user with the exact commands.

- [ ] **Step 3: User check in a real call**

Ask the user to select "BlackHole 2ch" as the microphone in a meeting app's audio test and confirm that their voice comes through with background noise removed. Record the answer in the final report.
