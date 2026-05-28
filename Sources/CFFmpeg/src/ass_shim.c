#include "ass_shim.h"

#include <errno.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct ass_library ASS_Library;
typedef struct ass_renderer ASS_Renderer;
typedef struct ass_track ASS_Track;

typedef struct ass_image {
    int w;
    int h;
    int stride;
    unsigned char *bitmap;
    uint32_t color;
    int dst_x;
    int dst_y;
    struct ass_image *next;
    int type;
} ASS_Image;

ASS_Library *ass_library_init(void);
void ass_library_done(ASS_Library *priv);
void ass_set_message_cb(ASS_Library *priv,
                        void (*msg_cb)(int level, const char *fmt, va_list va, void *data),
                        void *data);
void ass_set_fonts_dir(ASS_Library *priv, const char *fonts_dir);
void ass_set_extract_fonts(ASS_Library *priv, int extract);

ASS_Renderer *ass_renderer_init(ASS_Library *priv);
void ass_renderer_done(ASS_Renderer *priv);
void ass_set_frame_size(ASS_Renderer *priv, int width, int height);
void ass_set_storage_size(ASS_Renderer *priv, int width, int height);
void ass_set_pixel_aspect(ASS_Renderer *priv, double par);
void ass_set_shaper(ASS_Renderer *priv, int level);
void ass_set_fonts(ASS_Renderer *priv,
                   const char *default_font,
                   const char *default_family,
                   int dfp,
                   const char *config,
                   int update);
ASS_Image *ass_render_frame(ASS_Renderer *priv, ASS_Track *track, long long now, int *detect_change);

ASS_Track *ass_new_track(ASS_Library *priv);
void ass_free_track(ASS_Track *track);
void ass_process_codec_private(ASS_Track *track, const char *data, int size);
void ass_process_chunk(ASS_Track *track, const char *data, int size, long long timecode, long long duration);
void ass_set_check_readorder(ASS_Track *track, int check_readorder);
void ass_flush_events(ASS_Track *track);

struct SPASSContext {
    ASS_Library *library;
    ASS_Renderer *renderer;
    ASS_Track *track;
    int width;
    int height;
};

static void sp_ass_message_callback(int level, const char *fmt, va_list va, void *data) {
    (void)level;
    (void)fmt;
    (void)va;
    (void)data;
}

static void sp_ass_context_destroy_members(SPASSContext *context) {
    if (context == NULL) {
        return;
    }
    if (context->track != NULL) {
        ass_free_track(context->track);
        context->track = NULL;
    }
    if (context->renderer != NULL) {
        ass_renderer_done(context->renderer);
        context->renderer = NULL;
    }
    if (context->library != NULL) {
        ass_library_done(context->library);
        context->library = NULL;
    }
}

SPASSContext *sp_ass_context_create(int width,
                                    int height,
                                    const char *fonts_dir,
                                    const char *default_family,
                                    int use_default_provider) {
    if (width <= 0 || height <= 0) {
        return NULL;
    }

    SPASSContext *context = (SPASSContext *)calloc(1, sizeof(SPASSContext));
    if (context == NULL) {
        return NULL;
    }

    context->width = width;
    context->height = height;
    context->library = ass_library_init();
    if (context->library == NULL) {
        free(context);
        return NULL;
    }

    ass_set_message_cb(context->library, sp_ass_message_callback, NULL);
    ass_set_extract_fonts(context->library, 1);
    if (fonts_dir != NULL && fonts_dir[0] != '\0') {
        ass_set_fonts_dir(context->library, fonts_dir);
    }

    context->renderer = ass_renderer_init(context->library);
    context->track = ass_new_track(context->library);
    if (context->renderer == NULL || context->track == NULL) {
        sp_ass_context_destroy_members(context);
        free(context);
        return NULL;
    }

    ass_set_frame_size(context->renderer, width, height);
    ass_set_storage_size(context->renderer, width, height);
    ass_set_pixel_aspect(context->renderer, 1.0);
    ass_set_shaper(context->renderer, 1);
    ass_set_fonts(context->renderer, NULL, default_family, use_default_provider, NULL, 1);
    ass_set_check_readorder(context->track, 1);
    return context;
}

void sp_ass_context_free(SPASSContext *context) {
    if (context == NULL) {
        return;
    }
    sp_ass_context_destroy_members(context);
    free(context);
}

int sp_ass_context_process_header(SPASSContext *context, const uint8_t *data, int size) {
    if (context == NULL || context->track == NULL) {
        return -EINVAL;
    }
    if (data == NULL || size <= 0) {
        return 0;
    }
    ass_process_codec_private(context->track, (const char *)data, size);
    return 0;
}

