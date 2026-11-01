// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import CryptoKit
import Foundation

enum AtmosMetadataCoding {
  static func oamd(_ positions: [DDPPosition]) -> [UInt8] {
    var body = BitWriter()
    body.write(0, 1)  // required Object element; counted inside its byte extent
    body.write(0, 2)
    body.write(0, 3)
    body.write(0, 6)
    body.write(2, 2)
    body.write(1, 1)
    // Object zero is the isolated LFE bed. Dynamic element amplitudes are
    // already in PCM; unity OAMD gain prevents applying source gain twice.
    body.write(0, 1)
    body.write(0, 2)
    body.write(1, 1)
    body.write(0, 1)
    for p in positions {
      body.write(0, 1)
      body.write(3, 2)
      body.write(1, 1)
      let x = max(0, min(62, Int(((p.x + 1) * 31).rounded())))
      let y = max(0, min(62, Int(((1 - p.y) * 31).rounded())))
      let z = max(0, min(15, Int((abs(p.z) * 15).rounded())))
      body.write(x, 6)
      body.write(y, 6)
      body.write(p.z >= 0 ? 1 : 0, 1)
      body.write(z, 4)
      body.write(0, 1)
      body.write(1, 4)
      body.write(0, 2)
      body.write(0, 1)
      body.write(0, 1)
      body.write(0, 1)
    }
    body.align()
    var w = BitWriter()
    w.write(0, 2)
    w.write(positions.count, 5)  // total includes LFE, minus one
    w.write(1, 1)
    w.write(1, 1)
    w.write(0, 1)
    w.write(1, 4)
    // Known object-element lengths are bytes minus one. The field name's
    // "bits" suffix describes its coded integer, not a bit-count unit.
    // The required-element bit is included in the counted body above;
    // no second control bit is inserted between this size and the body.
    w.write(1, 4)
    w.variable(body.bytes.count - 1, width: 4)
    w.append(body.bytes)
    w.align()
    return w.bytes
  }
  static func joc(_ matrices: [[[Double]]], sequence: Int, bandIndex: Int = 5) -> [UInt8] {
    precondition((0...1023).contains(sequence))
    var w = BitWriter()
    w.write(0, 3)
    w.write(matrices.count - 1, 6)
    w.write(0, 3)
    w.write(4, 3)
    w.write(0, 5)
    w.write(sequence, 10)
    for _ in matrices {
      w.write(1, 1)
      w.write(bandIndex, 3)
      w.write(0, 1)
      w.write(1, 1)
      w.write(0, 1)
      w.write(0, 1)
    }
    for matrix in matrices {
      for row in matrix {
        var previous = 96
        for gain in row {
          let q = max(0, min(191, Int((gain * 10).rounded()) + 96))
          let symbol = (q - previous + 192) % 192
          let code = JOCHuffman.fine[symbol]
          w.write(code.0, code.1)
          previous = q
        }
      }
    }
    w.align()
    return w.bytes
  }
}

