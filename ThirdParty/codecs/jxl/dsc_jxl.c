// JPEG XL Codec für DropShelf (ABI Version 1, siehe ../dummy/README.md).
// Eingabe PNG/JPEG (stb_image, ohne Apple-Frameworks), Ausgabe .jxl (libjxl).
#include <jxl/encode.h>
#include <jxl/thread_parallel_runner.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#include "stb_image.h"

#define EXPORT __attribute__((visibility("default")))

// Qualität: Distance 1.0 (visuell nahezu verlustfrei, etwa JPEG-Qualität 90), Effort 5.
#define DSC_DISTANCE 1.0f
#define DSC_EFFORT 5

EXPORT int32_t dsc_api_version(void) { return 1; }

// Rückgabe: 0 Erfolg, 1 src nicht lesbar/dekodierbar, 2 dst nicht schreibbar,
// 3 Schreibfehler, 4 Encoder-Fehler, 5 Zielformat nicht unterstützt.
EXPORT int32_t dsc_convert(const char *src, const char *dst, const char *targetExt) {
    if (!src || !dst || !targetExt || strcasecmp(targetExt, "jxl") != 0) return 5;

    int w, h, n;
    unsigned char *px = stbi_load(src, &w, &h, &n, 0);
    if (!px) return 1;

    int32_t rc = 4;
    uint8_t *out = NULL;
    size_t cap = 1 << 20, len = 0;
    void *runner = JxlThreadParallelRunnerCreate(NULL, JxlThreadParallelRunnerDefaultNumWorkerThreads());
    JxlEncoder *enc = JxlEncoderCreate(NULL);
    if (!enc || !runner) goto done;
    if (JxlEncoderSetParallelRunner(enc, JxlThreadParallelRunner, runner) != JXL_ENC_SUCCESS) goto done;

    JxlBasicInfo info;
    JxlEncoderInitBasicInfo(&info);
    info.xsize = (uint32_t)w;
    info.ysize = (uint32_t)h;
    info.bits_per_sample = 8;
    info.num_color_channels = (n <= 2) ? 1 : 3;
    info.num_extra_channels = (n == 2 || n == 4) ? 1 : 0;
    info.alpha_bits = info.num_extra_channels ? 8 : 0;
    info.uses_original_profile = JXL_FALSE;
    if (JxlEncoderSetBasicInfo(enc, &info) != JXL_ENC_SUCCESS) goto done;

    JxlColorEncoding ce;
    JxlColorEncodingSetToSRGB(&ce, info.num_color_channels == 1);
    if (JxlEncoderSetColorEncoding(enc, &ce) != JXL_ENC_SUCCESS) goto done;

    JxlEncoderFrameSettings *fs = JxlEncoderFrameSettingsCreate(enc, NULL);
    JxlEncoderSetFrameDistance(fs, DSC_DISTANCE);
    JxlEncoderFrameSettingsSetOption(fs, JXL_ENC_FRAME_SETTING_EFFORT, DSC_EFFORT);
    JxlPixelFormat pf = {(uint32_t)n, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
    if (JxlEncoderAddImageFrame(fs, &pf, px, (size_t)w * h * n) != JXL_ENC_SUCCESS) goto done;
    JxlEncoderCloseInput(enc);

    out = malloc(cap);
    if (!out) goto done;
    JxlEncoderStatus st;
    do {
        uint8_t *next = out + len;
        size_t avail = cap - len;
        st = JxlEncoderProcessOutput(enc, &next, &avail);
        len = (size_t)(next - out);
        if (st == JXL_ENC_NEED_MORE_OUTPUT) {
            cap *= 2;
            uint8_t *p = realloc(out, cap);
            if (!p) goto done;
            out = p;
        }
    } while (st == JXL_ENC_NEED_MORE_OUTPUT);
    if (st != JXL_ENC_SUCCESS) goto done;

    FILE *f = fopen(dst, "wb");
    if (!f) { rc = 2; goto done; }
    rc = (fwrite(out, 1, len, f) == len) ? 0 : 3;
    if (fclose(f) != 0 && rc == 0) rc = 3;

done:
    free(out);
    if (enc) JxlEncoderDestroy(enc);
    if (runner) JxlThreadParallelRunnerDestroy(runner);
    stbi_image_free(px);
    return rc;
}
