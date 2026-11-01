// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

/// A fixed room basis has continuous shared edges. In particular, crossing an
/// equidistant direction never replaces a nonzero third-nearest coefficient.
struct AtmosRoomPanner {
  let anchors: [DDPPosition]
  private let floorRows: [(Double, [Int])]
  private let heightRows: [(Double, [Int])]

  init(elements: Int) {
    precondition([11, 13, 15].contains(elements))
    var points: [DDPPosition] = [
      .init(x: -1, y: 1, z: 0), .init(x: 1, y: 1, z: 0), .init(x: 0, y: 1, z: 0),
      .init(x: -1, y: 0, z: 0), .init(x: 1, y: 0, z: 0),
      .init(x: -1, y: -1, z: 0), .init(x: 1, y: -1, z: 0),
    ]
    var floor: [(Double, [Int])] = [(1, [0, 2, 1])]
    if elements > 11 {
      points += [.init(x: -1, y: 0.65, z: 0), .init(x: 1, y: 0.65, z: 0)]
      floor.append((0.65, [7, 8]))
    }
    floor += [(0, [3, 4]), (-1, [5, 6])]
    let firstHeight = points.count
    points += [.init(x: -1, y: 1, z: 1), .init(x: 1, y: 1, z: 1)]
    var height: [(Double, [Int])] = [(1, [firstHeight, firstHeight + 1])]
    if elements == 15 {
      height.append((0, [points.count, points.count + 1]))
      points += [.init(x: -1, y: 0, z: 1), .init(x: 1, y: 0, z: 1)]
    }
    height.append((-1, [points.count, points.count + 1]))
    points += [.init(x: -1, y: -1, z: 1), .init(x: 1, y: -1, z: 1)]
    anchors = points
    floorRows = floor
    heightRows = height
  }

  func gains(at point: DDPPosition, spread: Double = 0) -> [Double] {
    let x = max(-1, min(1, point.x))
    let y = max(-1, min(1, point.y))
    let elevation = max(0, min(1, point.z)) * Double.pi / 2
    var result = [Double](repeating: 0, count: anchors.count)
    func row(_ indices: [Int], level: Double) {
      if x <= anchors[indices[0]].x {
        result[indices[0]] += level
        return
      }
      if x >= anchors[indices.last!].x {
        result[indices.last!] += level
        return
      }
      for i in 1..<indices.count where x <= anchors[indices[i]].x {
        let left = indices[i - 1]
        let right = indices[i]
        let angle = (x - anchors[left].x) / (anchors[right].x - anchors[left].x) * .pi / 2
        result[left] += level * cos(angle)
        result[right] += level * sin(angle)
        return
      }
    }
    func plane(_ rows: [(Double, [Int])], level: Double) {
      if y >= rows[0].0 {
        row(rows[0].1, level: level)
        return
      }
      for i in 1..<rows.count where y >= rows[i].0 {
        let angle = (rows[i - 1].0 - y) / (rows[i - 1].0 - rows[i].0) * .pi / 2
        row(rows[i - 1].1, level: level * cos(angle))
        row(rows[i].1, level: level * sin(angle))
        return
      }
      row(rows.last!.1, level: level)
    }
    plane(floorRows, level: cos(elevation))
    plane(heightRows, level: sin(elevation))
    let width = max(0, min(1, spread))
    if width > 0 {
      let diffuse = width / sqrt(Double(result.count))
      result = result.map { (1 - width) * $0 + diffuse }
      let norm = sqrt(result.reduce(0) { $0 + $1 * $1 })
      result = result.map { $0 / norm }
    }
    return result
  }

  static func coreGains(at point: DDPPosition) -> [Double] {
    let x = max(-1, min(1, point.x))
    let y = max(0, min(1, point.y))
    let front = y * Double.pi / 2
    let side = (x + 1) * Double.pi / 4
    var gains = [Double](repeating: 0, count: 5)
    if x < 0 {
      let angle = (x + 1) * Double.pi / 2
      gains[0] = cos(angle) * sin(front)
      gains[2] = sin(angle) * sin(front)
    } else {
      let angle = x * Double.pi / 2
      gains[2] = cos(angle) * sin(front)
      gains[1] = sin(angle) * sin(front)
    }
    gains[3] = cos(side) * cos(front)
    gains[4] = sin(side) * cos(front)
    return gains
  }

