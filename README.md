# libddpatmos

Copyright (c) 2026 B00kerLouis. Licensed under LGPL-3.0-or-later.

Native Swift 6 E-AC-3 / Dolby Digital Plus encoding for macOS14+, with a Framework
and CLI. Ordinary PCM produces the corresponding channel presentation; admitted
Atmos masters produce E-AC-3 JOC with object metadata. The products do not require
an external codec executable, bundled codec library or neighbouring project.

## Build

Xcode26.3, Swift6.2.4 and SDK26.2 are the project toolchain.

```sh
xcodebuild -project libddpatmos.xcodeproj -scheme ddpatmos \
  -configuration Release -derivedDataPath Build/Derived \
  CODE_SIGNING_ALLOWED=NO build
```

Keep `libddpatmos.framework` beside `ddpatmos` when using the CLI. Both arm64 and
x86_64 builds are supported. CI performs a universal Release build of both products.

## CLI

```sh
ddpatmos -i input.wav -o output.ec3
ddpatmos -i master.atmos -o atmos.ec3 -b 768 --downmix-mode LTRT
ddpatmos -i master.mxf -o excerpt.ec3 --start 20 --duration 12 --threads 4
ddpatmos inspect output.ec3 --report stream.json
ddpatmos probe master.atmos
```

| Option | Meaning | Default |
|---|---|---|
| `-i`, `--input` | Source PCM or master | Required |
| `-o`, `--output` | New EC3 output | Required |
| `-b`, `--bitrate` | Total kbit/s | 768 |
| `--downmix-mode` | LTRT or LORO | LTRT |
| `--layout` | Ordinary PCM layout | WAVE mask, then unambiguous channel count |
| `--dialnorm` | -31 through -1 | -31 |
| `-sc`, `--spatial-clusters` | Atmos elements including LFE:12,14,16 | 16 |
| `--object-mode` | dynamic or channelbase | dynamic |
| `--start`, `--duration` | File-relative seconds | Whole source |
| `-j`, `--threads` | 0 automatic,1 serial,2...128 worker limit | 0, up to8 CPUs |
| `--report` | New JSON report file | Console JSON |

Ordinary layouts:2.0,2.1,3.0,3.1,4.0,4.1,5.0,5.1,6.0,6.1,7.0,7.1.
Input uses WAVE physical order. Unlabelled seven-channel PCM requires explicit
6.1 or7.0. Ordinary PCM admits32/44.1/48kHz at96...1024kbit/s. Atmos admits
48kHz at384...1024kbit/s.

Sources include PCM WAVE/RF64/CAF, ADM BWF, DAMF and implemented PCM IAB MXF.
DAMF has one legal entry:the `.atmos` manifest. Standalone `.audio` and directory
entries are rejected. IAB DLC and anisotropic spread fail explicitly. PCM admits
16/24/32-bit integers and32/64-bit floating point in the supported containers.

## Framework

```swift
import Foundation
import libddpatmos

let options = DDPFileOptions(configuration:
    DDPConfiguration(bitrate: 768, downmixMode: .ltrt, threads: 0))
let report = try DDPFileEncoder.encode(
    input: URL(fileURLWithPath: inputPath),
    output: URL(fileURLWithPath: outputPath),
    options: options)
```

`DDPEncoder` accepts normalized interleaved Float PCM. Supply exactly
`inputFrameCount` frames per call. `DDPChannelLayout.lfeChannel` identifies LFE.
The transform delay is256 samples; file reports separate source/coded counts.

Instances are externally serialized; separate encoders may run concurrently.
File encoding is synchronous and belongs on a worker. Intra-AU CPU work is
bounded; state commits and output order remain sequential.

## Storage

Original media is read directly in bounded buffers. ADM/DAMF events, IAB extents
and per-frame object maps use temporary disk indexes. IAB identity lanes can be
reused between scenes. No whole-programme PCM or event list is retained in RAM.
There is no64MiB whole-programme metadata cap; individual records/fields/tables
and IAB frames remain bounded. File offsets and sample positions are64-bit.

File encoding places derived indexes beside the destination, writes each AU,
synchronizes every64AUs and publishes atomically on success. It refuses overwrite.
Graceful errors/cancellation remove partials and indexes; abrupt termination can
leave hidden scratch files. There is no persistent job store or resume mode.

Native source clients select `workingDirectory` in `DDPMasterSource.open`; its
default is system temporary storage. Use `source.metadata(at:)` for current indexed
states. `info.channels` exposes labels; `indexedMetadataEvents` and
`metadataIndexBytes` expose index counts rather than full event arrays.

## License

First-party code is LGPL-3.0-or-later. See [LICENSE](LICENSE), incorporated GPLv3
terms in [COPYING](COPYING), and retained [third-party notices](THIRD_PARTY_NOTICES.md).
Research materials, user media and binary references are not part of this repository.
