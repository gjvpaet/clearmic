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

setvbuf(stdout, nil, _IOLBF, 0)  // show status and drop counts at once, even when output is piped to a file
let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else {
        fail("usage: clearmic [--list] [--in \"<mic name>\"] [--out \"<device name>\"] [--listen \"<device name>\"] [--echo-cancel] [--no-inbound] | --file in.wav out.wav", 2)
    }
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
    fail("Cannot load the model at \(modelPath). Run scripts/build-native.sh from the project folder, or set CLEARMIC_MODEL.", 4)
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

// Live mode. Devices are resolved before asking for the microphone, so a wrong name never triggers the prompt.
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
// The call's own audio as our microphone would send the call back to itself.
if let inbound, (inID ?? defaultInputDeviceID()) == inbound.source {
    fail("The microphone is \(inboundName), which carries the call audio. Pick your real microphone with --in \"<name>\" (see --list).", 2)
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