/// Key-zero HMAC over compacted audio followed by the canonical EMDF body.
/// Production frames are authenticated after rate allocation and serialization.
/// The admitted profile uses four primary bytes and no secondary history.
enum EMDFProtection {
  private static let key: SymmetricKey = {
    let encoded = "2c16951c38232060d8975aa6cbdc54813142dc269dcc5d437697206c93871de4"
    var bytes = [UInt8]()
    var p = encoded.startIndex
    while p < encoded.endIndex {
      let next = encoded.index(p, offsetBy: 2)
      bytes.append(UInt8(encoded[p..<next], radix: 16)! ^ 0x7a)
      p = next
    }
    return SymmetricKey(data: bytes)
  }()
  static func authenticate(_ data: [UInt8]) -> [UInt8] {
    Array(HMAC<SHA256>.authenticationCode(for: Data(data), using: key))
  }
  static func bindToAudio(frame: inout [UInt8], metadataOffset: Int, associatedAudio: [UInt8])
    throws
  {
    let container = try EMDFContainer.parse(frame, at: metadataOffset)
    guard container.keyID == 0, container.secondaryLength == 0 else {
      throw DDPError.unsupported("Audio binding requires the key-zero primary-only EMDF profile")
    }
    var canonical = container.body
    for bit in container.protectionStart..<(container.protectionStart + container.primaryLength * 8)
    {
      canonical[bit >> 3] &= ~(1 << (7 - (bit & 7)))
    }
    let digest = authenticate(associatedAudio + canonical)
    let start = metadataOffset + 32 + container.protectionStart
    for i in 0..<(container.primaryLength * 8) {
      let bit = start + i
      let mask: UInt8 = 1 << (7 - (bit & 7))
      frame[bit >> 3] =
        (frame[bit >> 3] & ~mask)
        | (((digest[i >> 3] >> (7 - (i & 7))) & 1) << (7 - (bit & 7)))
    }
  }
  static func wrap(_ payloads: [(Int, [UInt8])], associatedData: [UInt8] = []) -> [UInt8] {
    var w = BitWriter()
    w.write(0, 2)
    w.write(0, 3)
    for (id, payload) in payloads {
      w.write(id, 5)
      w.write(0, 1)
      w.write(0, 1)
      w.write(1, 1)
      w.variable(0, width: 2)
      w.write(0, 1)
      w.write(0, 1)
      w.write(1, 1)
      w.write(0, 2)
      w.write(0, 7)
      w.variable(payload.count, width: 8)
      w.append(payload)
    }
    w.write(0, 5)
    w.write(2, 2)
    w.write(0, 2)
    let protectionStart = w.count
    w.write(0, 32)
    w.align()
    let digest = authenticate(associatedData + w.bytes)
    // The protection bits need not start at a byte boundary.
    for i in 0..<32 {
      let bit = protectionStart + i
      let mask: UInt8 = 1 << (7 - (bit & 7))
      w.bytes[bit >> 3] =
        (w.bytes[bit >> 3] & ~mask) | (((digest[i >> 3] >> (7 - (i & 7))) & 1) << (7 - (bit & 7)))
    }
    var out = BitWriter()
    out.write(0x5838, 16)
    out.write(w.bytes.count, 16)
    out.append(w.bytes)
    return out.bytes
  }
}

public enum DDPObjectMode: String, Codable, Sendable { case dynamic, channelbase }

/// Zero signals a stream start or splice. Continuous frames cycle through
/// 1...1023; a ten-bit integer wrap would falsely announce a splice every 1024 AUs.
struct JOCFrameSequence {
  private(set) var value = 0

  mutating func advance() {
    value = value == 1023 ? 1 : value + 1
  }
}

/// Spatially aggregates the master into 11/13/15 non-LFE elements. Per-band
/// regularized least squares derives reconstruction filters from actual signal
/// covariance, including correlations between source tracks.
final class AtmosDDPEncoder {
  let source: DDPSourceInfo
  let count: Int
  let mode: DDPObjectMode
  let core: DDPEncoder
  private let spatial: AtmosSpatialRenderer
  private let metadata: ((UInt64) throws -> [DDPPositionEvent])?
  private let observePCM: (([Float]) throws -> Void)?
  private var pending: AtmosSpatialFrame?
  private var limiter = AtmosLookaheadLimiter()
  private var previousElements: [[Double]]
  private var previousCore: [[Double]]
  private var previousMatrices: [[[Double]]]
  private var bandIndex = 5
  private var bandRecovery = 0
  private var sequence = JOCFrameSequence()
  init(
    source: DDPSourceInfo, configuration: DDPConfiguration, elements: Int, mode: DDPObjectMode,
    metadata: ((UInt64) throws -> [DDPPositionEvent])? = nil,
    observePCM: (([Float]) throws -> Void)? = nil
  )
    throws
  {
    guard configuration.bitrate >= 384 else {
      throw DDPError.invalidConfiguration("Atmos bitrate must be at least 384 kbit/s")
    }
    guard [12, 14, 16].contains(elements), source.sampleRate == 48000, source.isAtmos else {
      throw DDPError.invalidConfiguration(
        "Atmos requires 48 kHz metadata and 12, 14 or 16 transport elements")
    }
    self.source = source
    self.metadata = metadata
    self.observePCM = observePCM
    count = elements - 1
    self.mode = mode
    var c = configuration
    c.layout = .fiveOne
    core = try DDPEncoder(configuration: c)
    spatial = AtmosSpatialRenderer(
      source: source, elements: elements - 1, mode: mode, threads: configuration.resolvedThreads)
    previousMatrices = Array(
      repeating: Array(repeating: Array(repeating: 0, count: 12), count: 5), count: elements - 1)
    previousElements = Array(repeating: [Double](repeating: 0, count: 256), count: elements - 1)
    previousCore = Array(repeating: [Double](repeating: 0, count: 256), count: 5)
  }
  func encode(_ pcm: [Float], at sample: UInt64) throws -> Data {
    let next = try spatial.render(pcm, at: sample, states: metadata?(sample))
    guard let current = pending else {
      pending = next
      return Data()
    }
    pending = next
    return try encodePrepared(limiter.process(current, next: next))
  }

