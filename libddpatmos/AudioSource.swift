// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

public struct DDPPosition: Sendable, Codable, Equatable {
  public var x: Double, y: Double, z: Double
  public init(x: Double, y: Double, z: Double) {
    self.x = x
    self.y = y
    self.z = z
  }
  static let centre = DDPPosition(x: 0, y: 0, z: 0)
}
public struct DDPPositionEvent: Sendable, Codable {
  public var sample: UInt64
  public var position: DDPPosition
  public var gain: Double
  public var spread: Double
  public var ramp: UInt64
  public init(
    sample: UInt64, position: DDPPosition, gain: Double = 1, spread: Double = 0, ramp: UInt64 = 0
  ) {
    self.sample = sample
    self.position = position
    self.gain = gain
    self.spread = spread
    self.ramp = ramp
  }
}
public struct DDPSourceChannel: Sendable, Codable {
  public var id: Int
  public var label: String?
  public var events: [DDPPositionEvent]
  public init(id: Int, label: String? = nil, events: [DDPPositionEvent] = []) {
    self.id = id
    self.label = label
    self.events = events
  }
  public func state(at sample: UInt64) -> DDPPositionEvent {
    if events.isEmpty { return DDPPositionEvent(sample: 0, position: Self.bedPosition(label)) }
    var lo = 0
    var hi = events.count
    while lo < hi {
      let m = (lo + hi) / 2
      if events[m].sample <= sample { lo = m + 1 } else { hi = m }
    }
    let index = max(0, lo - 1)
    var state = events[index]
    if index > 0, state.ramp > 0, sample < state.sample + state.ramp {
      let previous = events[index - 1]
      let t = Double(sample - state.sample) / Double(state.ramp)
      state.position = DDPPosition(
        x: previous.position.x + (state.position.x - previous.position.x) * t,
        y: previous.position.y + (state.position.y - previous.position.y) * t,
        z: previous.position.z + (state.position.z - previous.position.z) * t)
      state.gain = previous.gain + (state.gain - previous.gain) * t
    }
    return state
  }
  static func bedPosition(_ label: String?) -> DDPPosition {
    let positions: [String: DDPPosition] = [
      "L": .init(x: -1, y: 1, z: 0), "R": .init(x: 1, y: 1, z: 0), "C": .init(x: 0, y: 1, z: 0),
      "Lss": .init(x: -1, y: 0, z: 0), "Rss": .init(x: 1, y: 0, z: 0),
      "Lrs": .init(x: -1, y: -1, z: 0),
      "Rrs": .init(x: 1, y: -1, z: 0), "Lts": .init(x: -1, y: 0, z: 1),
      "Rts": .init(x: 1, y: 0, z: 1),
    ]
    return positions[label ?? ""] ?? .centre
  }
}

public struct DDPSourceInfo: Sendable, Codable {
  public var sampleRate: Int
  public var channelCount: Int
  public var sampleCount: UInt64
  public var channelMask: UInt32
  public var channels: [DDPSourceChannel]
  public var indexedMetadataEvents: UInt64? = nil
  public var metadataIndexBytes: UInt64? = nil
  public var isAtmos: Bool { !channels.isEmpty }
  public var duration: Double { Double(sampleCount) / Double(sampleRate) }
}

public protocol DDPAudioSource: AnyObject {
  var info: DDPSourceInfo { get }
  func seek(to sample: UInt64) throws
  func read(frameCount: Int) throws -> [Float]
  func metadata(at sample: UInt64) throws -> [DDPPositionEvent]
  func validateIntegrity() throws
}

extension DDPAudioSource {
  public func metadata(at sample: UInt64) throws -> [DDPPositionEvent] {
    info.channels.map { $0.state(at: sample) }
  }
  public func validateIntegrity() throws {}
}

