// AV1-Codec für DropShelf (ABI Version 1, siehe ../dummy/README.md).
// Eingabe .y4m (YUV4MPEG2, 4:2:0), Ausgabe .webm mit AV1 (libaom), nur Video.
// Ohne Apple-Frameworks. Der Matroska/WebM-Muxer steht in dieser Datei (eigener Code, Lizenz wie das Repo).
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <aom/aom_encoder.h>
#include <aom/aomcx.h>

#define EXPORT __attribute__((visibility("default")))

// Qualität: konstante Qualität (AOM_Q) mit CQ-Level 32 (0 bis 63, kleiner = besser), cpu-used 6 (0 langsamst bis 8 schnellst),
// Keyframe höchstens alle 128 Bilder. Nur Video.
#define DSC_CQ 32
#define DSC_CPUUSED 6
#define DSC_MAX_DIM 16384

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


// Liest Profil, Level und Tier aus dem Sequence-Header-OBU (für av1C). Ohne timing_info; sonst Level 31 (maximale Parameter).
static void seq_info(const uint8_t *o, size_t n, int *profile, int *level, int *tier) {
    *profile = 0; *level = 31; *tier = 0;
    if (n < 3) return;
    size_t i = 1 + ((o[0] >> 2) & 1); // Header, optional Extension
    while (i < n && (o[i] & 0x80)) i++;
    i++; // letztes leb128-Byte
    if (i + 4 > n) return;
    const uint8_t *p = o + i; // profile(3) still(1) reduced(1) timing(1) delay(1) ops-1(5) idc(12) level(5) [tier(1)]
    *profile = p[0] >> 5;
    if (p[0] & 0x08) { *level = ((p[0] & 7) << 2) | (p[1] >> 6); return; } // reduced_still_picture_header
    if (p[0] & 0x04) return;
    *level = (p[3] >> 3) & 31;
    if (*level > 7) *tier = (p[3] >> 2) & 1;
}

EXPORT int32_t dsc_api_version(void) { return 1; }

