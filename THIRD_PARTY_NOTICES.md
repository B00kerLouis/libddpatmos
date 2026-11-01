# Third-party notices

First-party Swift implementation and project notices: B00kerLouis.

## FFmpeg

A/52 coding, exponent-domain bit allocation, quantization, CRC and normative
numeric tables were studied against FFmpeg's AC-3/E-AC-3 sources. Relevant
reference notices include:

- Copyright (c) 2000 Fabrice Bellard.
- Copyright (c) 2006–2010 Justin Ruggles.
- Copyright (c) 2006–2010 Prakash Punnoor.
- Copyright (c) 2011 Justin Ruggles, E-AC-3 encoder.

FFmpeg is free software under the GNU Lesser General Public License, version
2.1 or, at your option, a later version. It is distributed without warranty,
including the implied warranties of merchantability and fitness for a particular
purpose. The retained license text is [Licenses/FFmpeg-LGPL-2.1.txt](Licenses/FFmpeg-LGPL-2.1.txt).

Reference: [FFmpeg](https://ffmpeg.org/). No FFmpeg executable or library is
embedded in either product.

## ETSI / EBU

The JOC Huffman codewords implement the normative Annex A tables from ETSI TS
103 420 V1.2.1. Copyright ETSI and European Broadcasting Union 2018; all rights
reserved. The standard and its table attachment remain their original works.

- [ETSI TS 103 420 V1.2.1](https://www.etsi.org/deliver/etsi_ts/103400_103499/103420/01.02.01_60/ts_103420v010201p.pdf)
- [Normative table attachment](https://www.etsi.org/deliver/etsi_ts/103400_103499/103420/01.02.01_60/ts_103420v010201p0.zip)
- [ETSI TS 102 366 V1.4.1](https://www.etsi.org/deliver/etsi_ts/102300_102399/102366/01.04.01_60/ts_102366v010401p.pdf)

## Supplied interoperability references

The user supplied Swift_TrueHD and dolby-atmos-encoder-main as algorithm and
behavior references. Their source files and build products are not linked or
included. Local Dolby executables/libraries were used for analysis and controlled
validation; none are included in the products or required at runtime.

## macOS system XML library

Incremental ADM XML parsing calls the libxml2 SAX API supplied by macOS through
Swift's system module. The products do not redistribute libxml2 source or binary.
The system library retains its own copyright and MIT-style license notices.
