// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import Testing

@testable import libddpatmos

struct SpatialTransitionTests {
  private func source(_ events: [DDPPositionEvent], label: String? = nil) -> DDPSourceInfo {
    .init(
      sampleRate: 48000, channelCount: 1, sampleCount: 48 * 1536, channelMask: 0,
      channels: [.init(id: 10, label: label, events: events)])
  }

  @Test func roomBasisHasContinuousSharedEdges() {
    for count in [11, 13, 15] {
      let panner = AtmosRoomPanner(elements: count)
      for x in [-1.0, -0.5, 0, 0.5, 1] {
        for y in [-1.0, -0.5, 0, 0.65, 1] {
          for z in [0.0, 0.5, 1] {
            for spread in [0.0, 0.5, 1] {
              let point = DDPPosition(x: x, y: y, z: z)
              let a = panner.gains(at: point, spread: spread)
              #expect(abs(a.reduce(0) { $0 + $1 * $1 } - 1) < 1e-12)
              for axis in 0..<3 {
                var next = point
                if axis == 0 { next.x += 1e-7 }
                if axis == 1 { next.y += 1e-7 }
                if axis == 2 { next.z += 1e-7 }
                let b = panner.gains(at: next, spread: spread)
                #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 })
              }
            }
          }
        }
      }
      let floor = panner.gains(at: .init(x: 0.3, y: -0.2, z: 0))
      for i in floor.indices where panner.anchors[i].z > 0 { #expect(floor[i] == 0) }
    }
  }

  @Test func movingSustainedObjectHasNoFrameSteps() throws {
    let events = (0..<48).map {
      DDPPositionEvent(
        sample: UInt64($0 * 1536),
        position: .init(x: $0 < 16 ? -0.6 : $0 < 32 ? 0.6 : -0.6, y: 0.3, z: 0.4))
    }
    for count in [11, 13, 15] {
      for mode in [DDPObjectMode.dynamic, .channelbase] {
        let renderer = AtmosSpatialRenderer(source: source(events), elements: count, mode: mode)
        var priorCore: [Double]?
        var priorElements: [Double]?
        var maximumStep = 0.0
        for unit in 0..<48 {
          let frame = try renderer.render(
            [Float](repeating: 0.2, count: 1536), at: UInt64(unit * 1536))
          for f in 0..<1536 {
            for c in 0..<5 {
              if let previous = f > 0 ? frame.downmix[c][f - 1] : priorCore?[c] {
                maximumStep = max(maximumStep, abs(frame.downmix[c][f] - previous))
              }
            }
            for k in 0..<count {
              if let previous = f > 0 ? frame.elements[k][f - 1] : priorElements?[k] {
                maximumStep = max(maximumStep, abs(frame.elements[k][f] - previous))
              }
            }
          }
          priorCore = frame.downmix.map { $0.last! }
          priorElements = frame.elements.map { $0.last! }
        }
        #expect(maximumStep < 0.001, "\(count) elements, \(mode): \(maximumStep)")
      }
    }
  }

  @Test func objectAndLFEGainUpdatesAreContinuous() throws {
    let events = [
      DDPPositionEvent(sample: 0, position: .init(x: -1, y: 1, z: 0), gain: 0),
      DDPPositionEvent(sample: 1536, position: .init(x: -1, y: 1, z: 0), gain: 1),
      DDPPositionEvent(sample: 3072, position: .init(x: -1, y: 1, z: 0), gain: 0),
    ]
    for label in [nil, "LFE"] as [String?] {
      let renderer = AtmosSpatialRenderer(
        source: source(events, label: label), elements: 15, mode: .channelbase)
      var previous = 0.0
      for unit in 0..<4 {
        let frame = try renderer.render(
          [Float](repeating: 0.2, count: 1536), at: UInt64(unit * 1536))
        let samples = label == nil ? frame.elements[0] : frame.lfe
        for sample in samples {
          #expect(abs(sample - previous) <= 0.2 / 1536 + 1e-10)
          previous = sample
        }
      }
    }
  }

  @Test func limiterPlansAcrossFramesWithoutGainSteps() {
    func frame(_ unit: Int) -> AtmosSpatialFrame {
      var core = Array(repeating: [Double](repeating: 0.25, count: 1536), count: 5)
      if unit == 1 { core[1][10] = 10 }
      if unit == 3 { core[2][1500] = -4 }
      return .init(
        elements: [], downmix: core, lfe: .init(repeating: 0.1, count: 1536), positions: [])
    }
    var limiter = AtmosLookaheadLimiter()
    var previous: Double?
    for unit in 0..<6 {
      let result = limiter.process(frame(unit), next: unit < 5 ? frame(unit + 1) : nil)
      #expect(result.downmix.joined().allSatisfy { abs($0) <= 0.980000001 })
      #expect(result.lfe.allSatisfy { $0 == 0.1 })
      for sample in result.downmix[0] {
        let gain = sample / 0.25
        if let previous {
          #expect(gain - previous <= AtmosLookaheadLimiter.releaseStep + 1e-12)
          #expect(previous - gain <= AtmosLookaheadLimiter.attackStep + 1e-12)
        }
        previous = gain
      }
    }
  }

  @Test func lookaheadFlushPreservesEveryAccessUnit() throws {
    for count in [12, 14, 16] {
      for bitrate in [384, 1024] {
        let encoder = try AtmosDDPEncoder(
          source: source([.init(sample: 0, position: .init(x: -0.4, y: 0.5, z: 0.6))]),
          configuration: .init(bitrate: bitrate), elements: count, mode: .dynamic)
        var stream = Data()
        for unit in 0..<3 {
          let data = try encoder.encode(
            [Float](repeating: 0.1, count: 1536), at: UInt64(unit * 1536))
          #expect(data.isEmpty == (unit == 0))
          stream.append(data)
        }
        stream.append(try encoder.finish())
        #expect(try encoder.finish().isEmpty)
        let frameBytes = bitrate * 4
        #expect(stream.count == 3 * frameBytes)
        for unit in 0..<3 {
          let frame = Array(stream[(unit * frameBytes)..<((unit + 1) * frameBytes)])
          #expect(DDPCRC.crc16(frame.dropFirst(2)) == 0)
          let container = try #require(EMDFContainer.find(frame))
          #expect(container.payloads.map { $0.0 } == [11, 14])
        }
      }
    }
  }
}