/// Opens original media in place. Audio reads are bounded by the requested block;
/// chunk walking seeks over programme PCM and reads only format/metadata chunks.
public enum DDPMasterSource {
  public static func open(_ url: URL) throws -> any DDPAudioSource {
    try open(url, workingDirectory: nil)
  }
  public static func open(
    _ url: URL, workingDirectory: URL?,
    isCancelled: () -> Bool = { false }
  ) throws -> any DDPAudioSource {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw DDPError.io("Input does not exist: \(url.path)")
    }
    if isDirectory.boolValue {
      throw DDPError.invalidConfiguration("Select the DAMF .atmos manifest, not a directory")
    }
    switch url.pathExtension.lowercased() {
    case "atmos":
      return try DAMFSource.open(url, workingDirectory: workingDirectory, isCancelled: isCancelled)
    case "mxf":
      return try IABSource(url: url, workingDirectory: workingDirectory, isCancelled: isCancelled)
    case "wav", "wave", "rf64", "caf":
      return try PCMFileSource(
        url: url, workingDirectory: workingDirectory, isCancelled: isCancelled)
    default:
      throw DDPError.unsupported(
        "Supported inputs: WAVE/RF64, ADM BWF, CAF, DAMF .atmos and IAB MXF")
    }
  }
}

enum BinaryIO {
  static func read(_ file: FileHandle, _ offset: UInt64, _ count: Int) throws -> [UInt8] {
    return try autoreleasepool {
      guard count >= 0 else { throw DDPError.malformedInput("Negative read size") }
      try file.seek(toOffset: offset)
      let data = try file.read(upToCount: count) ?? Data()
      guard data.count == count else {
        throw DDPError.malformedInput(
          "Truncated input at byte \(offset), wanted \(count), got \(data.count)")
      }
      return Array(data)
    }
  }

  static func extendedChunkSize(
    _ file: FileHandle, table: (offset: UInt64, count: UInt64),
    id: String, occurrence: UInt64
  ) throws -> UInt64 {
    var found: UInt64 = 0
    var at: UInt64 = 0
    while at < table.count {
      let count = Int(min(4096, table.count - at))
      let bytes = try read(file, table.offset + at * 12, count * 12)
      for i in 0..<count where tag(bytes, i * 12) == id {
        if found == occurrence { return integer(bytes, i * 12 + 4, 8) }
        found += 1
      }
      at += UInt64(count)
    }
    throw DDPError.malformedInput("No ds64 extent for chunk \(id)")
  }
  static func integer(_ bytes: [UInt8], _ at: Int, _ width: Int, big: Bool = false) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<width { v |= UInt64(bytes[at + i]) << (8 * (big ? width - 1 - i : i)) }
    return v
  }
  static func tag(_ bytes: [UInt8], _ offset: Int = 0, _ length: Int = 4) -> String {
    String(bytes: bytes[offset..<(offset + length)].prefix { $0 != 0 }, encoding: .utf8) ?? ""
  }
}

