import Testing
import Foundation
import MPXPrimeNative

// Confirms `mpx_enable_flush_to_zero()` actually sets the hardware FP
// control register flags. This is the standard defense against
// denormal-accumulation audio dropouts on Intel — see MPXPrimeNative.h
// for the rationale and the v0.30.2 / "white noise after a couple of
// songs" bug report that motivated it.
//
// Test strategy: build a REAL subnormal at run time (half the smallest
// normal Float, through a value the compiler cannot fold) on a FRESH thread
// and check the arithmetic produces a non-zero subnormal before the guard
// (the control) and exactly zero after it. The old test multiplied 1e-30 by
// (1e-5)^10 = 1e-80, which is below the smallest subnormal (1.4e-45) and
// underflows to 0.0 with or without flush-to-zero, so an empty
// `mpx_enable_flush_to_zero()` passed (test-suite review 2026-10
// finding 11). The FP control register is per-thread, so the check runs on
// its own thread: enabling FTZ on a shared test-pool thread would leak into
// every other test scheduled there.

private final class FloatPairBox: @unchecked Sendable {
    var value: (Float, Float) = (.nan, .nan)
}

/// Run `body` on a new thread and wait for its result.
private func onFreshThread(_ body: @escaping @Sendable () -> (Float, Float)) -> (Float, Float) {
    let box = FloatPairBox()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.value = body()
        done.signal()
    }
    thread.start()
    done.wait()
    return box.value
}

/// A runtime 0.5 the optimiser cannot see through: the product below must be
/// computed by the FPU, not folded at compile time.
@inline(never)
private func opaqueHalf() -> Float {
    Float(ProcessInfo.processInfo.processorCount > 0 ? 0.5 : 0.25)
}

/// Half the smallest normal Float: 5.9e-39, a subnormal.
private func subnormalProduct() -> Float {
    Float.leastNormalMagnitude * opaqueHalf()
}

@Suite("Denormal guard")
struct DenormalGuardTests {

    @Test func flushToZeroSilencesDenormalArithmetic() {
        let (before, after) = onFreshThread { () -> (Float, Float) in
            let before = subnormalProduct()
            mpx_enable_flush_to_zero()
            let after = subnormalProduct()
            return (before, after)
        }
        // Control: without the guard the product is a genuine subnormal, so
        // the measurement can see the flag.
        #expect(before != 0.0 && before.isSubnormal,
                "control failed: \(before) is not a subnormal, so the check below cannot fail")
        #expect(after == 0.0,
                "mpx_enable_flush_to_zero() did not silence denormal arithmetic -- got \(after). The audio thread will still hit the denormal slow path and produce dropouts after long sessions.")
    }

    /// The helper runs at the top of every render callback, so repeated calls
    /// must leave the flag set and normal arithmetic untouched.
    @Test func helperIsIdempotentAndLeavesNormalArithmeticAlone() {
        let (flushed, normal) = onFreshThread { () -> (Float, Float) in
            for _ in 0..<1000 { mpx_enable_flush_to_zero() }
            return (subnormalProduct(), Float.leastNormalMagnitude * (opaqueHalf() * 2.0))
        }
        #expect(flushed == 0.0, "after 1000 calls the flag is no longer effective: \(flushed)")
        #expect(normal == Float.leastNormalMagnitude, "FTZ changed a NORMAL result: \(normal)")
    }
}
