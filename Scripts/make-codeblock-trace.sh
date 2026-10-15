#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$root/.reference/openjpeg" "$work/openjpeg"
python3 -I - "$work/openjpeg/src/lib/openjp2/t1.c" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
s = path.read_text()
needle = '''    /* Restore original t1->data is needed */
    if (cblk->decoded_data) {'''
replacement = '''    /* Pre-dequantisation, signed Int32 values. Row-major, full block. */
    {
        static int count = 0;
        if (getenv("JP2K_TRACE_ALL") != NULL || count < 4) {
            OPJ_UINT32 ix, total = t1->w * t1->h;
            fprintf(stderr, "BLOCK %d %d %d %d %u %u %u", count,
                    cblk->x0, cblk->y0, cblk->x1, cblk->y1, orient, cblk->numbps);
            for (ix = 0; ix < total; ++ix) fprintf(stderr, " %d", t1->data[ix]);
            fprintf(stderr, "\\n");
            ++count;
        }
    }
    /* Restore original t1->data is needed */
    if (cblk->decoded_data) {'''
assert needle in s
path.write_text('#include <stdio.h>\n' + s.replace(needle, replacement, 1))
PY
cmake -S "$work/openjpeg" -B "$work/build" -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=OFF > "$work/cmake.log"
cmake --build "$work/build" -j 4 > "$work/build.log"
cat > "$work/trace.c" <<'C'
#include <openjpeg.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    opj_dparameters_t p;
    opj_stream_t *s;
    opj_codec_t *c;
    opj_image_t *image = NULL;
    int ok;
    if (argc != 2) return 2;
    opj_set_default_decoder_parameters(&p);
    s = opj_stream_create_default_file_stream(argv[1], OPJ_TRUE);
    if (!s) return 3;
    c = opj_create_decompress(strstr(argv[1], ".jp2") ? OPJ_CODEC_JP2 : OPJ_CODEC_J2K);
    if (!c) return 4;
    ok = opj_setup_decoder(c, &p) && opj_read_header(s, c, &image)
      && opj_decode(c, s, image) && opj_end_decompress(c, s);
    opj_image_destroy(image);
    opj_destroy_codec(c);
    opj_stream_destroy(s);
    return ok ? 0 : 5;
}
C
lib="$(find "$work/build" -name libopenjp2.a -print -quit)"
config="$(find "$work/build" -name opj_config.h -print -quit)"
cc -I "$work/openjpeg/src/lib/openjp2" -I "$(dirname "$config")" "$work/trace.c" "$lib" -lm -lz -lpthread -o "$work/trace"
for name in gray-378x472-53.j2k gray-378x472-97.jp2 rgb-64-53-mct.jp2 rgb-64-97.jp2; do
    "$work/trace" "$root/Tests/JP2KTests/Fixtures/$name" 2> "$work/output.txt"
    grep '^BLOCK ' "$work/output.txt" > "$root/Tests/JP2KTests/Fixtures/codeblock-${name%.*}.txt"
done
JP2K_TRACE_ALL=1 "$work/trace" "$root/Tests/JP2KTests/Fixtures/cblk-8x8.j2k" 2> "$work/output.txt"
grep '^BLOCK ' "$work/output.txt" > "$root/Tests/JP2KTests/Fixtures/codeblock-cblk-8x8.txt"
