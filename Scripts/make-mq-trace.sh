#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$root/.reference/openjpeg" "$work/openjpeg"
python3 -I - "$work/openjpeg/src/lib/openjp2" <<'PY'
import pathlib, sys
base = pathlib.Path(sys.argv[1])
path = base / 'mqc_inl.h'
s = path.read_text()
s = '#include <stdio.h>\nextern int opj_mq_trace_count;\n' + s
needle = '''            d = (*curctx)->mps; \\
        } \\
    } \\
}'''
replacement = '''            d = (*curctx)->mps; \\
        } \\
    } \\
    if (opj_mq_trace_count < 128) { \\
        fprintf(stderr, "S %td %u\\n", (curctx) - (mqc)->ctxs, (unsigned)(d)); \\
        opj_mq_trace_count++; \\
    } \\
}'''
assert needle in s
s = s.replace(needle, replacement, 1)
path.write_text(s)
path = base / 't1.c'
s = path.read_text()
s = '#include <stdio.h>\nint opj_mq_trace_count = 0;\n' + s
needle = '''            opj_mqc_init_dec(mqc, cblkdata + cblkdataindex, seg->len,
                             OPJ_COMMON_CBLK_DATA_EXTRA);'''
replacement = needle + '''
            if (opj_mq_trace_count == 0) {
                OPJ_UINT32 trace_i;
                fprintf(stderr, "B ");
                for (trace_i = 0; trace_i < seg->len; trace_i++)
                    fprintf(stderr, "%02x", cblkdata[cblkdataindex + trace_i]);
                fprintf(stderr, "\\n");
            }'''
assert needle in s
path.write_text(s.replace(needle, replacement, 1))
PY
cmake -S "$work/openjpeg" -B "$work/build" -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=OFF > "$work/cmake.log"
cmake --build "$work/build" -j 4 > "$work/build.log"
cat > "$work/trace.c" <<'C'
#include <openjpeg.h>
#include <stdio.h>
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
    c = opj_create_decompress(OPJ_CODEC_J2K);
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
"$work/trace" "$root/Tests/JP2KTests/Fixtures/gray-378x472-53.j2k" 2> "$work/trace.txt"
python3 -I - "$work/trace.txt" "$root/Tests/JP2KTests/Fixtures/mq-trace-gray-53.txt" <<'PY'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
block = next(line for line in lines if line.startswith('B '))
symbols = [line for line in lines if line.startswith('S ')][:128]
pathlib.Path(sys.argv[2]).write_text('# OpenJPEG v2.5.4, first MQ code-block segment; context and decoded bit\n' + block + '\n' + '\n'.join(symbols) + '\n')
PY
