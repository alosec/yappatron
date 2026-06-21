import Foundation

extension NSLock {
    @discardableResult
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}

final class CaptureGate: @unchecked Sendable {
    struct Snapshot {
        let isListening: Bool
        let generation: UInt64
    }

    private let lock = NSLock()
    private var isListening = false
    private var generation: UInt64 = 0

    @discardableResult
    func open() -> UInt64 {
        lock.withLock {
            generation &+= 1
            isListening = true
            return generation
        }
    }

    @discardableResult
    func close(invalidateQueuedAudio: Bool = false) -> UInt64 {
        lock.withLock {
            isListening = false
            if invalidateQueuedAudio {
                generation &+= 1
            }
            return generation
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(isListening: isListening, generation: generation)
        }
    }

    func shouldProcess(generation candidate: UInt64) -> Bool {
        lock.withLock {
            candidate == generation
        }
    }
}
