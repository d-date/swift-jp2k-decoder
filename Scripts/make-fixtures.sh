#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/Tests/JP2KTests/Fixtures"
# Packet-order text references are regenerated separately with
# Scripts/make-packet-orders.sh, which instruments OpenJPEG's decoder.
compress="${OPJ_COMPRESS:-/opt/homebrew/bin/opj_compress}"
decompress="${OPJ_DECOMPRESS:-/opt/homebrew/bin/opj_decompress}"
for tool in "$compress" "$decompress"; do
  version="$($tool -h 2>&1 | head -n 8 || true)"
  if [[ "$version" != *"openjp2 library v2.5.4"* ]]; then
    echo "Expected OpenJPEG 2.5.4: $tool" >&2
    exit 1
  fi
done
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 -I - "$work" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
seed = 0x4a50324b
def noise():
    global seed
    seed = (1664525 * seed + 1013904223) & 0xffffffff
    return seed >> 24
def pixel(x, y, c, maximum):
    gradient = (x * 71 // 378 + y * 61 // 472 + c * 37) % 256
    checker = 53 if ((x // 7) ^ (y // 5)) & 1 else 0
    return ((gradient + checker + noise() // 3) * maximum // 255) & maximum
def pnm(name, w, h, components, maximum):
    data = bytearray()
    for y in range(h):
        for x in range(w):
            for c in range(components):
                v = pixel(x, y, c, maximum)
                data.extend(v.to_bytes(1 if maximum <= 255 else 2, 'big'))
    header = f'P{5 if components == 1 else 6}\n{w} {h}\n{maximum}\n'.encode()
    (root / name).write_bytes(header + data)
pnm('gray.pgm', 378, 472, 1, 255)
pnm('small.pgm', 127, 61, 1, 255)
pnm('rgb.ppm', 64, 64, 3, 255)
pnm('gray16.pgm', 40, 30, 1, 65535)
# Raw inputs need their own layouts. OpenJPEG's PGX reader derives precision
# from the positive maximum, which cannot preserve signed 12-bit precision.
raw = bytearray()
for y in range(17):
    for x in range(33):
        for c in range(4):
            raw.append((x * 7 + y * 13 + c * 41) & 255)
(root / 'rgba.raw').write_bytes(raw)
values = bytearray()
for y in range(19):
    for x in range(31):
        v = ((x * 67 + y * 103) % 4096) - 2048
        if x == 0 and y == 0:
            v = -2048
        elif x == 1 and y == 0:
            v = 2047
        values.extend((v & 0xffff).to_bytes(2, 'big'))
(root / 'signed12.raw').write_bytes(values)
PY
encode() {
  local name="$1" input="$2"
  shift 2
  "$compress" -i "$work/$input" -o "$out/$name" "$@" >/dev/null 2>&1
  "$decompress" -i "$out/$name" -o "$out/${name%.*}.pgx" >/dev/null 2>&1
}
encode gray-378x472-53.jp2 gray.pgm
encode gray-378x472-97.jp2 gray.pgm -I -r 20
encode gray-378x472-53.j2k gray.pgm
encode rgb-64-53-mct.jp2 rgb.ppm
encode rgb-64-97.jp2 rgb.ppm -I -r 20
encode rgba-33x17.jp2 rgba.raw -F 33,17,4,8,u -n 4
encode gray16-40x30.jp2 gray16.pgm -n 5
encode signed12-31x19.j2k signed12.raw -F 31,19,1,12,s -n 4
for progression in LRCP RLCP RPCL PCRL CPRL; do
  encode "prog-${progression,,}.j2k" small.pgm -p "$progression" -n 5
done
encode tiles-127x61.j2k small.pgm -t 32,16 -n 5
encode tileparts.j2k small.pgm -t 32,16 -TP R -n 5
encode poc.j2k rgb.ppm -n 5 -POC 'T1=0,0,1,3,2,CPRL/T1=3,0,1,5,3,LRCP'
encode precincts.j2k small.pgm -n 5 -c '[16,16],[8,8]'
encode cblk-8x8.j2k small.pgm -n 5 -b 8,8
encode layers.j2k small.pgm -n 5 -r 40,20,10
for entry in bypass:1 reset:2 termall:4 vcausal:8 pterm:16 segsym:32 all:63; do
  encode "modes-${entry%%:*}.j2k" small.pgm -n 5 -M "${entry##*:}"
done
encode roi.j2k small.pgm -n 5 -ROI c=0,U=4
encode subsampled.j2k small.pgm -n 5 -s 2,2
encode subsampled-rgb.j2k rgb.ppm -n 5 -s 2,2
encode sop-eph.j2k small.pgm -n 5 -SOP -EPH
encode origin.j2k small.pgm -n 5 -d 3,5 -T 1,2
encode levels-0.j2k small.pgm -n 1
encode levels-max.j2k small.pgm -n 6
(
  cd "$out"
  find . -type f ! -name MANIFEST.sha256 -print | sed 's@^./@@' | LC_ALL=C sort | xargs shasum -a 256 > MANIFEST.sha256
)
