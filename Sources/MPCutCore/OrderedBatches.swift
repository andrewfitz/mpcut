import Foundation

// Each slot has one writer. concurrentPerform joins all writers before the
// caller consumes their results in input order.
private final class BatchSlot<Value>: @unchecked Sendable {
    var result: Result<Value, Error>?
}

package func forEachOrderedBatch<Value>(
    count: Int, batchSize: Int, workerLimit: Int = 8,
    check: () throws -> Void,
    transform: (Range<Int>) throws -> Value,
    consume: (Value) throws -> Void
) throws {
    let workers = min(workerLimit, ProcessInfo.processInfo.activeProcessorCount)
    for start in stride(from: 0, to: count, by: batchSize * workers) {
        try check()
        let end = min(count, start + batchSize * workers)
        let ranges = stride(from: start, to: end, by: batchSize).map { $0..<min($0 + batchSize, end) }
        if ranges.count == 1 {
            try consume(transform(ranges[0]))
            continue
        }
        let slots = ranges.map { _ in BatchSlot<Value>() }
        DispatchQueue.concurrentPerform(iterations: ranges.count) { i in
            slots[i].result = Result { try transform(ranges[i]) }
        }
        for slot in slots {
            try check()
            try consume(slot.result!.get())
        }
    }
}
