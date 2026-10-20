// Thin C shim over mackron/dr_libs (dr_mp3, dr_flac, dr_wav).
//
// dr_libs is a set of single-header C libraries; this file is the one place the
// implementations are compiled. It exposes a tiny opaque API so the Zig side
// never has to mirror dr_libs' large structs (no @cImport needed).

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#define DR_MP3_IMPLEMENTATION
#include "dr_mp3.h"
#define DR_FLAC_IMPLEMENTATION
#include "dr_flac.h"
#define DR_WAV_IMPLEMENTATION
#include "dr_wav.h"

typedef enum { LM_MP3 = 1, LM_FLAC = 2, LM_WAV = 3 } lm_kind;

// Failure reasons reported by lm_open (mirrored in decoder.zig).
enum { LM_ERR_OPEN = 1, LM_ERR_OOM = 2, LM_ERR_PATH = 3 };

typedef struct lm_decoder {
    lm_kind kind;
    union {
        drmp3 mp3;
        drflac* flac;
        drwav wav;
    } u;
} lm_decoder;

static int lm_has_ext(const char* path, const char* ext) {
    size_t n = strlen(path), e = strlen(ext);
    if (n < e) return 0;
    path += n - e;
    for (size_t i = 0; i < e; i++) {
        if (tolower((unsigned char)path[i]) != ext[i]) return 0;
    }
    return 1;
}

// Opens `path` (UTF-8) by file extension. Returns NULL on failure and stores the
// reason in `*err` (LM_ERR_*). On success fills in the native channel count and
// sample rate.
lm_decoder* lm_open(const char* path, uint32_t* channels, uint32_t* sample_rate, int* err) {
    *err = LM_ERR_OPEN;
    lm_decoder* d = (lm_decoder*)calloc(1, sizeof(*d));
    if (!d) { *err = LM_ERR_OOM; return NULL; }

#ifdef _WIN32
    // fopen() on Windows takes the ANSI code page; convert UTF-8 -> UTF-16 and use
    // dr_libs' *_w entry points so non-ASCII file names work.
    int wn = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (wn <= 0) { free(d); *err = LM_ERR_PATH; return NULL; }
    wchar_t* wpath = (wchar_t*)malloc((size_t)wn * sizeof(wchar_t));
    if (!wpath) { free(d); *err = LM_ERR_OOM; return NULL; }
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wpath, wn) <= 0) {
        free(wpath); free(d); *err = LM_ERR_PATH; return NULL;
    }
#endif

    int ok = 0;
    if (lm_has_ext(path, ".mp3")) {
        d->kind = LM_MP3;
#ifdef _WIN32
        ok = drmp3_init_file_w(&d->u.mp3, wpath, NULL);
#else
        ok = drmp3_init_file(&d->u.mp3, path, NULL);
#endif
        if (ok) { *channels = d->u.mp3.channels; *sample_rate = d->u.mp3.sampleRate; }
    } else if (lm_has_ext(path, ".flac")) {
        d->kind = LM_FLAC;
#ifdef _WIN32
        d->u.flac = drflac_open_file_w(wpath, NULL);
#else
        d->u.flac = drflac_open_file(path, NULL);
#endif
        ok = d->u.flac != NULL;
        if (ok) { *channels = d->u.flac->channels; *sample_rate = d->u.flac->sampleRate; }
    } else if (lm_has_ext(path, ".wav")) {
        d->kind = LM_WAV;
#ifdef _WIN32
        ok = drwav_init_file_w(&d->u.wav, wpath, NULL);
#else
        ok = drwav_init_file(&d->u.wav, path, NULL);
#endif
        if (ok) { *channels = d->u.wav.channels; *sample_rate = d->u.wav.sampleRate; }
    }

#ifdef _WIN32
    free(wpath);
#endif
    if (!ok) { free(d); return NULL; }
    return d;
}

// Total length in frames as declared by the file header, or 0 when the format
// does not say (MP3). Lets the caller tell a truncated/corrupt file from EOF,
// because the read functions return 0 for both.
uint64_t lm_total_frames(lm_decoder* d) {
    switch (d->kind) {
        case LM_MP3:  return 0;
        case LM_FLAC: return d->u.flac->totalPCMFrameCount;
        case LM_WAV:  return d->u.wav.totalPCMFrameCount;
    }
    return 0;
}

// Reads up to `frames` interleaved float frames. Returns frames read (0 = EOF).
uint64_t lm_read_f32(lm_decoder* d, uint64_t frames, float* out) {
    switch (d->kind) {
        case LM_MP3:  return drmp3_read_pcm_frames_f32(&d->u.mp3, frames, out);
        case LM_FLAC: return drflac_read_pcm_frames_f32(d->u.flac, frames, out);
        case LM_WAV:  return drwav_read_pcm_frames_f32(&d->u.wav, frames, out);
    }
    return 0;
}

void lm_close(lm_decoder* d) {
    if (!d) return;
    switch (d->kind) {
        case LM_MP3:  drmp3_uninit(&d->u.mp3); break;
        case LM_FLAC: drflac_close(d->u.flac); break;
        case LM_WAV:  drwav_uninit(&d->u.wav); break;
    }
    free(d);
}
