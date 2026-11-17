# ClearMic Inbound Cleaning and Echo Cancelling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ClearMic also cleans the other participants' audio (meeting app → BlackHole 16ch → noise removal → the user's speakers or headphones) and, with `--echo-cancel`, removes that audio from the microphone signal.

**Architecture:** One Rust static library, `libclearnative.a`, bundles DeepFilterNet's C functions and a four-function C wrapper around WebRTC's echo canceller. `AudioPipeline` becomes direction-neutral (input device, output device, a processing closure, an optional "this was played" callback) and is used twice. `EchoCanceller` pairs one played frame with each microphone frame on the microphone thread.

**Tech Stack:** Swift 5 mode / SwiftPM / XCTest, AVFoundation, CoreAudio, Rust 1.100 (`deep_filter` at commit `7b14b895fe7fc42cab72b4a4c1e49c982bd6404b`, `webrtc-audio-processing` `=2.1.0` with `bundled`), meson, ninja, pkg-config.

**Spec:** `docs/superpowers/specs/2026-11-17-clearmic-inbound-aec-design.md`

## Notes for every task

- User prerequisites: `brew install blackhole-16ch pkg-config meson ninja` (BlackHole 16ch is only needed for Task 4).
- All tasks run **one after another in the same worktree**. `vendor/` is git-ignored; the controller moves the existing `vendor/` folder (DeepFilterNet clone + model) into the worktree before Task 1. No parallel wave.
- Run only the named test filter, one build or test process at a time.
- Commits carry no `Co-Authored-By:` line. `~/.gitconfig` is currently broken (`gpg.format` empty): if `git` fails with that message, do not edit it; report `BLOCKED` and the controller commits.
- Never start live audio in Tasks 1–3: `.build/debug/clearmic` may only be run with `--list`, `--file`, or arguments that are expected to exit with status 2.
- Deviation from the spec's order of work, on purpose: the echo canceller wrapper (Task 2) is built before the inbound pipeline (Task 3), so `main.swift` is rewritten once instead of twice. Inbound still works alone without `--echo-cancel`.

## File map

| File | Change |
|---|---|
| `native/Cargo.toml`, `native/src/lib.rs`, `native/Cargo.lock` | New Rust crate `clearnative`: links DeepFilterNet's `df_*`, adds `aec_*` |
| `scripts/build-libdf.sh` → `scripts/build-native.sh` | Builds `vendor/lib/libclearnative.a` |
| `Sources/CDeepFilter/` → `Sources/CNative/` | Header gains `aec_*` |
| `Package.swift` | Target rename, link `clearnative` and `c++` |
| `Sources/ClearMicCore/Denoiser.swift` | `import CNative` |
| `Sources/ClearMicCore/EchoCanceller.swift` | New |
| `Sources/ClearMicCore/AudioDevices.swift` | `defaultOutputDeviceID()` |
| `Sources/ClearMicCore/AudioPipeline.swift` | Direction-neutral |
| `Sources/clearmic/main.swift` | Inbound, `--listen`, `--echo-cancel`, `--no-inbound` |

---

### Task 1: Combined native library (time-boxed trial)

**Depends on:** none

**Files:**
- Create: `native/Cargo.toml`, `native/src/lib.rs`, `scripts/build-native.sh`
- Delete: `scripts/build-libdf.sh`
- Rename: `Sources/CDeepFilter/` → `Sources/CNative/` (both files inside)
- Modify: `Package.swift`, `Sources/ClearMicCore/Denoiser.swift:1`
- Test: `Tests/ClearMicCoreTests/EchoCancellerTests.swift`

This is a trial. If after reasonable effort (about an hour) the combined library cannot be built or linked, stop and report `BLOCKED` with the exact error and what you tried. Do not redesign.

- [ ] **Step 1: Write the Rust crate**

`native/Cargo.toml`:

```toml
[package]
name = "clearnative"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["staticlib"]

[dependencies]
deep_filter = { path = "../vendor/DeepFilterNet/libDF", default-features = false, features = ["capi"] }
webrtc-audio-processing = { version = "=2.1.0", features = ["bundled"] }
```

`native/src/lib.rs`:

