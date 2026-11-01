// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

public struct DDPFileOptions: Sendable {
  public var configuration: DDPConfiguration
  public var layout: DDPChannelLayout?
  public var spatialElements: Int = 16
  public var objectMode: DDPObjectMode = .dynamic
  public var start: Double = 0
  public var duration: Double?
  public init(configuration: DDPConfiguration = .init(), layout: DDPChannelLayout? = nil) {
    self.configuration = configuration
    self.layout = layout
  }
}

public enum DDPFileEncoder {
  /// Writes on the caller's executor. The progress callback is synchronous.
  /// Cancellation/failure removes the newly created partial file; publication
  /// refuses to replace an existing destination.
  public static func encode(
    input: URL, output: URL, options: DDPFileOptions = .init(),
    progress: ((UInt64, UInt64) -> Void)? = nil,
    isCancelled: () -> Bool = { false }
  ) throws -> DDPEncodingReport {
    let jobStart = DispatchTime.now().uptimeNanoseconds
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw DDPError.io("Output already exists: \(output.path)")
    }
    let source = try DDPMasterSource.open(
      input,
      workingDirectory: output.deletingLastPathComponent(), isCancelled: isCancelled)
    let info = source.info
    guard options.start.isFinite, options.start >= 0, options.start <= info.duration else {
      throw DDPError.invalidConfiguration("Start is outside input")
    }
    if let duration = options.duration {
      guard duration.isFinite, duration > 0 else {
        throw DDPError.invalidConfiguration("Duration must be positive")
      }
    }
    var configuration = options.configuration
    configuration.sampleRate = info.sampleRate
    if !info.isAtmos {
      let layout: DDPChannelLayout
      if let chosen = options.layout {
        layout = chosen
      } else if info.channelMask != 0 {
        let masks: [UInt32: DDPChannelLayout] = [
          0x3: .stereo, 0xb: .twoOne, 0x7: .three, 0xf: .threeOne,
          0x33: .quad, 0x603: .quad, 0x3b: .quadOne, 0x60b: .quadOne,
          0x37: .five, 0x607: .five, 0x3f: .fiveOne, 0x60f: .fiveOne,
          0x707: .six, 0x70f: .sixOne, 0x637: .seven, 0x63f: .sevenOne,
        ]
        guard let known = masks[info.channelMask] else {
          throw DDPError.unsupported(
            "Unsupported WAVE channel mask \(String(info.channelMask,radix:16)); select an explicit --layout only when its physical order is known"
          )
        }
        layout = known
      } else {
        switch info.channelCount {
        case 2: layout = .stereo
        case 3: layout = .three
        case 4: layout = .quad
        case 5: layout = .five
        case 6: layout = .fiveOne
        case 7:
          throw DDPError.invalidConfiguration(
            "Unlabelled seven-channel PCM requires --layout 6.1 or 7.0")
        case 8: layout = .sevenOne
        default:
          throw DDPError.unsupported(
            "Ordinary PCM layout cannot be inferred from \(info.channelCount) channels")
        }
      }
      guard layout.channels == info.channelCount else {
        throw DDPError.invalidConfiguration("Selected layout does not match input channel count")
      }
      configuration.layout = layout
    }
    try configuration.validate()
    let plain = info.isAtmos ? nil : try DDPEncoder(configuration: configuration)
    let atmos =
      info.isAtmos
      ? try AtmosDDPEncoder(
        source: info, configuration: configuration, elements: options.spatialElements,
        mode: options.objectMode, metadata: { try source.metadata(at: $0) }) : nil
    let start = UInt64((options.start * Double(info.sampleRate)).rounded())
    let remaining = info.sampleCount - start
    let wanted =
      options.duration.map {
        UInt64(min(Double(remaining), ($0 * Double(info.sampleRate)).rounded()))
      } ?? remaining
    guard wanted > 0 else { throw DDPError.invalidConfiguration("Selected input range is empty") }
    try source.seek(to: start)
    let partial = output.deletingLastPathComponent().appendingPathComponent(
      ".\(output.lastPathComponent).\(UUID().uuidString).partial")
    guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
      throw DDPError.io("Cannot create output in \(partial.deletingLastPathComponent().path)")
    }
    let file = try FileHandle(forWritingTo: partial)
    var published = false
    defer {
      try? file.close()
      if !published { try? FileManager.default.removeItem(at: partial) }
    }
    var consumed: UInt64 = 0
    var units: UInt64 = 0
    var bytes: UInt64 = 0
    let frameSize = plain?.inputFrameCount ?? 1536
    // Include the 256-sample lapped-transform tail. A raw EC3 stream has no
    // container edit list, so report padding separately from source samples.
    let requiredUnits = (wanted + 256 + UInt64(frameSize - 1)) / UInt64(frameSize)
    let encodeStart = DispatchTime.now().uptimeNanoseconds
    while units < requiredUnits {
      try autoreleasepool {
        if isCancelled() { throw CancellationError() }
        let n = Int(min(UInt64(frameSize), wanted - consumed))
        var pcm = n > 0 ? try source.read(frameCount: n) : []
        guard pcm.count == n * info.channelCount else {
          throw DDPError.io("Input became shorter while encoding")
        }
        pcm.append(contentsOf: repeatElement(Float(0), count: (frameSize - n) * info.channelCount))
        let data: Data
        if let plain {
          data = try plain.encode(pcm)
        } else {
          data = try atmos!.encode(pcm, at: start + consumed)
        }
        try file.write(contentsOf: data)
        consumed += UInt64(n)
        units += 1
        bytes += UInt64(data.count)
        if units % 64 == 0 { try file.synchronize() }
        progress?(consumed, wanted)
      }
    }
    if let atmos {
      if isCancelled() { throw CancellationError() }
      let finalFrame = try atmos.finish()
      try file.write(contentsOf: finalFrame)
      bytes += UInt64(finalFrame.count)
    }
    try source.validateIntegrity()
    try file.synchronize()
    try file.close()
    // moveItem fails if another process has created the destination meanwhile.
    try FileManager.default.moveItem(at: partial, to: output)
    published = true
    let ended = DispatchTime.now().uptimeNanoseconds
    return .init(
      inputSamples: wanted, encodedSamples: units * UInt64(frameSize), bytes: bytes,
      accessUnits: units, sampleRate: info.sampleRate,
      channels: info.isAtmos ? 6 : info.channelCount, atmos: info.isAtmos,
      elapsedSeconds: Double(ended - jobStart) / 1e9,
      preparationSeconds: Double(encodeStart - jobStart) / 1e9,
      encodingSeconds: Double(ended - encodeStart) / 1e9,
      workerLimit: configuration.resolvedThreads, metadataIndexBytes: info.metadataIndexBytes)
  }
}