final class PCMFileSource: DDPAudioSource {
  private(set) var info: DDPSourceInfo
  let file: FileHandle
  let dataOffset: UInt64
  let stride: Int
  let bits: Int
  let floating: Bool
  let bigEndian: Bool
  private var cursor: UInt64 = 0
  private var identities: [DDPSourceIdentity]
  private var metadataIndex: DDPMetadataIndex?
  init(url: URL, workingDirectory: URL? = nil, isCancelled: () -> Bool = { false }) throws {
    identities = [try DDPSourceIdentity(url)]
    let file = try FileHandle(forReadingFrom: url)
    self.file = file
    let length = try file.seekToEnd()
    let header = try BinaryIO.read(file, 0, 12)
    var channels = 0
    var rate = 0
    var bits = 0
    var stride = 0
    var offset: UInt64 = 0
    var size: UInt64 = 0
    var mask: UInt32 = 0
    var floating = false
    var big = false
    var xml: (offset: UInt64, size: UInt64)?
    var chna: [UInt8]?
    switch BinaryIO.tag(header) {
    case "RIFF", "RF64", "BW64":
      guard BinaryIO.tag(header, 8) == "WAVE" else {
        throw DDPError.malformedInput("RIFF input is not WAVE")
      }
      var p: UInt64 = 12
      var largeData: UInt64?
      var largeTable: (offset: UInt64, count: UInt64)?
      var largeOccurrences = [String: UInt64]()
      while p + 8 <= length {
        if isCancelled() { throw CancellationError() }
        let h = try BinaryIO.read(file, p, 8)
        let id = BinaryIO.tag(h)
        var n = BinaryIO.integer(h, 4, 4)
        if n == 0xffff_ffff {
          if id == "data" {
            guard let largeData else { throw DDPError.malformedInput("RF64 data lacks ds64 size") }
            n = largeData
          } else {
            guard let largeTable else {
              throw DDPError.malformedInput("RF64 chunk lacks ds64 table")
            }
            let occurrence = largeOccurrences[id, default: 0]
            n = try BinaryIO.extendedChunkSize(
              file, table: largeTable, id: id, occurrence: occurrence)
            largeOccurrences[id] = occurrence + 1
          }
        }
        guard n <= length - p - 8 else {
          throw DDPError.malformedInput("WAVE chunk \(id) exceeds file at \(p)")
        }
        let payload = p + 8
        if id == "ds64" {
          guard n >= 28, n <= 64 * 1024 * 1024 else {
            throw DDPError.malformedInput("Invalid ds64 table")
          }
          let d = try BinaryIO.read(file, payload, 28)
          largeData = BinaryIO.integer(d, 8, 8)
          let entries = BinaryIO.integer(d, 24, 4)
          guard entries <= (n - 28) / 12 else {
            throw DDPError.malformedInput("Truncated ds64 table")
          }
          largeTable = (payload + 28, entries)
        } else if id == "fmt " {
          guard (16...4096).contains(n) else {
            throw DDPError.malformedInput("Invalid WAVE format size")
          }
          let d = try BinaryIO.read(file, payload, Int(n))
          var code = Int(BinaryIO.integer(d, 0, 2))
          channels = Int(BinaryIO.integer(d, 2, 2))
          rate = Int(BinaryIO.integer(d, 4, 4))
          stride = Int(BinaryIO.integer(d, 12, 2))
          bits = Int(BinaryIO.integer(d, 14, 2))
          if code == 0xfffe {
            guard n >= 40 else { throw DDPError.malformedInput("Truncated extensible WAVE format") }
            mask = UInt32(BinaryIO.integer(d, 20, 4))
            code = Int(BinaryIO.integer(d, 24, 2))
          }
          guard code == 1 || code == 3 else {
            throw DDPError.unsupported("WAVE encoding \(code) is not PCM")
          }
          floating = code == 3
        } else if id == "data" {
          offset = payload
          size = n
        } else if id == "axml" {
          xml = (payload, n)
        } else if id == "chna" {
          guard n <= 64 * 1024 * 1024 else {
            throw DDPError.malformedInput("Track map exceeds 64 MiB")
          }
          chna = try BinaryIO.read(file, payload, Int(n))
        }
        p = payload + n + (n & 1)
      }
    case "caff":
      var p: UInt64 = 8
      while p + 12 <= length {
        let h = try BinaryIO.read(file, p, 12)
        let id = BinaryIO.tag(h)
        var n = BinaryIO.integer(h, 4, 8, big: true)
        let payload = p + 12
        // CAF permits -1 only for a terminal audio-data chunk.
        if n == UInt64.max, id == "data" { n = length - payload }
        guard n <= length - payload else { throw DDPError.malformedInput("CAF chunk exceeds file") }
        if id == "desc" {
          guard n >= 32 else { throw DDPError.malformedInput("Short CAF desc") }
          let d = try BinaryIO.read(file, payload, 32)
          rate = Int(Double(bitPattern: BinaryIO.integer(d, 0, 8, big: true)).rounded())
          guard BinaryIO.tag(d, 8) == "lpcm" else {
            throw DDPError.unsupported("CAF input must be lpcm")
          }
          let flags = BinaryIO.integer(d, 12, 4, big: true)
          let packet = BinaryIO.integer(d, 16, 4, big: true)
          let frames = BinaryIO.integer(d, 20, 4, big: true)
          guard frames > 0, flags & 32 == 0 else {
            throw DDPError.unsupported("Noninterleaved CAF is unsupported")
          }
          stride = Int(packet / frames)
          channels = Int(BinaryIO.integer(d, 24, 4, big: true))
          bits = Int(BinaryIO.integer(d, 28, 4, big: true))
          floating = flags & 1 != 0
          big = flags & 2 == 0
        } else if id == "data" {
          guard n >= 4 else { throw DDPError.malformedInput("Short CAF data") }
          offset = payload + 4
          size = n - 4
        }
        p = payload + n
      }
    default: throw DDPError.malformedInput("Input is not WAVE or CAF")
    }
    guard (1...128).contains(channels), (8000...192000).contains(rate),
      [16, 24, 32, 64].contains(bits),
      !floating || bits == 32 || bits == 64, floating || bits != 64,
      stride >= channels * (bits / 8), offset > 0, size % UInt64(stride) == 0
    else { throw DDPError.malformedInput("Invalid PCM format or data extent") }
    self.dataOffset = offset
    self.stride = stride
    self.bits = bits
    self.floating = floating
    bigEndian = big
    info = DDPSourceInfo(
      sampleRate: rate, channelCount: channels, sampleCount: size / UInt64(stride),
      channelMask: mask, channels: [])
    if let xml {
      guard let chna else { throw DDPError.malformedInput("ADM axml requires a chna track map") }
      let index = try DDPMetadataIndex(directory: workingDirectory)
      let stream = try DDPFileRangeStream(url: url, offset: xml.offset, length: xml.size)
      info.channels = try ADMSourceMetadata.parse(
        stream: stream, chna: chna, count: channels, rate: rate, index: index,
        isCancelled: isCancelled)
      try index.seal()
      metadataIndex = index
      try validateIntegrity()
      info.indexedMetadataEvents = index.eventCount
      info.metadataIndexBytes = index.byteCount
    }
  }
  deinit { try? file.close() }
  func metadata(at sample: UInt64) throws -> [DDPPositionEvent] {
    if let metadataIndex { return try metadataIndex.states(channels: info.channels, at: sample) }
    return info.channels.map { $0.state(at: sample) }
  }
  func validateIntegrity() throws {
    for identity in identities { try identity.validate(force: true) }
  }
  func addIdentity(_ identity: DDPSourceIdentity) { identities.append(identity) }
  func setChannels(_ channels: [DDPSourceChannel], index: DDPMetadataIndex? = nil) throws {
    guard channels.count == info.channelCount else {
      throw DDPError.malformedInput("Metadata channel count differs from PCM")
    }
    info.channels = channels
    metadataIndex = index
    info.indexedMetadataEvents = index?.eventCount
    info.metadataIndexBytes = index?.byteCount
  }
  func seek(to sample: UInt64) throws {
    guard sample <= info.sampleCount else {
      throw DDPError.invalidConfiguration("Seek beyond input end")
    }
    cursor = sample
  }
  func read(frameCount: Int) throws -> [Float] {
    guard frameCount > 0, frameCount <= 65536 else {
      throw DDPError.invalidConfiguration("PCM read size must be 1...65536 frames")
    }
    for identity in identities { try identity.validate() }
    let n = Int(min(UInt64(frameCount), info.sampleCount - cursor))
    let bytes = try BinaryIO.read(file, dataOffset + cursor * UInt64(stride), n * stride)
    var result = [Float]()
    result.reserveCapacity(n * info.channelCount)
    let divisor = pow(2, Double(bits - 1))
    for frame in 0..<n {
      for channel in 0..<info.channelCount {
        let raw = BinaryIO.integer(
          bytes, frame * stride + channel * (bits / 8), bits / 8, big: bigEndian)
        let value: Float
        if floating {
          value = bits == 32 ? Float(bitPattern: UInt32(raw)) : Float(Double(bitPattern: raw))
        } else {
          let signed = Int64(bitPattern: raw << (64 - bits)) >> (64 - bits)
          value = Float(Double(signed) / divisor)
        }
        guard value.isFinite, abs(value) <= 1 else {
          throw DDPError.malformedInput(
            "PCM out of normalized range at frame \(cursor+UInt64(frame)), channel \(channel)")
        }
        result.append(value)
      }
    }
    cursor += UInt64(n)
    return result
  }
}
