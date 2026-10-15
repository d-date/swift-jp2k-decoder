/*
 * The copyright in this software is being made available under the 2-clauses
 * BSD License, included below. This software may be subject to other third
 * party and contributor rights, including patent rights, and no such rights
 * are granted under this license.
 *
 * Copyright (c) 2002-2014, Universite catholique de Louvain (UCL), Belgium
 * Copyright (c) 2002-2014, Professor Benoit Macq
 * Copyright (c) 2001-2003, David Janssens
 * Copyright (c) 2002-2003, Yannick Verschueren
 * Copyright (c) 2003-2007, Francois-Olivier Devaux
 * Copyright (c) 2003-2014, Antonin Descampe
 * Copyright (c) 2005, Herve Drolon, FreeImage Team
 * Copyright (c) 2007, Callum Lerwick <seg@haxxed.com>
 * Copyright (c) 2012, Carl Hetherington
 * Copyright (c) 2017, IntoPIX SA <support@intopix.com>
 * Copyright (c) 2008, Jerome Fimes, Communications & Systemes <jerome.fimes@c-s.fr>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS `AS IS'
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */
// Ported from OpenJPEG v2.5.4: t1.c: opj_t1_getctxno_zc, opj_t1_getctxno_sc, opj_t1_getctxno_mag, opj_t1_getspb; t1_luts.h: lut_ctxno_zc, lut_ctxno_sc, lut_spb; mqc.c: mqc_states
struct MQState {
    let qeval: UInt32
    let mps: Int
    let nmps: Int
    let nlps: Int
}

