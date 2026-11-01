// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import Testing

@testable import libddpatmos

struct IncrementalXMLTests {
  private func parse(_ data: Data, cancelled: () -> Bool = { false }) throws -> DDPPositionEvent {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Build/Streaming/Tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let index = try DDPMetadataIndex(directory: folder)
    var chna = [UInt8](repeating: 0, count: 44)
    chna[0] = 1
    chna[2] = 1
    chna[4] = 1
    for (i, b) in "AT_00031001_01".utf8.enumerated() { chna[18 + i] = b }
    let channels = try ADMSourceMetadata.parse(
      stream: InputStream(data: data), chna: chna, count: 1, rate: 48000, index: index,
      isCancelled: cancelled)
    try index.seal()
    return try index.state(channel: 0, at: 0, fallback: channels[0])
  }
  private var xml: String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE root [<!ENTITY level "0.25">]>
    <a:root xmlns:a="urn:ebu:metadata-schema:ebuCore_2017">
      <a:audioChannelFormat audioChannelFormatID="AC_00031001" audioChannelFormatName="Object &amp; sound">
        <a:audioBlockFormat rtime="00:00:00.000000">
          <a:cartesian>1</a:cartesian><a:position coordinate="X"><![CDATA[-0.6]]></a:position>
          <a:position coordinate="Y">0.3</a:position><a:position coordinate="Z">0.4</a:position>
          <a:gain>&level;</a:gain>
        </a:audioBlockFormat>
      </a:audioChannelFormat>
    </a:root>
    """
  }
  @Test func namespaceCDATAAndInternalEntitiesPreserveValues() throws {
    let state = try parse(Data(xml.utf8))
    #expect(state.position == .init(x: -0.6, y: 0.3, z: 0.4) && state.gain == 0.25)
  }
  @Test func UTF16InputIsIncrementallyDecoded() throws {
    let source = xml.replacingOccurrences(of: "encoding=\"UTF-8\"", with: "encoding=\"UTF-16\"")
    var bytes = Data([0xff, 0xfe])
    bytes.append(try #require(source.data(using: .utf16LittleEndian)))
    #expect(try parse(bytes).gain == 0.25)
  }
  @Test func malformedXMLAndExternalEntitiesFail() throws {
    #expect(throws: DDPError.self) { try parse(Data(xml.dropLast(12).utf8)) }
    let external = xml.replacingOccurrences(
      of: "<!ENTITY level \"0.25\">",
      with: "<!ENTITY level SYSTEM \"file:///ddpatmos-test-no-external-entity\">")
    #expect(throws: DDPError.self) { try parse(Data(external.utf8)) }
  }
  @Test func cancellationIsCheckedWithinLongText() throws {
    let data = Data(
      xml.replacingOccurrences(
        of: "<![CDATA[-0.6]]>",
        with: "<![CDATA[-0.6" + String(repeating: " ", count: 300000) + "]]>"
      ).utf8)
    var calls = 0
    #expect(throws: CancellationError.self) {
      try parse(
        data,
        cancelled: {
          calls += 1
          return calls > 8
        })
    }
  }
  @Test func metadataLinesHandleBOMAndCRLF() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("lines")
    try Data("\u{FEFF}first\r\nsecond\r\nthird\r".utf8).write(to: url)
    var lines = [String]()
    try forEachMetadataLine(url, isCancelled: { false }) { lines.append($0) }
    #expect(lines == ["first", "second", "third"])
  }
}
