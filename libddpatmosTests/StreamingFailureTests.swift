// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import Testing

@testable import libddpatmos

struct StreamingFailureTests {
  private func fixture() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Build/Streaming/Tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let samples = 48000 * 6
    let channels = 2
    var bytes = Data("RIFF".utf8)
    func word(_ value: Int, _ width: Int) {
      for i in 0..<width { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
    }
    word(36 + samples * channels * 2, 4)
    bytes.append(Data("WAVEfmt ".utf8))
    word(16, 4)
    word(1, 2)
    word(channels, 2)
    word(48000, 4)
    word(48000 * channels * 2, 4)
    word(channels * 2, 2)
    word(16, 2)
    bytes.append(Data("data".utf8))
    word(samples * channels * 2, 4)
    bytes.append(Data(repeating: 0, count: samples * channels * 2))
    try bytes.write(to: root.appendingPathComponent("master.audio"))
    try Data(
      "audio: master.audio\nmetadata: master.metadata\nbedInstances:\n- channel: LFE\n  ID: 1\nobjects:\n- ID: 0\n"
        .utf8
    ).write(to: root.appendingPathComponent("master.atmos"))
    let file = FileManager.default.createFile(
      atPath: root.appendingPathComponent("master.metadata").path, contents: nil)
    #expect(file)
    let h = try FileHandle(forWritingTo: root.appendingPathComponent("master.metadata"))
    defer { try? h.close() }
    for i in 0..<10000 {
      try h.write(contentsOf: Data("- ID: 0\n  samplePos: \(i*16)\n  pos: [-0.6, 0.3, 0.4]\n".utf8))
    }
    return root
  }
  private func assertClean(_ root: URL) throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(!names.contains { $0.contains(".partial") || $0.hasPrefix(".ddpatmos-index-") })
    #expect(!names.contains("result.ec3"))
  }
  @Test func cancelledMetadataScanRemovesDiskIndexes() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var calls = 0
    #expect(throws: CancellationError.self) {
      try DDPFileEncoder.encode(
        input: root.appendingPathComponent("master.atmos"),
        output: root.appendingPathComponent("result.ec3"),
        isCancelled: {
          calls += 1
          return calls >= 6
        })
    }
    try assertClean(root)
  }
  @Test func changedCompanionPreventsPublicationAndCleansIndexes() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var changed = false
    let companion = root.appendingPathComponent("master.metadata")
    #expect(throws: DDPError.self) {
      try DDPFileEncoder.encode(
        input: root.appendingPathComponent("master.atmos"),
        output: root.appendingPathComponent("result.ec3"),
        progress: { _, _ in
          if !changed {
            changed = true
            // Same length with a new inode: a cached URL/size check is insufficient.
            let data = try! Data(contentsOf: companion)
            try! data.write(to: companion, options: .atomic)
          }
        })
    }
    #expect(changed)
    try assertClean(root)
  }
  @Test func rf64ExtendedTableSupports64BitRepeatedChunkSizes() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("sizes")
    var data = Data()
    for (name, size) in [
      ("axml", UInt64(1) << 35), ("JUNK", UInt64(50)), ("axml", UInt64(1) << 36),
    ] {
      data.append(Data(name.utf8))
      var little = size.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    try data.write(to: url)
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    #expect(
      try BinaryIO.extendedChunkSize(h, table: (0, 3), id: "axml", occurrence: 0) == UInt64(1) << 35
    )
    #expect(
      try BinaryIO.extendedChunkSize(h, table: (0, 3), id: "axml", occurrence: 1) == UInt64(1) << 36
    )
    #expect(throws: DDPError.self) {
      try BinaryIO.extendedChunkSize(h, table: (0, 3), id: "axml", occurrence: 2)
    }
  }
}
