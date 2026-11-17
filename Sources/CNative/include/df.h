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
