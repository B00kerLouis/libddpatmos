# libddpatmos

Author: B00kerLouis. First-party code is LGPL-3.0-or-later. Preserve required
third-party notices. No AI co-author trailers. New Git author/committer names
must be B00kerLouis; commit messages are exactly `Fixed known issues.` with no body.

Apply the installed no-defensive-replies and chatgpt-honor-code skills when
available. User permissions and explicit test restrictions take precedence.

Native Swift 6, macOS14+, Xcode26.3/Swift6.2.4/SDK26.2. Xcode manages the
libddpatmos Framework and ddpatmos CLI. Do not migrate to SPM or add another
implementation language. No codec subprocess, bundled reference encoder or
neighbouring project dependency is permitted. System XML parsing uses the SDK
module privately; framework consumers do not need custom XML header paths.

The Framework owns bit I/O, lapped transforms, A/52 allocation, serialization,
source readers, spatial aggregation and metadata. Consumers provide normalized
Float PCM in WAVE order. Stateful instances are externally serialized; distinct
instances can run concurrently. Transform tables are immutable.

Input is read directly. Metadata uses fixed64-byte disk events,16-byte IAB
extents and1896-byte per-frame object maps, with64KiB pages. Keep only current
IAB identities in RAM; retire absent IDs, emit zero gain and reuse free lanes.
The limit is118 simultaneous objects plus10 bed lanes, not lifetime object IDs.
DAMF accepts only the .atmos manifest; .audio is a companion, never an entry.
IAB admits the implemented PCM profile; reject DLC and anisotropic spread.
Metadata fields/lines, DTD/tables and individual IAB frames are limited to64MiB;
whole-programme metadata is streamed. Use64-bit checked offsets and sample times.

File encode scratch indexes use the output volume; source-only clients can
select workingDirectory. No full PCM staging or programme-sized event arrays.
Output uses a same-directory temporary file, per-AU writes and sync every64AUs.
Publish atomically only on success. Refuse overwrite. Detect changed sources and
companions. Graceful failure/cancellation cleans partials and indexes. Abrupt
termination can leave scratch files. No persistent job database or resumable
encode state exists; do not add SwiftData to this synchronous API.

Workers are bounded: threads0 automatic up to8,1 serial, manual up to128.
Parallelize independent channel/element/band/block work with owned results.
Keep overlap, positions, matrix history, sequence, authentication and output
commits ordered. Never encode independent AUs/segments and concatenate them.
Retain reduction order and compare serial/parallel byte output when tests are
requested. Rate search counts exact grouped mantissa bits; quantize only the
selected allocation. Maintain original public initializer overloads.

Authentication binds compacted audio and canonical EMDF using key-zero HMAC-SHA256,
after serialization and before CRC. Preserve exclusion ranges and nearest16-bit
word rounding in authenticatedAudioBytes. Keep one EMDF container within511bytes.
JOC sequence0 is stream-start/splice only; continuous frames cycle1...1023.
Do not use ten-bit masking for sequence rollover. Keep1536-sample source ramps,
quantized OAMD trajectories and limiter lookahead; flush the pending final AU.

Ordinary admission:12 layouts2.0...7.1,32/44.1/48kHz,96...1024kbit/s.
Atmos admission:48kHz,384...1024kbit/s,12/14/16 transport elements. Document
supported source profiles in README. Syntax/CRC, spatial reconstruction and
physical playback are separate validation claims; do not infer certification.

Build CLI and Framework:
`xcodebuild -project libddpatmos.xcodeproj -scheme ddpatmos -configuration Release
-derivedDataPath Build/Derived CODE_SIGNING_ALLOWED=NO build`.
Tests use the libddpatmos scheme, destination platform=macOS. Standalone official
xctest can execute a build-for-testing bundle with its sibling Framework rpath.
An installed independent decoder is permitted only as a test oracle.

Research, measurements, media, archives and proprietary references remain local
under ignored Build/ or Research/. Never stage them for GitHub. Stage explicit
allowlists, preserve private repository access, and verify owner/admin identity
before committing. CI builds both architectures with Xcode26.3. It intentionally
does not run tests or publish binary artifacts without further user instruction.
