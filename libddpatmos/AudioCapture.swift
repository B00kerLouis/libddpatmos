// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

public struct DDPAudioDevice: Sendable, Codable {
  public let id: UInt32
  public let name: String
  public let inputChannels: Int
  public let outputChannels: Int
  public let sampleRate: Double
  public let defaultOutput: Bool
}

public enum DDPAudioCapture {
  static func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
      throw DDPError.io("\(operation) failed with CoreAudio status \(status)")
    }
  }
  static func channels(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) throws -> Int {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size),
      "Read stream configuration size")
    let memory = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    try check(
      AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory),
      "Read stream configuration")
    return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
      .reduce(0) { $0 + Int($1.mNumberChannels) }
  }
  public static func devices() throws -> [DDPAudioDevice] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), "Enumerate audio devices"
    )
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    try check(
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids),
      "Read audio devices")
    var defaultDevice: AudioObjectID = 0
    address.mSelector = kAudioHardwarePropertyDefaultOutputDevice
    size = 4
    try check(
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &defaultDevice),
      "Read default output")
    return try ids.map { id in
      var name: Unmanaged<CFString>?
      address.mSelector = kAudioObjectPropertyName
      size = UInt32(MemoryLayout<CFString>.size)
      try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name), "Read device name")
      var rate = 0.0
      address.mSelector = kAudioDevicePropertyNominalSampleRate
      size = 8
      try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate), "Read device rate")
      let deviceName = name?.takeRetainedValue() as String? ?? "Unnamed device"
      return DDPAudioDevice(
        id: id, name: deviceName, inputChannels: try channels(id, kAudioDevicePropertyScopeInput),
        outputChannels: try channels(id, kAudioDevicePropertyScopeOutput), sampleRate: rate,
        defaultOutput: id == defaultDevice)
    }
  }
  /// Records a selected loopback device in physical order, without resampling
  /// or channel remapping. The bounded capture allocation precedes device start.
  public static func record(deviceName: String, duration: Double, output: URL) throws
    -> DDPCaptureReport
  {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw DDPError.io(
        "Audio recording permission is not granted to the launching application. Run capture from an authorized terminal or Xcode; denied input is delivered as silence by macOS."
      )
    }
    guard duration.isFinite, duration > 0, duration <= 120 else {
      throw DDPError.invalidConfiguration("Capture duration must be 0...120 seconds")
    }
    let matches = try devices().filter { $0.name == deviceName && $0.inputChannels > 0 }
    guard matches.count == 1 else {
      throw DDPError.invalidConfiguration("Expected exactly one input device named \(deviceName)")
    }
    let device = matches[0]
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw DDPError.io("Capture output already exists")
    }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(
      AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &format), "Read capture format"
    )
    guard format.mFormatID == kAudioFormatLinearPCM,
      format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32
    else { throw DDPError.unsupported("Capture device must expose native Float32 PCM") }
    let frames = Int((duration * format.mSampleRate).rounded())
    guard frames * device.inputChannels <= 32_000_000 else {
      throw DDPError.invalidConfiguration("Capture exceeds 128 MB PCM bound")
    }
    let state = CaptureState(channels: device.inputChannels, frames: frames)
    var proc: AudioDeviceIOProcID?
    let callback: AudioDeviceIOProc = { _, _, input, _, _, _, context in
      guard let context else { return noErr }
      let state = Unmanaged<CaptureState>.fromOpaque(context).takeUnretainedValue()
      state.consume(input)
      return noErr
    }
    let context = Unmanaged.passUnretained(state).toOpaque()
    try check(
      AudioDeviceCreateIOProcID(device.id, callback, context, &proc),
      "Create loopback capture callback")
    guard let proc else { throw DDPError.io("CoreAudio returned no capture callback") }
    defer { AudioDeviceDestroyIOProcID(device.id, proc) }
    try check(AudioDeviceStart(device.id, proc), "Start loopback capture")
    // This synchronous diagnostic API owns its calling worker. Stop completes
    // callback access before reading results; the UI must call on a worker.
    Thread.sleep(forTimeInterval: duration + 0.1)
    try check(AudioDeviceStop(device.id, proc), "Stop loopback capture")
    guard state.frames > 0 else { throw DDPError.io("No PCM arrived from capture device") }
    try state.writeWave(output, rate: Int(format.mSampleRate))
    var rms = [Double](repeating: 0, count: state.channels)
    var peak = rms
    for f in 0..<state.frames {
      for c in 0..<state.channels {
        let value = Double(state.pcm[f * state.channels + c])
        rms[c] += value * value
        peak[c] = max(peak[c], abs(value))
      }
    }
    rms = rms.map { sqrt($0 / Double(state.frames)) }
    return .init(device: device, frames: state.frames, rms: rms, peak: peak)
  }
}

public struct DDPCaptureReport: Sendable, Codable {
  public let device: DDPAudioDevice
  public let frames: Int
  public let rms: [Double]
  public let peak: [Double]
}

private final class CaptureState {
  let channels: Int
  let capacity: Int
  let pcm: UnsafeMutablePointer<Float>
  var frames = 0
  init(channels: Int, frames: Int) {
    self.channels = channels
    capacity = frames
    pcm = .allocate(capacity: channels * frames)
    pcm.initialize(repeating: 0, count: channels * frames)
  }
  deinit {
    pcm.deinitialize(count: channels * capacity)
    pcm.deallocate()
  }
  func consume(_ input: UnsafePointer<AudioBufferList>) {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard let first = buffers.first, first.mNumberChannels > 0 else { return }
    let available = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
    let n = min(available, capacity - frames)
    if n <= 0 { return }
    var channel = 0
    for b in buffers {
      let count = Int(b.mNumberChannels)
      if let data = b.mData?.assumingMemoryBound(to: Float.self) {
        let limit = min(n, Int(b.mDataByteSize) / (4 * max(1, count)))
        for f in 0..<limit {
          for c in 0..<count where channel + c < channels {
            pcm[(frames + f) * channels + channel + c] = data[f * count + c]
          }
        }
      }
      channel += count
    }
    frames += n
  }
  func writeWave(_ url: URL, rate: Int) throws {
    var data = Data()
    func u16(_ n: Int) {
      var v = UInt16(n).littleEndian
      withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    func u32(_ n: Int) {
      var v = UInt32(n).littleEndian
      withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: "RIFF".utf8)
    u32(36 + frames * channels * 4)
    data.append(contentsOf: "WAVEfmt ".utf8)
    u32(16)
    u16(3)
    u16(channels)
    u32(rate)
    u32(rate * channels * 4)
    u16(channels * 4)
    u16(32)
    data.append(contentsOf: "data".utf8)
    u32(frames * channels * 4)
    data.append(
      UnsafeBufferPointer(
        start: UnsafeRawPointer(pcm).assumingMemoryBound(to: UInt8.self),
        count: frames * channels * 4))
    try data.write(to: url, options: .withoutOverwriting)
  }
}
