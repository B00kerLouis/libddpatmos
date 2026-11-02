// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

/// Stateful, externally serialized PCM encoder. Each call accepts
/// `inputFrameCount` interleaved frames; the caller owns padding and output storage.
public final class DDPEncoder {
  public let configuration: DDPConfiguration
  public let inputFrameCount: Int
  private var overlap: [[Double]]
  private var dependent: DDPEncoder?
  private var frameIndex: UInt64 = 0
  private let dependentStream: Bool
  private let streamBitrate: Int
  private let customChannelMap: Int
  private var synthesisOverlap: [[Double]] = []
  private(set) var reconstructedPCM: [[Double]] = []
  private var reconstructOutput = false

  /// File-level feedback observes both the independent compatibility stream
  /// and every dependent channel, with separate synthesis histories.
  func enableReconstruction() {
    reconstructOutput = true
    synthesisOverlap = overlap.map { _ in [Double](repeating: 0, count: 256) }
    dependent?.enableReconstruction()
  }
  public init(configuration: DDPConfiguration) throws {
    try configuration.validate()
    self.configuration = configuration
    dependentStream = false
    customChannelMap = 0
    let extensionProfile = configuration.layout.extensionProfile
    streamBitrate = extensionProfile != nil ? configuration.bitrate / 2 : configuration.bitrate
    inputFrameCount = streamBitrate * 1000 * 1536 / configuration.sampleRate / 8 > 4096 ? 768 : 1536
    overlap = Array(
      repeating: [Double](repeating: 0, count: 256), count: configuration.layout.codedOrder.count)
    if let extensionProfile {
      var c = configuration
      c.layout = extensionProfile.layout
      c.bitrate = configuration.bitrate - streamBitrate
      dependent = try DDPEncoder(
        configuration: c, dependent: true, inputFrameCount: inputFrameCount,
        channelMap: extensionProfile.map)
    }
  }
  private init(
    configuration: DDPConfiguration, dependent: Bool, inputFrameCount: Int, channelMap: Int
  ) throws {
    self.configuration = configuration
    dependentStream = dependent
    streamBitrate = configuration.bitrate
    self.inputFrameCount = inputFrameCount
    customChannelMap = channelMap
    overlap = Array(
      repeating: [Double](repeating: 0, count: 256), count: configuration.layout.codedOrder.count)
  }
  public func reset() {
    frameIndex = 0
    for c in overlap.indices { overlap[c] = [Double](repeating: 0, count: 256) }
    dependent?.reset()
    if reconstructOutput { enableReconstruction() }
  }
  public func encode(_ interleaved: [Float]) throws -> Data {
    try encode(interleaved, emdf: [], complexity: 0)
  }
  func encode(_ interleaved: [Float], emdf: [UInt8], complexity: Int) throws -> Data {
    let c = configuration
    guard interleaved.count == inputFrameCount * c.layout.channels else {
      throw DDPError.invalidConfiguration(
        "A DDP access unit requires \(inputFrameCount) frames of interleaved PCM")
    }
    guard interleaved.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
      throw DDPError.invalidConfiguration("PCM must be finite and within -1...1")
    }
    let order = c.layout.codedOrder
    let lfe = c.layout.hasLFE
    let compatibilityPairs = c.layout.compatibilityPairs
    let srCode = [48_000, 44_100, 32_000].firstIndex(of: c.sampleRate)!
    // Fractional frame words are distributed deterministically at 44.1 kHz.
    let denominator = UInt64(c.sampleRate * 16)
    let wordRate = UInt64(streamBitrate * 1000 * inputFrameCount)
    let words = Int((frameIndex + 1) * wordRate / denominator - frameIndex * wordRate / denominator)
    let frameBytes = words * 2
    guard frameBytes <= 4096 else {
      throw DDPError.invalidConfiguration("Frame exceeds E-AC-3 4096-byte limit")
    }
    let blockCount = inputFrameCount / 256
    let initialOverlap = overlap
    let channels = DDPParallel.map(count: order.count, threads: c.resolvedThreads) { coded in
      let source = order[coded]
      var previous = initialOverlap[coded]
      var spectra = [DDPAllocation.Spectrum]()
      for b in 0..<blockCount {
        let current = (0..<256).map { offset -> Double in
          let at = (b * 256 + offset) * c.layout.channels
          if let back = compatibilityPairs[source] {
            return 0.5 * (Double(interleaved[at + source]) + Double(interleaved[at + back]))
          }
          return Double(interleaved[at + source])
        }
        let coefficients = DDPTransform.forward(previous: previous, current: current)
        previous = current
        spectra.append(
          DDPAllocation.analyze(
            coefficients, bins: lfe && coded == order.count - 1 ? 7 : 253,
            sampleRateCode: srCode, lfe: lfe && coded == order.count - 1))
      }
      return DDPChannelAnalysis(spectra: spectra, tail: previous)
    }
    overlap = channels.map { $0.tail }
    var blocks = (0..<blockCount).map { b in channels.map { $0.spectra[b] } }
    // Reuse exponents for spectrally stable channels. Low-rate frames use a
    // shared maximum envelope so side information cannot consume the entire
    // frame budget. The envelope always bounds every represented coefficient.
    for ch in order.indices {
      let force = streamBitrate < order.count * 64 || (!emdf.isEmpty && streamBitrate < 640)
      let first = blocks[0][ch]
      let stable = blocks.dropFirst().allSatisfy { block in
        zip(first.exponents, block[ch].exponents).reduce(0) { $0 + abs($1.0 - $1.1) } < 500
      }
      if force || stable {
        let bins = first.coefficients.count
        var envelope = [Double](repeating: 0, count: bins)
        for block in blocks {
          for k in 0..<bins { envelope[k] = max(envelope[k], abs(block[ch].coefficients[k])) }
        }
        let strategy = force && streamBitrate < order.count * 40 ? 3 : 2
        let common = DDPAllocation.analyze(
          envelope, bins: bins, sampleRateCode: srCode, lfe: first.isLFE, strategy: strategy)
        for b in blocks.indices {
          blocks[b][ch].exponents = common.exponents
          blocks[b][ch].mask = common.mask
          blocks[b][ch].groups = b == 0 ? common.groups : []
          blocks[b][ch].strategy = b == 0 ? common.strategy : 0
        }
      }
    }
    // Account for every side-information bit using the same serializer used
    // for output. Binary search the largest feasible SNR offset.
    let overhead =
      serialize(
        blocks: blocks, snr: 0, frameBytes: frameBytes, includeMantissas: false, emdf: emdf,
        complexity: complexity
      ).count + 18
    guard overhead <= frameBytes * 8 else {
      throw DDPError.invalidConfiguration(
        "Bitrate is too low for this channel layout and exponent precision")
    }
    var low = 0
    var high = 1023
    while low < high {
      let mid = (low + high + 1) / 2
      var size = overhead
      for b in blocks { size += DDPAllocation.mantissaBitCount(b, snr: mid) }
      if size <= frameBytes * 8 { low = mid } else { high = mid - 1 }
    }
    let selectedSNR = low
    let finalBlocks = blocks
    let reconstruct = reconstructOutput
    let quantized = DDPParallel.map(count: blocks.count, threads: c.resolvedThreads) {
      DDPAllocation.quantize(finalBlocks[$0], snr: selectedSNR, reconstruct: reconstruct)
    }
    let mantissaBlocks = quantized.map(\.bits)
    if reconstruct {
      reconstructedPCM = order.map { _ in [Double]() }
      for block in quantized {
        for channel in order.indices {
          let windowed = DDPTransform.inverse(block.coefficients[channel])
          reconstructedPCM[channel] += (0..<256).map {
            synthesisOverlap[channel][$0] + windowed[$0]
          }
          synthesisOverlap[channel] = Array(windowed[256..<512])
        }
      }
    }
    var writer = serialize(
      blocks: blocks, snr: low, frameBytes: frameBytes, includeMantissas: true, emdf: emdf,
      complexity: complexity, mantissaBlocks: mantissaBlocks)
    guard writer.count <= frameBytes * 8 - 18 else {
      throw DDPError.invalidConfiguration("Internal bit allocation overflow")
    }
    let audioEnd = writer.count
    writer.pad(to: frameBytes * 8)
    writer.authenticationExclusions.append(audioEnd..<writer.count)
    if let metadataOffset = writer.emdfBitOffset {
      try EMDFProtection.bindToAudio(
        frame: &writer.bytes, metadataOffset: metadataOffset,
        associatedAudio: writer.authenticatedAudioBytes())
    }
    DDPCRC.finishFrame(&writer.bytes)
    frameIndex += 1
    var data = Data(writer.bytes)
    if let dependent {
      let sources = c.layout.extensionProfile!.sources
      var rear = [Float]()
      rear.reserveCapacity(inputFrameCount * sources.count)
      for f in 0..<inputFrameCount {
        for source in sources { rear.append(interleaved[f * c.layout.channels + source]) }
      }
      data.append(try dependent.encode(rear))
      if reconstruct { reconstructedPCM += dependent.reconstructedPCM }
    }
    return data
  }

  private func serialize(
    blocks: [[DDPAllocation.Spectrum]], snr: Int, frameBytes: Int, includeMantissas: Bool,
    emdf: [UInt8], complexity: Int, mantissaBlocks: [BitWriter] = []
  ) -> BitWriter {
    let c = configuration
    let acmod = c.layout.acmod
    let lfe = c.layout.hasLFE
    let fbw = c.layout.codedOrder.count - (lfe ? 1 : 0)
    let blockCount = blocks.count
    var w = BitWriter()
    w.write(0x0b77, 16)
    w.write(dependentStream ? 1 : 0, 2)
    w.write(0, 3)
    w.write(frameBytes / 2 - 1, 11)
    w.authenticationExclusions.append(0..<w.count)
    w.write([48_000, 44_100, 32_000].firstIndex(of: c.sampleRate)!, 2)
    w.write(blockCount == 6 ? 3 : 2, 2)
    w.write(acmod, 3)
    w.write(lfe ? 1 : 0, 1)
    w.write(16, 5)
    w.write(-c.dialogueLevel, 5)
    w.write(0, 1)
    // Replacement side channels plus the rear pair keep the full physical
    // mapping explicit in both legacy and extended decoder channel arrays.
    if dependentStream {
      w.write(1, 1)
      w.write(customChannelMap, 16)
    }
    w.write(dependentStream ? 0 : 1, 1)
    if !dependentStream {
      if acmod > 2 { w.write(c.downmixMode == .ltrt ? 1 : 2, 2) }
      if acmod & 1 != 0 {
        w.write(4, 3)
        w.write(4, 3)
      }  // -3 dB centre
      if acmod & 4 != 0 {
        w.write(4, 3)
        w.write(4, 3)
      }
      if lfe { w.write(0, 1) }
      w.write(0, 1)
      w.write(0, 1)
      w.write(0, 2)
      w.write(0, 1)
    }
    let infoStart = w.count
    w.write(0, 1)  // informational metadata absent
    w.authenticationExclusions.append(infoStart..<w.count)
    if blockCount != 6, !dependentStream { w.write(frameIndex % 2 == 0 ? 1 : 0, 1) }
    let additionalStart = w.count
    if emdf.isEmpty {
      w.write(0, 1)
    } else {
      w.write(1, 1)
      w.write(1, 6)
      w.write(1, 8)
      w.write(complexity, 8)
    }
    w.authenticationExclusions.append(additionalStart..<w.count)
    if blockCount == 6 {
      w.write(1, 1)
      w.write(0, 1)
    }  // per-block exponent strategies, no AHT
    w.write(0, 2)  // one frame-level SNR offset
    w.write(0, 1)  // transient processing absent
    w.write(0, 1)  // long blocks
    w.write(1, 1)  // explicit dither flags: omission would turn decoder dither ON
    for _ in 0..<3 { w.write(0, 1) }  // BAM, fast gain, DBA
    let skipSyntaxStart = w.count
    w.write(emdf.isEmpty ? 0 : 1, 1)
    w.authenticationExclusions.append(skipSyntaxStart..<w.count)
    w.write(0, 1)  // skip fields, SPX
    w.write(0, 1)  // block zero coupling off
    for _ in 1..<blockCount { w.write(0, 1) }  // reuse coupling state
    for block in blocks { for ch in 0..<fbw { w.write(block[ch].strategy, 2) } }
    if lfe { for block in blocks { w.write(block[block.count - 1].strategy == 0 ? 0 : 1, 1) } }
    if !dependentStream {
      if blockCount == 6 { for _ in 0..<fbw { w.write(0, 5) } } else { w.write(0, 1) }
    }  // AC-3 converter exponent strategy
    w.write(snr >> 4, 6)
    w.write(snr & 15, 4)
    w.write(0, 1)  // no block-start offsets
    for (index, block) in blocks.enumerated() {
      for _ in 0..<fbw { w.write(0, 1) }  // zero-BAP bins reconstruct as true zero
      w.write(0, 1)  // dynamic range absent
      w.write(0, 1)  // no spectral extension strategy
      if acmod == 2 {
        if index > 0 { w.write(0, 1) } else { w.write(0, 4) }  // initial stereo rematrix flags
      }
      for ch in 0..<fbw where block[ch].strategy != 0 { w.write(60, 6) }  // 253 spectral bins
      for spectrum in block where spectrum.strategy != 0 {
        w.write(spectrum.groups[0], 4)
        for group in spectrum.groups.dropFirst() { w.write(group, 7) }
        if !spectrum.isLFE { w.write(0, 2) }
      }
      if !dependentStream { w.write(0, 1) }  // converter SNR absent
      if !emdf.isEmpty {
        let skipStart = w.count
        let begin = index * 511
        let end = min(begin + 511, emdf.count)
        let n = max(0, end - begin)
        w.write(n > 0 ? 1 : 0, 1)
        if n > 0 {
          w.write(n, 9)
          if begin == 0 { w.emdfBitOffset = w.count }
          w.append(Array(emdf[begin..<end]))
        }
        w.authenticationExclusions.append(skipStart..<w.count)
      }
      if includeMantissas {
        let m = mantissaBlocks[index]
        w.append(m.bytes, bits: m.count)
      }
    }
    return w
  }
}

private struct DDPChannelAnalysis: Sendable {
  let spectra: [DDPAllocation.Spectrum]
  let tail: [Double]
}
