// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

// A/52 exponent-domain masking and bit allocation. See THIRD_PARTY_NOTICES.
import Foundation

enum DDPAllocation {
  static let bandStarts = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
    26, 27, 28, 31, 34, 37, 40, 43, 46, 49, 55, 61, 67, 73, 79, 85, 97, 109, 121, 133, 157, 181,
    205, 229, 253,
  ]
  static let bandForBin: [Int] = (0..<253).map { bin in bandStarts.lastIndex(where: { $0 <= bin })!
  }
  static let bapTable = [
    0, 1, 1, 1, 1, 1, 2, 2, 3, 3, 3, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 8, 9, 9, 9, 9, 10,
    10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 15,
    15, 15, 15, 15, 15, 15, 15, 15,
  ]
  // Normative A/52 log-add lookup: integer table values must be exact.
  static let logAdd = [
    64, 63, 62, 61, 60, 59, 58, 57, 56, 55, 54, 53, 52, 52, 51, 50, 49, 48, 47, 47, 46, 45, 44, 44,
    43, 42, 41, 41, 40, 39, 38, 38, 37, 36, 36, 35, 35, 34, 33, 33, 32, 32, 31, 30, 30, 29, 29, 28,
    28, 27, 27, 26, 26, 25, 25, 24, 24, 23, 23, 22, 22, 21, 21, 21, 20, 20, 19, 19, 19, 18, 18, 18,
    17, 17, 17, 16, 16, 16, 15, 15, 15, 14, 14, 14, 13, 13, 13, 13, 12, 12, 12, 12, 11, 11, 11, 11,
    10, 10, 10, 10, 10, 9, 9, 9, 9, 9, 8, 8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 6, 6, 6, 6, 6, 6, 6, 6,
    5, 5, 5, 5, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0,
  ]
  static let hearing: [[Int]] = [
    [0x4d0, 0x4f0, 0x580], [0x4d0, 0x4f0, 0x580], [0x440, 0x460, 0x4b0], [0x400, 0x410, 0x450],
    [0x3e0, 0x3e0, 0x420], [0x3c0, 0x3d0, 0x3f0], [0x3b0, 0x3c0, 0x3e0], [0x3b0, 0x3b0, 0x3d0],
    [0x3a0, 0x3b0, 0x3c0], [0x3a0, 0x3a0, 0x3b0], [0x3a0, 0x3a0, 0x3b0], [0x3a0, 0x3a0, 0x3b0],
    [0x3a0, 0x3a0, 0x3a0], [0x390, 0x3a0, 0x3a0], [0x390, 0x390, 0x3a0], [0x390, 0x390, 0x3a0],
    [0x380, 0x390, 0x3a0], [0x380, 0x380, 0x3a0], [0x370, 0x380, 0x3a0], [0x370, 0x380, 0x3a0],
    [0x360, 0x370, 0x390], [0x360, 0x370, 0x390], [0x350, 0x360, 0x390], [0x350, 0x360, 0x390],
    [0x340, 0x350, 0x380], [0x340, 0x350, 0x380], [0x330, 0x340, 0x380], [0x320, 0x340, 0x370],
    [0x310, 0x320, 0x360], [0x300, 0x310, 0x350], [0x2f0, 0x300, 0x340], [0x2f0, 0x2f0, 0x330],
    [0x2f0, 0x2f0, 0x320], [0x2f0, 0x2f0, 0x310], [0x300, 0x2f0, 0x300], [0x310, 0x300, 0x2f0],
    [0x340, 0x320, 0x2f0], [0x390, 0x350, 0x2f0], [0x3e0, 0x390, 0x300], [0x420, 0x3e0, 0x310],
    [0x460, 0x420, 0x330], [0x490, 0x450, 0x350], [0x4a0, 0x4a0, 0x3c0], [0x460, 0x490, 0x410],
    [0x440, 0x460, 0x470], [0x440, 0x440, 0x4a0], [0x520, 0x480, 0x460], [0x800, 0x630, 0x440],
    [0x840, 0x840, 0x450], [0x840, 0x840, 0x4e0],
  ]

  struct Spectrum: Sendable {
    var coefficients: [Double]
    var exponents: [Int]
    var groups: [Int]
    var mask: [Int]
    var isLFE: Bool
    var strategy: Int
  }

  static func analyze(
    _ coefficients: [Double], bins: Int, sampleRateCode: Int, lfe: Bool, strategy: Int = 2
  ) -> Spectrum {
    // D25 groups adjacent coefficients. The smoothing passes
    // only lower exponents, so normalization can never overflow a mantissa.
    let stride = lfe ? 1 : 1 << (strategy - 1)
    let groupCount = (bins + 3 * stride - 4) / (3 * stride)
    let codedBins = 1 + groupCount * 3 * stride
    let raw = (0..<codedBins).map { k -> Int in
      let v = k < bins ? abs(coefficients[k]) : 0
      return v > 1.0 / 16_777_216 ? max(0, min(24, Int(ceil(-log2(v))) - 1)) : 24
    }
    var e = [raw[0]]
    for i in 0..<(groupCount * 3) {
      e.append(raw[(1 + i * stride)..<(1 + (i + 1) * stride)].min()!)
    }
    e[0] = min(e[0], 15)
    for i in 1..<e.count { e[i] = min(e[i], e[i - 1] + 2) }
    for i in (0..<(e.count - 1)).reversed() { e[i] = min(e[i], e[i + 1] + 2) }
    var groups = [e[0]]
    for i in Swift.stride(from: 1, to: e.count, by: 3) {
      groups.append(
        (e[i] - e[i - 1] + 2) * 25 + (e[i + 1] - e[i] + 2) * 5 + e[i + 2] - e[i + 1] + 2)
    }
    let expanded = [e[0]] + e.dropFirst().flatMap { Array(repeating: $0, count: stride) }
    let psd = expanded.prefix(bins).map { 3072 - $0 * 128 }
    var bandPSD = [Int](repeating: 0, count: 50)
    let endBand = bandForBin[bins - 1] + 1
    for b in 0..<endBand {
      let range = bandStarts[b]..<min(bandStarts[b + 1], bins)
      var value = psd[range.lowerBound]
      for k in range.dropFirst() {
        let peak = max(value, psd[k])
        let index = min(255, peak - ((value + psd[k] + 1) >> 1))
        value = peak + logAdd[index]
      }
      bandPSD[b] = value
    }
    var excitation = [Int](repeating: 0, count: 50)
    var low = 0
    var fast = 0
    var slow = 0
    var begin = 7
    func compensate(_ a: Int, _ b: Int, _ c: Int, _ strength: Int) -> Int {
      a + 256 == b ? strength : (a > b ? max(c - 64, 0) : c)
    }
    low = compensate(bandPSD[0], bandPSD[1], low, 384)
    excitation[0] = bandPSD[0] - 640 - low
    low = compensate(bandPSD[1], bandPSD[2], low, 384)
    excitation[1] = bandPSD[1] - 640 - low
    for b in 2..<7 {
      if !(lfe && b == 6) { low = compensate(bandPSD[b], bandPSD[b + 1], low, 384) }
      fast = bandPSD[b] - 640
      slow = bandPSD[b] - 1240
      excitation[b] = fast - low
      if !(lfe && b == 6), bandPSD[b] <= bandPSD[b + 1] {
        begin = b + 1
        break
      }
    }
    if begin < min(endBand, 22) {
      for b in begin..<min(endBand, 22) {
        if !(lfe && b == 6) {
          low =
            b < 20
            ? compensate(bandPSD[b], bandPSD[b + 1], low, b < 7 ? 384 : 320) : max(low - 128, 0)
        }
        fast = max(fast - 83, bandPSD[b] - 640)
        slow = max(slow - 19, bandPSD[b] - 1240)
        excitation[b] = max(fast - low, slow)
      }
    }
    if endBand > 22 {
      for b in 22..<endBand {
        fast = max(fast - 83, bandPSD[b] - 640)
        slow = max(slow - 19, bandPSD[b] - 1240)
        excitation[b] = max(fast, slow)
      }
    }
    var mask = [Int](repeating: 0, count: 50)
    for b in 0..<endBand {
      let adjustment = max(0, 2304 - bandPSD[b]) >> 2
      mask[b] = max(hearing[b][sampleRateCode], excitation[b] + adjustment)
    }
    return Spectrum(
      coefficients: Array(coefficients.prefix(bins)), exponents: Array(expanded.prefix(bins)),
      groups: groups, mask: mask, isLFE: lfe, strategy: lfe ? 1 : strategy)
  }

  static func pointers(_ spectrum: Spectrum, snr: Int) -> [Int] {
    if snr == 0 { return [Int](repeating: 0, count: spectrum.exponents.count) }
    let offset = (snr - 240) * 4
    return spectrum.exponents.indices.map { k in
      let floor = -2048
      let m = (max(spectrum.mask[bandForBin[k]] - offset - floor, 0) & 0x1fe0) + floor
      let address = max(0, min(63, (3072 - spectrum.exponents[k] * 128 - m) >> 5))
      return bapTable[address]
    }
  }

  /// Rate search needs only the exact grouped bit budget. Quantizing and
  /// packing every rejected SNR candidate wastes most of the encoder's work.
  static func mantissaBitCount(_ spectra: [Spectrum], snr: Int) -> Int {
    var counts = [Int](repeating: 0, count: 16)
    for spectrum in spectra { for pointer in pointers(spectrum, snr: snr) { counts[pointer] += 1 } }
    var bits = ((counts[1] + 2) / 3) * 5 + ((counts[2] + 2) / 3) * 7
    bits += counts[3] * 3 + ((counts[4] + 1) / 2) * 7 + counts[5] * 4
    for pointer in 6..<14 { bits += counts[pointer] * (pointer - 1) }
    return bits + counts[14] * 14 + counts[15] * 16
  }

  /// Grouped mantissas run across channel boundaries, and restart each block.
  static func mantissas(_ spectra: [Spectrum], snr: Int) -> BitWriter {
    quantize(spectra, snr: snr, reconstruct: false).bits
  }

  struct QuantizedBlock: Sendable {
    let bits: BitWriter
    let coefficients: [[Double]]
  }

  static func quantize(_ spectra: [Spectrum], snr: Int, reconstruct: Bool) -> QuantizedBlock {
    var entries = [(Int, Int)]()
    var pending = [Int: [Int]]()
    var coefficients = [[Double]]()
    for s in spectra {
      var decoded = reconstruct ? [Double](repeating: 0, count: s.coefficients.count) : []
      for (k, b) in pointers(s, snr: snr).enumerated() {
        if b == 0 { continue }
        let normalized = max(-1, min(1 - 1e-12, s.coefficients[k] * pow(2, Double(s.exponents[k]))))
        let levels = [1: 3, 2: 5, 3: 7, 4: 11, 5: 15][b]
        let width = b == 15 ? 16 : b == 14 ? 14 : b - 1
        let value: Int
        if let levels {
          value = max(0, min(levels - 1, Int(floor((normalized + 1) * Double(levels) / 2))))
        } else {
          value = max(
            -(1 << (width - 1)),
            min((1 << (width - 1)) - 1, Int((normalized * Double(1 << (width - 1))).rounded())))
        }
        if reconstruct {
          // Reconstruct signed Q23 and apply exponent shifts before floating
          // synthesis, retaining the decoder's negative-value rounding.
          // Zero-BAP bins stay zero: this writer explicitly disables dither.
          let mantissa: Int
          if let levels {
            mantissa = (value - levels / 2) * 16_777_216 / levels
          } else {
            mantissa = value * (1 << (24 - width))
          }
          decoded[k] = Double(mantissa >> s.exponents[k]) / 8_388_608
        }
        if [1, 2, 4].contains(b) {
          let target = b == 4 ? 2 : 3
          var indices = pending[b, default: []]
          indices.append(entries.count)
          entries.append((value, 0))
          if indices.count == target {
            var grouped = 0
            for i in indices { grouped = grouped * levels! + entries[i].0 }
            entries[indices[0]] = (grouped, b == 1 ? 5 : 7)
            pending[b] = []
          } else {
            pending[b] = indices
          }
        } else {
          entries.append((value, b == 3 ? 3 : b == 5 ? 4 : width))
        }
      }
      if reconstruct { coefficients.append(decoded) }
    }
    for (b, indices) in pending where !indices.isEmpty {
      let target = b == 4 ? 2 : 3
      let levels = b == 1 ? 3 : b == 2 ? 5 : 11
      var grouped = 0
      for i in 0..<target {
        grouped = grouped * levels + (i < indices.count ? entries[indices[i]].0 : levels / 2)
      }
      entries[indices[0]] = (grouped, b == 1 ? 5 : 7)
    }
    var result = BitWriter()
    for (value, width) in entries where width > 0 { result.write(value, width) }
    return .init(bits: result, coefficients: coefficients)
  }
}
