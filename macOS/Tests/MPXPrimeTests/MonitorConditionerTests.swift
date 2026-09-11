import Testing
import Atomics
import Foundation
import MPXPrimeCore
@testable import MPXPrime

/// The monitor conditioner: what the operator HEARS in each operating mode.
///
/// The contract is "sounds like the receiving end", so the interesting
/// assertion is that a pre-emphasised feed comes back FLAT -- if this drifts,
/// the monitor lies about the tonal balance and an operator would EQ against
/// a curve that is not on air.
@Suite("Monitor conditioner")
struct MonitorConditionerTests {

    private let sampleRate: Float = 48_000

    /// Level of `freq` in the conditioned output, relative to the level of the
    /// ORIGINAL programme before pre-emphasis, in dB. 0 means the monitor plays
    /// what went into the chain -- which is what a receiver plays.
    ///
    /// The tone is snapped to an exact analysis bin: de-emphasis shifts phase,
    /// and an off-bin Goertzel leaks by an amount that depends on phase, which
    /// would show up here as a response error that is not there.
    private func conditionedResponseDB(
        curve: PreemphasisCurve, freq: Double, shape: MonitorConditioner.Shape
    ) -> Double {
        let frames = 24_000
        let skip = 4_000
        let span = Double(frames - skip)
        let bin = max(1.0, (span * freq / Double(sampleRate)).rounded())
        let tone = bin * Double(sampleRate) / span
        var preL = PreemphasisFilter()
        var preR = PreemphasisFilter()
        preL.configure(curve: curve, sampleRate: sampleRate)
        preR.configure(curve: curve, sampleRate: sampleRate)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        var source = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let s = Float(0.05 * sin(2.0 * .pi * tone * Double(i) / Double(sampleRate)))
            source[i] = s
            left[i] = preL.process(s)
            right[i] = preR.process(s)
        }
        let inputLevel = goertzel(source, freqHz: tone, startFrame: skip)

