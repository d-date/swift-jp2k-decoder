| Swift file | Swift symbol | OpenJPEG file | OpenJPEG function |
| --- | --- | --- | --- |
| Sources/JP2K/Container/JP2Boxes.swift | JP2Parser.next | src/lib/openjp2/jp2.c | opj_jp2_read_boxhdr, opj_jp2_read_boxhdr_char |
| Sources/JP2K/Container/JP2Boxes.swift | JP2Parser.parse | src/lib/openjp2/jp2.c | opj_jp2_read_header, opj_jp2_read_jp2h, opj_jp2_read_ftyp |
| Sources/JP2K/Container/JP2Header.swift | JP2Header.readImageHeader | src/lib/openjp2/jp2.c | opj_jp2_read_ihdr |
| Sources/JP2K/Container/JP2Header.swift | JP2Header.parse | src/lib/openjp2/jp2.c | opj_jp2_read_bpcc, opj_jp2_read_colr, opj_jp2_read_pclr, opj_jp2_read_cmap, opj_jp2_read_cdef |
| Sources/JP2K/Container/JP2Header.swift | JP2Header.validate | src/lib/openjp2/jp2.c | opj_jp2_check_color |
