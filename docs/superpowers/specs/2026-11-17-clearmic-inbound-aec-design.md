# ClearMic inbound cleaning and echo cancelling — design

Date: 2026-11-17. Status: design approved, awaiting spec review.
Builds on: `2026-11-17-clearmic-prototype-design.md` (mic-only prototype, merged to `main`).

## Goal

1. Remove background noise from the other participants' audio before the user
   hears it.
2. When the user listens on loudspeakers, remove the other participants'
   voices from the user's microphone signal before it is sent to the meeting.

Done means: in a real call with BlackHole 2ch as the meeting app's microphone
and BlackHole 16ch as its speaker, (a) on headphones the user hears the others
with noise removed, and (b) on loudspeakers with `--echo-cancel`, the others do
not hear themselves echoed back.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Capturing inbound audio | Second loopback device, BlackHole 16ch, selected as the meeting app's speaker | Same technique as the mic side; no new permissions. Per-app audio taps are deferred until ClearMic is a bundled app |
| Echo canceller | WebRTC AEC3 through the Rust crate `webrtc-audio-processing` 2.1.0, `bundled` feature | User's choice over Apple voice processing: no Apple voice tuning, full control |
| Native code packaging | One Rust static library that contains both DeepFilterNet (`deep_filter`, `capi`) and the canceller wrapper | Two Rust static libraries each embed the Rust standard library and collide at link time |
| Listening modes | Headphones: inbound cleaning only. Loudspeakers: add `--echo-cancel` | Echo cancelling costs CPU and is unnecessary on headphones |

## Audio paths

All processing is 48 kHz, mono, 32-bit float, in 480-sample (10 ms) frames.

1. Outbound (exists): input device → [echo canceller capture step, if enabled]
   → Denoiser A → BlackHole 2ch.
2. Inbound (new): BlackHole 16ch → Denoiser B → listen device.
3. Echo reference (new, with `--echo-cancel`): the samples the inbound
   playback callback actually pulls for the listen device are copied into a
   "played" queue. The outbound thread drains that queue into the canceller's
   render step, then runs the capture step on each mic frame. Only the outbound
   thread touches the canceller.

Denoiser A and B are separate instances; a DeepFilterNet state is not
thread-safe and holds per-stream history.

## Components

| Unit | Change | Depends on |
|---|---|---|
| `native/` (new Rust crate `clearnative`, staticlib) | Depends on `deep_filter` (path `vendor/DeepFilterNet/libDF`, feature `capi`) and `webrtc-audio-processing` (`bundled`). Re-exports the `df_*` functions and adds `aec_create()`, `aec_process_render(st, frame)`, `aec_process_capture(st, frame)`, `aec_free(st)`; frames are 480 floats, processed in place | cargo, meson, ninja, pkg-config |
| `scripts/build-libdf.sh` → `scripts/build-native.sh` | Builds `clearnative` and copies `libclearnative.a` to `vendor/lib/`; keeps the pinned DeepFilterNet commit and the LTO-off setting | — |
| `Sources/CDeepFilter` → `Sources/CNative` | Header gains the four `aec_*` declarations; links `clearnative` | `vendor/lib/libclearnative.a` |
| `EchoCanceller.swift` (new) | Owns one canceller. `played(_ frame: [Float])`, `clean(_ frame: [Float]) -> [Float]` | CNative |
| `AudioPipeline.swift` | Generalised to `AudioPipeline(process:)` with `start(input:output:)`; `process` maps captured 48 kHz mono samples to output samples. Optional `onPlayed` callback receives the samples pulled by the playback callback | FrameBuffer, Conversion |
| `main.swift` | Builds one pipeline per direction; new flags below | all |

## Command

- `clearmic` — outbound as today, plus inbound when a device named
  "BlackHole 16ch" exists.
- `--listen "<device>"` — where the user hears the others. Default: the system
  default output device.
- `--echo-cancel` — enable the canceller (for loudspeakers).
- `--no-inbound` — mic-only, today's behaviour.
- Existing flags (`--list`, `--in`, `--out`, `--file`) are unchanged.

## Failure handling

- Listen device is BlackHole 16ch or BlackHole 2ch (a loop): refuse to start,
  exit status 2, message naming `--listen`.
- BlackHole 16ch absent and `--no-inbound` not given: print one line saying
  inbound is off and how to install it; continue mic-only.
- `--echo-cancel` given while inbound is off: refuse, exit status 2 (there is
  no reference signal).
- Canceller creation fails: print the error, exit status 4.
- Inbound falls behind: same policy as outbound (drop oldest beyond 300 ms,
  count, report every 10 s).

## Testing

- Unit: `EchoCanceller` — reference is 5 s of band-limited noise; capture is
  the same signal delayed 40 ms and attenuated 6 dB. After the first 3 s the
  cleaned capture's RMS is at least 15 dB below the uncleaned capture's RMS.
- Existing 7 tests keep passing after the native library is combined.
- Live (agent, user present): play a speech file into BlackHole 16ch with
  ClearMic listening on the loudspeakers; record BlackHole 2ch with and without
  `--echo-cancel`; the echo-cancelled recording is at least 10 dB quieter during
  far-end speech.
- Live (user): one call on headphones, one on loudspeakers.

## Order of work

1. Spike (time-boxed, about 1 hour): `clearnative` builds, links into the
   Swift package, the existing tests pass, and `aec_create` returns a state.
   If the combined library cannot be made to link, stop and report options
   before continuing.
2. Inbound for headphones: generalised pipeline, `--listen`, `--no-inbound`,
   loop guard. Usable on its own.
3. Echo cancelling: `EchoCanceller`, "played" queue, `--echo-cancel`.

## User-performed steps

- `brew install blackhole-16ch pkg-config meson ninja` (admin password for
  BlackHole; a reboot or `sudo killall coreaudiod` to load the driver).
- In the meeting app: speaker = BlackHole 16ch (microphone stays BlackHole 2ch).

## Risks

- Delay: each direction adds roughly 100–200 ms. If AEC3 cannot track the echo
  at the resulting delay, the remedy is the lower-latency capture method
  (AUHAL callbacks instead of engine taps), planned as its own task.
- Clock drift between BlackHole 16ch and the listen device causes occasional
  dropped or silent 10 ms blocks; accepted for now.
- The Rust crate states it does not follow semantic versioning strictly; pin
  `=2.1.0`.

## Out of scope

Stereo inbound (voices are mixed to mono), per-app audio taps, menu-bar UI, own
virtual driver, lower-latency capture, automatic headphone detection.
