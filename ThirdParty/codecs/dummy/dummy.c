#include <stdint.h>
#include <stdio.h>

int32_t dsc_api_version(void) { return 1; }

// Test-Codec: kopiert src nach dst, targetExt wird ignoriert.
int32_t dsc_convert(const char *src, const char *dst, const char *targetExt) {
    (void)targetExt;
    FILE *in = fopen(src, "rb");
    if (!in) return 1;
    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); return 2; }
    char buf[65536];
    size_t n;
    int32_t rc = 0;
    while ((n = fread(buf, 1, sizeof buf, in)) > 0)
        if (fwrite(buf, 1, n, out) != n) { rc = 3; break; }
    fclose(in);
    if (fclose(out) != 0 && rc == 0) rc = 3;
    return rc;
}
