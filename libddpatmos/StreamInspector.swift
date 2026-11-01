// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

public struct DDPEMDFInfo: Sendable, Codable {
  public var bitOffset: Int
  public var byteCount: Int
  public var keyID: Int
  public var payloadIDs: [Int]
  public var primary: String
  public var secondary: String
}
public struct DDPStreamInfo: Sendable, Codable {
  public var sampleRate: Int
  public var channels: Int
  public var frameCount: UInt64
  public var accessUnits: UInt64
  public var sampleCount: UInt64
  public var bytes: UInt64
  public var crcFailures: UInt64
  public var atmosFrames: UInt64
  public var emdfFrames: UInt64
  public var firstEMDF: DDPEMDFInfo?
  public var bitrate: Double {
    sampleCount > 0 ? Double(bytes) * 8 * Double(sampleRate) / Double(sampleCount) : 0
  }
}

struct EMDFContainer {
  var offset: Int
  var body: [UInt8]
  var keyID: Int
  var payloads: [(Int, [UInt8])]
  var protectionStart: Int
  var primaryLength: Int
  var secondaryLength: Int
  var primary: [UInt8]
  var secondary: [UInt8]
  static func parse(_ data: [UInt8], at offset: Int) throws -> EMDFContainer {
    var r = BitReader(bytes: data, position: offset)
    guard try r.read(16) == 0x5838 else { throw DDPError.malformedInput("EMDF sync mismatch") }
    let size = try r.read(16)
    let start = r.position
    guard size > 0, size * 8 <= r.remaining else {
      throw DDPError.malformedInput("EMDF extent exceeds frame")
    }
    var body = [UInt8]()
    for _ in 0..<size { body.append(UInt8(try r.read(8))) }
    r = BitReader(bytes: body)
    var version = try r.read(2)
    if version == 3 { version += try r.variable(2) }
    guard version == 0 else { throw DDPError.unsupported("Unsupported EMDF version") }
    var key = try r.read(3)
    if key == 7 { key += try r.variable(3) }
    var payloads = [(Int, [UInt8])]()
    for _ in 0..<128 {
      var id = try r.read(5)
      if id == 0 { break }
      if id == 31 { id += try r.variable(5) }
      let sample = try r.read(1)
      if sample == 1 { _ = try r.read(12) }
      if try r.read(1) == 1 { _ = try r.variable(11) }
      if try r.read(1) == 1 { _ = try r.variable(2) }
      if try r.read(1) == 1 { _ = try r.read(8) }
      if try r.read(1) == 0 {
        let aligned = sample == 0 ? try r.read(1) : 0
        if aligned == 1 { _ = try r.read(2) }
        if sample == 1 || aligned == 1 { _ = try r.read(7) }
      }
      let n = try r.variable(8)
      guard n <= r.remaining / 8 else {
        throw DDPError.malformedInput("EMDF payload exceeds container")
      }
      var p = [UInt8]()
      for _ in 0..<n { p.append(UInt8(try r.read(8))) }
      payloads.append((id, p))
    }
    let lengths = [0, 1, 4, 16]
    let primaryLength = lengths[try r.read(2)]
    let secondaryLength = lengths[try r.read(2)]
    let protect = r.position
    guard primaryLength > 0 else {
      throw DDPError.malformedInput("EMDF primary protection is empty")
    }
    var primary = [UInt8]()
    var secondary = [UInt8]()
    for _ in 0..<primaryLength { primary.append(UInt8(try r.read(8))) }
    for _ in 0..<secondaryLength { secondary.append(UInt8(try r.read(8))) }
    guard r.remaining < 8, !payloads.isEmpty else {
      throw DDPError.malformedInput("Invalid EMDF tail")
    }
    _ = start
    return .init(
      offset: offset, body: body, keyID: key, payloads: payloads, protectionStart: protect,
      primaryLength: primaryLength, secondaryLength: secondaryLength, primary: primary,
      secondary: secondary)
  }
  static func find(_ bytes: [UInt8]) -> EMDFContainer? {
    var sync = 0
    for bit in 0..<(bytes.count * 8) {
      sync = ((sync << 1) | Int(bytes[bit >> 3] >> (7 - (bit & 7))) & 1) & 0xffff
      if sync == 0x5838, let result = try? parse(bytes, at: bit - 15) { return result }
    }
    return nil
  }
  var info: DDPEMDFInfo {
    .init(
      bitOffset: offset, byteCount: body.count, keyID: keyID, payloadIDs: payloads.map(\.0),
      primary: primary.map { String(format: "%02x", $0) }.joined(),
      secondary: secondary.map { String(format: "%02x", $0) }.joined())
  }
}

