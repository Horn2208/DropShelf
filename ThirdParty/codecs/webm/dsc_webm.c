// WebM-Codec für DropShelf (ABI Version 1, siehe ../dummy/README.md).
// Eingabe .y4m (YUV4MPEG2, 4:2:0), Ausgabe .webm mit VP9 (libvpx) und Opus (libopus, Stille).
// Ohne Apple-Frameworks. Der Matroska/WebM-Muxer steht in dieser Datei (eigener Code, Lizenz wie das Repo).
#include <math.h>
#include <opus.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vpx/vp8cx.h>
#include <vpx/vpx_encoder.h>

#define EXPORT __attribute__((visibility("default")))

// Qualität: konstante Qualität (VPX_Q) mit CQ-Level 35 (0 bis 63, kleiner = besser), Speed cpu-used 4,
// Keyframe höchstens alle 128 Bilder. Audio: Opus 48 kHz Stereo, 96 kbit/s, Stille.
#define DSC_CQ 35
#define DSC_CPUUSED 4
#define DSC_MAX_DIM 16384
#define OPUS_FRAME 960 // 20 ms bei 48 kHz

// ---- wachsender Puffer ----
typedef struct { uint8_t *p; size_t len, cap; int fail; } Buf;
static void bput(Buf *b, const void *d, size_t n) {
    if (b->fail) return;
    if (b->len + n > b->cap) {
        size_t c = b->cap ? b->cap * 2 : 4096;
        while (c < b->len + n) c *= 2;
        uint8_t *q = realloc(b->p, c);
        if (!q) { b->fail = 1; return; }
        b->p = q; b->cap = c;
    }
    if (n) memcpy(b->p + b->len, d, n);
    b->len += n;
}
static void bbyte(Buf *b, uint8_t v) { bput(b, &v, 1); }

// ---- EBML ----
static void put_id(Buf *b, uint32_t id) {
    int n = id > 0xFFFFFF ? 4 : id > 0xFFFF ? 3 : id > 0xFF ? 2 : 1;
    for (int i = n - 1; i >= 0; i--) bbyte(b, (uint8_t)(id >> (8 * i)));
}
static void put_size(Buf *b, uint64_t s) { // vint, kürzeste Länge
    int n = 1;
    while (n < 8 && s >= ((uint64_t)1 << (7 * n)) - 1) n++;
    uint64_t v = s | ((uint64_t)1 << (7 * n));
    for (int i = n - 1; i >= 0; i--) bbyte(b, (uint8_t)(v >> (8 * i)));
}
static void put_elem(Buf *b, uint32_t id, const void *d, size_t n) { put_id(b, id); put_size(b, n); bput(b, d, n); }
static void put_uint(Buf *b, uint32_t id, uint64_t v) {
    uint8_t t[8]; int n = 1;
    while (n < 8 && (v >> (8 * n))) n++;
    for (int i = 0; i < n; i++) t[i] = (uint8_t)(v >> (8 * (n - 1 - i)));
    put_elem(b, id, t, n);
}
static void put_float(Buf *b, uint32_t id, double d) {
    uint64_t u; memcpy(&u, &d, 8);
    uint8_t t[8];
    for (int i = 0; i < 8; i++) t[i] = (uint8_t)(u >> (8 * (7 - i)));
    put_elem(b, id, t, 8);
}
static void put_str(Buf *b, uint32_t id, const char *s) { put_elem(b, id, s, strlen(s)); }
static void put_master(Buf *b, uint32_t id, Buf *child) { put_elem(b, id, child->p, child->len); if (child->fail) b->fail = 1; free(child->p); }

// ---- Pakete ----
typedef struct { int64_t ts; int track, key; uint8_t *d; size_t n; } Pkt;
typedef struct { Pkt *a; size_t n, cap; } PktList;
static int pkt_add(PktList *l, int64_t ts, int track, int key, const void *d, size_t n) {
    if (l->n == l->cap) {
        size_t c = l->cap ? l->cap * 2 : 256;
        Pkt *q = realloc(l->a, c * sizeof(Pkt));
        if (!q) return 0;
        l->a = q; l->cap = c;
    }
    uint8_t *cp = malloc(n ? n : 1);
    if (!cp) return 0;
    memcpy(cp, d, n);
    l->a[l->n++] = (Pkt){ts, track, key, cp, n};
    return 1;
}
static int pkt_cmp(const void *x, const void *y) {
    const Pkt *a = x, *b = y;
    if (a->ts != b->ts) return a->ts < b->ts ? -1 : 1;
    return a->track - b->track;
}

// ---- Y4M ----
// Liest eine Zeile (ohne \n) bis max. n-1 Zeichen. 0 bei Dateiende oder zu langer Zeile.
static int read_line(FILE *f, char *s, size_t n) {
    if (!fgets(s, (int)n, f)) return 0;
    size_t l = strlen(s);
    if (l == 0 || s[l - 1] != '\n') return 0;
    s[l - 1] = 0;
    return 1;
}
// Liest ein Planar-Bild (I420) in img-Puffer. Rückgabe 1 ok.
static int read_plane(FILE *f, uint8_t *dst, int stride, int w, int h) {
    for (int y = 0; y < h; y++)
        if (fread(dst + (size_t)y * stride, 1, (size_t)w, f) != (size_t)w) return 0;
    return 1;
}