  func finish() throws -> Data {
    guard let current = pending else { return Data() }
    pending = nil
    return try encodePrepared(limiter.process(current, next: nil))
  }

  private func encodePrepared(_ frame: AtmosSpatialFrame) throws -> Data {
    let elements = frame.elements
    let downmix = frame.downmix
    let lfe = frame.lfe
    let positions = frame.positions
    let matrices = analyze(elements: elements, downmix: downmix)
    let objectMetadata = AtmosMetadataCoding.oamd(positions)
    func packet(_ index: Int) -> (bytes: [UInt8], matrix: [[[Double]]]) {
      let reduced = reduceBands(matrices, to: index)
      return (
        EMDFProtection.wrap([
          (11, objectMetadata),
          (14, AtmosMetadataCoding.joc(reduced, sequence: sequence.value, bandIndex: index)),
        ]), reduced
      )
    }
    var chosen = packet(bandIndex)
    while chosen.bytes.count > 511, bandIndex > 0 {
      bandIndex -= 1
      bandRecovery = 0
      chosen = packet(bandIndex)
    }
    if bandIndex < 5 {
      let finer = packet(bandIndex + 1)
      // Drop resolution immediately on overflow, but require four frames and
      // 48 bytes of headroom before recovering it. Marginal fits must not flap.
      bandRecovery = finer.bytes.count <= 463 ? bandRecovery + 1 : 0
      if bandRecovery >= 4 {
        bandIndex += 1
        bandRecovery = 0
        chosen = finer
      }
    }
    let metadata = chosen.bytes
    guard metadata.count <= 511 else {
      throw DDPError.invalidConfiguration("JOC metadata exceeds one skip field")
    }
    let quantized = chosen.matrix.map {
      $0.map { $0.map { Double(max(0, min(191, Int(($0 * 10).rounded()) + 96)) - 96) / 10 } }
    }
    previousMatrices = expandBands(quantized, from: bandIndex)
    var interleaved = [Float]()
    interleaved.reserveCapacity(1536 * 6)
    for f in 0..<1536 {
      interleaved += [
        Float(downmix[0][f]), Float(downmix[1][f]), Float(downmix[2][f]), Float(lfe[f]),
        Float(downmix[3][f]), Float(downmix[4][f]),
      ]
    }
    try observePCM?(interleaved)
    sequence.advance()
    return try core.encode(interleaved, emdf: metadata, complexity: count + 1)
  }
  private func reduceBands(_ matrices: [[[Double]]], to index: Int) -> [[[Double]]] {
    let edges = [
      [0, 64], [0, 3, 14, 64], [0, 1, 3, 9, 23, 64], [0, 1, 2, 4, 8, 14, 23, 64],
      [0, 1, 2, 3, 5, 7, 9, 14, 23, 64], [0, 1, 2, 3, 4, 6, 8, 11, 14, 18, 23, 35, 64],
    ]
    if index == 5 { return matrices }
    let from = edges[5]
    let to = edges[index]
    return matrices.map { matrix in
      matrix.map { row in
        (0..<(to.count - 1)).map { band in
          var value = 0.0
          for b in 0..<12 {
            let overlap = max(0, min(from[b + 1], to[band + 1]) - max(from[b], to[band]))
            value += row[b] * Double(overlap)
          }
          return value / Double(to[band + 1] - to[band])
        }
      }
    }
  }
  private func expandBands(_ matrices: [[[Double]]], from index: Int) -> [[[Double]]] {
    if index == 5 { return matrices }
    let edges = [
      [0, 64], [0, 3, 14, 64], [0, 1, 3, 9, 23, 64], [0, 1, 2, 4, 8, 14, 23, 64],
      [0, 1, 2, 3, 5, 7, 9, 14, 23, 64], [0, 1, 2, 3, 4, 6, 8, 11, 14, 18, 23, 35, 64],
    ]
    let source = edges[index]
    let target = edges[5]
    return matrices.map {
      $0.map { row in
        (0..<12).map { b in
          var value = 0.0
          for j in row.indices {
            value +=
              row[j] * Double(max(0, min(source[j + 1], target[b + 1]) - max(source[j], target[b])))
          }
          return value / Double(target[b + 1] - target[b])
        }
      }
    }
  }

