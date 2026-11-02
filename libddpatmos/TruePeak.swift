// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Accelerate
import Foundation

public struct DDPTruePeakReport: Sendable, Codable {
  public let ceilingDBTP: Double
  public let reconstructedTruePeakDBTP: Double?
  public let limited: Bool
  public let encodingPasses: Int
  public let presentation: String
}

/// Streaming 16x, 256-tap windowed-sinc interpolation. Integer samples are also
/// tested. History is per channel and survives AU boundaries; finish includes
/// the interpolation tail. PCM is never resampled in the actual encoding path.
struct DDPTruePeakMeter {
  private static let filters: [[Double]] = (1..<16).map { phase in
    let fraction = Double(phase) / 16
    let taps = (-127...128).map { k -> Double in
      let x = Double(k) - fraction
      let sinc = sin(.pi * x) / (.pi * x)
      let angle = .pi * x / 128
      return sinc * (0.42 + 0.5 * cos(angle) + 0.08 * cos(2 * angle))
    }
    let sum = taps.reduce(0, +)
    return taps.map { $0 / sum }
  }
  private var history = [[Double]]()
  private(set) var maximum = 0.0

  mutating func consume(_ channels: [[Double]]) -> Double {
    guard let frames = channels.first?.count, frames > 0 else { return 0 }
    if history.isEmpty {
      history = channels.map { _ in [Double](repeating: 0, count: 256) }
    }
    precondition(history.count == channels.count && channels.allSatisfy { $0.count == frames })
    var peak = 0.0
    for c in channels.indices {
      let samples = history[c] + channels[c]
      peak = max(peak, channels[c].reduce(0) { max($0, abs($1)) })
      var interpolated = [Double](repeating: 0, count: frames)
      samples.withUnsafeBufferPointer { input in
        for filter in Self.filters {
          filter.withUnsafeBufferPointer { taps in
            interpolated.withUnsafeMutableBufferPointer { output in
              vDSP_convD(
                input.baseAddress!, 1, taps.baseAddress!, 1,
                output.baseAddress!, 1, vDSP_Length(frames), 256)
            }
          }
          var p = 0.0
          vDSP_maxmgvD(interpolated, 1, &p, vDSP_Length(frames))
          peak = max(peak, p)
        }
      }
      history[c] = Array(samples.suffix(256))
    }
    maximum = max(maximum, peak)
    return peak
  }

  mutating func finish() -> Double {
    consume(history.map { _ in [Double](repeating: 0, count: 256) })
  }
}

/// Fixed-width gain/peak records keep feedback independent of programme length.
/// Every retry is a continuous encode from the original source, with fresh
/// transform, spatial, sequence and authentication state. No AUs are spliced.
final class DDPTruePeakFeedback {
  let ceilingDBTP: Double
  let ceiling: Double
  private let directory: DDPScratchDirectory
  private var gains: DDPRecordFile?
  private var peaks: DDPRecordFile
  private var meter = DDPTruePeakMeter()
  private var pass = 0
  private(set) var limited = false
  private var unit: UInt64 = 0

  init(ceilingDBTP: Double, directory: URL) throws {
    guard ceilingDBTP.isFinite, (-60...0).contains(ceilingDBTP) else {
      throw DDPError.invalidConfiguration(
        "True peak limiter must be finite and within -60...0 dBTP")
    }
    self.ceilingDBTP = ceilingDBTP
    ceiling = pow(10, ceilingDBTP / 20)
    self.directory = try DDPScratchDirectory(parent: directory)
    peaks = try DDPRecordFile(directory: self.directory, name: "peaks-0", width: 8)
  }

  private func append(_ value: Double, to file: DDPRecordFile) throws {
    let word = value.bitPattern
    try file.append((0..<8).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) })
  }
  private func read(_ file: DDPRecordFile, _ index: UInt64) throws -> Double {
    Double(bitPattern: BinaryIO.integer(try file.record(index), 0, 8))
  }

  /// The time envelope is linked across all channels. Unity is exact until an
  /// actual reconstructed output violation creates a correction. Attack and
  /// release extend locally around that correction, never over the whole file.
  func envelope(at index: UInt64, frames: Int, sampleRate: Int) throws -> [Double]? {
    guard let gains else { return nil }
    let attack = Double(sampleRate) * 0.0213333333333333
    let release = Double(sampleRate) * 0.1
    let past = UInt64(ceil(release / Double(frames))) + 1
    let future = UInt64(ceil(attack / Double(frames))) + 1
    let first = index > past ? index - past : 0
    let last = min(gains.count - 1, index + future)
    var result = [Double](repeating: 1, count: frames)
    for nearby in first...last {
      let target = try read(gains, nearby)
      if target == 1 { continue }
      // Subtract in integer space before conversion, even for long programmes.
      let difference = nearby >= index ? Double(nearby - index) : -Double(index - nearby)
      let offset = difference * Double(frames)
      for f in 0..<frames {
        let distance: Double
        if Double(f) < offset {
          distance = (offset - Double(f)) / attack
        } else if Double(f) >= offset + Double(frames) {
          distance = (Double(f) - offset - Double(frames) + 1) / release
        } else {
          distance = 0
        }
        result[f] = min(result[f], target + distance)
      }
    }
    return result
  }

  func observe(_ channels: [[Double]]) throws {
    let peak = meter.consume(channels)
    try append(peak, to: peaks)
    unit += 1
  }

  /// A pass is accepted only after its coding and interpolator tails pass.
  /// The margin is applied only to offending neighbourhoods, to cover decoder
  /// arithmetic and interpolation differences, not as a fixed input pad.
  func finish(units: UInt64, isCancelled: () -> Bool) throws -> Bool {
    precondition(unit == units)
    try append(meter.finish(), to: peaks)
    try peaks.seal()
    if meter.maximum <= ceiling { return true }
    guard pass < 11 else {
      throw DDPError.invalidConfiguration(
        "True peak feedback did not converge; output was not published")
    }
    let corrected = try DDPRecordFile(directory: directory, name: "gain-\(pass)", width: 8)
    for i in 0..<units {
      if i % 1024 == 0, isCancelled() { throw CancellationError() }
      var peak = 0.0
      // Synthesis delays by 256 samples; interpolation by 129. Include both
      // adjacent AUs so changes cannot strand a peak at an immutable boundary.
      for j in (i == 0 ? 0 : i - 1)...min(peaks.count - 1, i + 1) {
        peak = max(peak, try read(peaks, j))
      }
      let old = try gains.map { try read($0, i) } ?? 1
      let correction = peak > ceiling ? ceiling / peak * pow(10, -0.15 / 20) : 1
      try append(old * correction, to: corrected)
    }
    try corrected.seal()
    gains = corrected
    limited = true
    pass += 1
    peaks = try DDPRecordFile(directory: directory, name: "peaks-\(pass)", width: 8)
    meter = .init()
    unit = 0
    return false
  }

  func report(atmos: Bool) -> DDPTruePeakReport {
    .init(
      ceilingDBTP: ceilingDBTP,
      reconstructedTruePeakDBTP: meter.maximum > 0 ? 20 * log10(meter.maximum) : nil,
      limited: limited, encodingPasses: pass + 1,
      presentation: atmos
        ? "EC3 5.1 compatibility presentation, including LFE"
        : "EC3 independent and dependent channels, including LFE")
  }
}
