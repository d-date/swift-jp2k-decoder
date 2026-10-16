#!/usr/bin/env python3
"""Regenerate the small malformed inputs used by CorruptCorpusTests."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIX = ROOT / "Tests/JP2KTests/Fixtures"
OUT = FIX / "corrupt"
OUT.mkdir(exist_ok=True)


def be16(value):
    return value.to_bytes(2, "big")


def be32(value):
    return value.to_bytes(4, "big")


def marker(code, payload):
    return be16(code) + be16(len(payload) + 2) + payload


raw = bytearray((FIX / "levels-0.j2k").read_bytes())
raw[8:16] = be32(60_000) + be32(60_000)
(OUT / "huge-siz.j2k").write_bytes(raw)

jp2 = bytearray((FIX / "gray16-40x30.jp2").read_bytes())
jp2[12:16] = be32(0xFFFF_FFFF)
(OUT / "huge-box.jp2").write_bytes(jp2)

def stuffed_packet_bits(values):
    out = bytearray()
    offset = 0
    while offset < len(values):
        width = 7 if out and out[-1] == 0xFF else 8
        chunk = values[offset:offset + width]
        out.append(int("".join(str(bit) for bit in chunk).ljust(width, "0"), 2))
        offset += len(chunk)
    return bytes(out)


# One LL code block: present, included, zero bitplanes, two passes, then a
# comma-coded increment of 29. Lblock becomes 32 (allowed), but the two-pass
# segment length needs 33 bits and must be rejected before any body read.
packet_header = stuffed_packet_bits([1, 1, 1, 1, 0] + [1] * 29 + [0])
packet_siz = (be16(0) + be32(1) + be32(1) + be32(0) + be32(0)
              + be32(1) + be32(1) + be32(0) + be32(0) + be16(1)
              + bytes([7, 1, 1]))
packet_cod = bytes([0, 0, 0, 1, 0, 0, 4, 4, 0, 1])
packet_main = (b"\xff\x4f" + marker(0xFF51, packet_siz)
               + marker(0xFF52, packet_cod) + marker(0xFF5C, b"\x00\x40"))
packet_sot = (b"\xff\x90" + be16(10) + be16(0)
              + be32(14 + len(packet_header)) + bytes([0, 1]))
(OUT / "packet-header.j2k").write_bytes(packet_main + packet_sot
                                         + b"\xff\x93" + packet_header + b"\xff\xd9")

siz = (be16(0) + be32(100) + be32(100) + be32(0) + be32(0)
       + be32(10) + be32(10) + be32(0) + be32(0) + be16(1)
       + bytes([7, 1, 1]))
cod = bytes([0, 0, 0, 1, 0, 0, 4, 4, 0, 1])
header = b"\xff\x4f" + marker(0xFF51, siz) + marker(0xFF52, cod) + marker(0xFF5C, b"\x00\x40")
parts = bytearray()
for ordinal in range(100):
    for tile in range(100):
        parts += b"\xff\x90" + be16(10) + be16(tile) + be32(14) + bytes([ordinal, 0]) + b"\xff\x93"
(OUT / "tile-part-flood.j2k").write_bytes(header + parts + b"\xff\xd9")

ppm = b"".join(marker(0xFF60, bytes([index]) + b"\x00" * 127) for index in range(100))
(OUT / "ppm-flood.j2k").write_bytes(header + ppm + b"\xff\x90")
