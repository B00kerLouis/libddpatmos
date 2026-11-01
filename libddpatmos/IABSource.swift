// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

/// IMF IAB clip-wrapped KLV reader. The frame index stores extents only; one IA
/// frame of PCM is cached. Track IDs remain stable when object order changes.
final class IABSource: DDPAudioSource {
  private(set) var info: DDPSourceInfo
  private let file: FileHandle
  private let index: DDPExtentIndex
  private let timeline: DDPMetadataIndex
  private let identity: DDPSourceIdentity
  private let objectMaps: DDPIABObjectMapIndex
  private var cursor: UInt64 = 0
  private let frameSamples: Int
  private var cachedFrame: UInt64?
  private var cachedPCM = [Float]()
  private static let labels = ["L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs", "Lts", "Rts"]
  private static let bedIDs = [0, 4, 2, 13, 5, 9, 7, 8, 11, 12]
  private struct Frame {
    var rate: Int, samples: Int, rateCode: Int, bits: Int
    var pcm = [Int: [Float]]()
    var beds = [(Int, Int, Double)]()
    var objects = [(Int, Int, [DDPPositionEvent])]()
  }
  init(url: URL, workingDirectory: URL? = nil, isCancelled: () -> Bool = { false }) throws {
    identity = try DDPSourceIdentity(url)
    timeline = try DDPMetadataIndex(directory: workingDirectory)
    index = try DDPExtentIndex(directory: timeline.directory)
    objectMaps = try DDPIABObjectMapIndex(directory: timeline.directory)
    file = try FileHandle(forReadingFrom: url)
    let length = try file.seekToEnd()
    let essenceKey: [UInt8] = [6, 14, 43, 52, 1, 2, 1, 1, 13, 1, 3, 1, 22, 1, 13, 1]
    var p: UInt64 = 0
    var extent: (UInt64, UInt64)?
    while p + 17 <= length {
      if isCancelled() { throw CancellationError() }
      let h = try BinaryIO.read(file, p, 17)
      let head = h[16]
      let width = head & 0x80 == 0 ? 0 : Int(head & 0x7f)
      guard width <= 8 else { throw DDPError.malformedInput("Invalid MXF BER length") }
      let size: UInt64
      if width == 0 {
        size = UInt64(head)
      } else {
        let b = try BinaryIO.read(file, p + 17, width)
        size = BinaryIO.integer(b, 0, width, big: true)
      }
      let value = p + 17 + UInt64(width)
      guard value <= length, size <= length - value else {
        throw DDPError.malformedInput("MXF KLV exceeds file")
      }
      if Array(h.prefix(16)) == essenceKey {
        extent = (value, size)
        break
      }
      p = value + size
    }
    guard let (start, size) = extent else {
      throw DDPError.malformedInput("No IMF IAB essence KLV")
    }
    p = start
    var initial: Frame?
    var presentBeds = Set<Int>()
    var slots = [Int: Int]()
    let inputFile = file
    let inputIdentity = identity
    let metadataTimeline = timeline
    let frameIndex = index
    let maps = objectMaps
    var lastStates = [Int: DDPPositionEvent]()
    while p < start + size {
      try autoreleasepool {
        if isCancelled() { throw CancellationError() }
        try inputIdentity.validate()
        let h = try BinaryIO.read(inputFile, p, 5)
        guard h[0] == 1 else { throw DDPError.malformedInput("IAB preamble tag missing at \(p)") }
        let pre = BinaryIO.integer(h, 1, 4, big: true)
        let tag = p + 5 + pre
        guard tag + 5 <= start + size else {
          throw DDPError.malformedInput("IAB preamble exceeds essence")
        }
        let ih = try BinaryIO.read(inputFile, tag, 5)
        let payload = BinaryIO.integer(ih, 1, 4, big: true)
        guard ih[0] == 2, payload <= 64 * 1024 * 1024, tag + 5 + payload <= start + size else {
          throw DDPError.malformedInput("Invalid IAB frame extent")
        }
        let frame = try Self.parseMetadata(file: inputFile, offset: tag + 5, length: Int(payload))
        if let initial {
          guard frame.samples == initial.samples, frame.rate == initial.rate else {
            throw DDPError.unsupported("IAB format changes within a clip")
          }
        } else {
          initial = frame
        }
        for (bed, _, _) in frame.beds { presentBeds.insert(bed) }
        let (baseSample, sampleOverflow) = frameIndex.count.multipliedReportingOverflow(
          by: UInt64(frame.samples))
        guard !sampleOverflow else { throw DDPError.malformedInput("IAB duration overflows") }
        var presentIDs = Set<Int>()
        for (id, _, _) in frame.objects {
          guard presentIDs.insert(id).inserted else {
            throw DDPError.malformedInput("Duplicate IAB object ID in frame")
          }
        }
        for id in Array(slots.keys) where !presentIDs.contains(id) {
          let slot = slots.removeValue(forKey: id)!
          var stopped = lastStates[slot] ?? .init(sample: baseSample, position: .centre)
          stopped.sample = baseSample
          stopped.gain = 0
          stopped.ramp = 0
          try metadataTimeline.append(stopped, channel: slot)
          lastStates[slot] = stopped
        }
        var occupied = Set(slots.values)
        for (id, _, events) in frame.objects {
          let slot: Int
          if let found = slots[id] {
            slot = found
          } else {
            guard let available = (10..<128).first(where: { !occupied.contains($0) }) else {
              throw DDPError.malformedInput("Too many simultaneous IAB objects")
            }
            slot = available
            occupied.insert(slot)
            slots[id] = slot
          }
          for var event in events {
            let (absolute, overflow) = event.sample.addingReportingOverflow(baseSample)
            guard !overflow else { throw DDPError.malformedInput("IAB event time overflows") }
            event.sample = absolute
            try metadataTimeline.append(event, channel: slot)
            lastStates[slot] = event
          }
        }
        try maps.append(slots)
        try frameIndex.append(offset: tag + 5, size: payload)
        p = tag + 5 + payload
      }
    }
    guard let initial else { throw DDPError.malformedInput("Empty IAB essence") }
    try timeline.seal()
    try index.seal()
    try objectMaps.seal()
    frameSamples = initial.samples
    let channels = (0..<128).map { slot in
      DDPSourceChannel(
        id: slot, label: slot < 10 ? Self.labels[slot] : nil,
        events: [
          .init(
            sample: 0,
            position: slot < 10 ? DDPSourceChannel.bedPosition(Self.labels[slot]) : .centre,
            gain: slot < 10 && presentBeds.contains(Self.bedIDs[slot]) ? 1 : 0)
        ])
    }
    info = .init(
      sampleRate: initial.rate, channelCount: 128,
      sampleCount: index.count * UInt64(frameSamples), channelMask: 0, channels: channels)
    info.indexedMetadataEvents = timeline.eventCount
    info.metadataIndexBytes =
      timeline.byteCount + index.count * UInt64(16 + DDPIABObjectMapIndex.recordWidth)
    try identity.validate(force: true)
  }
  func metadata(at sample: UInt64) throws -> [DDPPositionEvent] {
    try timeline.states(channels: info.channels, at: sample)
  }
  func validateIntegrity() throws { try identity.validate(force: true) }
  deinit { try? file.close() }
  func seek(to sample: UInt64) throws {
    guard sample <= info.sampleCount else {
      throw DDPError.invalidConfiguration("Seek beyond IAB clip")
    }
    cursor = sample
  }
  func read(frameCount: Int) throws -> [Float] {
    guard (1...65536).contains(frameCount) else {
      throw DDPError.invalidConfiguration("Invalid IAB read size")
    }
    try identity.validate()
    var left = Int(min(UInt64(frameCount), info.sampleCount - cursor))
    var out = [Float]()
    out.reserveCapacity(left * 128)
    while left > 0 {
      let i = cursor / UInt64(frameSamples)
      let within = Int(cursor % UInt64(frameSamples))
      if cachedFrame != i {
        let extent = try index.extent(i)
        let frame = try Self.parse(BinaryIO.read(file, extent.0, extent.1), audio: true)
        cachedPCM = [Float](repeating: 0, count: frameSamples * 128)
        for (bed, audio, gain) in frame.beds {
          if audio == 0 { continue }
          guard let slot = Self.bedIDs.firstIndex(of: bed), let values = frame.pcm[audio] else {
            throw DDPError.malformedInput("IAB bed references missing audio")
          }
          for f in 0..<frameSamples { cachedPCM[f * 128 + slot] += values[f] * Float(gain) }
        }
        let objectSlots = try objectMaps.mapping(i)
        for (id, audio, _) in frame.objects {
          if audio == 0 { continue }
          guard let slot = objectSlots[id], let values = frame.pcm[audio] else {
            throw DDPError.malformedInput("IAB object references missing audio")
          }
          // Object gain is retained in metadata and applied by spatial aggregation.
          for f in 0..<frameSamples { cachedPCM[f * 128 + slot] += values[f] }
        }
        cachedFrame = i
      }
      let n = min(left, frameSamples - within)
      out.append(contentsOf: cachedPCM[(within * 128)..<((within + n) * 128)])
      cursor += UInt64(n)
      left -= n
    }
    return out
  }
  private static func header<R: IABBitReading>(_ r: inout R) throws -> (Frame, Int) {
    guard try r.plex(8) == 8 else { throw DDPError.malformedInput("IAFrame element missing") }
    _ = try r.plex(8)
    guard try r.read(8) == 1 else { throw DDPError.unsupported("IAB version is not 1") }
    let sr = try r.read(2)
    let depth = try r.read(2)
    let fps = try r.read(4)
    guard sr < 2, depth < 2, fps < 10 else { throw DDPError.unsupported("Unsupported IAB format") }
    let rate = sr == 0 ? 48000 : 96000
    let counts = [2000, 1920, 1600, 1000, 960, 800, 500, 480, 400, 2002]
    let frame = Frame(
      rate: rate, samples: counts[fps] * (sr + 1), rateCode: fps, bits: depth == 0 ? 16 : 24)
    _ = try r.plex(8)
    r.align()
    let count = try r.plex(8)
    guard count <= 1024 else { throw DDPError.malformedInput("IAB child count exceeds limit") }
    return (frame, count)
  }
  private static func parse(_ bytes: [UInt8], audio: Bool) throws -> Frame {
    var r = BitReader(bytes: bytes)
    var (frame, count) = try header(&r)
    for _ in 0..<count {
      let id = try r.plex(8)
      let size = try r.plex(8)
      let start = r.position / 8
      guard size >= 0, size <= bytes.count - start else {
        throw DDPError.malformedInput("IAB child exceeds frame")
      }
      try consume(id: id, bytes: Array(bytes[start..<(start + size)]), frame: &frame, audio: audio)
      r.position = (start + size) * 8
    }
    return frame
  }
  private static func parseMetadata(file: FileHandle, offset: UInt64, length: Int) throws -> Frame {
    var r = DDPFileBitReader(file: file, offset: offset, length: length)
    var (frame, count) = try header(&r)
    for _ in 0..<count {
      let id = try r.plex(8)
      let size = try r.plex(8)
      let start = r.position / 8
      guard size >= 0, size <= length - start else {
        throw DDPError.malformedInput("IAB child exceeds frame")
      }
      if id == 0x10 || id == 0x40 || id == 0x200 {
        try consume(
          id: id, bytes: BinaryIO.read(file, offset + UInt64(start), size), frame: &frame,
          audio: false)
      }
      r.position = (start + size) * 8
    }
    return frame
  }
  private static func consume(id: Int, bytes: [UInt8], frame: inout Frame, audio: Bool) throws {
    var c = BitReader(bytes: bytes)
    let fps = frame.rateCode
    let sr = frame.rate == 48000 ? 0 : 1
    switch id {
    case 0x10:
      _ = try c.plex(8)
      if try c.read(1) == 1 { _ = try c.read(8) }
      let channels = try c.plex(4)
      guard channels <= 128 else { throw DDPError.malformedInput("IAB bed count exceeds limit") }
      for _ in 0..<channels {
        let bed = try c.plex(4)
        let aid = try c.plex(8)
        let gain = try readGain(&c)
        if try c.read(1) == 1 {
          _ = try c.read(4)
          if try c.read(2) > 1 { _ = try c.read(8) }
        }
        frame.beds.append((bed, aid, gain))
      }
    case 0x40:
      let object = try c.plex(8)
      let aid = try c.plex(8)
      if try c.read(1) == 1 {
        _ = try c.read(1)
        _ = try c.read(8)
      }
      _ = try c.read(1)
      let blocks = fps <= 2 || fps == 9 ? 8 : fps <= 5 ? 4 : 2
      var events = [DDPPositionEvent]()
      var sample = 0
      for b in 0..<blocks {
        defer {
          sample +=
            fps == 9 ? ([0, 4].contains(b) ? 251 : 250) * (sr + 1) : frame.samples / blocks
        }
        if b > 0, try c.read(1) == 0 { continue }
        let gain = try readGain(&c)
        _ = try c.read(3)
        let xCode = try c.read(16)
        let yCode = try c.read(16)
        let z = Double(try c.read(16)) / 65535
        guard xCode >= 32767, yCode >= 32767 else {
          throw DDPError.malformedInput("IAB position is outside the ST 2098-2 cube")
        }
        let x = Double(xCode - 32767) / 32768
        let y = Double(yCode - 32767) / 32768
        if try c.read(1) == 1 {
          if try c.read(1) == 1 { _ = try c.read(12) }
          _ = try c.read(1)
        }
        if try c.read(1) == 1 { for _ in 0..<9 { _ = try readGain(&c) } }
        let mode = try c.read(2)
        let spread: Double
        switch mode {
        case 0: spread = Double(try c.read(8)) / 255
        case 1: spread = 0
        case 2: spread = Double(try c.read(12)) / 4095
        default: throw DDPError.unsupported("Anisotropic IAB spread is unsupported")
        }
        _ = try c.read(4)
        if try c.read(2) > 1 { _ = try c.read(8) }
        events.append(
          .init(
            sample: UInt64(sample), position: .init(x: 2 * x - 1, y: 1 - 2 * y, z: z), gain: gain,
            spread: spread))
      }
      frame.objects.append((object, aid, events))
    case 0x400:
      if audio {
        let aid = try c.plex(8)
        let start = c.position / 8
        let stride = frame.bits / 8
        guard frame.samples * stride <= c.bytes.count - start else {
          throw DDPError.malformedInput("Short IAB PCM element")
        }
        var values = [Float]()
        values.reserveCapacity(frame.samples)
        let divisor = pow(2, Double(frame.bits - 1))
        for i in 0..<frame.samples {
          let raw = BinaryIO.integer(c.bytes, start + i * stride, stride)
          let signed = Int64(bitPattern: raw << (64 - frame.bits)) >> (64 - frame.bits)
          values.append(Float(Double(signed) / divisor))
        }
        frame.pcm[aid] = values
      }
    case 0x200: throw DDPError.unsupported("IAB DLC audio requires lossless DLC decoding")
    default: break
    }
  }
  private static func readGain(_ r: inout BitReader) throws -> Double {
    switch try r.read(2) {
    case 0: return 1
    case 1: return 0
    case 2:
      let code = try r.read(10)
      return code == 1023 ? 0 : pow(2, -Double(code) / 64)
    default: throw DDPError.malformedInput("Reserved IAB gain prefix")
    }
  }
}
