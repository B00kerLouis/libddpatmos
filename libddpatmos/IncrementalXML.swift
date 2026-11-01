// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
internal import libxml2

/// Incremental SAX parsing gives the caller an
/// explicit lifetime boundary every 64 KiB. Neither a document tree nor a
/// programme-sized autorelease pool is constructed. External entities are denied.
final class DDPXMLPushParser {
  private static let initialized: Void = { xmlInitParser() }()
  private let start: (String, [String: String]) throws -> Void
  private let text: (String) throws -> Void
  private let end: (String) throws -> Void
  private var context: xmlParserCtxtPtr?
  private var failure: Error?
  private var entityCount = 0
  private var entityBytes = 0
  init(
    start: @escaping (String, [String: String]) throws -> Void,
    text: @escaping (String) throws -> Void, end: @escaping (String) throws -> Void
  ) {
    self.start = start
    self.text = text
    self.end = end
  }
  private static func owner(_ pointer: UnsafeMutableRawPointer?) -> DDPXMLPushParser? {
    pointer.map { Unmanaged<DDPXMLPushParser>.fromOpaque($0).takeUnretainedValue() }
  }
  private func stop(_ error: Error) {
    if failure == nil { failure = error }
    if let context { xmlStopParser(context) }
  }
  private func entity(_ name: UnsafePointer<xmlChar>?, parameter: Bool) -> xmlEntityPtr? {
    guard let context else { return nil }
    let value =
      parameter ? xmlSAX2GetParameterEntity(context, name) : xmlSAX2GetEntity(context, name)
    guard let value else { return xmlGetPredefinedEntity(name) }
    let kind = value.pointee.etype
    guard
      kind == XML_INTERNAL_GENERAL_ENTITY || kind == XML_INTERNAL_PARAMETER_ENTITY
        || kind == XML_INTERNAL_PREDEFINED_ENTITY
    else {
      stop(DDPError.unsupported("External ADM XML entities are disabled"))
      return nil
    }
    return value
  }
  func parse(_ stream: InputStream, isCancelled: () -> Bool) throws {
    _ = Self.initialized
    var sax = xmlSAXHandler()
    sax.initialized = UInt32(XML_SAX2_MAGIC)
    sax.startDocument = { pointer in
      if let ctx = DDPXMLPushParser.owner(pointer)?.context { xmlSAX2StartDocument(ctx) }
    }
    sax.internalSubset = { pointer, name, externalID, systemID in
      if let ctx = DDPXMLPushParser.owner(pointer)?.context {
        xmlSAX2InternalSubset(ctx, name, externalID, systemID)
      }
    }
    sax.resolveEntity = { _, _, _ in nil }
    sax.getEntity = { DDPXMLPushParser.owner($0)?.entity($1, parameter: false) }
    sax.getParameterEntity = { DDPXMLPushParser.owner($0)?.entity($1, parameter: true) }
    sax.entityDecl = { pointer, name, kind, publicID, systemID, content in
      guard let self = DDPXMLPushParser.owner(pointer), let ctx = self.context else { return }
      self.entityCount += 1
      self.entityBytes += Int(xmlStrlen(content))
      guard self.entityCount <= 4096, self.entityBytes <= 64 * 1024 * 1024 else {
        self.stop(DDPError.malformedInput("ADM entity table exceeds limit"))
        return
      }
      xmlSAX2EntityDecl(ctx, name, kind, publicID, systemID, content)
    }
    sax.startElementNs = { pointer, local, _, _, _, _, count, _, attributes in
      guard let self = DDPXMLPushParser.owner(pointer), let local, self.failure == nil else {
        return
      }
      do {
        var values = [String: String]()
        if let attributes {
          for i in 0..<Int(count) {
            guard let name = attributes[i * 5], let first = attributes[i * 5 + 3],
              let last = attributes[i * 5 + 4]
            else { continue }
            let key = String(decodingCString: name, as: UTF8.self)
            if [
              "audioChannelFormatID", "audioChannelFormatName", "rtime", "coordinate", "gainUnit",
            ].contains(key) {
              let n = first.distance(to: last)
              guard n >= 0, n <= 64 * 1024 * 1024 else {
                throw DDPError.malformedInput("ADM attribute exceeds limit")
              }
              values[key] = String(
                decoding: UnsafeBufferPointer(start: first, count: n), as: UTF8.self)
            }
          }
        }
        try self.start(String(decodingCString: local, as: UTF8.self), values)
      } catch { self.stop(error) }
    }
    sax.characters = { pointer, bytes, count in
      guard let self = DDPXMLPushParser.owner(pointer), let bytes, self.failure == nil else {
        return
      }
      do {
        try self.text(
          String(decoding: UnsafeBufferPointer(start: bytes, count: Int(count)), as: UTF8.self))
      } catch { self.stop(error) }
    }
    sax.ignorableWhitespace = sax.characters
    sax.cdataBlock = sax.characters
    sax.endElementNs = { pointer, local, _, _ in
      guard let self = DDPXMLPushParser.owner(pointer), let local, self.failure == nil else {
        return
      }
      do { try self.end(String(decodingCString: local, as: UTF8.self)) } catch { self.stop(error) }
    }
    sax.serror = { pointer, error in
      guard let self = DDPXMLPushParser.owner(pointer), let error,
        error.pointee.level.rawValue >= XML_ERR_ERROR.rawValue
      else { return }
      let message =
        error.pointee.message.map {
          String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? "XML parse error"
      self.stop(DDPError.malformedInput("ADM XML line \(error.pointee.line): \(message)"))
    }
    guard
      let ctx = xmlCreatePushParserCtxt(
        &sax, Unmanaged.passUnretained(self).toOpaque(), nil, 0, nil)
    else {
      throw DDPError.io("Cannot create incremental XML parser")
    }
    context = ctx
    defer {
      let document = ctx.pointee.myDoc
      xmlFreeParserCtxt(ctx)
      if let document { xmlFreeDoc(document) }
      context = nil
    }
    let options = XML_PARSE_NONET.rawValue | XML_PARSE_NODICT.rawValue | XML_PARSE_NOENT.rawValue
    _ = xmlCtxtUseOptions(ctx, Int32(options))
    stream.open()
    defer { stream.close() }
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
    defer { buffer.deallocate() }
    while true {
      let n = try autoreleasepool { () throws -> Int in
        if isCancelled() { throw CancellationError() }
        let n = stream.read(buffer, maxLength: 65536)
        if n < 0 { throw stream.streamError ?? DDPError.io("ADM XML read failed") }
        let status = buffer.withMemoryRebound(to: CChar.self, capacity: 65536) {
          xmlParseChunk(ctx, n == 0 ? nil : $0, Int32(n), n == 0 ? 1 : 0)
        }
        if let failure { throw failure }
        guard status == 0 else { throw DDPError.malformedInput("Invalid ADM XML, code \(status)") }
        return n
      }
      if n == 0 { break }
    }
  }
}
