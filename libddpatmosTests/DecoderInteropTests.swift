// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import Testing

@testable import libddpatmos

struct DecoderInteropTests {
  private static let decoder = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first {
    FileManager.default.isExecutableFile(atPath: $0)
  }

  @Test(.enabled(if: decoder != nil, "DDP interoperability testing requires an independent decoder"))
  func allPhysicalChannelsDecodeIndependently() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    for rate in [32_000, 44_100, 48_000] {
      for layout in DDPChannelLayout.allCases {
        let encoder = try DDPEncoder(configuration: .init(sampleRate: rate, layout: layout))
        var stream = Data()
        for block in 0..<5 {
          var pcm = [Float]()
          pcm.reserveCapacity(encoder.inputFrameCount * layout.channels)
          for frame in 0..<encoder.inputFrameCount {
            for channel in 0..<layout.channels {
              let hz = layout.lfeChannel == channel ? 60 : 200 + channel * 100
              let sample = block * encoder.inputFrameCount + frame
              pcm.append(Float(0.1 * sin(2 * .pi * Double(hz * sample) / Double(rate))))
            }
          }
          stream.append(try encoder.encode(pcm))
        }
        let input = directory.appendingPathComponent("signal.ec3")
        let errorURL = directory.appendingPathComponent("decoder.log")
        try stream.write(to: input)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorURL)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: Self.decoder!)
        process.arguments = [
          "-v", "error", "-err_detect", "explode", "-i", input.path, "-f", "f32le", "-",
        ]
        process.standardOutput = pipe
        process.standardError = errors
        try process.run()
        let decoded = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try errors.close()
        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: errorURL).isEmpty)
        let samples = decoded.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let frames = samples.count / layout.channels
        #expect(frames == 5 * encoder.inputFrameCount)
        for channel in 0..<layout.channels {
          let hz = layout.lfeChannel == channel ? 60 : 200 + channel * 100
          var power = 0.0
          var error = 0.0
          var correlation = 0.0
          // Measure steady-state routing after startup and the first frame's
          // shared exponent envelope; transient lossy coding is a separate metric.
          for frame in 2048..<frames {
            let expected = 0.1 * sin(2 * .pi * Double(hz * (frame - 256)) / Double(rate))
            let actual = Double(samples[frame * layout.channels + channel])
            power += expected * expected
            error += (actual - expected) * (actual - expected)
            correlation += actual * expected
          }
          let gain = correlation / power
          let snr = 10 * log10(power / max(error, 1e-30))
          #expect(
            gain > 0.99 && gain < 1.01,
            "\(rate) Hz \(layout.rawValue) channel \(channel), gain \(gain)")
          #expect(snr > 35, "\(rate) Hz \(layout.rawValue) channel \(channel), SNR \(snr)")
        }
      }
    }
  }

  @Test func audioAuthenticationTracksHeaderChanges() throws {
    let object = AtmosMetadataCoding.oamd([.init(x: 0, y: 1, z: 1)])
    let matrix = [[[1.0], [0.0], [0.0], [0.0], [0.0]]]
    let metadata = EMDFProtection.wrap([
      (11, object), (14, AtmosMetadataCoding.joc(matrix, sequence: 0, bandIndex: 0)),
    ])
    let pcm = [Float](repeating: 0, count: 9216)
    let first = try DDPEncoder(configuration: .init(dialogueLevel: -31)).encode(
      pcm, emdf: metadata, complexity: 2)
    let second = try DDPEncoder(configuration: .init(dialogueLevel: -30)).encode(
      pcm, emdf: metadata, complexity: 2)
    let a = try #require(EMDFContainer.find(Array(first)))
    let b = try #require(EMDFContainer.find(Array(second)))
    #expect(a.payloads[0].1 == b.payloads[0].1)
    #expect(a.primary != b.primary)
    #expect(DDPCRC.crc16(first.dropFirst(2)) == 0)
    #expect(DDPCRC.crc16(second.dropFirst(2)) == 0)
  }
}