  private func analyze(elements: [[Double]], downmix: [[Double]]) -> [[[Double]]] {
    let edges = [0, 1, 2, 3, 4, 6, 8, 11, 14, 18, 23, 35, 64]
    let old = previousCore + previousElements
    let signals = downmix + elements
    let threads = core.configuration.resolvedThreads
    let spectra = DDPParallel.map(count: signals.count, threads: threads) { channel in
      var previous = old[channel]
      return (0..<6).map { block -> [Double] in
        let current = Array(signals[channel][(block * 256)..<((block + 1) * 256)])
        let values = DDPTransform.forward(previous: previous, current: current)
        previous = current
        return values
      }
    }
    previousCore = downmix.map { Array($0.suffix(256)) }
    previousElements = elements.map { Array($0.suffix(256)) }
    let elementCount = count
    let prior = previousMatrices
    let bands = DDPParallel.map(count: 12, threads: threads) { band -> [[Double]] in
      var a = [Double](repeating: 0, count: 25)
      var cross = Array(repeating: [Double](repeating: 0, count: 5), count: elementCount)
      // Retain the serial reduction order inside each band, irrespective of
      // worker count. Only independent bands and transforms execute concurrently.
      for b in 0..<6 {
        for bin in (edges[band] * 4)..<min(256, edges[band + 1] * 4) {
          for i in 0..<5 {
            for j in 0..<5 { a[i * 5 + j] += spectra[i][b][bin] * spectra[j][b][bin] }
          }
          for k in 0..<elementCount {
            for c in 0..<5 { cross[k][c] += spectra[5 + k][b][bin] * spectra[c][b][bin] }
          }
        }
      }
      var inverse = [Double](repeating: 0, count: 25)
      let trace = (0..<5).reduce(0.0) { $0 + a[$1 * 5 + $1] }
      // Anchor weakly observable directions to the last transmitted matrix,
      // rather than choosing a new high-gain solution in each frame's nullspace.
      let ridge = max(1e-18, trace * 0.0004)
      for i in 0..<5 {
        a[i * 5 + i] += ridge
        inverse[i * 5 + i] = 1
      }
      for c in 0..<5 {
        let pivot = (c..<5).max { abs(a[$0 * 5 + c]) < abs(a[$1 * 5 + c]) }!
        if pivot != c {
          for j in 0..<5 {
            a.swapAt(c * 5 + j, pivot * 5 + j)
            inverse.swapAt(c * 5 + j, pivot * 5 + j)
          }
        }
        let divisor = a[c * 5 + c]
        for j in 0..<5 {
          a[c * 5 + j] /= divisor
          inverse[c * 5 + j] /= divisor
        }
        for i in 0..<5 where i != c {
          let factor = a[i * 5 + c]
          for j in 0..<5 {
            a[i * 5 + j] -= factor * a[c * 5 + j]
            inverse[i * 5 + j] -= factor * inverse[c * 5 + j]
          }
        }
      }
      var result = Array(repeating: [Double](repeating: 0, count: 5), count: elementCount)
      for k in 0..<elementCount {
        for c in 0..<5 {
          let value = (0..<5).reduce(0.0) {
            $0 + (cross[k][$1] + ridge * prior[k][$1][band]) * inverse[$1 * 5 + c]
          }
          result[k][c] = max(-9.6, min(9.5, value))
        }
      }
      return result
    }
    return (0..<elementCount).map { k in (0..<5).map { c in (0..<12).map { bands[$0][k][c] } } }
  }
}
