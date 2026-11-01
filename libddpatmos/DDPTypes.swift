// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

public enum DDPError: Error, CustomStringConvertible, Sendable {
  case invalidConfiguration(String)
  case malformedInput(String)
  case unsupported(String)
  case io(String)
  public var description: String {
    switch self {
    case .invalidConfiguration(let s), .malformedInput(let s), .unsupported(let s), .io(let s):
      return s
    }
  }
}

public enum DDPDownmixMode: String, Sendable, Codable {
  case ltrt = "LTRT"
  case loro = "LORO"
}

/// Physical order is WAVE order. The bitstream writer performs the AC-3 reorder.
public enum DDPChannelLayout: String, Sendable, Codable, CaseIterable {
  case stereo = "2.0"
  case twoOne = "2.1"
  case three = "3.0"
  case threeOne = "3.1"
  case quad = "4.0"
  case quadOne = "4.1"
  case five = "5.0"
  case fiveOne = "5.1"
  case six = "6.0"
  case sixOne = "6.1"
  case seven = "7.0"
  case sevenOne = "7.1"
  public var channels: Int {
    switch self {
    case .stereo: 2
    case .twoOne, .three: 3
    case .threeOne, .quad: 4
    case .quadOne, .five: 5
    case .fiveOne, .six: 6
    case .sixOne, .seven: 7
    case .sevenOne: 8
    }
  }
  var acmod: Int {
    switch self {
    case .stereo, .twoOne: 2
    case .three, .threeOne: 3
    case .quad, .quadOne: 6
    default: 7
    }
  }
  public var lfeChannel: Int? {
    switch self {
    case .twoOne, .quadOne: 2
    case .threeOne, .fiveOne, .sixOne, .sevenOne: 3
    default: nil
    }
  }
  var hasLFE: Bool { lfeChannel != nil }
  var codedOrder: [Int] {
    switch self {
    case .stereo: [0, 1]
    case .twoOne: [0, 1, 2]
    case .three: [0, 2, 1]
    case .threeOne: [0, 2, 1, 3]
    case .quad: [0, 1, 2, 3]
    case .quadOne: [0, 1, 3, 4, 2]
    case .five: [0, 2, 1, 3, 4]
    case .fiveOne: [0, 2, 1, 4, 5, 3]
    case .six: [0, 2, 1, 4, 5]
    case .sixOne: [0, 2, 1, 5, 6, 3]
    case .seven: [0, 2, 1, 5, 6]
    case .sevenOne: [0, 2, 1, 6, 7, 3]
    }
  }
  var extensionProfile: (layout: DDPChannelLayout, map: Int, sources: [Int])? {
    switch self {
    case .sevenOne: (.quad, 0x1a00, [6, 7, 4, 5])
    case .seven: (.quad, 0x1a00, [5, 6, 3, 4])
    case .sixOne: (.three, 0x1900, [5, 4, 6])
    case .six: (.three, 0x1900, [4, 3, 5])
    default: nil
    }
  }
  var compatibilityPairs: [Int: Int] {
    switch self {
    case .sevenOne: [6: 4, 7: 5]
    case .seven: [5: 3, 6: 4]
    case .sixOne: [5: 4, 6: 4]
    case .six: [4: 3, 5: 3]
    default: [:]
    }
  }
}

public struct DDPConfiguration: Sendable, Codable {
  /// Total elementary stream bitrate in kbit/s, including dependent substreams and metadata.
  public var bitrate: Int = 768
  public var downmixMode: DDPDownmixMode = .ltrt
  /// Bitstream metadata only. -31 requests no dialnorm attenuation at playback.
  public var dialogueLevel: Int = -31
  public var sampleRate: Int = 48_000
  public var layout: DDPChannelLayout = .fiveOne
  /// Zero selects up to eight active CPUs; one selects serial execution.
  public var threads: Int = 0
  var resolvedThreads: Int {
    threads == 0 ? min(8, ProcessInfo.processInfo.activeProcessorCount) : threads
  }
  public init(
    bitrate: Int = 768, downmixMode: DDPDownmixMode = .ltrt,
    dialogueLevel: Int = -31, sampleRate: Int = 48_000, layout: DDPChannelLayout = .fiveOne
  ) {
    self.init(
      bitrate: bitrate, downmixMode: downmixMode, dialogueLevel: dialogueLevel,
      sampleRate: sampleRate, layout: layout, threads: 0)
  }
  public init(
    bitrate: Int = 768, downmixMode: DDPDownmixMode = .ltrt,
    dialogueLevel: Int = -31, sampleRate: Int = 48_000, layout: DDPChannelLayout = .fiveOne,
    threads: Int
  ) {
    self.bitrate = bitrate
    self.downmixMode = downmixMode
    self.dialogueLevel = dialogueLevel
    self.sampleRate = sampleRate
    self.layout = layout
    self.threads = threads
  }
  private enum CodingKeys: String, CodingKey {
    case bitrate, downmixMode, dialogueLevel, sampleRate, layout, threads
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    bitrate = try c.decode(Int.self, forKey: .bitrate)
    downmixMode = try c.decode(DDPDownmixMode.self, forKey: .downmixMode)
    dialogueLevel = try c.decode(Int.self, forKey: .dialogueLevel)
    sampleRate = try c.decode(Int.self, forKey: .sampleRate)
    layout = try c.decode(DDPChannelLayout.self, forKey: .layout)
    threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? 0
  }
  func validate() throws {
    guard (0...128).contains(threads) else {
      throw DDPError.invalidConfiguration("Threads must be 0 (automatic) through 128")
    }
    guard [32_000, 44_100, 48_000].contains(sampleRate) else {
      throw DDPError.invalidConfiguration("DDP sample rate must be 32000, 44100 or 48000 Hz")
    }
    guard (96...1024).contains(bitrate) else {
      throw DDPError.invalidConfiguration("Bitrate must be 96...1024 kbit/s")
    }
    guard (-31 ... -1).contains(dialogueLevel) else {
      throw DDPError.invalidConfiguration("Dialnorm must be -31...-1")
    }
  }
}

public struct DDPEncodingReport: Sendable, Codable {
  public let inputSamples: UInt64
  public let encodedSamples: UInt64
  public let bytes: UInt64
  public let accessUnits: UInt64
  public let sampleRate: Int
  public let channels: Int
  public let atmos: Bool
  public var elapsedSeconds: Double? = nil
  public var preparationSeconds: Double? = nil
  public var encodingSeconds: Double? = nil
  public var workerLimit: Int? = nil
  public var metadataIndexBytes: UInt64? = nil
  public var dialogueLevel: Int? = nil
  public var loudness: DDPLoudnessReport? = nil
}
