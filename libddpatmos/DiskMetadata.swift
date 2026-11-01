// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

/// Derived indexes contain fixed-width metadata only. File encodes place them
/// beside the output; source-only clients may choose another scratch volume.
final class DDPScratchDirectory {
  let url: URL
  init(parent: URL?) throws {
    url = (parent ?? FileManager.default.temporaryDirectory).appendingPathComponent(
      ".ddpatmos-index-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  }
  deinit { try? FileManager.default.removeItem(at: url) }
}

/// One append buffer and one random-read page, each at most 64 KiB. No mmap or
/// programme-sized offsets array is retained. The owner externally serializes use.
final class DDPRecordFile {
  let width: Int
  private let directory: DDPScratchDirectory
  private let file: FileHandle
  private var pending = [UInt8]()
  private var page = [UInt8]()
  private var pageFirst: UInt64 = .max
  private var sealed = false
  private(set) var count: UInt64 = 0
  private var pageRecords: Int { 65536 / width }
  init(directory: DDPScratchDirectory, name: String, width: Int) throws {
    self.directory = directory
    self.width = width
    let url = directory.url.appendingPathComponent(name)
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw DDPError.io("Cannot create metadata index in \(directory.url.path)")
    }
    file = try FileHandle(forUpdating: url)
    pending.reserveCapacity(65536)
  }
  deinit { try? file.close() }
  func append(_ bytes: [UInt8]) throws {
    guard !sealed, bytes.count == width else { throw DDPError.io("Invalid metadata index append") }
    pending.append(contentsOf: bytes)
    count += 1
    if pending.count >= pageRecords * width { try flush() }
  }
  private func flush() throws {
    if !pending.isEmpty {
      try autoreleasepool { try file.write(contentsOf: Data(pending)) }
      pending.removeAll(keepingCapacity: true)
    }
  }
  func seal() throws {
    if sealed { return }
    try flush()
    pending = []
    sealed = true
  }
  func record(_ index: UInt64) throws -> [UInt8] {
    guard sealed, index < count else { throw DDPError.io("Metadata index read outside extent") }
    let first = index / UInt64(pageRecords) * UInt64(pageRecords)
    if first != pageFirst {
      let n = Int(min(UInt64(pageRecords), count - first))
      page = try BinaryIO.read(file, first * UInt64(width), n * width)
      pageFirst = first
    }
    let at = Int(index - first) * width
    return Array(page[at..<(at + width)])
  }
}

private func indexWords(_ values: [UInt64]) -> [UInt8] {
  values.flatMap { value in (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
}

/// Timelines use 64-byte events on disk and a bounded forward/binary-search
/// cursor for each admitted channel. Only the current and previous event are
/// needed to reproduce an explicit source ramp.
final class DDPMetadataIndex {
  private final class Track {
    let records: DDPRecordFile
    var lastAppended: UInt64?
    var lastQuery: UInt64?
    var current: UInt64 = 0
    init(_ records: DDPRecordFile) { self.records = records }
  }
  let directory: DDPScratchDirectory
  private var tracks = [Int: Track]()
  private(set) var eventCount: UInt64 = 0
  var byteCount: UInt64 { eventCount * 64 }
  init(directory: URL?) throws { self.directory = try DDPScratchDirectory(parent: directory) }
  func append(_ event: DDPPositionEvent, channel: Int) throws {
    guard (0..<128).contains(channel), event.sample <= UInt64.max - event.ramp,
      [event.position.x, event.position.y, event.position.z, event.gain, event.spread].allSatisfy({
        $0.isFinite
      })
    else { throw DDPError.malformedInput("Invalid spatial metadata event") }
    let track: Track
    if let existing = tracks[channel] {
      track = existing
    } else {
      track = Track(try DDPRecordFile(directory: directory, name: "track-\(channel)", width: 64))
      tracks[channel] = track
    }
    if let last = track.lastAppended, event.sample < last {
      throw DDPError.malformedInput("Spatial events are not ordered on channel \(channel)")
    }
    try track.records.append(
      indexWords([
        event.sample, event.position.x.bitPattern, event.position.y.bitPattern,
        event.position.z.bitPattern,
        event.gain.bitPattern, event.spread.bitPattern, event.ramp, 0,
      ]))
    track.lastAppended = event.sample
    eventCount += 1
  }
  func seal() throws { for track in tracks.values { try track.records.seal() } }
  private func event(_ track: Track, _ index: UInt64) throws -> DDPPositionEvent {
    let b = try track.records.record(index)
    func word(_ i: Int) -> UInt64 { BinaryIO.integer(b, i * 8, 8) }
    return .init(
      sample: word(0),
      position: .init(
        x: Double(bitPattern: word(1)),
        y: Double(bitPattern: word(2)), z: Double(bitPattern: word(3))),
      gain: Double(bitPattern: word(4)), spread: Double(bitPattern: word(5)), ramp: word(6))
  }
  func state(channel: Int, at sample: UInt64, fallback: DDPSourceChannel) throws -> DDPPositionEvent
  {
    guard let track = tracks[channel], track.records.count > 0 else {
      return fallback.state(at: sample)
    }
    let count = track.records.count
    var search = true
    if let last = track.lastQuery, sample >= last {
      var steps = 0
      while track.current + 1 < count, try event(track, track.current + 1).sample <= sample,
        steps < 64
      {
        track.current += 1
        steps += 1
      }
      if track.current + 1 < count {
        search = try event(track, track.current + 1).sample <= sample
      } else {
        search = false
      }
    }
    if search {
      var lo: UInt64 = 0
      var hi = count
      while lo < hi {
        let mid = lo + (hi - lo) / 2
        if try event(track, mid).sample <= sample { lo = mid + 1 } else { hi = mid }
      }
      track.current = lo == 0 ? 0 : lo - 1
    }
    track.lastQuery = sample
    var current = try event(track, track.current)
    if track.current > 0, current.ramp > 0, sample < current.sample + current.ramp {
      let previous = try event(track, track.current - 1)
      let t = Double(sample - current.sample) / Double(current.ramp)
      current.position = AtmosRoomPanner.blend(previous.position, current.position, t)
      current.gain = previous.gain + (current.gain - previous.gain) * t
    }
    return current
  }
  func states(channels: [DDPSourceChannel], at sample: UInt64) throws -> [DDPPositionEvent] {
    try channels.enumerated().map {
      try state(channel: $0.offset, at: sample, fallback: $0.element)
    }
  }
}

final class DDPExtentIndex {
  private let records: DDPRecordFile
  var count: UInt64 { records.count }
  init(directory: DDPScratchDirectory) throws {
    records = try DDPRecordFile(directory: directory, name: "frames", width: 16)
  }
  func append(offset: UInt64, size: UInt64) throws {
    try records.append(indexWords([offset, size]))
  }
  func seal() throws { try records.seal() }
  func extent(_ index: UInt64) throws -> (UInt64, Int) {
    let b = try records.record(index)
    return (BinaryIO.integer(b, 0, 8), Int(BinaryIO.integer(b, 8, 8)))
  }
}

/// A fresh stat (not URL's cached resource values) detects replacement,
/// truncation and in-place edits before publication and periodically during reads.
final class DDPSourceIdentity {
  private let url: URL
  private let size: UInt64
  private let modified: Date
  private let inode: UInt64
  private let device: UInt64
  private var lastCheck: UInt64 = 0
  init(_ url: URL) throws {
    self.url = url
    let a = try FileManager.default.attributesOfItem(atPath: url.path)
    size = (a[.size] as? NSNumber)?.uint64Value ?? 0
    modified = a[.modificationDate] as? Date ?? .distantPast
    inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    device = (a[.systemNumber] as? NSNumber)?.uint64Value ?? 0
  }
  func validate(force: Bool = false) throws {
    let now = DispatchTime.now().uptimeNanoseconds
    if !force, now - lastCheck < 1_000_000_000 { return }
    lastCheck = now
    let a = try FileManager.default.attributesOfItem(atPath: url.path)
    guard (a[.size] as? NSNumber)?.uint64Value == size,
      a[.modificationDate] as? Date == modified,
      (a[.systemFileNumber] as? NSNumber)?.uint64Value == inode,
      (a[.systemNumber] as? NSNumber)?.uint64Value == device
    else {
      throw DDPError.io("Input changed while processing: \(url.path)")
    }
  }
}

/// A bounded UTF-8 line reader handles metadata files of arbitrary total size;
/// the 64-MiB limit applies to one record, never to the whole programme.
func forEachMetadataLine(_ url: URL, isCancelled: () -> Bool, _ body: (String) throws -> Void)
  throws
{
  let file = try FileHandle(forReadingFrom: url)
  defer { try? file.close() }
  var pending = Data()
  var firstLine = true
  while try autoreleasepool(invoking: {
    if isCancelled() { throw CancellationError() }
    let data = try file.read(upToCount: 65536) ?? Data()
    if data.isEmpty { return false }
    pending.append(data)
    var start = pending.startIndex
    while let end = pending[start...].firstIndex(of: 10) {
      guard end - start <= 64 * 1024 * 1024 else {
        throw DDPError.malformedInput("Metadata record exceeds 64 MiB")
      }
      let stop = end > start && pending[end - 1] == 13 ? end - 1 : end
      guard var line = String(data: pending[start..<stop], encoding: .utf8) else {
        throw DDPError.malformedInput("Metadata is not UTF-8")
      }
      if firstLine {
        firstLine = false
        if line.first == "\u{FEFF}" { line.removeFirst() }
      }
      try body(line)
      start = end + 1
    }
    if start > pending.startIndex { pending = Data(pending[start...]) }
    guard pending.count <= 64 * 1024 * 1024 else {
      throw DDPError.malformedInput("Metadata record exceeds 64 MiB")
    }
    return true
  }) {}
  if !pending.isEmpty {
    if pending.last == 13 { pending.removeLast() }
    guard var line = String(data: pending, encoding: .utf8) else {
      throw DDPError.malformedInput("Metadata is not UTF-8")
    }
    if firstLine, line.first == "\u{FEFF}" { line.removeFirst() }
    try body(line)
  }
}

/// The incremental parser consumes exactly the axml extent, including extents beyond 4 GiB.
/// Adjacent WAVE chunks are never presented to the XML parser.
final class DDPFileRangeStream: InputStream {
  private let file: FileHandle
  private var remaining: UInt64
  private var status: Stream.Status = .notOpen
  private var failure: Error?
  init(url: URL, offset: UInt64, length: UInt64) throws {
    file = try FileHandle(forReadingFrom: url)
    try file.seek(toOffset: offset)
    remaining = length
    super.init(data: Data())
  }
  override func open() { status = .open }
  override func close() {
    try? file.close()
    status = .closed
  }
  override var streamStatus: Stream.Status { status }
  override var streamError: Error? { failure }
  override var hasBytesAvailable: Bool { status == .open && remaining > 0 }
  override func getBuffer(
    _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    length len: UnsafeMutablePointer<Int>?
  ) -> Bool { false }
  override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
    guard status == .open else { return status == .atEnd ? 0 : -1 }
    if remaining == 0 {
      status = .atEnd
      return 0
    }
    return autoreleasepool {
      do {
        let count = min(len, 65536, Int(min(remaining, UInt64(Int.max))))
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw DDPError.io("ADM XML became shorter while parsing") }
        data.copyBytes(to: buffer, count: count)
        remaining -= UInt64(count)
        return count
      } catch {
        failure = error
        status = .error
        return -1
      }
    }
  }
  deinit { try? file.close() }
}

protocol IABBitReading {
  var position: Int { get set }
  mutating func read(_ width: Int) throws -> Int
  mutating func plex(_ base: Int) throws -> Int
  mutating func align()
}
extension BitReader: IABBitReading {}

/// Header reads use a small page; PCM child extents are skipped during indexing.
struct DDPFileBitReader: IABBitReading {
  let file: FileHandle
  let offset: UInt64
  let length: Int
  var position = 0
  private var pageFirst = -1
  private var page = [UInt8]()
  init(file: FileHandle, offset: UInt64, length: Int) {
    self.file = file
    self.offset = offset
    self.length = length
  }
  mutating func read(_ width: Int) throws -> Int {
    guard (0...32).contains(width), position >= 0, width <= length * 8 - position else {
      throw DDPError.malformedInput("Truncated IAB field")
    }
    var result = 0
    for _ in 0..<width {
      let byte = position >> 3
      let first = byte / 4096 * 4096
      if first != pageFirst {
        page = try BinaryIO.read(file, offset + UInt64(first), min(4096, length - first))
        pageFirst = first
      }
      result = result << 1 | Int(page[byte - first] >> (7 - (position & 7)) & 1)
      position += 1
    }
    return result
  }
  mutating func align() { position = (position + 7) & ~7 }
  mutating func plex(_ base: Int) throws -> Int {
    let a = try read(base)
    if a != (1 << base) - 1 { return a }
    let b = try read(base * 2)
    return b != (1 << (base * 2)) - 1 ? b : try read(base * 4)
  }
}

/// Each IAB frame records its own ID-to-lane mapping. Object identities may
/// change between scenes without growing a programme-wide identity dictionary.
final class DDPIABObjectMapIndex {
  static let recordWidth = 8 + 118 * 16
  private let records: DDPRecordFile
  init(directory: DDPScratchDirectory) throws {
    records = try DDPRecordFile(directory: directory, name: "object-maps", width: Self.recordWidth)
  }
  func append(_ mapping: [Int: Int]) throws {
    guard mapping.count <= 118 else {
      throw DDPError.malformedInput("Too many simultaneous IAB objects")
    }
    var words = [UInt64(mapping.count)]
    for id in mapping.keys.sorted() {
      guard id >= 0, let slot = mapping[id], (10..<128).contains(slot) else {
        throw DDPError.malformedInput("Invalid IAB object mapping")
      }
      words.append(UInt64(id))
      words.append(UInt64(slot))
    }
    words.append(contentsOf: repeatElement(0, count: 237 - words.count))
    try records.append(indexWords(words))
  }
  func seal() throws { try records.seal() }
  func mapping(_ frame: UInt64) throws -> [Int: Int] {
    let bytes = try records.record(frame)
    let count = BinaryIO.integer(bytes, 0, 8)
    guard count <= 118 else { throw DDPError.io("Invalid IAB mapping index") }
    var result = [Int: Int]()
    for i in 0..<Int(count) {
      let id = BinaryIO.integer(bytes, 8 + i * 16, 8)
      let slot = BinaryIO.integer(bytes, 16 + i * 16, 8)
      guard id <= UInt64(Int.max), (10..<128).contains(slot), result[Int(id)] == nil else {
        throw DDPError.io("Invalid IAB mapping record")
      }
      result[Int(id)] = Int(slot)
    }
    return result
  }
}
