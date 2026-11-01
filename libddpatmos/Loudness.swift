// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

public enum DDPLoudnessMode: String, Sendable, Codable {
  case measure
  case off
}

public struct DDPLoudnessReport: Sendable, Codable {
  public enum Status: String, Sendable, Codable {
    case measured, insufficientDuration, belowAbsoluteGate
  }
  public let mode: DDPLoudnessMode
  public let status: Status
  /// Programme loudness, without dialogue isolation. Nil when no gated block exists.
  public let integratedLUFS: Double?
  /// Includes LFE; this is a sample peak, not an oversampled true peak.
  public let samplePeakDBFS: Double?
  public let measuredSamples: UInt64
  public let measurementLayout: DDPChannelLayout
  public let presentation: String
  public let channelEnergyWeights: [Double]
  /// Loudness measurement never applies a normalization gain.
  public let normalizationGainDB: Double
}

/// K-weighted programme measurement uses complete 400-ms blocks at 100-ms hops.
/// Two gating passes read eight-byte energies from disk, keeping RAM bounded.
final class DDPLoudnessMeter {
  private struct Biquad {
    let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    mutating func process(_ x: Double) -> Double {
      let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
      x2 = x1
      x1 = x
      y2 = y1
      y1 = y
      return y
    }
  }
  private let records: DDPRecordFile
  private let layout: DDPChannelLayout
  private let presentation: String
  private let weights: [Double]
  private let hop: Int
  private var shelf: [Biquad]
  private var highpass: [Biquad]
  private var samples: UInt64 = 0
  private var peak = 0.0
  private var hopSamples = 0
  private var hopEnergy = 0.0
  private var recent = [Double](repeating: 0, count: 4)
  private var completedHops: UInt64 = 0

  init(sampleRate: Int, layout: DDPChannelLayout, atmos: Bool, directory: URL) throws {
    self.layout = layout
    presentation = atmos ? "Atmos 5.1 compatibility downmix before coding" : "Source PCM"
    hop = sampleRate / 10
    var weights = [Double](repeating: 1, count: layout.channels)
    if let lfe = layout.lfeChannel { weights[lfe] = 0 }
    let surround: [Int]
    switch layout {
    case .stereo, .twoOne, .three, .threeOne: surround = []
    case .quad: surround = [2, 3]
    case .quadOne, .five: surround = [3, 4]
    case .fiveOne, .six: surround = [4, 5]
    case .sixOne, .seven: surround = [5, 6]
    case .sevenOne: surround = [6, 7]
    }
    for channel in surround { weights[channel] = 1.41 }
    self.weights = weights
    let scratch = try DDPScratchDirectory(parent: directory)
    records = try DDPRecordFile(directory: scratch, name: "loudness", width: 8)

    // Bilinear K-weighting sections retain the prescribed high-pass numerator.
    let k = tan(.pi * 1681.974450955533 / Double(sampleRate))
    let q = 0.7071752369554196
    let highGain = pow(10, 3.999843853973347 / 20)
    let middleGain = pow(highGain, 0.4996667741545416)
    let divisor = 1 + k / q + k * k
    let s = Biquad(
      b0: (highGain + middleGain * k / q + k * k) / divisor,
      b1: 2 * (k * k - highGain) / divisor,
      b2: (highGain - middleGain * k / q + k * k) / divisor,
      a1: 2 * (k * k - 1) / divisor, a2: (1 - k / q + k * k) / divisor)
    let h = tan(.pi * 38.13547087602444 / Double(sampleRate))
    let d = 1 + h / 0.5003270373238773 + h * h
    let p = Biquad(b0: 1, b1: -2, b2: 1,
                   a1: 2 * (h * h - 1) / d,
                   a2: (1 - h / 0.5003270373238773 + h * h) / d)
    shelf = Array(repeating: s, count: layout.channels)
    highpass = Array(repeating: p, count: layout.channels)
  }

  func consume(_ pcm: [Float], frames: Int) throws {
    guard frames >= 0, frames <= pcm.count / layout.channels else {
      throw DDPError.invalidConfiguration("Invalid loudness PCM extent")
    }
    guard UInt64(frames) <= UInt64.max - samples else {
      throw DDPError.invalidConfiguration("Loudness sample count overflow")
    }
    for frame in 0..<frames {
      for channel in weights.indices {
        let x = Double(pcm[frame * layout.channels + channel])
        guard x.isFinite else { throw DDPError.malformedInput("Non-finite loudness PCM") }
        peak = max(peak, abs(x))
        if weights[channel] == 0 { continue }
        let shaped = shelf[channel].process(x)
        let filtered = highpass[channel].process(shaped)
        hopEnergy += weights[channel] * filtered * filtered
      }
      hopSamples += 1
      if hopSamples == hop {
        recent[Int(completedHops % 4)] = hopEnergy
        completedHops += 1
        if completedHops >= 4 {
          let energy = recent.reduce(0, +) / Double(hop * 4)
          let bits = energy.bitPattern
          try records.append((0..<8).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
        }
        hopSamples = 0
        hopEnergy = 0
      }
    }
    samples += UInt64(frames)
  }

  func finish(isCancelled: () -> Bool) throws -> DDPLoudnessReport {
    try records.seal()
    let absoluteGate = pow(10, (-70 + 0.691) / 10)
    func average(above threshold: Double) throws -> Double? {
      var sum = 0.0
      var count: UInt64 = 0
      for i in 0..<records.count {
        if i % 1024 == 0, isCancelled() { throw CancellationError() }
        let energy = Double(bitPattern: BinaryIO.integer(try records.record(i), 0, 8))
        if energy >= threshold {
          sum += energy
          count += 1
        }
      }
      return count > 0 ? sum / Double(count) : nil
    }
    let absoluteMean = try average(above: absoluteGate)
    let gatedMean = try absoluteMean.flatMap { try average(above: max(absoluteGate, $0 * 0.1)) }
    return .init(
      mode: .measure,
      status: records.count == 0 ? .insufficientDuration
        : (gatedMean == nil ? .belowAbsoluteGate : .measured),
      integratedLUFS: gatedMean.map { -0.691 + 10 * log10($0) },
      samplePeakDBFS: peak > 0 ? 20 * log10(peak) : nil,
      measuredSamples: samples, measurementLayout: layout, presentation: presentation,
      channelEnergyWeights: weights, normalizationGainDB: 0)
  }
}
