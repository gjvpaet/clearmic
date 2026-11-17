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
