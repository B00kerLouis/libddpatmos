// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

enum DAMFSource {
  static func open(_ manifest: URL, workingDirectory: URL?, isCancelled: () -> Bool) throws
    -> PCMFileSource
  {
    let manifestIdentity = try DDPSourceIdentity(manifest)
    let folder = manifest.deletingLastPathComponent()
    var audio: String?
    var metadata: String?
    var label: String?
    var bed = false
    var objects = false
    var ids = [Int]()
    var labels = [Int: String]()
    try forEachMetadataLine(manifest, isCancelled: isCancelled) { raw in
      let parts = raw.trimmingCharacters(in: .whitespaces).split(
        separator: ":", maxSplits: 1, omittingEmptySubsequences: false
      )
      .map { $0.trimmingCharacters(in: .whitespaces) }
      if parts.count < 2 { return }
      switch parts[0] {
      case "audio": audio = parts[1]
      case "metadata": metadata = parts[1]
      case "bedInstances":
        bed = true
        objects = false
      case "objects":
        objects = true
        bed = false
      case "- channel", "channel": if bed { label = parts[1] }
      case "- ID", "ID":
        if bed || objects, let id = Int(parts[1]) {
          guard ids.count < 128, !ids.contains(id) else {
            throw DDPError.malformedInput("Duplicate or excess DAMF track ID")
          }
          ids.append(id)
          if bed { labels[id] = label }
          label = nil
        }
      default: break
      }
    }
    func resolve(_ name: String?, _ ext: String) throws -> URL {
      if let name {
        let u = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: u.path) { return u }
      }
      let sibling = manifest.deletingPathExtension().appendingPathExtension(ext)
      guard FileManager.default.fileExists(atPath: sibling.path) else {
        throw DDPError.io("DAMF \(ext) companion is missing")
      }
      return sibling
    }
    let pcm = try PCMFileSource(
      url: resolve(audio, "audio"), workingDirectory: workingDirectory, isCancelled: isCancelled)
    guard !ids.isEmpty else { throw DDPError.malformedInput("DAMF manifest has no tracks") }
    let packed = ids.count == pcm.info.channelCount
    if !packed, !ids.allSatisfy({ (0..<pcm.info.channelCount).contains($0) }) {
      throw DDPError.malformedInput("DAMF IDs do not fit CAF slots")
    }
    let mapping = packed ? ids : Array(0..<pcm.info.channelCount)
    let slots = Dictionary(
      uniqueKeysWithValues: mapping.enumerated().map { ($0.element, $0.offset) })
    let metadataURL = try resolve(metadata, "metadata")
    let metadataIdentity = try DDPSourceIdentity(metadataURL)
    let index = try DDPMetadataIndex(directory: workingDirectory)
    var previous = [Int: DDPPositionEvent]()
    var id: Int?
    var position: DDPPosition?
    var sample: UInt64 = 0
    var ramp: UInt64 = 0
    var gain = 1.0
    var spread = 0.0
    var changed = false
    func flush() throws {
      guard let id, changed else { return }
      guard let slot = slots[id] else {
        throw DDPError.malformedInput("Undeclared DAMF metadata ID \(id)")
      }
      let e = DDPPositionEvent(
        sample: sample,
        position: position ?? previous[id]?.position ?? DDPSourceChannel.bedPosition(labels[id]),
        gain: gain, spread: spread, ramp: ramp)
      try index.append(e, channel: slot)
      previous[id] = e
    }
    try forEachMetadataLine(metadataURL, isCancelled: isCancelled) { raw in
      let p = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      if p.count != 2 { return }
      switch p[0] {
      case "- ID", "ID":
        try flush()
        id = Int(p[1])
        position = nil
        ramp = 0
        changed = false
        gain = id.flatMap { previous[$0]?.gain } ?? 1
        spread = id.flatMap { previous[$0]?.spread } ?? 0
      case "samplePos":
        guard let s = UInt64(p[1]) else { throw DDPError.malformedInput("Invalid DAMF samplePos") }
        sample = s
      case "pos":
        let v = p[1].trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
          .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 3 else { throw DDPError.malformedInput("Invalid DAMF position") }
        position = .init(x: v[0], y: v[1], z: v[2])
        changed = true
      case "gain":
        guard let db = Double(p[1]), db.isFinite else {
          throw DDPError.malformedInput("Invalid DAMF gain")
        }
        gain = pow(10, db / 20)
        changed = true
      case "active":
        if p[1] == "false" {
          gain = 0
          changed = true
        }
      case "size":
        guard let value = Double(p[1]), value.isFinite else {
          throw DDPError.malformedInput("Invalid DAMF size")
        }
        spread = value
        changed = true
      case "rampLength":
        guard let value = UInt64(p[1]) else { throw DDPError.malformedInput("Invalid DAMF ramp") }
        ramp = value
      default: break
      }
    }
    try flush()
    try index.seal()
    try pcm.setChannels(mapping.map { DDPSourceChannel(id: $0, label: labels[$0]) }, index: index)
    pcm.addIdentity(manifestIdentity)
    pcm.addIdentity(metadataIdentity)
    try pcm.validateIntegrity()
    return pcm
  }
}

/// SAX parsing writes each completed block directly to the disk timeline. Only
/// the channel map, current XML field and current object block occupy RAM.
final class ADMSourceMetadata {
  private let rate: Int
  private let index: DDPMetadataIndex
  private let requested: [String: [Int]]
  private let isCancelled: () -> Bool
  private var channels: [DDPSourceChannel]
  private var found = Set<String>()
  private var currentID: String?, name: String?, coordinate: String?, text = ""
  private var capturingText = false
  private var textBytes = 0
  private var start: UInt64 = 0
  private var cartesian = true, coords = [String: Double](), gain = 1.0, spread = 0.0

