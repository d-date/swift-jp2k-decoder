#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$root/.reference/openjpeg" "$work/openjpeg"

python3 -I - "$work/openjpeg/src/lib/openjp2/t2.c" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
start = source.index('static OPJ_BOOL opj_t2_read_packet_data(', source.index('static OPJ_BOOL opj_t2_read_packet_data(') + 1)
needle = '                l_seg->real_num_passes = l_seg->numpasses;'
assert source[start:].count(needle) == 1
replacement = needle + '''
                fprintf(stdout, "%u %u %u %u %u %u %u %u %u\\n",
                        p_pi->layno, p_pi->resno, p_pi->compno, p_pi->precno,
                        bandno, cblkno, l_cblk->numbps, l_seg->numnewpasses,
                        l_seg->newlen);'''
source = source[:start] + source[start:].replace(needle, replacement, 1)
path.write_text('#include <stdio.h>\n' + source)
PY

cmake -S "$work/openjpeg" -B "$work/build" \
  -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=OFF > "$work/cmake.log"
cmake --build "$work/build" -j 4 > "$work/build.log"
cat > "$work/packet-segments.c" <<'C'
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
config="$(find "$work/build" -name opj_config.h -print -quit)"
cc -I "$work/openjpeg/src/lib/openjp2" -I "$(dirname "$config")" \
  "$work/packet-segments.c" "$lib" -lm -lz -lpthread -o "$work/packet-segments"
fixtures="$root/Tests/JP2KTests/Fixtures"
for name in gray-378x472-53 sop-eph layers modes-termall modes-bypass precincts; do
  "$work/packet-segments" "$fixtures/$name.j2k" > "$fixtures/packet-segments-$name.txt"
done
conformance="$root/.reference/openjpeg-data/input/conformance"
for name in p1_02 p1_06; do
  if [[ -f "$conformance/$name.j2k" ]]; then
    "$work/packet-segments" "$conformance/$name.j2k" > "$fixtures/packet-segments-conformance-$name.txt"
  fi
done
python3 -I - "$fixtures" <<'PY'
import hashlib, pathlib, sys
fixtures = pathlib.Path(sys.argv[1])
manifest = fixtures / 'MANIFEST.sha256'
lines = [line for line in manifest.read_text().splitlines()
         if '  packet-segments-' not in line]
for path in sorted(fixtures.glob('packet-segments-*.txt')):
    lines.append(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}')
manifest.write_text('\n'.join(lines) + '\n')
PY
