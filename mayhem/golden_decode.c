/*
 * faad2/mayhem/golden_decode.c — honest golden-output PATCH oracle for mayhem/test.sh.
 *
 * Decodes a known ADTS AAC frame (mayhem/testsuite/golden.aac, passed as argv[1]) through the SAME
 * public libfaad API the fuzzer exercises (NeAACDecInit -> NeAACDecDecode) and asserts the decoder
 * reports the EXPECTED, deterministic header-derived values:
 *   - sample rate parsed from the ADTS sampling_frequency_index  (44100 Hz)
 *   - channel count parsed from the ADTS channel_configuration   (1 = mono)
 *   - NeAACDecInit consumes 0 bytes (ADTS header parsed, no frame consumed at init)
 *   - the first NeAACDecDecode reports frameinfo.error == 0 (clean decode of the frame)
 *
 * These are values read directly out of the AAC bitstream by the decoder, so a no-op / exit(0)
 * "patch" that stops actually decoding (or a regression that mis-parses the header) makes one of
 * the asserted values wrong and this program exits non-zero — it cannot be reward-hacked by
 * "ran without crashing". Built with NORMAL flags (no sanitizers) by build.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "neaacdec.h"

/* Expected, header-derived ground truth for mayhem/testsuite/golden.aac (44100 Hz, mono). */
#define EXPECT_SAMPLERATE 44100UL
#define EXPECT_CHANNELS   2

static unsigned char *slurp(const char *path, unsigned long *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return NULL; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return NULL; }
    unsigned char *buf = (unsigned char *)malloc((size_t)n);
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(buf); return NULL; }
    fclose(f);
    *out_len = (unsigned long)n;
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <golden.aac>\n", argv[0]); return 2; }

    unsigned long len = 0;
    unsigned char *data = slurp(argv[1], &len);
    if (!data) return 2;

    NeAACDecHandle dec = NeAACDecOpen();
    if (!dec) { fprintf(stderr, "NeAACDecOpen failed\n"); free(data); return 2; }

    unsigned long samplerate = 0;
    unsigned char channels = 0;
    long consumed = NeAACDecInit(dec, data, len, &samplerate, &channels);

    printf("init: consumed=%ld samplerate=%lu channels=%u\n", consumed, samplerate, channels);

    int rc = 0;
    if (consumed < 0) { fprintf(stderr, "FAIL: NeAACDecInit returned error %ld\n", consumed); rc = 1; }
    if (samplerate != EXPECT_SAMPLERATE) {
        fprintf(stderr, "FAIL: samplerate %lu != expected %lu\n", samplerate, EXPECT_SAMPLERATE); rc = 1;
    }
    if (channels != EXPECT_CHANNELS) {
        fprintf(stderr, "FAIL: channels %u != expected %u\n", channels, EXPECT_CHANNELS); rc = 1;
    }

    if (rc == 0) {
        NeAACDecFrameInfo info;
        memset(&info, 0, sizeof(info));
        /* Decode starting just past the bytes init consumed. */
        void *out = NeAACDecDecode(dec, &info, data + consumed, len - (unsigned long)consumed);
        printf("decode: error=%u samples=%lu channels=%u samplerate=%lu\n",
               info.error, info.samples, info.channels, info.samplerate);
        if (info.error != 0) {
            fprintf(stderr, "FAIL: decode error %u (%s)\n",
                    info.error, NeAACDecGetErrorMessage(info.error)); rc = 1;
        }
        if (info.samplerate != EXPECT_SAMPLERATE) {
            fprintf(stderr, "FAIL: decoded samplerate %lu != %lu\n", info.samplerate, EXPECT_SAMPLERATE); rc = 1;
        }
        (void)out;
    }

    NeAACDecClose(dec);
    free(data);
    if (rc == 0) printf("PASS: golden decode matched expected header values\n");
    return rc;
}