```rust
//! One static library for ClearMic: DeepFilterNet's C functions plus a small
//! C wrapper around WebRTC's echo canceller.

// Keeps DeepFilterNet's `df_*` C functions in this library.
extern crate df;

use webrtc_audio_processing::config::{Config, EchoCanceller};
use webrtc_audio_processing::Processor;

/// 10 ms at 48 kHz, mono.
const FRAME: usize = 480;

/// Returns null if the canceller cannot be created.
#[no_mangle]
pub extern "C" fn aec_create() -> *mut Processor {
    match Processor::new(48_000) {
        Ok(p) => {
            p.set_config(Config {
                echo_canceller: Some(EchoCanceller::default()),
                ..Default::default()
            });
            Box::into_raw(Box::new(p))
        }
        Err(_) => std::ptr::null_mut(),
    }
}

/// `frame`: 480 samples that were just sent to the loudspeakers. Returns 0 on success.
#[no_mangle]
pub unsafe extern "C" fn aec_process_render(st: *mut Processor, frame: *mut f32) -> i32 {
    let ch = std::slice::from_raw_parts_mut(frame, FRAME);
    match (*st).process_render_frame([ch]) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// `frame`: 480 microphone samples, cleaned in place. Returns 0 on success.
#[no_mangle]
pub unsafe extern "C" fn aec_process_capture(st: *mut Processor, frame: *mut f32) -> i32 {
    let ch = std::slice::from_raw_parts_mut(frame, FRAME);
    match (*st).process_capture_frame([ch]) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn aec_free(st: *mut Processor) {
    drop(Box::from_raw(st));
}
```

This Rust was written from the crate's `examples/simple.rs` and `src/lib.rs` without compiling. The frame argument of `process_render_frame` / `process_capture_frame` is generic; if `[ch]` does not satisfy its bound, read the function signatures in the downloaded crate source (`~/.cargo/registry/src/*/webrtc-audio-processing-2.1.0/src/lib.rs`) and pass one mono channel of 480 samples in whatever form compiles (the crate's tests use `vec![vec![0.0; 480]]`; copying into a `Vec` and back is acceptable). Keep the four C function names and signatures unchanged. Report what you used.

- [ ] **Step 2: Replace the build script**

Delete `scripts/build-libdf.sh` (`git rm`). Create `scripts/build-native.sh`:

```bash
#!/bin/bash
# Fetches DeepFilterNet at a pinned commit and builds the combined native
# library (DeepFilterNet + WebRTC echo canceller): vendor/lib/libclearnative.a
set -euo pipefail
cd "$(dirname "$0")/.."
REV=7b14b895fe7fc42cab72b4a4c1e49c982bd6404b
MODEL=vendor/DeepFilterNet/models/DeepFilterNet3_onnx.tar.gz
for tool in cargo meson ninja pkg-config; do
  command -v "$tool" >/dev/null || { echo "$tool missing: run 'brew install rust meson ninja pkg-config'" >&2; exit 1; }
done
mkdir -p vendor/lib
[ -d vendor/DeepFilterNet/.git ] || git clone https://github.com/Rikorose/DeepFilterNet vendor/DeepFilterNet
git -C vendor/DeepFilterNet checkout -q "$REV"
# A tiny file here means git stored a Git LFS pointer instead of the model.
[ "$(stat -f%z "$MODEL")" -gt 100000 ] || { echo "$MODEL is not a real model file (Git LFS pointer?)" >&2; exit 1; }
# Our own crate's release profile has no LTO, so Apple's linker can read the result.
cargo build --release --manifest-path native/Cargo.toml --target-dir vendor/native-target
cp vendor/native-target/release/libclearnative.a vendor/lib/libclearnative.a
rm -f vendor/lib/libdf.a
echo "built vendor/lib/libclearnative.a"
```

- [ ] **Step 3: Build it**

Run: `chmod +x scripts/build-native.sh && scripts/build-native.sh` (downloads Rust crates and compiles C++; allow 10–15 minutes, run in the background and wait)
Expected: last line `built vendor/lib/libclearnative.a`, and
`nm vendor/lib/libclearnative.a 2>/dev/null | grep -cE ' T _(df_create|df_process_frame|aec_create|aec_process_capture)$'` prints `4`.

If `df_*` symbols are missing while `aec_*` are present, `extern crate df;` did not keep them: add `pub use df::capi::*;` if that module is public, otherwise report `BLOCKED`.

- [ ] **Step 4: Rename the C module and add the declarations**

Run: `git mv Sources/CDeepFilter Sources/CNative`

`Sources/CNative/include/df.h` (whole file):