int sp_ass_context_process_chunk(SPASSContext *context,
                                 const char *data,
                                 int size,
                                 int64_t time_ms,
                                 int64_t duration_ms) {
    if (context == NULL || context->track == NULL || data == NULL || size <= 0) {
        return -EINVAL;
    }
    if (duration_ms <= 0) {
        return 0;
    }
    if (time_ms < 0) {
        time_ms = 0;
    }
    ass_process_chunk(context->track, data, size, (long long)time_ms, (long long)duration_ms);
    return 0;
}

static void sp_ass_blend_image(uint8_t *rgba,
                               int output_width,
                               int output_height,
                               int output_stride,
                               const ASS_Image *image) {
    if (rgba == NULL || image == NULL || image->bitmap == NULL || image->w <= 0 || image->h <= 0) {
        return;
    }

    int src_x = 0;
    int src_y = 0;
    int dst_x = image->dst_x;
    int dst_y = image->dst_y;
    int width = image->w;
    int height = image->h;

    if (dst_x < 0) {
        src_x = -dst_x;
        width += dst_x;
        dst_x = 0;
    }
    if (dst_y < 0) {
        src_y = -dst_y;
        height += dst_y;
        dst_y = 0;
    }
    if (dst_x + width > output_width) {
        width = output_width - dst_x;
    }
    if (dst_y + height > output_height) {
        height = output_height - dst_y;
    }
    if (width <= 0 || height <= 0) {
        return;
    }

    const uint8_t source_red = (uint8_t)((image->color >> 24) & 0xff);
    const uint8_t source_green = (uint8_t)((image->color >> 16) & 0xff);
    const uint8_t source_blue = (uint8_t)((image->color >> 8) & 0xff);
    const uint8_t source_alpha = (uint8_t)(255 - (image->color & 0xff));

    for (int y = 0; y < height; y++) {
        const uint8_t *source_row = image->bitmap + (src_y + y) * image->stride + src_x;
        uint8_t *destination_row = rgba + (dst_y + y) * output_stride + dst_x * 4;
        for (int x = 0; x < width; x++) {
            const int coverage = source_row[x];
            if (coverage == 0) {
                continue;
            }

            const int src_a = (coverage * source_alpha + 127) / 255;
            if (src_a <= 0) {
                continue;
            }

            uint8_t *destination = destination_row + x * 4;
            const int dst_a = destination[3];
            const int inv_a = 255 - src_a;
            const int out_a = src_a + (dst_a * inv_a + 127) / 255;
            if (out_a <= 0) {
                destination[0] = 0;
                destination[1] = 0;
                destination[2] = 0;
                destination[3] = 0;
                continue;
            }

            const int dst_factor = (dst_a * inv_a + 127) / 255;
            destination[0] = (uint8_t)((source_red * src_a + destination[0] * dst_factor + out_a / 2) / out_a);
            destination[1] = (uint8_t)((source_green * src_a + destination[1] * dst_factor + out_a / 2) / out_a);
            destination[2] = (uint8_t)((source_blue * src_a + destination[2] * dst_factor + out_a / 2) / out_a);
            destination[3] = (uint8_t)out_a;
        }
    }
}

int sp_ass_context_render_rgba(SPASSContext *context,
                               int64_t time_ms,
                               uint8_t *rgba,
                               int width,
                               int height,
                               int stride,
                               int *change) {
    if (context == NULL || context->renderer == NULL || context->track == NULL || rgba == NULL) {
        return -EINVAL;
    }
    if (width <= 0 || height <= 0 || stride < width * 4) {
        return -EINVAL;
    }

    memset(rgba, 0, (size_t)stride * (size_t)height);
    if (time_ms < 0) {
        time_ms = 0;
    }

    int local_change = 0;
    ASS_Image *image = ass_render_frame(context->renderer, context->track, (long long)time_ms, &local_change);
    if (change != NULL) {
        *change = local_change;
    }

    int did_draw = 0;
    for (ASS_Image *current = image; current != NULL; current = current->next) {
        if (current->bitmap != NULL && current->w > 0 && current->h > 0) {
            sp_ass_blend_image(rgba, width, height, stride, current);
            did_draw = 1;
        }
    }
    return did_draw;
}

void sp_ass_context_flush_events(SPASSContext *context) {
    if (context == NULL || context->track == NULL) {
        return;
    }
    ass_flush_events(context->track);
}