EXPORT int32_t dsc_api_version(void) { return 1; }

// Rückgabe: 0 Erfolg, 1 src nicht lesbar/kein gültiges y4m, 2 dst nicht schreibbar,
// 3 Schreibfehler, 4 Encoder-Fehler, 5 Zielformat nicht unterstützt (nur "webm").
EXPORT int32_t dsc_convert(const char *src, const char *dst, const char *targetExt) {
    if (!src || !dst || !targetExt || strcasecmp(targetExt, "webm") != 0) return 5;
    FILE *in = fopen(src, "rb");
    if (!in) return 1;

    int32_t rc = 4;
    PktList pk = {0};
    Buf out = {0};
    vpx_image_t img; int img_ok = 0;
    vpx_codec_ctx_t codec; int codec_ok = 0;
    OpusEncoder *oe = NULL;
    FILE *f = NULL;

    // Header
    char line[1024];
    if (!read_line(in, line, sizeof line) || strncmp(line, "YUV4MPEG2", 9) != 0) { rc = 1; goto done; }
    int w = 0, h = 0, fn = 30, fd = 1, c420 = 1;
    for (char *t = strtok(line + 9, " "); t; t = strtok(NULL, " ")) {
        if (t[0] == 'W') w = atoi(t + 1);
        else if (t[0] == 'H') h = atoi(t + 1);
        else if (t[0] == 'F') { int a, b; if (sscanf(t + 1, "%d:%d", &a, &b) == 2 && a > 0 && b > 0) { fn = a; fd = b; } }
        else if (t[0] == 'C') c420 = strncmp(t + 1, "420", 3) == 0 && strcmp(t + 1, "420p10") != 0 && strcmp(t + 1, "420p12") != 0;
    }
    if (w <= 0 || h <= 0 || w > DSC_MAX_DIM || h > DSC_MAX_DIM || !c420) { rc = 1; goto done; }

    if (vpx_img_alloc(&img, VPX_IMG_FMT_I420, (unsigned)w, (unsigned)h, 1) == NULL) goto done;
    img_ok = 1;
    int cw = (w + 1) / 2, ch = (h + 1) / 2;

    vpx_codec_enc_cfg_t cfg;
    if (vpx_codec_enc_config_default(vpx_codec_vp9_cx(), &cfg, 0) != VPX_CODEC_OK) goto done;
    cfg.g_w = (unsigned)w; cfg.g_h = (unsigned)h;
    cfg.g_timebase.num = fd; cfg.g_timebase.den = fn; // pts = Bildnummer
    cfg.rc_end_usage = VPX_Q;
    cfg.rc_min_quantizer = 0; cfg.rc_max_quantizer = 63;
    cfg.kf_max_dist = 128;
    cfg.g_threads = 4;
    if (vpx_codec_enc_init(&codec, vpx_codec_vp9_cx(), &cfg, 0) != VPX_CODEC_OK) goto done;
    codec_ok = 1;
    vpx_codec_control(&codec, VP8E_SET_CQ_LEVEL, DSC_CQ);
    vpx_codec_control(&codec, VP8E_SET_CPUUSED, DSC_CPUUSED);

    int64_t nframes = 0;
    #define DRAIN() do { vpx_codec_iter_t it = NULL; const vpx_codec_cx_pkt_t *p; \
        while ((p = vpx_codec_get_cx_data(&codec, &it)) != NULL) if (p->kind == VPX_CODEC_CX_FRAME_PKT) { \
            int64_t ms = (int64_t)((double)p->data.frame.pts * 1000.0 * fd / fn + 0.5); \
            if (!pkt_add(&pk, ms, 1, (p->data.frame.flags & VPX_FRAME_IS_KEY) != 0, p->data.frame.buf, p->data.frame.sz)) goto done; } } while (0)

    for (;;) {
        if (!read_line(in, line, sizeof line)) break;
        if (strncmp(line, "FRAME", 5) != 0) break;
        if (!read_plane(in, img.planes[0], img.stride[0], w, h) ||
            !read_plane(in, img.planes[1], img.stride[1], cw, ch) ||
            !read_plane(in, img.planes[2], img.stride[2], cw, ch)) break; // abgeschnittenes letztes Bild wird verworfen
        if (vpx_codec_encode(&codec, &img, nframes, 1, 0, VPX_DL_GOOD_QUALITY) != VPX_CODEC_OK) goto done;
        nframes++;
        DRAIN();
    }
    if (nframes == 0) { rc = 1; goto done; }
    if (vpx_codec_encode(&codec, NULL, -1, 1, 0, VPX_DL_GOOD_QUALITY) != VPX_CODEC_OK) goto done; // flush
    DRAIN();

    // Audio: Stille über die Videolänge
    int64_t dur_ms = (int64_t)((double)nframes * 1000.0 * fd / fn + 0.5);
    int err = 0;
    oe = opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, &err);
    if (!oe || err != OPUS_OK) goto done;
    opus_encoder_ctl(oe, OPUS_SET_BITRATE(96000));
    opus_int32 lookahead = 0;
    opus_encoder_ctl(oe, OPUS_GET_LOOKAHEAD(&lookahead));
    static const opus_int16 silence[OPUS_FRAME * 2];
    uint8_t ob[1500];
    int64_t na = (dur_ms + 19) / 20;
    for (int64_t i = 0; i < na; i++) {
        opus_int32 n = opus_encode(oe, silence, OPUS_FRAME, ob, sizeof ob);
        if (n < 0) goto done;
        if (!pkt_add(&pk, i * 20, 2, 1, ob, (size_t)n)) goto done;
    }
    qsort(pk.a, pk.n, sizeof(Pkt), pkt_cmp);

    // ---- Muxen ----
    Buf hd = {0};
    put_uint(&hd, 0x4286, 1); put_uint(&hd, 0x42F7, 1); put_uint(&hd, 0x42F2, 4); put_uint(&hd, 0x42F3, 8);
    put_str(&hd, 0x4282, "webm"); put_uint(&hd, 0x4287, 4); put_uint(&hd, 0x4285, 2);
    put_master(&out, 0x1A45DFA3, &hd);

    Buf seg = {0};
    Buf info = {0};
    put_uint(&info, 0x2AD7B1, 1000000); put_float(&info, 0x4489, (double)dur_ms);
    put_str(&info, 0x4D80, "dsc_webm"); put_str(&info, 0x5741, "dsc_webm");
    put_master(&seg, 0x1549A966, &info);

    Buf tracks = {0};
    Buf tv = {0}, vid = {0};
    put_uint(&tv, 0xD7, 1); put_uint(&tv, 0x73C5, 1); put_uint(&tv, 0x83, 1); put_uint(&tv, 0x9C, 0);
    put_str(&tv, 0x86, "V_VP9");
    put_uint(&vid, 0xB0, (uint64_t)w); put_uint(&vid, 0xBA, (uint64_t)h);
    put_master(&tv, 0xE0, &vid);
    put_master(&tracks, 0xAE, &tv);
    Buf ta = {0}, aud = {0};
    uint8_t head[19] = {'O','p','u','s','H','e','a','d', 1, 2, (uint8_t)lookahead, (uint8_t)(lookahead >> 8),
                        0x80, 0xBB, 0, 0, 0, 0, 0}; // 48000 Hz little endian = 80 BB 00 00, Gain 0, Mapping 0
    put_uint(&ta, 0xD7, 2); put_uint(&ta, 0x73C5, 2); put_uint(&ta, 0x83, 2); put_uint(&ta, 0x9C, 0);
    put_str(&ta, 0x86, "A_OPUS");
    put_uint(&ta, 0x56AA, (uint64_t)lookahead * 1000000000ull / 48000ull); put_uint(&ta, 0x56BB, 80000000);
    put_elem(&ta, 0x63A2, head, sizeof head);
    put_float(&aud, 0xB5, 48000.0); put_uint(&aud, 0x9F, 2);
    put_master(&ta, 0xE1, &aud);
    put_master(&tracks, 0xAE, &ta);
    put_master(&seg, 0x1654AE6B, &tracks);

    // Cluster: neuer Cluster alle 5 s
    for (size_t i = 0; i < pk.n;) {
        int64_t base = pk.a[i].ts;
        Buf cl = {0};
        put_uint(&cl, 0xE7, (uint64_t)base);
        for (; i < pk.n && pk.a[i].ts - base < 5000; i++) {
            Pkt *p = &pk.a[i];
            Buf sb = {0};
            bbyte(&sb, (uint8_t)(0x80 | p->track));
            int16_t rel = (int16_t)(p->ts - base);
            bbyte(&sb, (uint8_t)(rel >> 8)); bbyte(&sb, (uint8_t)rel);
            bbyte(&sb, p->key ? 0x80 : 0x00);
            bput(&sb, p->d, p->n);
            put_elem(&cl, 0xA3, sb.p, sb.len);
            if (sb.fail) cl.fail = 1;
            free(sb.p);
        }
        put_master(&seg, 0x1F43B675, &cl);
    }
    put_master(&out, 0x18538067, &seg);
    if (out.fail) goto done;

    f = fopen(dst, "wb");
    if (!f) { rc = 2; goto done; }
    rc = (fwrite(out.p, 1, out.len, f) == out.len) ? 0 : 3;
    if (fclose(f) != 0 && rc == 0) rc = 3;
    f = NULL;

done:
    for (size_t i = 0; i < pk.n; i++) free(pk.a[i].d);
    free(pk.a); free(out.p);
    if (oe) opus_encoder_destroy(oe);
    if (codec_ok) vpx_codec_destroy(&codec);
    if (img_ok) vpx_img_free(&img);
    fclose(in);
    return rc;
}
