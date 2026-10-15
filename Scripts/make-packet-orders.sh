#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$root/.reference/openjpeg" "$work/openjpeg"

# Instrument the decode loop only. The three opj_pi_next() loops in t2.c
# include encoding paths; this replacement selects the final, decode loop.
python3 -I - "$work/openjpeg/src/lib/openjp2/t2.c" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
needle = 'while (opj_pi_next(l_current_pi)) {'
assert source.count(needle) == 3
at = source.rfind(needle)
source = source[:at] + source[at:].replace(
    needle,
    needle + '\n            fprintf(stdout, "%u %u %u %u\\n", '
    'l_current_pi->layno, l_current_pi->resno, '
    'l_current_pi->compno, l_current_pi->precno);', 1)
path.write_text('#include <stdio.h>\n' + source)
PY

cmake -S "$work/openjpeg" -B "$work/build" \
  -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=OFF \
  > "$work/cmake.log"
cmake --build "$work/build" -j 4 > "$work/build.log"

cat > "$work/packet-orders.c" <<'C'
#include <openjpeg.h>
#include <stdio.h>

int main(int argc, char **argv) {
    opj_dparameters_t parameters;
    opj_stream_t *stream;
    opj_codec_t *codec;
    opj_image_t *image = NULL;
    int ok;
    if (argc != 2) return 2;
    opj_set_default_decoder_parameters(&parameters);
    stream = opj_stream_create_default_file_stream(argv[1], OPJ_TRUE);
    if (!stream) return 3;
    codec = opj_create_decompress(OPJ_CODEC_J2K);
    if (!codec) { opj_stream_destroy(stream); return 4; }
    ok = opj_setup_decoder(codec, &parameters) &&
         opj_read_header(stream, codec, &image) &&
         opj_decode(codec, stream, image) &&
         opj_end_decompress(codec, stream);
    opj_image_destroy(image);
    opj_destroy_codec(codec);
    opj_stream_destroy(stream);
    return ok ? 0 : 5;
}
C

lib="$(find "$work/build" -name libopenjp2.a -print -quit)"
if [[ -z "$lib" ]]; then echo 'OpenJPEG build produced no static library' >&2; exit 1; fi
config="$(find "$work/build" -name opj_config.h -print -quit)"
if [[ -z "$config" ]]; then echo 'OpenJPEG build produced no config header' >&2; exit 1; fi
cc -I "$work/openjpeg/src/lib/openjp2" -I "$(dirname "$config")" \
  "$work/packet-orders.c" "$lib" \
  -lm -lz -lpthread -o "$work/packet-orders"

fixtures="$root/Tests/JP2KTests/Fixtures"
for name in prog-lrcp prog-rlcp prog-rpcl prog-pcrl prog-cprl poc; do
  "$work/packet-orders" "$fixtures/$name.j2k" > "$fixtures/packet-order-$name.txt"
done

compress="${OPJ_COMPRESS:-$(command -v opj_compress || true)}"
if [[ -z "$compress" || "$($compress -h 2>&1 | head -n 8 || true)" != *"openjp2 library v2.5.4"* ]]; then
  echo 'OpenJPEG 2.5.4 opj_compress is required for spatial inputs' >&2
  exit 1
fi
for order in RPCL PCRL CPRL; do
  lower="${order,,}"
  "$compress" -i "$fixtures/precincts_0.pgx" -o "$work/spatial-$lower.j2k" \
    -n 5 -c '[16,16],[8,8]' -r 20,10 -p "$order" > "$work/compress-$lower.log" 2>&1
  "$work/packet-orders" "$work/spatial-$lower.j2k" > "$fixtures/packet-order-spatial-$lower.txt"
done
