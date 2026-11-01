// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

struct BitWriter: Sendable {
  var bytes = [UInt8]()
  var authenticationExclusions = [Range<Int>]()
  var emdfBitOffset: Int?
  private(set) var count = 0
  mutating func write(_ value: Int, _ width: Int) {
    precondition((0...32).contains(width))
    for shift in (0..<width).reversed() {
      if count & 7 == 0 { bytes.append(0) }
      bytes[count >> 3] |= UInt8((value >> shift) & 1) << (7 - (count & 7))
      count += 1
    }
  }
  mutating func append(_ data: [UInt8], bits: Int? = nil) {
    for i in 0..<(bits ?? data.count * 8) { write(Int(data[i >> 3] >> (7 - (i & 7))) & 1, 1) }
  }
  mutating func pad(to bitCount: Int) {
    precondition(bitCount >= count)
    while count < bitCount { write(0, min(32, bitCount - count)) }
  }
  mutating func align() { pad(to: (count + 7) & ~7) }
  /// Compacts included bits and rounds the result to the nearest 16-bit word.
  /// Remainders 0...15 have explicit regression coverage.
  func authenticatedAudioBytes() -> [UInt8] {
    let ranges = authenticationExclusions.sorted { $0.lowerBound < $1.lowerBound }
    var packed = BitWriter()
    var rangeIndex = 0
    for bit in 0..<count {
      while rangeIndex < ranges.count, ranges[rangeIndex].upperBound <= bit { rangeIndex += 1 }
      if rangeIndex < ranges.count, ranges[rangeIndex].contains(bit) { continue }
      packed.write(Int(bytes[bit >> 3] >> (7 - (bit & 7))) & 1, 1)
    }
    let byteCount = ((packed.count + 8) / 16) * 2
    if packed.bytes.count < byteCount {
      packed.bytes += repeatElement(0, count: byteCount - packed.bytes.count)
    }
    return Array(packed.bytes.prefix(byteCount))
  }
  mutating func variable(_ value: Int, width: Int) {
    precondition(value >= 0 && width > 0 && width <= 16)
    let base = 1 << width
    var value = value
    var groups = [value % base]
    while value >= base {
      value = value / base - 1
      groups.append(value % base)
    }
    for i in groups.indices.reversed() {
      write(groups[i], width)
      write(i > 0 ? 1 : 0, 1)
    }
  }
}

struct BitReader {
  let bytes: [UInt8]
  var position = 0
  var remaining: Int { bytes.count * 8 - position }
  mutating func read(_ width: Int) throws -> Int {
    guard (0...32).contains(width), width <= remaining else {
      throw DDPError.malformedInput("Truncated bit field at bit \(position), width \(width)")
    }
    var value = 0
    for _ in 0..<width {
      value = value << 1 | Int((bytes[position >> 3] >> (7 - (position & 7))) & 1)
      position += 1
    }
    return value
  }
  mutating func align() { position = (position + 7) & ~7 }
  mutating func variable(_ width: Int) throws -> Int {
    var result = 0
    for _ in 0..<8 {
      guard result < Int.max >> (width + 1) else {
        throw DDPError.malformedInput("Variable field overflows")
      }
      result = (result << width) | (try read(width))
      if try read(1) == 0 { return result }
      result += 1
    }
    throw DDPError.malformedInput("Variable field exceeds eight groups")
  }
  mutating func plex(_ base: Int) throws -> Int {
    let a = try read(base)
    if a != (1 << base) - 1 { return a }
    let b = try read(base * 2)
    return b != (1 << (base * 2)) - 1 ? b : try read(base * 4)
  }
}

enum DDPCRC {
  /// A/52 CRC-16, MSB first, initial remainder zero, polynomial x16+x15+x2+1.
  static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
    var crc: UInt16 = 0
    for b in bytes {
      crc ^= UInt16(b) << 8
      for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x8005 : crc &<< 1 }
    }
    return crc
  }
  static func finishFrame(_ bytes: inout [UInt8]) {
    let n = bytes.count
    var crc = crc16(bytes[2..<(n - 2)])
    if crc == 0x0b77 {
      bytes[n - 3] ^= 1
      crc ^= 0x8005
    }
    bytes[n - 2] = UInt8(crc >> 8)
    bytes[n - 1] = UInt8(truncatingIfNeeded: crc)
  }
}