// Rückgabe: 0 Erfolg, 1 src nicht lesbar/kein gültiges y4m, 2 dst nicht schreibbar,
// 3 Schreibfehler, 4 Encoder-Fehler, 5 Zielformat nicht unterstützt (nur "webm" und "mkv", beides schreibt dieselbe WebM-Datei).
EXPORT int32_t dsc_convert(const char *src, const char *dst, const char *targetExt) {
    if (!src || !dst || !targetExt || (strcasecmp(targetExt, "webm") != 0 && strcasecmp(targetExt, "mkv") != 0)) return 5;
    FILE *in = fopen(src, "rb");
    if (!in) return 1;

    int32_t rc = 4;
    PktList pk = {0};
    Buf out = {0};
    aom_image_t *img = NULL;
    aom_codec_ctx_t codec; int codec_ok = 0;
    aom_fixed_buf_t *gh = NULL;
    FILE *f = NULL;

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

    img = aom_img_alloc(NULL, AOM_IMG_FMT_I420, (unsigned)w, (unsigned)h, 1);
    if (!img) goto done;
    int cw = (w + 1) / 2, ch = (h + 1) / 2;

    aom_codec_iface_t *iface = aom_codec_av1_cx();
    aom_codec_enc_cfg_t cfg;
    if (aom_codec_enc_config_default(iface, &cfg, AOM_USAGE_GOOD_QUALITY) != AOM_CODEC_OK) goto done;
    cfg.g_w = (unsigned)w; cfg.g_h = (unsigned)h;
    cfg.g_timebase.num = fd; cfg.g_timebase.den = fn; // pts = Bildnummer
    cfg.rc_end_usage = AOM_Q;
    cfg.rc_min_quantizer = 0; cfg.rc_max_quantizer = 63;
    cfg.kf_max_dist = 128;
    cfg.g_threads = 4;
    if (aom_codec_enc_init(&codec, iface, &cfg, 0) != AOM_CODEC_OK) goto done;
    codec_ok = 1;
    aom_codec_control(&codec, AOME_SET_CQ_LEVEL, DSC_CQ);
    aom_codec_control(&codec, AOME_SET_CPUUSED, DSC_CPUUSED);

    int64_t nframes = 0;
    #define DRAIN() do { aom_codec_iter_t it = NULL; const aom_codec_cx_pkt_t *p; \
        while ((p = aom_codec_get_cx_data(&codec, &it)) != NULL) if (p->kind == AOM_CODEC_CX_FRAME_PKT) { \
            const uint8_t *d = p->data.frame.buf; size_t n = p->data.frame.sz; \
            if (n >= 2 && d[0] == 0x12 && d[1] == 0x00) { d += 2; n -= 2; } /* Temporal Delimiter weglassen (Matroska) */ \
            int64_t ms = (int64_t)((double)p->data.frame.pts * 1000.0 * fd / fn + 0.5); \
            if (!pkt_add(&pk, ms, 1, (p->data.frame.flags & AOM_FRAME_IS_KEY) != 0, d, n)) goto done; } } while (0)

    for (;;) {
        if (!read_line(in, line, sizeof line)) break;
        if (strncmp(line, "FRAME", 5) != 0) break;
        if (!read_plane(in, img->planes[0], img->stride[0], w, h) ||
            !read_plane(in, img->planes[1], img->stride[1], cw, ch) ||
            !read_plane(in, img->planes[2], img->stride[2], cw, ch)) break; // abgeschnittenes letztes Bild wird verworfen
        if (aom_codec_encode(&codec, img, nframes, 1, 0) != AOM_CODEC_OK) goto done;
        nframes++;
        DRAIN();
    }
    if (nframes == 0) { rc = 1; goto done; }
    for (size_t before = (size_t)-1; before != pk.n;) { // flush: wiederholen, bis kein Paket mehr kommt (Lookahead-Puffer)
        before = pk.n;
        if (aom_codec_encode(&codec, NULL, 0, 1, 0) != AOM_CODEC_OK) goto done;
        DRAIN();
    }
    if (pk.n == 0) goto done;

    gh = aom_codec_get_global_headers(&codec);
    if (!gh || !gh->buf || gh->sz < 3) goto done;
    int64_t dur_ms = (int64_t)((double)nframes * 1000.0 * fd / fn + 0.5);
    qsort(pk.a, pk.n, sizeof(Pkt), pkt_cmp);

    // ---- Muxen ----
    Buf hd = {0};
    put_uint(&hd, 0x4286, 1); put_uint(&hd, 0x42F7, 1); put_uint(&hd, 0x42F2, 4); put_uint(&hd, 0x42F3, 8);
    put_str(&hd, 0x4282, "webm"); put_uint(&hd, 0x4287, 4); put_uint(&hd, 0x4285, 2);
    put_master(&out, 0x1A45DFA3, &hd);

    Buf seg = {0};
    Buf info = {0};
    put_uint(&info, 0x2AD7B1, 1000000); put_float(&info, 0x4489, (double)dur_ms);
    put_str(&info, 0x4D80, "dsc_av1"); put_str(&info, 0x5741, "dsc_av1");
    put_master(&seg, 0x1549A966, &info);

    // av1C (4 Bytes) + Sequence-Header-OBU als CodecPrivate
    int prof, lvl, tier;
    seq_info(gh->buf, gh->sz, &prof, &lvl, &tier);
    Buf priv = {0};
    bbyte(&priv, 0x81); bbyte(&priv, (uint8_t)((prof << 5) | lvl)); bbyte(&priv, (uint8_t)((tier << 7) | 0x0C)); bbyte(&priv, 0);
    bput(&priv, gh->buf, gh->sz);

    Buf tracks = {0};
    Buf tv = {0}, vid = {0};
    put_uint(&tv, 0xD7, 1); put_uint(&tv, 0x73C5, 1); put_uint(&tv, 0x83, 1); put_uint(&tv, 0x9C, 0);
    put_str(&tv, 0x86, "V_AV1");
    put_elem(&tv, 0x63A2, priv.p, priv.len);
    if (priv.fail) tv.fail = 1;
    free(priv.p);
    put_uint(&vid, 0xB0, (uint64_t)w); put_uint(&vid, 0xBA, (uint64_t)h);
    put_master(&tv, 0xE0, &vid);
    put_master(&tracks, 0xAE, &tv);
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
    if (gh) { free(gh->buf); free(gh); }
    if (codec_ok) aom_codec_destroy(&codec);
    if (img) aom_img_free(img);
    fclose(in);
    return rc;
}
