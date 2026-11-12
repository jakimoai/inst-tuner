import Foundation
import Synchronization

/// Lock-free single-producer, single-consumer sample queue.
/// `write` is safe to call on the real-time audio thread: it never locks or allocates.
public final class SampleRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    private let writeCounter = Atomic<Int>(0)
    private let readCounter = Atomic<Int>(0)

    public init(minimumCapacity: Int) {
        var size = 1
        while size < minimumCapacity { size <<= 1 }
        capacity = size
        mask = size - 1
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deallocate()
    }

    /// Producer side. Returns how many samples fit; the rest are dropped.
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        let written = writeCounter.load(ordering: .relaxed)
        let read = readCounter.load(ordering: .acquiring)
        let accepted = min(count, capacity - (written - read))
        guard accepted > 0 else { return 0 }

        let start = written & mask
        let firstRun = min(accepted, capacity - start)
        (storage + start).update(from: source, count: firstRun)
        if accepted > firstRun {
            storage.update(from: source + firstRun, count: accepted - firstRun)
        }
        writeCounter.store(written + accepted, ordering: .releasing)
        return accepted
    }

    /// Consumer side.
    public var availableToRead: Int {
        writeCounter.load(ordering: .acquiring) - readCounter.load(ordering: .relaxed)
    }

    /// Consumer side. Returns how many samples were copied.
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let written = writeCounter.load(ordering: .acquiring)
        let read = readCounter.load(ordering: .relaxed)
        let delivered = min(count, written - read)
        guard delivered > 0 else { return 0 }

        let start = read & mask
        let firstRun = min(delivered, capacity - start)
        destination.update(from: storage + start, count: firstRun)
        if delivered > firstRun {
            (destination + firstRun).update(from: storage, count: delivered - firstRun)
        }
        readCounter.store(read + delivered, ordering: .releasing)
        return delivered
    }

    /// Consumer side. Throws away everything waiting to be read.
    public func discardAll() {
        readCounter.store(writeCounter.load(ordering: .acquiring), ordering: .releasing)
    }
}
