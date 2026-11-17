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
