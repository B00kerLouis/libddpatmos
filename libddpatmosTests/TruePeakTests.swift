// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import Testing

@testable import libddpatmos

struct TruePeakTests {
  private static let decoder = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first {
    FileManager.default.isExecutableFile(atPath: $0)
  }
  private func directory() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Build/TruePeak/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  private func wave(_ pcm: [Float], rate: Int, channels: Int, at url: URL) throws {
    var data = Data()
    func word(_ n: Int, _ width: Int) {
      for i in 0..<width { data.append(UInt8(truncatingIfNeeded: n >> (8 * i))) }
    }
    data.append(Data("RIFF".utf8))
    word(36 + pcm.count * 4, 4)
    data.append(Data("WAVEfmt ".utf8))
    word(16, 4)
    word(3, 2)
    word(channels, 2)
    word(rate, 4)
    word(rate * channels * 4, 4)
    word(channels * 4, 2)
    word(32, 2)
    data.append(Data("data".utf8))
    word(pcm.count * 4, 4)
    for sample in pcm { word(Int(sample.bitPattern), 4) }
    try data.write(to: url)
  }
  private func decode(_ input: URL, rate: Int? = nil) throws -> [Double] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: Self.decoder!)
    var arguments = ["-v", "error", "-drc_scale", "0", "-i", input.path]
    if let rate {
      arguments += ["-af", "aresample=\(rate * 16):filter_size=128:phase_shift=10:linear_interp=0"]
    }
    process.arguments = arguments + ["-f", "f64le", "-"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return bytes.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
  }

  @Test(.enabled(if: decoder != nil))
  func quantizedSynthesisMatchesIndependentDecoder() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    for bitrate in [96, 384, 768] {
      let encoder = try DDPEncoder(configuration: .init(bitrate: bitrate, layout: .stereo))
      encoder.enableReconstruction()
      var expected = [Double]()
      var data = Data()
      for unit in 0..<4 {
        let pcm = (0..<(encoder.inputFrameCount * 2)).map { i in
          let time = Double(i + unit * 3072)
          let low = 0.83 * sin(time * 0.0347)
          let high = 0.11 * sin(time * 1.373)
          return Float(low + high)
        }
        data.append(try encoder.encode(pcm))
        for f in 0..<encoder.inputFrameCount {
          for c in 0..<2 { expected.append(encoder.reconstructedPCM[c][f]) }
        }
      }
      let input = root.appendingPathComponent("synthesis-\(bitrate).ec3")
      try data.write(to: input)
      let decoded = try decode(input)
      #expect(decoded.count == expected.count)
      let error = zip(decoded, expected).reduce(0.0) { max($0, abs($1.0 - $1.1)) }
      print("Native synthesis \(bitrate) kbit/s max error: \(error)")
      #expect(error < 0.000002)
    }
  }

  @Test func meterDetectsIntersampleOversAndKeepsHistory() {
    let signal = (0..<3072).map { sin(Double($0) * .pi / 2 + .pi / 4) * 0.98 }
    #expect(signal.map(abs).max()! < pow(10, -2.5 / 20))
    var whole = DDPTruePeakMeter()
    _ = whole.consume([signal])
    _ = whole.finish()
    var chunked = DDPTruePeakMeter()
    for first in stride(from: 0, to: signal.count, by: 256) {
      _ = chunked.consume([Array(signal[first..<(first + 256)])])
    }
    _ = chunked.finish()
    #expect(whole.maximum > 0.97)
    #expect(abs(whole.maximum - chunked.maximum) < 1e-12)
  }

  @Test(.enabled(if: decoder != nil))
  func finalEC3IsLimitedWithoutChangingSafeProgrammes() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    for (rate, layout, bitrate) in [
      (48000, DDPChannelLayout.stereo, 96), (44100, .fiveOne, 384),
      (32000, .sevenOne, 1024), (48000, .stereo, 768),
    ] {
      for amplitude in [0.1, 0.98] {
        let frames = 1536 * 6 + 77
        var pcm = [Float]()
        for f in 0..<frames {
          for c in 0..<layout.channels {
            let frequency = layout.lfeChannel == c ? 2 * .pi * 60 / Double(rate) : .pi / 2
            pcm.append(Float(amplitude * sin(Double(f) * frequency + .pi / 4)))
          }
        }
        if amplitude > 0.5 { pcm[pcm.count - 1] = -1 }
        let input = root.appendingPathComponent("input.wav")
        let output = root.appendingPathComponent("output.ec3")
        try wave(pcm, rate: rate, channels: layout.channels, at: input)
        var options = DDPFileOptions(configuration: .init(bitrate: bitrate), layout: layout)
        options.truePeakLimitDBTP = -2.5
        let report = try DDPFileEncoder.encode(input: input, output: output, options: options)
        let peak = try decode(output, rate: rate).reduce(0.0) { max($0, abs($1)) }
        let db = 20 * log10(peak)
        print(
          "Final EC3 \(rate) \(layout.rawValue) \(bitrate), input \(amplitude): \(db) dBTP, \(report.truePeak!)"
        )
        #expect(db <= -2.5)
        #expect(report.truePeak?.limited == (amplitude > 0.5))
        if amplitude < 0.5 {
          var configuration = options.configuration
          configuration.sampleRate = rate
          configuration.layout = layout
          let raw = try DDPEncoder(configuration: configuration)
          var expected = Data()
          let unit = raw.inputFrameCount
          let count = (frames + 256 + unit - 1) / unit
          for i in 0..<count {
            let first = min(frames, i * unit) * layout.channels
            let last = min(frames, (i + 1) * unit) * layout.channels
            var block = Array(pcm[first..<last])
            block.append(contentsOf: repeatElement(0, count: unit * layout.channels - block.count))
            expected.append(try raw.encode(block))
          }
          #expect(try Data(contentsOf: output) == expected)
          #expect(report.truePeak?.encodingPasses == 1)
        }
        try FileManager.default.removeItem(at: output)
      }
    }
  }

  @Test func rejectsInvalidCeilingsBeforeCreatingOutput() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    for limit in [Double.nan, .infinity, 0.1, -60.1] {
      var options = DDPFileOptions()
      options.truePeakLimitDBTP = limit
      #expect(throws: DDPError.self) {
        try DDPFileEncoder.encode(
          input: root.appendingPathComponent("absent.wav"),
          output: root.appendingPathComponent("output.ec3"), options: options)
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
  }

  @Test(.enabled(if: decoder != nil))
  func nearCeilingTransientsAndHighFrequenciesStaySafe() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    for (index, frequency) in [0.25, 0.375, 0.475, 0.49].enumerated() {
      for amplitude in [0.681, 0.682, 0.69, 0.749, 0.99] {
        let frames = 1536 * 4 + 77
        var pcm = [Float]()
        for f in 0..<frames {
          let sample = Float(amplitude * sin(Double(f) * 2 * .pi * frequency + .pi / 4))
          pcm += [sample, sample * 0.75]
        }
        let input = root.appendingPathComponent("near.wav")
        let output = root.appendingPathComponent("\(index)-\(amplitude).ec3")
        try wave(pcm, rate: 48000, channels: 2, at: input)
        let report = try DDPFileEncoder.encode(
          input: input, output: output,
          options: .init(configuration: .init(layout: .stereo)))
        let peak = try decode(output, rate: 48000).reduce(0.0) { max($0, abs($1)) }
        let db = 20 * log10(peak)
        print(
          "Near ceiling \(frequency)fs, \(amplitude): \(db) dBTP, native \(report.truePeak!.reconstructedTruePeakDBTP!)"
        )
        #expect(db <= -2.5)
      }
    }
  }

  @Test(.enabled(if: decoder != nil))
  func atmosAndLFESurviveFeedbackAndFinalFlush() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let frames = 1536 * 4 + 77
    var pcm = [Float]()
    for f in 0..<frames {
      pcm.append(Float(0.99 * sin(Double(f) * .pi / 2 + .pi / 4)))
      pcm.append(Float(0.99 * sin(Double(f) * 2 * .pi * 60 / 48000)))
    }
    try wave(pcm, rate: 48000, channels: 2, at: root.appendingPathComponent("master.audio"))
    try Data(
      "audio: master.audio\nmetadata: master.metadata\nbedInstances:\n- channel: LFE\n  ID: 1\nobjects:\n- ID: 0\n"
        .utf8
    )
    .write(to: root.appendingPathComponent("master.atmos"))
    try Data("- ID: 0\n  samplePos: 0\n  pos: [-1, 1, 0]\n".utf8)
      .write(to: root.appendingPathComponent("master.metadata"))
    for elements in [12, 14, 16] {
      for mode in [DDPObjectMode.dynamic, .channelbase] {
        var options = DDPFileOptions(configuration: .init(bitrate: 768))
        options.spatialElements = elements
        options.objectMode = mode
        options.truePeakLimitDBTP = -6
        let output = root.appendingPathComponent("\(elements)-\(mode).ec3")
        let report = try DDPFileEncoder.encode(
          input: root.appendingPathComponent("master.atmos"),
          output: output, options: options)
        let peak = try decode(output, rate: 48000).reduce(0.0) { max($0, abs($1)) }
        print("Atmos \(elements) \(mode) peak: \(20 * log10(peak)) dBTP")
        #expect(20 * log10(peak) <= -6)
        #expect(report.truePeak?.limited == true)
        #expect(report.loudness?.measuredSamples == UInt64(frames))
        let stream = try DDPStreamInspector.inspect(output)
        #expect(stream.crcFailures == 0)
        #expect(stream.atmosFrames == report.accessUnits)
        #expect(stream.sampleCount == report.encodedSamples)
      }
    }
  }

  @Test func localEnvelopeRecoversAndWorkersRemainByteIdentical() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let frames = 48000
    var pcm = [Float](repeating: 0, count: frames * 2)
    for f in 0..<frames {
      let amplitude = (8000..<10000).contains(f) ? 0.99 : 0.1
      pcm[f * 2] = Float(amplitude * sin(Double(f) * .pi / 2 + .pi / 4))
      pcm[f * 2 + 1] = pcm[f * 2] * 0.5
    }
    let input = root.appendingPathComponent("local.wav")
    try wave(pcm, rate: 48000, channels: 2, at: input)
    let one = root.appendingPathComponent("one.ec3")
    let four = root.appendingPathComponent("four.ec3")
    var options = DDPFileOptions(configuration: .init(layout: .stereo, threads: 1))
    let serial = try DDPFileEncoder.encode(input: input, output: one, options: options)
    options.configuration.threads = 4
    options.loudnessMode = .off
    let parallel = try DDPFileEncoder.encode(input: input, output: four, options: options)
    #expect(try Data(contentsOf: one) == Data(contentsOf: four))
    #expect(serial.truePeak?.limited == true)
    #expect(
      serial.truePeak?.reconstructedTruePeakDBTP == parallel.truePeak?.reconstructedTruePeakDBTP)

    let feedback = try DDPTruePeakFeedback(ceilingDBTP: -2.5, directory: root)
    for unit in 0..<40 {
      try feedback.observe([[Double](repeating: unit == 10 ? 1 : 0.1, count: 1536)])
    }
    #expect(try feedback.finish(units: 40, isCancelled: { false }) == false)
    #expect(try feedback.envelope(at: 0, frames: 1536, sampleRate: 48000)!.allSatisfy { $0 == 1 })
    #expect(try feedback.envelope(at: 30, frames: 1536, sampleRate: 48000)!.allSatisfy { $0 == 1 })
    var previous: Double?
    for unit in 0..<40 {
      for gain in try feedback.envelope(at: UInt64(unit), frames: 1536, sampleRate: 48000)! {
        #expect(gain <= 1 && gain > 0)
        if let previous {
          #expect(gain - previous <= 1 / 4800.0 + 1e-12)
          #expect(previous - gain <= 1 / 1024.0 + 1e-12)
        }
        previous = gain
      }
    }
  }
}
