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
    guard count >= 0, batchSize > 0, workerLimit > 0 else {
        throw CutError(code: "invalid_arguments", message: "Invalid ordered batch size or worker count.")
    }
    let workers = min(workerLimit, ProcessInfo.processInfo.activeProcessorCount)
    var start = 0
    while start < count {
        try check()
        var ranges: [Range<Int>] = []
        while start < count, ranges.count < workers {
            let end = start + min(batchSize, count - start)
            ranges.append(start..<end)
            start = end
        }
        if ranges.count == 1 {
            let result = Result { try transform(ranges[0]) }
            try check()
            try consume(result.get())
            continue
        }
        let batch = ranges
        let slots = batch.map { _ in BatchSlot<Value>() }
        DispatchQueue.concurrentPerform(iterations: batch.count) { i in
            slots[i].result = Result { try transform(batch[i]) }
        }
        for slot in slots {
            try check()
            try consume(slot.result!.get())
        }
    }
}
