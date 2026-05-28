#ifndef ASS_SHIM_H
#define ASS_SHIM_H

#include <stdint.h>

typedef struct SPASSContext SPASSContext;

SPASSContext *sp_ass_context_create(int width,
                                    int height,
                                    const char *fonts_dir,
                                    const char *default_family,
                                    int use_default_provider);
void sp_ass_context_free(SPASSContext *context);
int sp_ass_context_process_header(SPASSContext *context, const uint8_t *data, int size);
int sp_ass_context_process_chunk(SPASSContext *context,
                                 const char *data,
                                 int size,
                                 int64_t time_ms,
                                 int64_t duration_ms);
int sp_ass_context_render_rgba(SPASSContext *context,
                               int64_t time_ms,
                               uint8_t *rgba,
                               int width,
                               int height,
                               int stride,
                               int *change);
void sp_ass_context_flush_events(SPASSContext *context);

#endif /* ASS_SHIM_H */