  static func blend(_ a: DDPPosition, _ b: DDPPosition, _ t: Double) -> DDPPosition {
    .init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t)
  }

  static func wirePosition(_ point: DDPPosition) -> DDPPosition {
    let x = max(0, min(62, Int(((point.x + 1) * 31).rounded())))
    let y = max(0, min(62, Int(((1 - point.y) * 31).rounded())))
    let z = max(0, min(15, Int((abs(point.z) * 15).rounded())))
    return .init(
      x: Double(x) / 31 - 1, y: 1 - Double(y) / 31, z: Double(z) / 15 * (point.z < 0 ? -1 : 1))
  }
}

struct AtmosSpatialFrame {
  var elements: [[Double]]
  var downmix: [[Double]]
  var lfe: [Double]
  let positions: [DDPPosition]
}

/// Control endpoints persist across access units. Zero-length master updates
/// become causal 1536-sample gain ramps; PCM itself is never low-pass filtered.
final class AtmosSpatialRenderer {
  private let source: DDPSourceInfo
  private let mode: DDPObjectMode
  private let threads: Int
  let panner: AtmosRoomPanner
  private var previousWeights: [[Double]?]
  private var previousGain: [Double?]
  private var previousPoints: [DDPPosition?]
  private var positions: [DDPPosition]
  private var previousPower: [Double]

  init(source: DDPSourceInfo, elements: Int, mode: DDPObjectMode, threads: Int = 1) {
    self.source = source
    self.mode = mode
    self.threads = threads
    panner = AtmosRoomPanner(elements: elements)
    previousWeights = .init(repeating: nil, count: source.channelCount)
    previousGain = .init(repeating: nil, count: source.channelCount)
    previousPoints = .init(repeating: nil, count: source.channelCount)
    positions = panner.anchors.map(AtmosRoomPanner.wirePosition)
    previousPower = .init(repeating: 0, count: elements)
  }