```c
#ifndef CLEARMIC_NATIVE_H
#define CLEARMIC_NATIVE_H
#include <stddef.h>

// DeepFilterNet's C interface (libDF/src/capi.rs).
typedef struct DFState DFState;
DFState *df_create(const char *path, float atten_lim, const char *log_level);
size_t df_get_frame_length(DFState *st);
float df_process_frame(DFState *st, float *input, float *output);
void df_free(DFState *st);

// Echo canceller wrapper (native/src/lib.rs). Frames are 480 floats (10 ms at 48 kHz mono).
typedef struct AecState AecState;
AecState *aec_create(void);
int aec_process_render(AecState *st, float *frame);
int aec_process_capture(AecState *st, float *frame);
void aec_free(AecState *st);

#endif
```

In `Package.swift`, replace the `CDeepFilter` target and the `ClearMicCore` dependency:

```swift
        .target(
            name: "CNative",
            linkerSettings: [
                .unsafeFlags(["-L", "vendor/lib"]),
                .linkedLibrary("clearnative"),
                // System libraries the Rust and C++ code needs.
                .linkedLibrary("c++"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("iconv"),
                .linkedLibrary("resolv"),
            ]),
        .target(name: "ClearMicCore", dependencies: ["CNative"]),
```

In `Sources/ClearMicCore/Denoiser.swift` line 1, change `import CDeepFilter` to `import CNative`.

- [ ] **Step 5: Write the failing link test**

`Tests/ClearMicCoreTests/EchoCancellerTests.swift`:

```swift
import CNative
import XCTest

final class EchoCancellerTests: XCTestCase {
    func testNativeCancellerCanBeCreated() {
        let state = aec_create()
        XCTAssertNotNil(state)
        aec_free(state)
    }
}
```

Add `"CNative"` to the test target's dependencies in `Package.swift`:

```swift
        .testTarget(name: "ClearMicCoreTests", dependencies: ["ClearMicCore", "CNative"]),
```

- [ ] **Step 6: Run the tests**

Run, one after another:
`swift test --filter EchoCancellerTests` → `Executed 1 test, with 0 failures`
`swift test --filter DenoiserTests` → `Executed 3 tests, with 0 failures`
`swift test --filter FrameBufferTests` → `Executed 3 tests, with 0 failures`
`swift test --filter AudioDevicesTests` → `Executed 1 test, with 0 failures`

If the linker reports undefined symbols, add the library or framework it names to `linkerSettings` (for example `.linkedFramework("Accelerate")`) and report each addition.

- [ ] **Step 7: Commit**

```bash
git add native scripts Package.swift Sources Tests
git commit -m "Combine DeepFilterNet and WebRTC echo canceller into one native library"
```

`native/Cargo.lock` must be in the commit; `vendor/` must not.

---

### Task 2: EchoCanceller

**Depends on:** 1

**Files:**
- Create: `Sources/ClearMicCore/EchoCanceller.swift`
- Modify: `Tests/ClearMicCoreTests/EchoCancellerTests.swift`

- [ ] **Step 1: Add the failing test**

Add to `EchoCancellerTests` (and add `@testable import ClearMicCore` at the top of the file):

```swift
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
```

(`rms` is already defined at file scope in `DenoiserTests.swift`.)

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter EchoCancellerTests`
Expected: build error, `cannot find 'EchoCanceller' in scope`.

- [ ] **Step 3: Implement**

`Sources/ClearMicCore/EchoCanceller.swift`:

```swift
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
```

- [ ] **Step 4: Run to see it pass**

Run: `swift test --filter EchoCancellerTests`
Expected: `Executed 2 tests, with 0 failures`. If only the −15 dB check fails, print `dropDb` and report the number; do not loosen the threshold.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClearMicCore/EchoCanceller.swift Tests/ClearMicCoreTests/EchoCancellerTests.swift
git commit -m "Add EchoCanceller"
```

---

### Task 3: Direction-neutral pipeline, inbound cleaning, new flags

**Depends on:** 2

**Files:**
- Modify: `Sources/ClearMicCore/AudioDevices.swift`, `Sources/ClearMicCore/AudioPipeline.swift` (whole file), `Sources/clearmic/main.swift` (from `let outName` to the end)
- Test: `Tests/ClearMicCoreTests/AudioDevicesTests.swift`

- [ ] **Step 1: Add the failing device assertion**

In `AudioDevicesTests.testListsNamedDevicesAndFindsThemByName`, after the existing `defaultInputDeviceID` block, add:

```swift
        if let id = defaultOutputDeviceID() {
            XCTAssertTrue(devices.contains { $0.id == id && $0.hasOutput })
        }
```

Run: `swift test --filter AudioDevicesTests`
Expected: build error, `cannot find 'defaultOutputDeviceID' in scope`.

- [ ] **Step 2: Implement `defaultOutputDeviceID`**

