// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import Testing

@testable import libddpatmos

struct ParallelTests {
  @Test func ordinarySerialAndParallelFramesAreIdentical() throws {
    for rate in [32000, 44100, 48000] {
      for layout in [DDPChannelLayout.stereo, .sevenOne] {
        let serial = try DDPEncoder(
          configuration: .init(sampleRate: rate, layout: layout, threads: 1))
        let parallel = try DDPEncoder(
          configuration: .init(sampleRate: rate, layout: layout, threads: 4))
        for unit in 0..<3 {
          let pcm = (0..<(serial.inputFrameCount * layout.channels)).map { i in
            Float(0.1 * sin(Double(i + unit * 937) * 0.019))
          }
          #expect(try serial.encode(pcm) == parallel.encode(pcm))
        }
      }
    }
  }
  @Test func atmosphericStateAndAuthenticationAreWorkerIndependent() throws {
    let events = (0..<8).map { i in
      DDPPositionEvent(
        sample: UInt64(i * 1536),
        position: .init(x: Double(i % 3) - 1, y: 0.4, z: 0.7), gain: 0.8)
    }
    let source = DDPSourceInfo(
      sampleRate: 48000, channelCount: 1, sampleCount: 1536 * 8,
      channelMask: 0, channels: [.init(id: 10, events: events)])
    let serial = try AtmosDDPEncoder(
      source: source, configuration: .init(threads: 1), elements: 16, mode: .dynamic)
    let parallel = try AtmosDDPEncoder(
      source: source, configuration: .init(threads: 4), elements: 16, mode: .dynamic)
    for unit in 0..<8 {
      let pcm = (0..<1536).map { Float(0.2 * sin(Double(unit * 1536 + $0) * 0.037)) }
      #expect(
        try serial.encode(pcm, at: UInt64(unit * 1536))
          == parallel.encode(pcm, at: UInt64(unit * 1536)))
    }
    #expect(try serial.finish() == parallel.finish())
  }
  @Test func oldConfigurationJSONDefaultsToAutomaticWorkers() throws {
    let data = try JSONEncoder().encode(DDPConfiguration())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "threads")
    let old = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(DDPConfiguration.self, from: old).threads == 0)
  }
}
