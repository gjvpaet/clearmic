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
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else {
        fail("usage: clearmic [--list] [--in \"<mic name>\"] [--out \"<device name>\"] | --file in.wav out.wav", 2)
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

if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
    let done = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in done.signal() }
    done.wait()
}
guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
    fail("Microphone access is denied. Allow it for your terminal app in System Settings > Privacy & Security > Microphone.", 3)
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
    RunLoop.main.run(until: Date().addingTimeInterval(10))  // not sleep: lets main-thread audio notifications arrive
    let dropped = pipeline.droppedSamples
    if dropped > reported {
        print("dropped \(dropped - reported) samples in the last 10 s")
        reported = dropped
    }
}
