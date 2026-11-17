# ClearMic prototype — design

Date: 2026-11-17. Status: design approved, awaiting spec review.

## Goal

A command-line tool for macOS (Apple Silicon) that removes background noise
from the user's microphone in real time and exposes the cleaned audio as a
microphone that meeting apps (Zoom, Meet, Teams) can select.

Done means: with `clearmic` running and "BlackHole 2ch" selected as the
microphone in a meeting app, other participants hear the user's voice with
background noise removed.

## Background

Static inspection of Krisp 3.19.6 showed the same shape: a virtual audio
device, a native processing chain, and a DeepFilterNet-style model run on CPU
in 10–15 ms frames. ClearMic reproduces that shape with open-source parts
only. No Krisp code or model is used.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Noise model | DeepFilterNet3, via its Rust library `libDF` and its C interface (`capi` feature) | Open source, pretrained, real-time on CPU |
| App shell | Swift (SwiftPM executable) | Native CoreAudio access; grows into a menu-bar app later |
| Virtual microphone | BlackHole 2ch (installed by the user with Homebrew) | Works today. GPL-3: acceptable for personal use; must be replaced by our own driver before any closed-source distribution |
| Form | Command-line tool | Smallest thing that proves a real call |

## Audio path

1. Capture the chosen input device with `AVAudioEngine`.
2. Convert to 48 kHz, mono, 32-bit float.
3. Regroup into frames of `df_get_frame_length()` samples (480 = 10 ms).
4. `df_process_frame(state, in, out)` per frame.
5. Play cleaned frames to the chosen output device (BlackHole 2ch), duplicated
   to both channels.

## Components

Repository: `Personal/clearmic` (own git repo).

| Unit | Responsibility | Depends on |
|---|---|---|
| `scripts/build-libdf.sh` | Clone DeepFilterNet at a pinned commit into `vendor/`, build `libdf.a` with `--features capi`, copy it to `vendor/lib/` | cargo, git |
| `Sources/CDeepFilter` | C header + module map declaring `df_create`, `df_get_frame_length`, `df_process_frame`, `df_set_atten_lim`, `df_free`; links `libdf.a` | `vendor/lib/libdf.a` |
| `Sources/ClearMicCore/Denoiser.swift` | Owns one `DFState`. `frameLength`, `process(_ frame: [Float]) -> [Float]` | CDeepFilter |
| `Sources/ClearMicCore/FrameBuffer.swift` | Pure Swift. `push(samples)`, `popFrame() -> [Float]?` for a fixed frame size | nothing |
| `Sources/ClearMicCore/AudioDevices.swift` | List CoreAudio devices; resolve a device by name | CoreAudio |
| `Sources/ClearMicCore/AudioPipeline.swift` | Wire input device → converter → FrameBuffer → Denoiser → output device; count dropped frames | the three above |
| `Sources/clearmic/main.swift` | Argument parsing and the three modes below | ClearMicCore |

## Command

- `clearmic --list` — print input and output device names.
- `clearmic --in "<mic name>" --out "BlackHole 2ch"` — run live until Ctrl-C.
  `--in` defaults to the system default input; `--out` defaults to
  "BlackHole 2ch".
- `clearmic --file in.wav out.wav` — clean a WAV file offline (used by tests).

## Failure handling

- Unknown device name: print the device list, exit with status 2.
- Microphone permission denied: print where to grant it (System Settings →
  Privacy & Security → Microphone), exit with status 3.
- Model fails to load: print the error, exit with status 4.
- Processing falls behind: drop the oldest queued frames, keep a count, print
  the count every 10 seconds when non-zero. Never grow latency.

## Testing

- Unit: `FrameBuffer` (exact frames, remainders kept, order preserved).
- Integration: `--file` on generated white noise; output RMS at least 20 dB
  below input RMS.
- Live (agent): play noise through the pipeline, record from BlackHole with
  ffmpeg, confirm the level drop.
- Live (user): one real call.

## User-performed steps

- `brew install rust`
- `brew install blackhole-2ch` (admin password; may need logout/reboot)
- Grant microphone permission to the terminal on first run.

## Out of scope

Menu-bar UI, cleaning inbound audio (other participants), our own virtual
driver, echo cancellation, Intel Macs, packaging and signing.