  private init(
    rate: Int, index: DDPMetadataIndex, requested: [String: [Int]], channels: [DDPSourceChannel],
    isCancelled: @escaping () -> Bool
  ) {
    self.rate = rate
    self.index = index
    self.requested = requested
    self.channels = channels
    self.isCancelled = isCancelled
  }
  static func parse(
    stream: InputStream, chna: [UInt8], count: Int, rate: Int,
    index: DDPMetadataIndex, isCancelled: () -> Bool
  ) throws -> [DDPSourceChannel] {
    guard chna.count >= 4, Int(BinaryIO.integer(chna, 0, 2)) == count else {
      throw DDPError.malformedInput("ADM track count mismatch")
    }
    let records = Int(BinaryIO.integer(chna, 2, 2))
    guard records <= 128, chna.count >= 4 + records * 40 else {
      throw DDPError.malformedInput("Truncated chna records")
    }
    var requested = [String: [Int]]()
    var mapped = Set<Int>()
    var channels = (0..<count).map { DDPSourceChannel(id: $0) }
    let bedLabels = ["L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs", "Lts", "Rts"]
    var standard = Set<String>()
    for i in 0..<records {
      let at = 4 + i * 40
      let track = Int(BinaryIO.integer(chna, 4 + i * 40, 2)) - 1
      guard (0..<count).contains(track), mapped.insert(track).inserted else {
        throw DDPError.malformedInput("Invalid or duplicate chna track index")
      }
      let ref = BinaryIO.tag(chna, at + 14, 14)
      let key = "AC" + ref.dropFirst(2).prefix(9)
      requested[key, default: []].append(track)
      if key.hasPrefix("AC_000110"), let n = Int(key.suffix(2), radix: 16), (1...10).contains(n) {
        standard.insert(key)
        channels[track].label = bedLabels[n - 1]
      }
    }
    guard mapped.count == count else {
      throw DDPError.malformedInput("ADM does not map every track")
    }
    return try withoutActuallyEscaping(isCancelled) { cancel in
      let delegate = ADMSourceMetadata(
        rate: rate, index: index, requested: requested, channels: channels, isCancelled: cancel)
      let parser = DDPXMLPushParser(
        start: { try delegate.startElement($0, attributes: $1) },
        text: { try delegate.characters($0) }, end: { try delegate.endElement($0) })
      try parser.parse(stream, isCancelled: cancel)
      for key in requested.keys where !delegate.found.contains(key) && !standard.contains(key) {
        throw DDPError.malformedInput("Unresolved ADM channel \(key)")
      }
      return delegate.channels
    }
  }
  private func timestamp(_ value: String) throws -> UInt64 {
    let p = value.split(separator: ":").compactMap { Double($0) }
    let seconds = p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : Double(value) ?? 0
    let samples = (seconds * Double(rate)).rounded()
    guard samples.isFinite, samples >= 0, samples < Double(UInt64.max) else {
      throw DDPError.malformedInput("Invalid ADM timestamp")
    }
    return UInt64(samples)
  }
  func startElement(_ e: String, attributes a: [String: String]) throws {
    if isCancelled() { throw CancellationError() }
    text = ""
    textBytes = 0
    capturingText = false
    if e == "audioChannelFormat" {
      currentID = a["audioChannelFormatID"]
      name = a["audioChannelFormatName"]
      if let id = currentID, let slots = requested[id] {
        guard found.insert(id).inserted else {
          throw DDPError.malformedInput("Duplicate ADM channel format \(id)")
        }
        for slot in slots {
          channels[slot].label = name == "LFE" || name == "RoomCentricLFE" ? "LFE" : nil
        }
      }
    }
    guard let id = currentID, requested[id] != nil else { return }
    capturingText = ["position", "cartesian", "gain", "width", "height", "depth"].contains(e)
    if e == "audioBlockFormat" {
      start = try timestamp(a["rtime"] ?? "0")
      coords = [:]
      cartesian = true
      gain = 1
      spread = 0
    }
    if e == "position" { coordinate = a["coordinate"] }
    if e == "gain", a["gainUnit"] == "dB" { gain = -1 }
  }
  func characters(_ string: String) throws {
    guard capturingText else { return }
    let bytes = string.utf8.count
    guard textBytes + bytes <= 64 * 1024 * 1024 else {
      throw DDPError.malformedInput("ADM field exceeds 64 MiB")
    }
    textBytes += bytes
    text += string
  }
  func endElement(_ e: String) throws {
    guard let id = currentID, let slots = requested[id] else { return }
    let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if e == "position", let coordinate, let n = Double(v) { coords[coordinate.lowercased()] = n }
    if e == "cartesian" { cartesian = v == "1" }
    if e == "gain", let n = Double(v) { gain = gain == -1 ? pow(10, n / 20) : n }
    if ["width", "height", "depth"].contains(e), let n = Double(v) { spread = max(spread, n) }
    if e == "audioBlockFormat" {
      let p: DDPPosition
      if cartesian {
        p = .init(x: coords["x"] ?? 0, y: coords["y"] ?? 0, z: coords["z"] ?? 0)
      } else {
        let az = (coords["azimuth"] ?? 0) * .pi / 180
        let el = (coords["elevation"] ?? 0) * .pi / 180
        let d = coords["distance"] ?? 1
        p = .init(x: -sin(az) * cos(el) * d, y: cos(az) * cos(el) * d, z: sin(el) * d)
      }
      for slot in slots {
        try index.append(
          .init(sample: start, position: p, gain: gain, spread: min(1, spread)), channel: slot)
      }
    }
    if e == "audioChannelFormat" { currentID = nil }
  }
}
