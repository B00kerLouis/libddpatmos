// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import Testing

@testable import libddpatmos

struct CodecTests {
  @Test func countedMantissasMatchActualGroupedSerialization() {
    for channels in [1, 2, 5, 7] {
      let spectra = (0..<channels).map { channel in
        let bins = channel == channels - 1 ? 7 : 253
        let values = (0..<bins).map { 0.03 * sin(Double($0 * 7 + channel * 31) * 0.19) }
        return DDPAllocation.analyze(values, bins: bins, sampleRateCode: 0, lfe: bins == 7)
      }
      for snr in stride(from: 0, through: 1023, by: 37) {
        #expect(
          DDPAllocation.mantissaBitCount(spectra, snr: snr)
            == DDPAllocation.mantissas(spectra, snr: snr).count)
      }
    }
  }

  @Test func jocSequenceReservesZeroForStreamStart() throws {
    var sequence = JOCFrameSequence()
    let matrix = [[[1.0], [0.0], [0.0], [0.0], [0.0]]]
    // Include three complete rollover boundaries. Read the actual serialized
    // field: a valid ten-bit value alone does not imply continuous JOC syntax.
    for frame in 0..<4096 {
      let payload = AtmosMetadataCoding.joc(matrix, sequence: sequence.value, bandIndex: 0)
      var reader = BitReader(bytes: payload, position: 20)
      let actual = try reader.read(10)
      let expected = frame == 0 ? 0 : 1 + (frame - 1) % 1023
      #expect(actual == expected, "Frame \(frame), sequence \(actual), expected \(expected)")
      #expect((actual == 0) == (frame == 0))
      sequence.advance()
    }
  }

  @Test func nativeAudioCanonicalRemainders() {
    let expected = [
      "00010203040506070809", "00020406080a0c0e1012", "0004080c1014181c2024",
      "00081018202830384048", "00102030405060708090", "0020406080a0c0e10120",
      "004080c1014181c20240", "00810182028303840480", "01020304050607080900",
      "020406080a0c0e10", "04080c1014181c20", "0810182028303840", "1020304050607080",
      "20406080a0c0e101", "4080c1014181c202", "8101820283038404",
    ]
    for removed in 0..<16 {
      var writer = BitWriter()
      writer.append((0..<10).map(UInt8.init))
      if removed > 0 { writer.authenticationExclusions.append(0..<removed) }
      let actual = writer.authenticatedAudioBytes().map { String(format: "%02x", $0) }.joined()
      #expect(actual == expected[removed])
    }
  }
  @Test func crcDetectsPayloadDamage() throws {
    let encoder = try DDPEncoder(configuration: .init(layout: .stereo))
    var frame = Array(try encoder.encode([Float](repeating: 0, count: 3072)))
    #expect(frame.count == 3072)
    #expect(DDPCRC.crc16(frame.dropFirst(2)) == 0)
    frame[100] ^= 1
    #expect(DDPCRC.crc16(frame.dropFirst(2)) != 0)
  }
  @Test func ratesHaveExactLongTermFrameBudget() throws {
    for rate in [32000, 44100, 48000] {
      let encoder = try DDPEncoder(configuration: .init(sampleRate: rate, layout: .stereo))
      var bytes = 0
      for _ in 0..<16 {
        bytes += try encoder.encode([Float](repeating: 0, count: encoder.inputFrameCount * 2)).count
      }
      #expect(bytes == Int(UInt64(16 * 768000 * encoder.inputFrameCount) / UInt64(rate * 16)) * 2)
    }
  }
  @Test func nativeAuthenticatorReplayVector() {
    // Key-zero authentication known-answer vector for bytes 0...250,
    // without associated audio data.
    let actual = EMDFProtection.authenticate((0...250).map(UInt8.init)).map {
      String(format: "%02x", $0)
    }.joined()
    #expect(actual == "01f8b1f2259cd576d66f0a6b9a90ae5e176890863903c3e22bc22245e331776b")
  }
  @Test func invalidPCMDoesNotProduceAFrame() throws {
    let encoder = try DDPEncoder(configuration: .init(layout: .stereo))
    #expect(throws: DDPError.self) { try encoder.encode([0, 1]) }
    var pcm = [Float](repeating: 0, count: 3072)
    pcm[42] = .nan
    #expect(throws: DDPError.self) { try encoder.encode(pcm) }
  }
  @Test func boundedBitReaderRejectsTruncation() throws {
    var r = BitReader(bytes: [0xa5])
    #expect(try r.read(4) == 10)
    #expect(throws: DDPError.self) { try r.read(5) }
    #expect(try r.read(4) == 5)
  }
  @Test func variableLengthSyntaxBoundaries() throws {
    for width in [2, 4, 8] {
      for value in [0, 1, 3, 4, 15, 16, 255, 256, 4095, 65535] {
        var w = BitWriter()
        w.variable(value, width: width)
        var r = BitReader(bytes: w.bytes)
        #expect(try r.variable(width) == value)
      }
    }
  }
  @Test func emdfPreservesPayloadAndAuthenticates() throws {
    let oamd = AtmosMetadataCoding.oamd([.init(x: -1, y: 1, z: 1), .init(x: 1, y: -1, z: 0)])
    let encoded = EMDFProtection.wrap([(11, oamd)])
    let container = try EMDFContainer.parse(encoded, at: 0)
    #expect(container.payloads.count == 1)
    #expect(container.payloads[0].0 == 11)
    #expect(container.payloads[0].1 == oamd)
    var unsigned = container.body
    for bit in container.protectionStart..<(container.protectionStart + 32) {
      unsigned[bit >> 3] &= ~(1 << (7 - (bit & 7)))
    }
    #expect(container.primary == Array(EMDFProtection.authenticate(unsigned).prefix(4)))
  }
  @Test func masterEntryRejectsStandaloneAudio() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".audio")
    try Data([1, 2, 3]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: DDPError.self) { try DDPMasterSource.open(url) }
  }
}
