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
  /// Measurement reports programme loudness without changing PCM or dialnorm metadata.
  public var loudnessMode: DDPLoudnessMode = .measure
  /// Ceiling checked on reconstructed quantized EC3, not just input PCM.
  /// Only local overloads reduce gain; no programme normalization is applied.
  public var truePeakLimitDBTP: Double = -2.5
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
    let feedback = try DDPTruePeakFeedback(
      ceilingDBTP: options.truePeakLimitDBTP, directory: output.deletingLastPathComponent())
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
    var units: UInt64 = 0
    var bytes: UInt64 = 0
    var frameSize = 1536
    var loudness: DDPLoudnessReport?
    let encodeStart = DispatchTime.now().uptimeNanoseconds
    while true {
      if isCancelled() { throw CancellationError() }
      try source.validateIntegrity()
      try source.seek(to: start)
      try file.truncate(atOffset: 0)
      try file.seek(toOffset: 0)
      let meter =
        options.loudnessMode == .measure
        ? try DDPLoudnessMeter(
          sampleRate: info.sampleRate, layout: info.isAtmos ? .fiveOne : configuration.layout,
          atmos: info.isAtmos, directory: output.deletingLastPathComponent()) : nil
      let plain = info.isAtmos ? nil : try DDPEncoder(configuration: configuration)
      plain?.enableReconstruction()
      // Spatial lookahead is a scheduling delay, not a shift in sample time.
      // Observe final prepared PCM in order and count only source samples.
      var unmeasured = wanted
      let atmos =
        info.isAtmos
        ? try AtmosDDPEncoder(
          source: info, configuration: configuration, elements: options.spatialElements,
          mode: options.objectMode, metadata: { try source.metadata(at: $0) },
          observePCM: meter.map { meter in
            { pcm in
              let n = Int(min(unmeasured, 1536))
              try meter.consume(pcm, frames: n)
              unmeasured -= UInt64(n)
            }
          },
          preparePCM: { original, index in
            guard
              let gains = try feedback.envelope(
                at: index, frames: 1536, sampleRate: info.sampleRate)
            else { return original }
            var frame = original
            for f in 0..<1536 {
              for c in frame.downmix.indices { frame.downmix[c][f] *= gains[f] }
              for c in frame.elements.indices { frame.elements[c][f] *= gains[f] }
              frame.lfe[f] *= gains[f]
            }
            return frame
          }, observeReconstruction: { try feedback.observe($0) }) : nil
      var consumed: UInt64 = 0
      units = 0
      bytes = 0
      frameSize = plain?.inputFrameCount ?? 1536
      // Include the transform tail; the peak meter additionally flushes its FIR.
      let requiredUnits = (wanted + 256 + UInt64(frameSize - 1)) / UInt64(frameSize)
      while units < requiredUnits {
        try autoreleasepool {
          if isCancelled() { throw CancellationError() }
          let n = Int(min(UInt64(frameSize), wanted - consumed))
          var pcm = n > 0 ? try source.read(frameCount: n) : []
          guard pcm.count == n * info.channelCount else {
            throw DDPError.io("Input became shorter while encoding")
          }
          pcm.append(
            contentsOf: repeatElement(Float(0), count: (frameSize - n) * info.channelCount))
          let data: Data
          if let plain {
            try meter?.consume(pcm, frames: n)
            if let gains = try feedback.envelope(
              at: units, frames: frameSize, sampleRate: info.sampleRate)
            {
              for f in 0..<frameSize {
                for c in 0..<info.channelCount {
                  pcm[f * info.channelCount + c] *= Float(gains[f])
                }
              }
            }
            data = try plain.encode(pcm)
            try feedback.observe(plain.reconstructedPCM)
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
      if try feedback.finish(units: units, isCancelled: isCancelled) {
        loudness = try meter?.finish(isCancelled: isCancelled)
        break
      }
    }
    if isCancelled() { throw CancellationError() }
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
      workerLimit: configuration.resolvedThreads, metadataIndexBytes: info.metadataIndexBytes,
      dialogueLevel: configuration.dialogueLevel, loudness: loudness,
      truePeak: feedback.report(atmos: info.isAtmos))
  }
}