public enum DDPStreamInspector {
  public static func inspect(_ url: URL) throws -> DDPStreamInfo {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let size = try file.seekToEnd()
    var report = DDPStreamInfo(
      sampleRate: 0, channels: 0, frameCount: 0, accessUnits: 0, sampleCount: 0, bytes: size,
      crcFailures: 0, atmosFrames: 0, emdfFrames: 0)
    var offset: UInt64 = 0
    var independentMask: UInt64 = 0
    let modes: [UInt64] = [0x3, 0x4, 0x3, 0x7, 0x103, 0x107, 0x603, 0x607]
    let extensions: [UInt64] = [
      1, 4, 2, 512, 1024, 192, 48, 256, 2048,
      (1 << 33) | (1 << 34), (1 << 31) | (1 << 32), 0x5000, 0x2000, 0x28000, 1 << 35, 8,
    ]
    while offset < size {
      guard size - offset >= 7 else {
        throw DDPError.malformedInput("Truncated E-AC-3 header at byte \(offset)")
      }
      let h = try BinaryIO.read(file, offset, 7)
      var r = BitReader(bytes: h)
      guard try r.read(16) == 0x0b77 else {
        throw DDPError.malformedInput("Missing E-AC-3 syncword at byte \(offset)")
      }
      let type = try r.read(2)
      _ = try r.read(3)
      let bytes = (try r.read(11) + 1) * 2
      let sr = try r.read(2)
      let bc = try r.read(2)
      let mode = try r.read(3)
      let lfe = try r.read(1)
      let bsid = try r.read(5)
      guard bsid == 16, type < 2, UInt64(bytes) <= size - offset else {
        throw DDPError.malformedInput("Invalid E-AC-3 header at byte \(offset)")
      }
      let rate = sr == 3 ? [24000, 22050, 16000, 0][bc] : [48000, 44100, 32000][sr]
      guard rate > 0 else { throw DDPError.malformedInput("Reserved sample rate") }
      let count = [2, 1, 2, 3, 3, 4, 4, 5][mode] + lfe
      if type == 0 {
        if report.sampleRate != 0, report.sampleRate != rate {
          throw DDPError.unsupported("Sample rate changes within stream")
        }
        report.sampleRate = rate
        report.channels = max(report.channels, count)
        report.accessUnits += 1
        independentMask = modes[mode] | (lfe == 1 ? 8 : 0)
        report.sampleCount += UInt64((sr == 3 ? 6 : [1, 2, 3, 6][bc]) * 256)
      }
      let frame = try BinaryIO.read(file, offset, bytes)
      if type == 1 {
        guard independentMask != 0 else {
          throw DDPError.malformedInput("Dependent frame precedes its independent stream")
        }
        var q = BitReader(bytes: frame, position: 45)
        _ = try q.read(5)
        if try q.read(1) == 1 { _ = try q.read(8) }
        if mode == 0 {
          _ = try q.read(5)
          if try q.read(1) == 1 { _ = try q.read(8) }
        }
        var combined = independentMask
        if try q.read(1) == 1 {
          let map = try q.read(16)
          for bit in 0..<16 where map & (1 << (15 - bit)) != 0 { combined |= extensions[bit] }
        } else {
          combined |= modes[mode] | (lfe == 1 ? 8 : 0)
        }
        report.channels = max(report.channels, combined.nonzeroBitCount)
      }
      if DDPCRC.crc16(frame.dropFirst(2)) != 0 { report.crcFailures += 1 }
      if let emdf = EMDFContainer.find(frame) {
        report.emdfFrames += 1
        if emdf.payloads.contains(where: { $0.0 == 14 }) { report.atmosFrames += 1 }
        if report.firstEMDF == nil { report.firstEMDF = emdf.info }
      }
      report.frameCount += 1
      offset += UInt64(bytes)
    }
    return report
  }
}