enum T1Tables {
    static let zeroCoding: [UInt8] = [
        0, 1, 3, 3, 1, 2, 3, 3, 5, 6, 7, 7, 6, 6, 7, 7, 0, 1, 3, 3, 1, 2, 3, 3, 5, 6, 7, 7, 6, 6, 7, 7,
        5, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 5, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        1, 2, 3, 3, 2, 2, 3, 3, 6, 6, 7, 7, 6, 6, 7, 7, 1, 2, 3, 3, 2, 2, 3, 3, 6, 6, 7, 7, 6, 6, 7, 7,
        6, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 6, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7, 3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7, 3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        1, 2, 3, 3, 2, 2, 3, 3, 6, 6, 7, 7, 6, 6, 7, 7, 1, 2, 3, 3, 2, 2, 3, 3, 6, 6, 7, 7, 6, 6, 7, 7,
        6, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 6, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        2, 2, 3, 3, 2, 2, 3, 3, 6, 6, 7, 7, 6, 6, 7, 7, 2, 2, 3, 3, 2, 2, 3, 3, 6, 6, 7, 7, 6, 6, 7, 7,
        6, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 6, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7, 3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7, 3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        0, 1, 5, 6, 1, 2, 6, 6, 3, 3, 7, 7, 3, 3, 7, 7, 0, 1, 5, 6, 1, 2, 6, 6, 3, 3, 7, 7, 3, 3, 7, 7,
        3, 3, 7, 7, 3, 3, 7, 7, 4, 4, 7, 7, 4, 4, 7, 7, 3, 3, 7, 7, 3, 3, 7, 7, 4, 4, 7, 7, 4, 4, 7, 7,
        1, 2, 6, 6, 2, 2, 6, 6, 3, 3, 7, 7, 3, 3, 7, 7, 1, 2, 6, 6, 2, 2, 6, 6, 3, 3, 7, 7, 3, 3, 7, 7,
        3, 3, 7, 7, 3, 3, 7, 7, 4, 4, 7, 7, 4, 4, 7, 7, 3, 3, 7, 7, 3, 3, 7, 7, 4, 4, 7, 7, 4, 4, 7, 7,
        5, 6, 8, 8, 6, 6, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 5, 6, 8, 8, 6, 6, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8,
        7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8,
        6, 6, 8, 8, 6, 6, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 6, 6, 8, 8, 6, 6, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8,
        7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8,
        1, 2, 6, 6, 2, 2, 6, 6, 3, 3, 7, 7, 3, 3, 7, 7, 1, 2, 6, 6, 2, 2, 6, 6, 3, 3, 7, 7, 3, 3, 7, 7,
        3, 3, 7, 7, 3, 3, 7, 7, 4, 4, 7, 7, 4, 4, 7, 7, 3, 3, 7, 7, 3, 3, 7, 7, 4, 4, 7, 7, 4, 4, 7, 7,
        2, 2, 6, 6, 2, 2, 6, 6, 3, 3, 7, 7, 3, 3, 7, 7, 2, 2, 6, 6, 2, 2, 6, 6, 3, 3, 7, 7, 3, 3, 7, 7,
        3, 3, 7, 7, 3, 3, 7, 7, 4, 4, 7, 7, 4, 4, 7, 7, 3, 3, 7, 7, 3, 3, 7, 7, 4, 4, 7, 7, 4, 4, 7, 7,
        6, 6, 8, 8, 6, 6, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 6, 6, 8, 8, 6, 6, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8,
        7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8,
        6, 6, 8, 8, 6, 6, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 6, 6, 8, 8, 6, 6, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8,
        7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8, 7, 7, 8, 8,
        0, 1, 3, 3, 1, 2, 3, 3, 5, 6, 7, 7, 6, 6, 7, 7, 0, 1, 3, 3, 1, 2, 3, 3, 5, 6, 7, 7, 6, 6, 7, 7,
        5, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 5, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        1, 2, 3, 3, 2, 2, 3, 3, 6, 6, 7, 7, 6, 6, 7, 7, 1, 2, 3, 3, 2, 2, 3, 3, 6, 6, 7, 7, 6, 6, 7, 7,
        6, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 6, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7, 3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7, 3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        1, 2, 3, 3, 2, 2, 3, 3, 6, 6, 7, 7, 6, 6, 7, 7, 1, 2, 3, 3, 2, 2, 3, 3, 6, 6, 7, 7, 6, 6, 7, 7,
        6, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 6, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        2, 2, 3, 3, 2, 2, 3, 3, 6, 6, 7, 7, 6, 6, 7, 7, 2, 2, 3, 3, 2, 2, 3, 3, 6, 6, 7, 7, 6, 6, 7, 7,
        6, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 6, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7, 3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7, 3, 3, 4, 4, 3, 3, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
        0, 3, 1, 4, 3, 6, 4, 7, 1, 4, 2, 5, 4, 7, 5, 7, 0, 3, 1, 4, 3, 6, 4, 7, 1, 4, 2, 5, 4, 7, 5, 7,
        1, 4, 2, 5, 4, 7, 5, 7, 2, 5, 2, 5, 5, 7, 5, 7, 1, 4, 2, 5, 4, 7, 5, 7, 2, 5, 2, 5, 5, 7, 5, 7,
        3, 6, 4, 7, 6, 8, 7, 8, 4, 7, 5, 7, 7, 8, 7, 8, 3, 6, 4, 7, 6, 8, 7, 8, 4, 7, 5, 7, 7, 8, 7, 8,
        4, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8, 4, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8,
        1, 4, 2, 5, 4, 7, 5, 7, 2, 5, 2, 5, 5, 7, 5, 7, 1, 4, 2, 5, 4, 7, 5, 7, 2, 5, 2, 5, 5, 7, 5, 7,
        2, 5, 2, 5, 5, 7, 5, 7, 2, 5, 2, 5, 5, 7, 5, 7, 2, 5, 2, 5, 5, 7, 5, 7, 2, 5, 2, 5, 5, 7, 5, 7,
        4, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8, 4, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8,
        5, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8,
        3, 6, 4, 7, 6, 8, 7, 8, 4, 7, 5, 7, 7, 8, 7, 8, 3, 6, 4, 7, 6, 8, 7, 8, 4, 7, 5, 7, 7, 8, 7, 8,
        4, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8, 4, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8,
        6, 8, 7, 8, 8, 8, 8, 8, 7, 8, 7, 8, 8, 8, 8, 8, 6, 8, 7, 8, 8, 8, 8, 8, 7, 8, 7, 8, 8, 8, 8, 8,
        7, 8, 7, 8, 8, 8, 8, 8, 7, 8, 7, 8, 8, 8, 8, 8, 7, 8, 7, 8, 8, 8, 8, 8, 7, 8, 7, 8, 8, 8, 8, 8,
        4, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8, 4, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8,
        5, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8, 5, 7, 5, 7, 7, 8, 7, 8,
        7, 8, 7, 8, 8, 8, 8, 8, 7, 8, 7, 8, 8, 8, 8, 8, 7, 8, 7, 8, 8, 8, 8, 8, 7, 8, 7, 8, 8, 8, 8, 8,
        7, 8, 7, 8, 8, 8, 8, 8, 7, 8, 7, 8, 8, 8, 8, 8, 7, 8, 7, 8, 8, 8, 8, 8, 7, 8, 7, 8, 8, 8, 8, 8
    ]
    static let signCoding: [UInt8] = [
        0x9, 0x9, 0xa, 0xa, 0x9, 0x9, 0xa, 0xa, 0xc, 0xc, 0xd, 0xb, 0xc, 0xc, 0xd, 0xb, 0x9, 0x9, 0xa, 0xa, 0x9, 0x9, 0xa, 0xa, 0xc, 0xc, 0xb, 0xd, 0xc, 0xc, 0xb, 0xd,
        0xc, 0xc, 0xd, 0xd, 0xc, 0xc, 0xb, 0xb, 0xc, 0x9, 0xd, 0xa, 0x9, 0xc, 0xa, 0xb, 0xc, 0xc, 0xb, 0xb, 0xc, 0xc, 0xd, 0xd, 0xc, 0x9, 0xb, 0xa, 0x9, 0xc, 0xa, 0xd,
        0x9, 0x9, 0xa, 0xa, 0x9, 0x9, 0xa, 0xa, 0xc, 0xc, 0xd, 0xb, 0xc, 0xc, 0xd, 0xb, 0x9, 0x9, 0xa, 0xa, 0x9, 0x9, 0xa, 0xa, 0xc, 0xc, 0xb, 0xd, 0xc, 0xc, 0xb, 0xd,
        0xc, 0xc, 0xd, 0xd, 0xc, 0xc, 0xb, 0xb, 0xc, 0x9, 0xd, 0xa, 0x9, 0xc, 0xa, 0xb, 0xc, 0xc, 0xb, 0xb, 0xc, 0xc, 0xd, 0xd, 0xc, 0x9, 0xb, 0xa, 0x9, 0xc, 0xa, 0xd,
        0xa, 0xa, 0xa, 0xa, 0xa, 0xa, 0xa, 0xa, 0xd, 0xb, 0xd, 0xb, 0xd, 0xb, 0xd, 0xb, 0xa, 0xa, 0x9, 0x9, 0xa, 0xa, 0x9, 0x9, 0xd, 0xb, 0xc, 0xc, 0xd, 0xb, 0xc, 0xc,
        0xd, 0xd, 0xd, 0xd, 0xb, 0xb, 0xb, 0xb, 0xd, 0xa, 0xd, 0xa, 0xa, 0xb, 0xa, 0xb, 0xd, 0xd, 0xc, 0xc, 0xb, 0xb, 0xc, 0xc, 0xd, 0xa, 0xc, 0x9, 0xa, 0xb, 0x9, 0xc,
        0xa, 0xa, 0x9, 0x9, 0xa, 0xa, 0x9, 0x9, 0xb, 0xd, 0xc, 0xc, 0xb, 0xd, 0xc, 0xc, 0xa, 0xa, 0xa, 0xa, 0xa, 0xa, 0xa, 0xa, 0xb, 0xd, 0xb, 0xd, 0xb, 0xd, 0xb, 0xd,
        0xb, 0xb, 0xc, 0xc, 0xd, 0xd, 0xc, 0xc, 0xb, 0xa, 0xc, 0x9, 0xa, 0xd, 0x9, 0xc, 0xb, 0xb, 0xb, 0xb, 0xd, 0xd, 0xd, 0xd, 0xb, 0xa, 0xb, 0xa, 0xa, 0xd, 0xa, 0xd
    ]
    static let signPrediction: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1,
        0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 1, 1, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1,
        0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 1, 1, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1,
        0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1,
        1, 1, 0, 0, 1, 1, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1,
        0, 0, 0, 0, 1, 1, 1, 1, 0, 1, 0, 0, 1, 1, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1
    ]
    static let states: [MQState] = [
        MQState(qeval: 0x5601, mps: 0, nmps: 2, nlps: 3),
        MQState(qeval: 0x5601, mps: 1, nmps: 3, nlps: 2),
        MQState(qeval: 0x3401, mps: 0, nmps: 4, nlps: 12),
        MQState(qeval: 0x3401, mps: 1, nmps: 5, nlps: 13),
        MQState(qeval: 0x1801, mps: 0, nmps: 6, nlps: 18),
        MQState(qeval: 0x1801, mps: 1, nmps: 7, nlps: 19),
        MQState(qeval: 0x0ac1, mps: 0, nmps: 8, nlps: 24),
        MQState(qeval: 0x0ac1, mps: 1, nmps: 9, nlps: 25),
        MQState(qeval: 0x0521, mps: 0, nmps: 10, nlps: 58),
        MQState(qeval: 0x0521, mps: 1, nmps: 11, nlps: 59),
        MQState(qeval: 0x0221, mps: 0, nmps: 76, nlps: 66),
        MQState(qeval: 0x0221, mps: 1, nmps: 77, nlps: 67),
        MQState(qeval: 0x5601, mps: 0, nmps: 14, nlps: 13),
        MQState(qeval: 0x5601, mps: 1, nmps: 15, nlps: 12),
        MQState(qeval: 0x5401, mps: 0, nmps: 16, nlps: 28),
        MQState(qeval: 0x5401, mps: 1, nmps: 17, nlps: 29),
        MQState(qeval: 0x4801, mps: 0, nmps: 18, nlps: 28),
        MQState(qeval: 0x4801, mps: 1, nmps: 19, nlps: 29),
        MQState(qeval: 0x3801, mps: 0, nmps: 20, nlps: 28),
        MQState(qeval: 0x3801, mps: 1, nmps: 21, nlps: 29),
        MQState(qeval: 0x3001, mps: 0, nmps: 22, nlps: 34),
        MQState(qeval: 0x3001, mps: 1, nmps: 23, nlps: 35),
        MQState(qeval: 0x2401, mps: 0, nmps: 24, nlps: 36),
        MQState(qeval: 0x2401, mps: 1, nmps: 25, nlps: 37),
        MQState(qeval: 0x1c01, mps: 0, nmps: 26, nlps: 40),
        MQState(qeval: 0x1c01, mps: 1, nmps: 27, nlps: 41),
        MQState(qeval: 0x1601, mps: 0, nmps: 58, nlps: 42),
        MQState(qeval: 0x1601, mps: 1, nmps: 59, nlps: 43),
        MQState(qeval: 0x5601, mps: 0, nmps: 30, nlps: 29),
        MQState(qeval: 0x5601, mps: 1, nmps: 31, nlps: 28),
        MQState(qeval: 0x5401, mps: 0, nmps: 32, nlps: 28),
        MQState(qeval: 0x5401, mps: 1, nmps: 33, nlps: 29),
        MQState(qeval: 0x5101, mps: 0, nmps: 34, nlps: 30),
        MQState(qeval: 0x5101, mps: 1, nmps: 35, nlps: 31),
        MQState(qeval: 0x4801, mps: 0, nmps: 36, nlps: 32),
        MQState(qeval: 0x4801, mps: 1, nmps: 37, nlps: 33),
        MQState(qeval: 0x3801, mps: 0, nmps: 38, nlps: 34),
        MQState(qeval: 0x3801, mps: 1, nmps: 39, nlps: 35),
        MQState(qeval: 0x3401, mps: 0, nmps: 40, nlps: 36),
        MQState(qeval: 0x3401, mps: 1, nmps: 41, nlps: 37),
        MQState(qeval: 0x3001, mps: 0, nmps: 42, nlps: 38),
        MQState(qeval: 0x3001, mps: 1, nmps: 43, nlps: 39),
        MQState(qeval: 0x2801, mps: 0, nmps: 44, nlps: 38),
        MQState(qeval: 0x2801, mps: 1, nmps: 45, nlps: 39),
        MQState(qeval: 0x2401, mps: 0, nmps: 46, nlps: 40),
        MQState(qeval: 0x2401, mps: 1, nmps: 47, nlps: 41),
        MQState(qeval: 0x2201, mps: 0, nmps: 48, nlps: 42),
        MQState(qeval: 0x2201, mps: 1, nmps: 49, nlps: 43),
        MQState(qeval: 0x1c01, mps: 0, nmps: 50, nlps: 44),
        MQState(qeval: 0x1c01, mps: 1, nmps: 51, nlps: 45),
        MQState(qeval: 0x1801, mps: 0, nmps: 52, nlps: 46),
        MQState(qeval: 0x1801, mps: 1, nmps: 53, nlps: 47),
        MQState(qeval: 0x1601, mps: 0, nmps: 54, nlps: 48),
        MQState(qeval: 0x1601, mps: 1, nmps: 55, nlps: 49),
        MQState(qeval: 0x1401, mps: 0, nmps: 56, nlps: 50),
        MQState(qeval: 0x1401, mps: 1, nmps: 57, nlps: 51),
        MQState(qeval: 0x1201, mps: 0, nmps: 58, nlps: 52),
        MQState(qeval: 0x1201, mps: 1, nmps: 59, nlps: 53),
        MQState(qeval: 0x1101, mps: 0, nmps: 60, nlps: 54),
        MQState(qeval: 0x1101, mps: 1, nmps: 61, nlps: 55),
        MQState(qeval: 0x0ac1, mps: 0, nmps: 62, nlps: 56),
        MQState(qeval: 0x0ac1, mps: 1, nmps: 63, nlps: 57),
        MQState(qeval: 0x09c1, mps: 0, nmps: 64, nlps: 58),
        MQState(qeval: 0x09c1, mps: 1, nmps: 65, nlps: 59),
        MQState(qeval: 0x08a1, mps: 0, nmps: 66, nlps: 60),
        MQState(qeval: 0x08a1, mps: 1, nmps: 67, nlps: 61),
        MQState(qeval: 0x0521, mps: 0, nmps: 68, nlps: 62),
        MQState(qeval: 0x0521, mps: 1, nmps: 69, nlps: 63),
        MQState(qeval: 0x0441, mps: 0, nmps: 70, nlps: 64),
        MQState(qeval: 0x0441, mps: 1, nmps: 71, nlps: 65),
        MQState(qeval: 0x02a1, mps: 0, nmps: 72, nlps: 66),
        MQState(qeval: 0x02a1, mps: 1, nmps: 73, nlps: 67),
        MQState(qeval: 0x0221, mps: 0, nmps: 74, nlps: 68),
        MQState(qeval: 0x0221, mps: 1, nmps: 75, nlps: 69),
        MQState(qeval: 0x0141, mps: 0, nmps: 76, nlps: 70),
        MQState(qeval: 0x0141, mps: 1, nmps: 77, nlps: 71),
        MQState(qeval: 0x0111, mps: 0, nmps: 78, nlps: 72),
        MQState(qeval: 0x0111, mps: 1, nmps: 79, nlps: 73),
        MQState(qeval: 0x0085, mps: 0, nmps: 80, nlps: 74),
        MQState(qeval: 0x0085, mps: 1, nmps: 81, nlps: 75),
        MQState(qeval: 0x0049, mps: 0, nmps: 82, nlps: 76),
        MQState(qeval: 0x0049, mps: 1, nmps: 83, nlps: 77),
        MQState(qeval: 0x0025, mps: 0, nmps: 84, nlps: 78),
        MQState(qeval: 0x0025, mps: 1, nmps: 85, nlps: 79),
        MQState(qeval: 0x0015, mps: 0, nmps: 86, nlps: 80),
        MQState(qeval: 0x0015, mps: 1, nmps: 87, nlps: 81),
        MQState(qeval: 0x0009, mps: 0, nmps: 88, nlps: 82),
        MQState(qeval: 0x0009, mps: 1, nmps: 89, nlps: 83),
        MQState(qeval: 0x0005, mps: 0, nmps: 90, nlps: 84),
        MQState(qeval: 0x0005, mps: 1, nmps: 91, nlps: 85),
        MQState(qeval: 0x0001, mps: 0, nmps: 90, nlps: 86),
        MQState(qeval: 0x0001, mps: 1, nmps: 91, nlps: 87),
        MQState(qeval: 0x5601, mps: 0, nmps: 92, nlps: 92),
        MQState(qeval: 0x5601, mps: 1, nmps: 93, nlps: 93)
    ]
    static func zeroContext(orientation: Int, flags: Int) -> Int {
        Int(zeroCoding[((orientation & 3) << 9) | (flags & 0x1EF)])
    }

    static func signContext(_ index: Int) -> Int { Int(signCoding[index & 0xFF]) }
    static func predictedSign(_ index: Int) -> Int { Int(signPrediction[index & 0xFF]) }

    static func magnitudeContext(flags: Int) -> Int {
        if flags & (1 << 20) != 0 { return 16 }
        return flags & 0x1EF != 0 ? 15 : 14
    }
}