In `Sources/ClearMicCore/AudioDevices.swift`, replace the existing `defaultInputDeviceID` function with:

```swift
private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var addr = address(selector)
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return status == noErr && id != kAudioObjectUnknown ? id : nil
}

/// The system default microphone, or nil if there is none.
public func defaultInputDeviceID() -> AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }

/// The system default speakers or headphones, or nil if there are none.
public func defaultOutputDeviceID() -> AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }
```

Run: `swift test --filter AudioDevicesTests`
Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 3: Make the pipeline direction-neutral**

`Sources/ClearMicCore/AudioPipeline.swift` (whole file):

```swift
import AVFoundation
import CoreAudio

public struct AudioPipelineError: Error { public let message: String }

/// Live path: input device -> `process` -> output device.
public final class AudioPipeline {
    private let capture = AVAudioEngine()
    private let playback = AVAudioEngine()
    private let outQueue = FrameBuffer()
    private let process: ([Float]) -> [Float]
    private let onPlayed: (([Float]) -> Void)?
    /// Samples discarded because playback fell behind. Written on the audio thread, read for logging only.
    public private(set) var droppedSamples = 0

    /// `process` maps captured 48 kHz mono samples to the samples to play.
    /// `onPlayed` receives exactly what is sent to the output device, silence included.
    public init(process: @escaping ([Float]) -> [Float], onPlayed: (([Float]) -> Void)? = nil) {
        self.process = process
        self.onPlayed = onPlayed
    }

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
            outQueue.push(process(toWorkSamples(buffer, using: converter)))
            droppedSamples += outQueue.dropOldest(downTo: maxQueued)
        }

        let source = AVAudioSourceNode(format: workFormat) { [outQueue, onPlayed] _, _, frameCount, bufferList in
            let n = Int(frameCount)
            let dst = UnsafeMutableAudioBufferListPointer(bufferList)[0].mData!.assumingMemoryBound(to: Float.self)
            // Nothing ready yet means silence.
            let samples = outQueue.pop(n) ?? [Float](repeating: 0, count: n)
            samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: n) }
            onPlayed?(samples)
            return noErr
        }
        playback.attach(source)
        // The mixer copies our mono signal to every output channel.
        playback.connect(source, to: playback.mainMixerNode, format: workFormat)

        try playback.start()
        try capture.start()
    }
}
```

- [ ] **Step 4: Rewrite the live part of the command**

In `Sources/clearmic/main.swift`, keep everything above the line `let outName = option("--out") ?? "BlackHole 2ch"` unchanged, and replace from that line to the end of the file with:

```swift
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
// Same device both ways would record our own output in a loop.
if (inID ?? defaultInputDeviceID()) == outDevice.id {
    fail("Input and output are the same device (\(outName)). Pick your real microphone with --in \"<name>\" (see --list).", 2)
}

// Inbound: clean what the meeting app plays. The meeting app must use this device as its speaker.
let inboundName = "BlackHole 16ch"
let echoCancel = args.contains("--echo-cancel")
var inbound: (source: AudioDeviceID, listen: AudioDeviceID)?
if !args.contains("--no-inbound") {
    if let source = findDevice(named: inboundName, input: true) {
        var chosen = defaultOutputDeviceID()
        if let listenName = option("--listen") {
            guard let listenDevice = findDevice(named: listenName, input: false) else {
                printDevices()
                fail("No output device named \"\(listenName)\". Devices are listed above.", 2)
            }
            chosen = listenDevice.id
        }
        // Playing into either loopback device would feed the call back into itself.
        guard let listenID = chosen, listenID != source.id, listenID != outDevice.id else {
            fail("Cannot play the cleaned call audio into \(inboundName) or \(outName). Pick your speakers or headphones with --listen \"<name>\" (see --list).", 2)
        }
        inbound = (source.id, listenID)
    } else {
        print("Inbound cleaning is off: no device named \"\(inboundName)\". Install it with: brew install blackhole-16ch")
    }
}
if echoCancel && inbound == nil {
    fail("--echo-cancel needs inbound cleaning: \(inboundName) installed and no --no-inbound.", 2)
}

if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
    let done = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in done.signal() }
    done.wait()
}
guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
    fail("Microphone access is denied. Allow it for your terminal app in System Settings > Privacy & Security > Microphone.", 3)
}

func makeEchoCanceller() -> EchoCanceller {
    do { return try EchoCanceller() } catch { fail("Could not start the echo canceller.", 4) }
}
let echo: EchoCanceller? = echoCancel ? makeEchoCanceller() : nil

// Microphone: [echo canceller] -> noise removal -> virtual microphone.
let micPipeline = AudioPipeline(process: { samples in denoiser.clean(echo?.clean(samples) ?? samples) })
do {
    try micPipeline.start(input: inID, output: outDevice.id)
} catch {
    fail("Could not start audio: \(error)", 1)
}
var pipelines = [("mic", micPipeline)]

if let inbound {
    // A second model instance: each stream needs its own state.
    let inboundDenoiser: Denoiser
    do {
        inboundDenoiser = try Denoiser(modelPath: modelPath)
    } catch {
        fail("Cannot load the model at \(modelPath).", 4)
    }
    let inboundPipeline = AudioPipeline(
        process: { inboundDenoiser.clean($0) },
        onPlayed: echo.map { canceller in { canceller.played($0) } })
    do {
        try inboundPipeline.start(input: inbound.source, output: inbound.listen)
    } catch {
        fail("Could not start inbound audio: \(error)", 1)
    }
    pipelines.append(("inbound", inboundPipeline))
    print("Inbound cleaning is on. Select \"\(inboundName)\" as the speaker in your meeting app.\(echoCancel ? " Echo cancelling is on." : "")")
}
print("ClearMic is running. Select \"\(outName)\" as the microphone in your meeting app. Press Ctrl-C to stop.")

var reported = [Int](repeating: 0, count: pipelines.count)
while true {
    RunLoop.main.run(until: Date().addingTimeInterval(10))  // not sleep: lets main-thread audio notifications arrive
    for (i, (name, pipeline)) in pipelines.enumerated() {
        let dropped = pipeline.droppedSamples
        if dropped > reported[i] {
            print("\(name): dropped \(dropped - reported[i]) samples in the last 10 s")
            reported[i] = dropped
        }
    }
}
```

