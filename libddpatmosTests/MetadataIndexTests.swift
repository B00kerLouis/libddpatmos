// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import Testing

@testable import libddpatmos

struct MetadataIndexTests {
  private func directory() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Build/Streaming/Tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  @Test func diskTimelineMatchesInlineRandomSeeksAndRamps() throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    var index: DDPMetadataIndex? = try .init(directory: folder)
    let scratch = index!.directory.url
    var events = [DDPPositionEvent]()
    for i in 0..<3500 {
      let point = DDPPosition(x: Double(i % 21) / 10 - 1, y: 0.2, z: 0.7)
      events.append(.init(sample: UInt64(i * 128), position: point,
        gain: Double(i % 7) / 6, spread: 0.2, ramp: i == 0 ? 0 : 64))
    }
    for event in events { try index!.append(event, channel: 0) }
    try index!.seal()
    let channel = DDPSourceChannel(id: 0, events: events)
    for n in [0, 1, 127, 128, 129, 160, 131071, 131072, 131100, 400000, 448000, 256, 131073] {
      let a = try index!.state(channel: 0, at: UInt64(n), fallback: .init(id: 0))
      let b = channel.state(at: UInt64(n))
      #expect(a.position == b.position && a.gain == b.gain && a.spread == b.spread)
    }
    #expect(index!.byteCount == 3500 * 64)
    index = nil
    #expect(!FileManager.default.fileExists(atPath: scratch.path))
  }
  @Test func extentIndexUses64BitOffsetsAcrossPages() throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let scratch = try DDPScratchDirectory(parent: folder)
    let index = try DDPExtentIndex(directory: scratch)
    for i in 0..<9000 {
      try index.append(offset: (1 << 34) + UInt64(i * 4096), size: UInt64(i + 1))
    }
    try index.seal()
    for i in [8999, 0, 4095, 4096, 8192, 42] {
      let value = try index.extent(UInt64(i))
      #expect(value.0 == (1 << 34) + UInt64(i * 4096) && value.1 == i + 1)
    }
  }
  @Test func identityRejectsSameSizeReplacement() throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("source")
    try Data([1, 2, 3]).write(to: url)
    let identity = try DDPSourceIdentity(url)
    try Data([4, 5, 6]).write(to: url, options: .atomic)
    #expect(throws: DDPError.self) { try identity.validate(force: true) }
  }
}
