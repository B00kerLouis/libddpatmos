// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Darwin
import Dispatch
import Foundation
import libddpatmos

@main struct DDPCommand {
  static func main() {
    do { try run(Array(CommandLine.arguments.dropFirst())) } catch is CancellationError {
      FileHandle.standardError.write(Data("ddpatmos: Encoding cancelled\n".utf8))
      exit(130)
    } catch {
      FileHandle.standardError.write(Data("ddpatmos: \(error)\n".utf8))
      exit(1)
    }
  }
  static func json<T: Encodable>(_ value: T, report: String? = nil) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    if let report { try data.write(to: URL(fileURLWithPath: report), options: .withoutOverwriting) }
    print(String(decoding: data, as: UTF8.self))
  }
  static func run(_ arguments: [String]) throws {
    if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
      print(help)
      return
    }
    if arguments == ["--version"] {
      print("ddpatmos 1.2.0 / Swift 6")
      return
    }
    var a = arguments
    var command = "encode"
    if ["encode", "inspect", "probe", "devices", "capture"].contains(a[0]) {
      command = a.removeFirst()
    }
    if command == "devices" {
      try json(DDPAudioCapture.devices())
      return
    }
    var input: String?
    var output: String?
    var reportPath: String?
    var device = "Pro Tools Audio Bridge 16"
    var options = DDPFileOptions()
    var i = 0
    func value() throws -> String {
      guard i + 1 < a.count else {
        throw DDPError.invalidConfiguration("Missing value after \(a[i])")
      }
      i += 1
      return a[i]
    }
    while i < a.count {
      switch a[i] {
      case "-i", "--input": input = try value()
      case "-o", "--output": output = try value()
      case "--device": device = try value()
      case "--report": reportPath = try value()
      case "-b", "--bitrate":
        let v = try value()
        guard let n = Int(v), [384, 448, 576, 640, 768].contains(n) else {
          throw DDPError.invalidConfiguration("Bitrate must be 384, 448, 576, 640 or 768 kbit/s")
        }
        options.configuration.bitrate = n
      case "--downmix-mode":
        let v = try value()
        guard let mode = DDPDownmixMode(rawValue: v.uppercased()) else {
          throw DDPError.invalidConfiguration("Downmix mode must be LTRT or LORO")
        }
        options.configuration.downmixMode = mode
      case "--layout":
        let v = try value()
        guard let layout = DDPChannelLayout(rawValue: v) else {
          throw DDPError.invalidConfiguration("Unknown layout \(v)")
        }
        options.layout = layout
      case "-j", "--threads":
        let v = try value()
        guard let n = Int(v), (0...128).contains(n) else {
          throw DDPError.invalidConfiguration("Threads must be 0 (automatic) through 128")
        }
        options.configuration.threads = n
      case "--dialnorm":
        let v = try value()
        if v.lowercased() == "measure" {
          options.loudnessMode = .measure
          options.configuration.dialogueLevel = -31
        } else {
          guard let n = Int(v) else {
            throw DDPError.invalidConfiguration("Dialnorm must be measure or -31...-1")
          }
          options.configuration.dialogueLevel = n
        }
      case "--loudness":
        guard let mode = DDPLoudnessMode(rawValue: try value().lowercased()) else {
          throw DDPError.invalidConfiguration("Loudness mode must be measure or off")
        }
        options.loudnessMode = mode
      case "--ture-peak-limter", "--true-peak-limiter":
        let v = try value()
        guard let n = Double(v), n.isFinite, (-60...0).contains(n) else {
          throw DDPError.invalidConfiguration("True peak limiter must be -60...0 dBTP")
        }
        options.truePeakLimitDBTP = n
      case "-sc", "--spatial-clusters":
        let v = try value()
        guard let n = Int(v), [12, 14, 16].contains(n) else {
          throw DDPError.invalidConfiguration("Spatial clusters must be 12, 14 or 16")
        }
        options.spatialElements = n
      case "--object-mode":
        let v = try value()
        guard let mode = DDPObjectMode(rawValue: v) else {
          throw DDPError.invalidConfiguration("Object mode must be dynamic or channelbase")
        }
        options.objectMode = mode
      case "--start":
        let v = try value()
        guard let n = Double(v) else {
          throw DDPError.invalidConfiguration("Invalid start seconds")
        }
        options.start = n
      case "--duration":
        let v = try value()
        guard let n = Double(v) else {
          throw DDPError.invalidConfiguration("Invalid duration seconds")
        }
        options.duration = n
      default:
        if command != "encode", input == nil, !a[i].hasPrefix("-") {
          input = a[i]
        } else {
          throw DDPError.invalidConfiguration("Unknown option: \(a[i])")
        }
      }
      i += 1
    }
    if command == "capture" {
      guard let output, let duration = options.duration else {
        throw DDPError.invalidConfiguration("capture requires --output and --duration")
      }
      try json(
        DDPAudioCapture.record(
          deviceName: device, duration: duration, output: URL(fileURLWithPath: output)),
        report: reportPath)
      return
    }
    guard let input else { throw DDPError.invalidConfiguration("--input is required") }
    let url = URL(fileURLWithPath: input)
    if command == "inspect" {
      try json(DDPStreamInspector.inspect(url), report: reportPath)
      return
    }
    if command == "probe" {
      try json(DDPMasterSource.open(url).info, report: reportPath)
      return
    }
    guard let output else { throw DDPError.invalidConfiguration("--output is required") }
    let cancellation = EncodingCancellation()
    let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(
        signal: number, queue: .global(qos: .userInitiated))
      source.setEventHandler { cancellation.cancel() }
      source.resume()
      return source
    }
    defer { for source in signals { source.cancel() } }
    let report = try DDPFileEncoder.encode(
      input: url, output: URL(fileURLWithPath: output), options: options,
      isCancelled: { cancellation.isCancelled })
    try json(report, report: reportPath)
  }
  static let help = """
    ddpatmos — native Swift 6 E-AC-3 encoder
    Copyright (c) 2026 B00kerLouis

    ddpatmos [-i INPUT] [-o OUTPUT.ec3] [options]
    ddpatmos inspect INPUT.ec3
    ddpatmos probe INPUT
    ddpatmos devices
    ddpatmos capture --device NAME --duration SECONDS -o CAPTURE.wav

    -i, --input PATH           PCM WAVE/CAF, ADM BWF, DAMF .atmos or IAB MXF
    -o, --output PATH          New E-AC-3 elementary stream (refuses overwrite)
    -b, --bitrate KBIT         384|448|576|640|768 kbit/s, optional, default 768
        --downmix-mode MODE   LTRT|LORO, default LTRT
        --layout LAYOUT       Ordinary PCM channel layout in WAVE order
        --dialnorm VALUE      measure (default), or explicit metadata -31...-1
        --loudness MODE       measure|off, default measure; never normalizes PCM
        --ture-peak-limter DBTP  Decoded EC3 peak ceiling, default -2.5 (-60...0)
    -sc,--spatial-clusters N   Atmos transport elements: 12|14|16, default 16
        --object-mode MODE    dynamic|channelbase, default dynamic
        --start SECONDS       Input start, default 0
        --duration SECONDS    Encode a bounded range
        --report PATH         Write JSON diagnostics to a new file
        -j, --threads N       CPU workers, 0 = automatic (default)
        --version             Print version
    -h, --help                Print usage
    """
}

/// Signal delivery occurs on a dispatch worker, not in the POSIX signal handler.
/// A lock synchronizes cancellation reads with signal delivery.
private final class EncodingCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func cancel() {
    lock.lock()
    value = true
    lock.unlock()
  }
}
