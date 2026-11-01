// Copyright (c) 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later

import Dispatch
import Foundation

/// Each worker owns disjoint result cells. concurrentPerform joins all workers
/// before results are read or freed. No codec instance is marked Sendable and
/// no access-unit state is shared between workers.
private final class DDPParallelResults<Value: Sendable>: @unchecked Sendable {
  let pointer: UnsafeMutablePointer<Value?>
  let count: Int
  init(count: Int) {
    self.count = count
    pointer = .allocate(capacity: count)
    pointer.initialize(repeating: nil, count: count)
  }
  deinit {
    pointer.deinitialize(count: count)
    pointer.deallocate()
  }
}

enum DDPParallel {
  static func map<Value: Sendable>(count: Int, threads: Int, _ body: @Sendable (Int) -> Value)
    -> [Value]
  {
    let workers = min(count, max(1, threads))
    if workers < 2 { return (0..<count).map(body) }
    let results = DDPParallelResults<Value>(count: count)
    DispatchQueue.concurrentPerform(iterations: workers) { worker in
      for i in stride(from: worker, to: count, by: workers) {
        results.pointer[i] = body(i)
      }
    }
    return (0..<count).map { results.pointer[$0]! }
  }
}
