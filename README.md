# libddpatmos

Copyright (c) 2026 B00kerLouis. Licensed under LGPL-3.0-or-later.

Native Swift 6 E-AC-3 / Dolby Digital Plus encoding for macOS14+, with a Framework
and CLI. Ordinary PCM produces the corresponding channel presentation; admitted
Atmos masters produce E-AC-3 JOC with object metadata. Both products use the
native Swift encoder.

## Build

Xcode26.3, Swift6.2.4 and SDK26.2 are the project toolchain.

```sh
xcodebuild -project libddpatmos.xcodeproj -scheme ddpatmos \
  -configuration Release -derivedDataPath Build/Derived \
  CODE_SIGNING_ALLOWED=NO build
```

`ddpatmos` statically links the shared encoder source through the Xcode
`libddpatmosStatic` Framework target and runs without a companion `.framework`.
The original `libddpatmos` Framework target still produces a dynamic
`libddpatmos.framework` for library consumers. Both targets compile the same
source directory; there is no second codec implementation. The `ddpatmos` scheme
builds both the standalone CLI and the dynamic Framework. Both arm64 and x86_64
builds are supported. CI verifies both architectures and the linkage types.

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
| `-b`, `--bitrate` | Optional total kbit/s:384,448,576,640,768 only | 768 |
| `--downmix-mode` | LTRT or LORO | LTRT |
| `--layout` | Ordinary PCM layout | WAVE mask, then unambiguous channel count |
| `--dialnorm` | `measure`, or explicit metadata -31 through -1 | measure, metadata -31 |
| `--loudness` | `measure` or `off`; never applies normalization | measure |
| `--ture-peak-limter` | Decoded EC3 true peak ceiling in dBTP, -60...0 | -2.5 |
| `-sc`, `--spatial-clusters` | Atmos elements including LFE:12,14,16 | 16 |
| `--object-mode` | dynamic or channelbase | dynamic |
| `--start`, `--duration` | File-relative seconds | Whole source |
| `-j`, `--threads` | 0 automatic,1 serial,2...128 worker limit | 0, up to8 CPUs |
| `--report` | New JSON report file | Console JSON |

Ordinary layouts:2.0,2.1,3.0,3.1,4.0,4.1,5.0,5.1,6.0,6.1,7.0,7.1.
Input uses WAVE physical order. Unlabelled seven-channel PCM requires explicit
6.1 or7.0. The CLI accepts only384,448,576,640 or768kbit/s; omit `--bitrate`
to use768. The Framework's underlying admission remains32/44.1/48kHz at
96...1024kbit/s for ordinary PCM, and48kHz at384...1024kbit/s for Atmos.

Sources include PCM WAVE/RF64/CAF, ADM BWF, DAMF and implemented PCM IAB MXF.
DAMF has one legal entry:the `.atmos` manifest. Standalone `.audio` and directory
entries are rejected. IAB DLC and anisotropic spread fail explicitly. PCM admits
16/24/32-bit integers and32/64-bit floating point in the supported containers.

### True peak soft limiter

File encoding enables a linked soft limiter with a default ceiling of-2.5dBTP.
The optional `--ture-peak-limter -3` changes the ceiling; the correctly spelled
`--true-peak-limiter` is also accepted. There is no fixed input attenuation,
programme normalization or makeup gain. A programme whose reconstructed output
stays below the ceiling retains its first-pass encoded audio. Overloads create
local gain reduction with a21.33ms attack and100ms release; surrounding channels
share the envelope to preserve their balance.

The check reconstructs the actual selected, quantized EC3 mantissas, performs
windowed synthesis and overlap-add, and measures sample and intersample peaks
with16x FIR interpolation across AU boundaries, including coding and filter tails.
Decoder dither is explicitly disabled so zero-bit bins reconstruct as zero.
The checked presentation includes every independent and dependent channel and
LFE; for Atmos it is the5.1 compatibility presentation. This does not describe
the peaks of an arbitrary speaker render, a downstream downmix or playback gain.

If the encoded reconstruction exceeds the ceiling, the encoder rereads the
original source and continuously re-encodes with a local correction envelope.
Only offending neighbourhoods receive a0.15dB numerical margin. Peak and gain
indexes use eight-byte disk records beside the output, with bounded page buffers;
no programme PCM is staged. Every retry resets all codec and metadata state.
The output is published only after verification succeeds, with at most12 passes;
failure or cancellation removes partials and indexes. `--loudness off` does not
disable the limiter. Explicit dialnorm metadata remains unchanged.

The JSON `truePeak` result reports `ceilingDBTP`,
`reconstructedTruePeakDBTP`, `limited`, `encodingPasses` and `presentation`.
This is a numerical reconstruction check, separate from physical playback.

### Loudness

File encoding defaults to measurement only. It reports integrated programme LUFS
using K weighting, complete400ms blocks at100ms hops, a-70LUFS absolute gate and
a-10LU relative gate. The method follows the programme measurement in
[ITU-R BS.1770](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I/en).
It does not isolate dialogue. LFE is excluded from loudness and included in the
reported sample peak; sample peak is not true peak.

Ordinary PCM is measured in its selected source layout. Quad and5.x surround
pairs use the110-degree surround convention. In6.x/7.x, side surrounds receive
the1.41 energy weight and rear channels receive1. The report includes all channel
weights. Atmos is measured on the prepared5.1 compatibility downmix after spatial
aggregation and its existing safety limiter, before lossy coding. This is labeled
explicitly and is not a measurement of a7.1.4 render or the original object master.
Only the selected source range is counted; coding padding and tail are excluded.

Measurements never change PCM gain or automatically replace dialnorm metadata.
The default metadata is-31, avoiding dialnorm playback attenuation for music
masters. `--dialnorm measure` selects this behavior explicitly. Numeric
`--dialnorm -24`, for example, requests that metadata value and its corresponding
decoder playback adjustment while still measuring. `--loudness off` disables
measurement without changing the selected metadata value. Options are applied
in command-line order. No automatic normalization mode is enabled.

JSON reports contain `dialogueLevel` and, when measuring, `loudness` with
`integratedLUFS`, `samplePeakDBFS`, `measuredSamples`, `presentation`,
`channelEnergyWeights` and `normalizationGainDB` (always0). Silence or energy below
the absolute gate reports `belowAbsoluteGate`; ranges shorter than400ms report
`insufficientDuration`. Unavailable numeric results are omitted from JSON.
Eight-byte block energies use a temporary disk index rather than a programme-sized
RAM array or an additional PCM pass.

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

`DDPFileOptions.loudnessMode` defaults to `.measure`; set `.off` to omit measurement.
`report.loudness` exposes the result. `DDPConfiguration.dialogueLevel` remains
explicit bitstream metadata and defaults to-31. Raw `DDPEncoder` calls do not run
file-level programme measurement or apply normalization.

`DDPFileOptions.truePeakLimitDBTP` defaults to-2.5 and controls file encoding's
output limiter; `report.truePeak` exposes its verification result. The raw
fixed-AU `DDPEncoder` interface retains its PCM and timing contract and does not
run the file-level feedback limiter.

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

First-party code is LGPL-3.0-or-later. See [LICENSE](LICENSE), the incorporated
GPLv3 terms in [COPYING](COPYING), and the [license files](Licenses/).