        var cond = MonitorConditioner()
        cond.configure(shape: shape, sampleRate: sampleRate, gainDB: 0)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                // swiftlint:disable:next force_unwrapping
                cond.process(left: l.baseAddress!, right: r.baseAddress!, frameCount: frames)
            }
        }
        let outputLevel = goertzel(left, freqHz: tone, startFrame: skip)
        return 20.0 * log10(max(1e-12, outputLevel / max(1e-12, inputLevel)))
    }

    private func goertzel(_ buf: [Float], freqHz: Double, startFrame: Int) -> Double {
        let span = buf.count - startFrame
        let k = (Double(span) * freqHz / Double(sampleRate)).rounded()
        let omega = 2.0 * .pi * k / Double(span)
        let coeff = 2.0 * cos(omega)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<span {
            let s0 = coeff * s1 - s2 + Double(buf[startFrame + i])
            s2 = s1
            s1 = s0
        }
        let real = s1 - s2 * cos(omega)
        let imag = s2 * sin(omega)
        return sqrt(real * real + imag * imag) / Double(span) * 2.0
    }

    @Test func fmMonitorRemovesThePreemphasisCurve() {
        // The FM feed carries the operator's pre-emphasis; a listener wants
        // what a receiver plays, i.e. the curve taken back out.
        for tau in [50, 75] {
            for f in [1_000.0, 5_000.0, 10_000.0, 15_000.0] {
                let delta = conditionedResponseDB(curve: .fm(tauUS: tau), freq: f, shape: .deemphasised(.fm(tauUS: tau)))
                #expect(abs(delta) < 0.1,
                        "\(tau) us monitor at \(Int(f)) Hz is \(String(format: "%+.2f", delta)) dB off the programme it started from")
            }
        }
    }

    @Test func amMonitorRemovesTheNRSCCurve() {
        // Until 0.60 this applied the FM curve and removed the FM curve, so
        // it was flat whatever NRSC did -- it could not have caught the wrong
        // network. Now it applies NRSC-1 and asks the monitor to undo it.
        for f in [500.0, 2_000.0, 5_000.0, 9_000.0] {
            let delta = conditionedResponseDB(curve: .nrsc, freq: f, shape: .deemphasised(.nrsc))
            #expect(abs(delta) < 0.1, "NRSC monitor at \(Int(f)) Hz is \(delta) dB off flat")
        }
    }

    @Test func theAMMonitorWouldNotBeFlatWithTheFMInverse() {
        // The guard that makes the test above mean something: removing the
        // FM 75 us curve from an NRSC-1 feed leaves a large error, so
        // "flat" really does pin the right network.
        let delta = conditionedResponseDB(curve: .nrsc, freq: 9_000.0, shape: .deemphasised(.fm(tauUS: 75)))
        #expect(abs(delta) > 2.0,
                "the FM inverse on an NRSC feed is only \(delta) dB off -- the curves are not distinguishable here")
    }

    @Test func flatAndDecodedShapesDoNotTouchTheSamples() {
        // hd is flat on the wire, and mpx arrives already decoded: the
        // conditioner must be a pass-through for both, or it would colour a
        // feed that is already right.
        for shape in [MonitorConditioner.Shape.flat, .decodedComposite] {
            var cond = MonitorConditioner()
            cond.configure(shape: shape, sampleRate: sampleRate, gainDB: 0)
            var left: [Float] = [0.1, -0.2, 0.9, -0.95, 0.33]
            var right: [Float] = [-0.1, 0.2, -0.9, 0.95, -0.33]
            let inL = left, inR = right
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    // swiftlint:disable:next force_unwrapping
                    cond.process(left: l.baseAddress!, right: r.baseAddress!, frameCount: inL.count)
                }
            }
            #expect(left == inL, "\(shape) changed the left channel")
            #expect(right == inR, "\(shape) changed the right channel")
        }
    }

    @Test func shapePerModeFollowsWhatTheChainActuallyDid() {
        var cfg = AppConfig()
        cfg.preemphasisUS = 50
        cfg.amPreemphasisUS = 75
        #expect(MonitorConditioner.shape(for: .mpx, config: cfg) == .decodedComposite)
        #expect(MonitorConditioner.shape(for: .fm, config: cfg) == .deemphasised(.fm(tauUS: 50)))
        // hd forces pre-emphasis OFF in the chain, so the monitor must stay
        // flat no matter what the INI still says.
        #expect(MonitorConditioner.shape(for: .hd, config: cfg) == .flat)
        // AM is the NRSC curve, NOT .fm(tauUS: 75).
        #expect(MonitorConditioner.shape(for: .am, config: cfg) == .deemphasised(.nrsc))

        cfg.preemphasisUS = 0
        cfg.amPreemphasisUS = 0
        #expect(MonitorConditioner.shape(for: .fm, config: cfg) == .flat,
                "a flat FM feed has nothing to de-emphasise")
        #expect(MonitorConditioner.shape(for: .am, config: cfg) == .flat)
    }

    @Test func monitorLevelScalesAndClampsWithoutTouchingTheFeed() {
        var cond = MonitorConditioner()
        cond.configure(shape: .flat, sampleRate: sampleRate, gainDB: -6.0)
        var left: [Float] = [0.5, -0.5]
        var right: [Float] = [0.5, -0.5]
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                // swiftlint:disable:next force_unwrapping
                cond.process(left: l.baseAddress!, right: r.baseAddress!, frameCount: 2)
            }
        }
        let half = 0.5 * powf(10.0, -6.0 / 20.0)
        #expect(abs(left[0] - half) < 1e-6, "got \(left[0])")

        var hot = MonitorConditioner()
        hot.configure(shape: .flat, sampleRate: sampleRate, gainDB: 6.0)
        var l2: [Float] = [0.9, -0.9]
        var r2: [Float] = [0.9, -0.9]
        l2.withUnsafeMutableBufferPointer { l in
            r2.withUnsafeMutableBufferPointer { r in
                // swiftlint:disable:next force_unwrapping
                hot.process(left: l.baseAddress!, right: r.baseAddress!, frameCount: 2)
            }
        }
        #expect(l2[0] == 1.0 && l2[1] == -1.0, "a boosted monitor must clamp, got \(l2)")
    }

    // MARK: - Level changes (0.60 audit, P0-5)

    /// The conditioner belongs to one thread; a level change reaches it
    /// through `setTargetGain` on that thread and is RAMPED rather than
    /// applied as a step, so moving the monitor fader cannot click.
    @Test func aLevelChangeRampsInsteadOfStepping() {
        var cond = MonitorConditioner()
        cond.configure(shape: .flat, sampleRate: sampleRate, gainDB: 0.0)
        cond.setTargetGain(0.5)

        let frames = 64
        var left = [Float](repeating: 1.0, count: frames)
        var right = [Float](repeating: 1.0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                // swiftlint:disable:next force_unwrapping
                cond.process(left: l.baseAddress!, right: r.baseAddress!, frameCount: frames)
            }
        }
        // 10 ms at this rate is far more than 64 frames, so the whole block
        // is still on the way down: monotonic, and nowhere near the target.
        #expect(left[0] < 1.0 && left[0] > 0.98, "the ramp started with a step: \(left[0])")
        #expect(left[frames - 1] < left[0], "the ramp is not moving")
        #expect(left[frames - 1] > 0.5, "the ramp reached the target far too fast")
        for i in 1..<frames {
            #expect(left[i] <= left[i - 1], "the ramp is not monotonic at \(i)")
        }
        #expect(left == right, "the two channels must ramp together")
    }

    @Test func theRampSettlesExactlyOnTheTarget() {
        var cond = MonitorConditioner()
        cond.configure(shape: .flat, sampleRate: sampleRate, gainDB: 0.0)
        cond.setTargetGain(0.25)
        // One second is far longer than the 10 ms ramp.
        let frames = Int(sampleRate)
        var left = [Float](repeating: 1.0, count: frames)
        var right = [Float](repeating: 1.0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                // swiftlint:disable:next force_unwrapping
                cond.process(left: l.baseAddress!, right: r.baseAddress!, frameCount: frames)
            }
        }
        #expect(abs(left[frames - 1] - 0.25) < 1e-6,
                "settled on \(left[frames - 1]) instead of the target")
        #expect(cond.gainLinear == 0.25)
    }

    @Test func configureSetsTheLevelWithoutARamp() {
        // Engine start must come up at the configured level immediately --
        // a ramp there would fade the monitor in on every restart.
        var cond = MonitorConditioner()
        cond.configure(shape: .flat, sampleRate: sampleRate, gainDB: -6.0)
        var left: [Float] = [1.0]
        var right: [Float] = [1.0]
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                // swiftlint:disable:next force_unwrapping
                cond.process(left: l.baseAddress!, right: r.baseAddress!, frameCount: 1)
            }
        }
        #expect(abs(left[0] - powf(10.0, -6.0 / 20.0)) < 1e-6, "got \(left[0])")
    }

    @Test func aNonFiniteLevelIsIgnoredRatherThanAdopted() {
        var cond = MonitorConditioner()
        cond.configure(shape: .flat, sampleRate: sampleRate, gainDB: 0.0)
        cond.setTargetGain(Float.nan)
        #expect(cond.gainLinear == 1.0, "a NaN level reached the monitor")
    }

    /// Models the shipped hand-off exactly: the control side stores a Float
    /// bit pattern into an atomic, the audio thread loads it, adopts it and
    /// processes. Under `swift test --sanitize=thread` this is the check
    /// that the monitor level no longer crosses threads by assignment --
    /// before 0.60 the control side wrote straight into this struct while
    /// the audio thread was mutating it.
    @Test func theLevelHandOffSurvivesConcurrentControlWrites() {
        let pending = ManagedAtomic<UInt32>(Float(1.0).bitPattern)
        let stop = ManagedAtomic<Bool>(false)
        let writer = Thread {
            var i = 0
            while !stop.load(ordering: .relaxed) {
                let gain = Float(0.1 + Double(i % 10) * 0.1)
                pending.store(gain.bitPattern, ordering: .relaxed)
                i &+= 1
            }
        }
        writer.start()
        defer { stop.store(true, ordering: .relaxed) }

        var cond = MonitorConditioner()
        cond.configure(shape: .flat, sampleRate: sampleRate, gainDB: 0.0)
        let frames = 256
        var left = [Float](repeating: 0.5, count: frames)
        var right = [Float](repeating: 0.5, count: frames)
        for _ in 0..<1_000 {
            cond.setTargetGain(Float(bitPattern: pending.load(ordering: .relaxed)))
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    // swiftlint:disable force_unwrapping
                    cond.process(left: l.baseAddress!, right: r.baseAddress!, frameCount: frames)
                    // swiftlint:enable force_unwrapping
                }
            }
            #expect(left.allSatisfy { $0.isFinite && abs($0) <= 1.0 })
            for i in 0..<frames {
                left[i] = 0.5
                right[i] = 0.5
            }
        }
    }

    /// Startup regression (reported against the 0.60 P0-5 change): the
    /// players' pending-gain atomics default to UNITY while the conditioner
    /// is configured from `monitor_gain_db`. If the player does not publish
    /// the configured level before the audio thread runs, the first block
    /// reads that unity default and ramps the monitor to 0 dB -- and on
    /// headless macOS, which does not re-apply the runtime config after
    /// start, it then stays there.
    ///
    /// The previous concurrency test could not see this: it configured both
    /// sides at unity, where the mismatch is invisible.
    @Test func startupPublishesTheConfiguredLevelBeforeTheFirstBlock() {
        let startupDB = -12.0
        let expected = powf(10.0, Float(startupDB) / 20.0)

        var cond = MonitorConditioner()
        cond.configure(shape: .flat, sampleRate: sampleRate, gainDB: startupDB)

        // Exactly what a player does at startup, in order.
        let pending = ManagedAtomic<UInt32>(Float(1.0).bitPattern)
        pending.store(cond.publishedGainBitPattern, ordering: .relaxed)

        // Now the audio thread's first block, and several after it.
        let frames = 256
        for block in 0..<8 {
            cond.setTargetGain(Float(bitPattern: pending.load(ordering: .relaxed)))
            var left = [Float](repeating: 1.0, count: frames)
            var right = [Float](repeating: 1.0, count: frames)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    // swiftlint:disable force_unwrapping
                    cond.process(left: l.baseAddress!, right: r.baseAddress!, frameCount: frames)
                    // swiftlint:enable force_unwrapping
                }
            }
            for (i, v) in left.enumerated() {
                #expect(abs(v - expected) < 1e-6,
                        "block \(block) sample \(i) is \(v), expected the configured \(expected)")
            }
            #expect(left == right)
        }
    }

    /// The same sequence WITHOUT the publish, proving the test above is
    /// testing something: an unseeded atomic drags the monitor to unity.
    @Test func anUnseededAtomicWouldRampTheMonitorToUnity() {
        var cond = MonitorConditioner()
        cond.configure(shape: .flat, sampleRate: sampleRate, gainDB: -12.0)
        let pending = ManagedAtomic<UInt32>(Float(1.0).bitPattern)   // never published to
        let frames = 4_800   // 100 ms, far longer than the 10 ms ramp
        cond.setTargetGain(Float(bitPattern: pending.load(ordering: .relaxed)))
        var left = [Float](repeating: 1.0, count: frames)
        var right = [Float](repeating: 1.0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                // swiftlint:disable force_unwrapping
                cond.process(left: l.baseAddress!, right: r.baseAddress!, frameCount: frames)
                // swiftlint:enable force_unwrapping
            }
        }
        #expect(abs(left[frames - 1] - 1.0) < 1e-6,
                "without the publish the monitor should end at unity, got \(left[frames - 1])")
    }
}
