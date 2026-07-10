// OSAllocatedUnfairLock polyfill for platforms without Apple's os module
// (the Linux CLI build). Same name and the same state-protecting API shape as
// os.OSAllocatedUnfairLock, so MPXGenerator's snapshot lock compiles
// unchanged via:
//
//   #if canImport(os)
//   import os
//   #else
//   import MPXPrimeAcceleration
//   #endif
//
// The backing mutex is a pthread mutex with PTHREAD_PRIO_INHERIT. That is
// deliberate: the macOS comment on the snapshot lock documents that
// os_unfair_lock's priority inheritance is load-bearing on the render path
// (an un-inherited holder can priority-invert the real-time audio thread).
// Swift's Synchronization.Mutex is futex-based without PI on Linux -- do not
// substitute it here. The pthread_mutex_t lives in explicitly allocated
// memory (not a Swift stored property) so its address is stable, as pthread
// requires.
#if !canImport(os)

#if canImport(Glibc)
import Glibc
#endif

public struct OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private final class Storage {
        var state: State
        let mutex: UnsafeMutablePointer<pthread_mutex_t>

        init(_ initialState: State) {
            state = initialState
            mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
            mutex.initialize(to: pthread_mutex_t())
            var attr = pthread_mutexattr_t()
            pthread_mutexattr_init(&attr)
            pthread_mutexattr_setprotocol(&attr, CInt(PTHREAD_PRIO_INHERIT))
            pthread_mutex_init(mutex, &attr)
            pthread_mutexattr_destroy(&attr)
        }

        deinit {
            pthread_mutex_destroy(mutex)
            mutex.deinitialize(count: 1)
            mutex.deallocate()
        }
    }

    private let storage: Storage

    public init(initialState: State) {
        storage = Storage(initialState)
    }

    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        pthread_mutex_lock(storage.mutex)
        defer { pthread_mutex_unlock(storage.mutex) }
        return try body(&storage.state)
    }
}

extension OSAllocatedUnfairLock where State == Void {
    public init() {
        self.init(initialState: ())
    }

    public func lock() {
        pthread_mutex_lock(storage.mutex)
    }

    public func unlock() {
        pthread_mutex_unlock(storage.mutex)
    }

    /// Non-blocking acquire, mirroring os.OSAllocatedUnfairLock's API --
    /// used by render threads that must never block on a producer.
    public func lockIfAvailable() -> Bool {
        pthread_mutex_trylock(storage.mutex) == 0
    }

    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        pthread_mutex_lock(storage.mutex)
        defer { pthread_mutex_unlock(storage.mutex) }
        return try body()
    }
}

#endif  // !canImport(os)