If this does not compile, make the smallest fix that keeps the behaviour and report it with the compiler message.

- [ ] **Step 5: Build and check the refusal paths (no live audio)**

Run: `swift build 2>&1 | tail -1` → `Build complete!`

Run each and report output and exit code (all must exit before audio starts):
- `.build/debug/clearmic --list` → device list, exit 0
- `.build/debug/clearmic --out "no such device"; echo "exit=$?"` → exit 2
- `.build/debug/clearmic --listen "no such device"; echo "exit=$?"` → exit 2 if "BlackHole 16ch" is in the device list; if it is not, do NOT run this command (it would start live audio) and say so
- `.build/debug/clearmic --listen "BlackHole 2ch"; echo "exit=$?"` → exit 2 with the "Cannot play the cleaned call audio" message, same condition as above
- `.build/debug/clearmic --no-inbound --echo-cancel; echo "exit=$?"` → exit 2 with the `--echo-cancel needs inbound cleaning` message

- [ ] **Step 6: Run the remaining tests, one after another**

`swift test --filter FrameBufferTests`, `swift test --filter DenoiserTests`, `swift test --filter EchoCancellerTests`, `swift test --filter AudioDevicesTests` — all with 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources Tests
git commit -m "Add inbound cleaning, --listen, --echo-cancel and --no-inbound"
```

---

### Task 4: Live verification (main agent with the user present)

**Depends on:** 3, and the user having installed BlackHole 16ch (visible in `clearmic --list`)

**Files:** none

- [ ] **Step 1: Inbound on its own**

Start `.build/debug/clearmic --in "MacBook Pro Microphone" --listen "MacBook Pro Speakers"` in the background. Play a noisy speech file into BlackHole 16ch (`ffmpeg ... -f audiotoolbox -audio_device_index <BlackHole 16ch index> -`), and record the MacBook microphone for the same period. Expected: the speech is audible from the speakers (microphone recording clearly above the room's quiet level) and `clearmic` prints `Inbound cleaning is on.` with no steady `dropped` lines.

- [ ] **Step 2: Echo cancelling**

Repeat with the same speech file twice, recording BlackHole 2ch (what the meeting app would receive from the microphone): once without `--echo-cancel`, once with it. Expected: during the far-end speech the recording with `--echo-cancel` is at least 10 dB quieter (`ffmpeg -af volumedetect`, `mean_volume`). Report both numbers. If the drop is under 10 dB, report it as not meeting the spec; the likely cause is total delay (spec, "Risks") and the remedy is a separate task.

- [ ] **Step 3: User checks**

Ask the user to try one call on headphones (speaker = BlackHole 16ch in the meeting app) and one on loudspeakers with `--echo-cancel`, and record both answers in the final report.
