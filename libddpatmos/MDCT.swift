// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Accelerate
import Foundation

/// 512-point lapped transform with the A/52 alpha=5 Kaiser-Bessel-derived window.
/// Immutable tables are shared; overlap belongs to the encoder instance.
enum DDPTransform {
  static let window: [Double] = {
    func i0(_ x: Double) -> Double {
      var sum = 1.0
      var term = 1.0
      for k in 1...60 {
        term *= x * x / (4 * Double(k * k))
        sum += term
        if term < sum * 1e-17 { break }
      }
      return sum
    }
    let kaiser = (0...256).map { i -> Double in
      let t = Double(i) / 128 - 1
      return i0(5 * .pi * sqrt(max(0, 1 - t * t)))
    }
    let total = kaiser.reduce(0, +)
    var accumulated = 0.0
    let half = (0..<256).map { i -> Double in
      accumulated += kaiser[i]
      return sqrt(accumulated / total)
    }
    return half + half.reversed()
  }()
  static let matrix: [Double] = (0..<256).flatMap { k in
    (0..<512).map { n in -cos(.pi / 256 * (Double(n) + 128.5) * (Double(k) + 0.5)) / 256 }
  }
  static func forward(previous: [Double], current: [Double]) -> [Double] {
    let x = zip(previous + current, window).map(*)
    var out = [Double](repeating: 0, count: 256)
    matrix.withUnsafeBufferPointer { m in
      x.withUnsafeBufferPointer { p in
        out.withUnsafeMutableBufferPointer { o in
          vDSP_mmulD(m.baseAddress!, 1, p.baseAddress!, 1, o.baseAddress!, 1, 256, 1, 512)
        }
      }
    }
    return out
  }

  private static let inverseMatrix: [Double] = (0..<512).flatMap { n in
    (0..<256).map { k in matrix[k * 512 + n] * 512 * window[n] }
  }

  /// Windowed synthesis of the exact serialized mantissas. The caller owns
  /// overlap-add state, just as an independent long-block decoder does.
  static func inverse(_ coefficients: [Double]) -> [Double] {
    var padded = coefficients
    padded.append(contentsOf: repeatElement(0, count: 256 - coefficients.count))
    var out = [Double](repeating: 0, count: 512)
    inverseMatrix.withUnsafeBufferPointer { m in
      padded.withUnsafeBufferPointer { p in
        out.withUnsafeMutableBufferPointer { o in
          vDSP_mmulD(m.baseAddress!, 1, p.baseAddress!, 1, o.baseAddress!, 1, 512, 1, 256)
        }
      }
    }
    return out
  }
}