  func render(_ pcm: [Float], at sample: UInt64, states: [DDPPositionEvent]? = nil) throws
    -> AtmosSpatialFrame
  {
    if let states, states.count != source.channelCount {
      throw DDPError.malformedInput("Spatial metadata channel count differs from PCM")
    }
    let count = panner.anchors.count
    guard pcm.count == 1536 * source.channelCount else {
      throw DDPError.invalidConfiguration("Invalid Atmos spatial input block")
    }
    var buildingControls = [AtmosSourceControl]()
    for channel in 0..<source.channelCount {
      let state = states?[channel] ?? source.channels[channel].state(at: sample)
      let target = panner.gains(at: state.position, spread: state.spread)
      buildingControls.append(
        .init(
          from: previousWeights[channel] ?? target, target: target,
          fromGain: previousGain[channel] ?? state.gain, gain: state.gain,
          point: previousPoints[channel] ?? state.position, targetPoint: state.position,
          lfe: source.channels[channel].label == "LFE"))
      previousWeights[channel] = target
      previousGain[channel] = state.gain
      previousPoints[channel] = state.position
    }
    let controls = buildingControls
    let channels = source.channelCount
    let prepared = DDPParallel.map(count: channels, threads: threads) {
      channel -> AtmosPreparedSource? in
      let control = controls[channel]
      if control.lfe { return nil }
      var values = [Double](repeating: 0, count: 1536)
      var norms = [Double](repeating: 1, count: 1536)
      let dot = zip(control.from, control.target).reduce(0) { $0 + $1.0 * $1.1 }
      var active = false
      for f in 0..<1536 {
        let t = Double(f) / 1536
        let value =
          Double(pcm[f * channels + channel])
          * (control.fromGain + (control.gain - control.fromGain) * t)
        if value == 0 { continue }
        active = true
        values[f] = value
        norms[f] = sqrt(max(1e-20, (1 - t) * (1 - t) + t * t + 2 * t * (1 - t) * dot))
      }
      return active ? .init(control: control, values: values, norms: norms) : nil
    }.compactMap { $0 }
    // A worker owns one complete element. Source and sample summation order
    // within that element stays identical to the serial renderer.
    let mixed = DDPParallel.map(count: count, threads: threads) { k in
      var row = [Double](repeating: 0, count: 1536)
      var moment = [Double](repeating: 0, count: 4)
      for input in prepared {
        let control = input.control
        for f in 0..<1536 {
          let value = input.values[f]
          if value == 0 { continue }
          let t = Double(f) / 1536
          let weight =
            (control.from[k] + (control.target[k] - control.from[k]) * t) / input.norms[f]
          if weight < 1e-15 { continue }
          row[f] += value * weight
          let p = AtmosRoomPanner.blend(control.point, control.targetPoint, t)
          let energy = value * value
          let power = energy * weight * weight
          moment[0] += power * p.x
          moment[1] += power * p.y
          moment[2] += power * p.z
          moment[3] += power
        }
      }
      return AtmosElementMix(samples: row, moment: moment)
    }
    let elements = mixed.map { $0.samples }
    let moments = mixed.map { $0.moment }
    var lfe = [Double](repeating: 0, count: 1536)
    for channel in 0..<channels where controls[channel].lfe {
      let c = controls[channel]
      for f in 0..<1536 {
        let t = Double(f) / 1536
        lfe[f] += Double(pcm[f * channels + channel]) * (c.fromGain + (c.gain - c.fromGain) * t)
      }
    }
    let fromPositions = positions
    if mode == .dynamic {
      for k in 0..<count where moments[k][3] > 1e-14 {
        let m = moments[k]
        let old = positions[k]
        let target = DDPPosition(x: m[0] / m[3], y: m[1] / m[3], z: m[2] / m[3])
        let activeBefore = previousPower[k] > 1e-14
        let endpoint =
          activeBefore
          ? DDPPosition(
            x: old.x + max(-0.2, min(0.2, target.x - old.x)),
            y: old.y + max(-0.2, min(0.2, target.y - old.y)),
            z: old.z + max(-0.2, min(0.2, target.z - old.z))) : target
        positions[k] = AtmosRoomPanner.wirePosition(endpoint)
      }
    }
    previousPower = moments.map { $0[3] }
    let routes = (0..<count).map { k in
      (0...24).map { knot in
        AtmosRoomPanner.coreGains(
          at:
            AtmosRoomPanner.blend(fromPositions[k], positions[k], Double(knot * 64) / 1536))
      }
    }
    let routeNorms = routes.map { knots in
      (0..<24).map { block in
        let dot = zip(knots[block], knots[block + 1]).reduce(0) { $0 + $1.0 * $1.1 }
        return (0..<64).map { f in
          let t = Double(f) / 64
          return sqrt(max(1e-20, (1 - t) * (1 - t) + t * t + 2 * t * (1 - t) * dot))
        }
      }
    }
    let core = DDPParallel.map(count: 5, threads: threads) { c in
      var row = [Double](repeating: 0, count: 1536)
      for k in 0..<count {
        for block in 0..<24 {
          let a = routes[k][block][c]
          let b = routes[k][block + 1][c]
          for f in 0..<64 {
            let t = Double(f) / 64
            let n = block * 64 + f
            row[n] += elements[k][n] * (a + (b - a) * t) / routeNorms[k][block][f]
          }
        }
      }
      return row
    }
    guard lfe.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
      throw DDPError.malformedInput("Summed LFE exceeds normalized PCM range")
    }
    return .init(elements: elements, downmix: core, lfe: lfe, positions: positions)
  }
}

/// One complete future access unit supplies more than the 1024-sample attack
/// horizon. The gain at the next AU start therefore agrees with prior planning.
struct AtmosLookaheadLimiter {
  private var previousGain: Double?
  static let attackStep = 1.0 / 1024
  static let releaseStep = 1.0 / 4800

  mutating func process(_ frame: AtmosSpatialFrame, next: AtmosSpatialFrame?) -> AtmosSpatialFrame {
    var result = frame
    let all = frame.downmix.indices.map { frame.downmix[$0] + (next?.downmix[$0] ?? []) }
    var safe = (0..<all[0].count).map { f -> Double in
      let peak = all.reduce(0.0) { max($0, abs($1[f])) }
      return peak > 0.98 ? 0.98 / peak : 1
    }
    for f in (0..<(safe.count - 1)).reversed() {
      safe[f] = min(safe[f], safe[f + 1] + Self.attackStep)
    }
    var gain = previousGain ?? safe[0]
    for f in 0..<1536 {
      gain = min(safe[f], gain + Self.releaseStep)
      for c in 0..<5 { result.downmix[c][f] *= gain }
    }
    previousGain = gain
    return result
  }
}

private struct AtmosSourceControl: Sendable {
  let from: [Double], target: [Double]
  let fromGain: Double, gain: Double
  let point: DDPPosition, targetPoint: DDPPosition
  let lfe: Bool
}
private struct AtmosPreparedSource: Sendable {
  let control: AtmosSourceControl
  let values: [Double], norms: [Double]
}
private struct AtmosElementMix: Sendable {
  let samples: [Double], moment: [Double]
}
