import Foundation
import Testing

#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif

// Golden-fixture pinning for the MPXPrimeAcceleration shim.
//
// The fixture (Support/accelerate_golden.json) is captured ON MACOS from real
// Accelerate: run once with MPXPRIME_CAPTURE_GOLDEN=1 to (re)write it. In
// normal runs this suite computes the same quantities with whichever
// implementation the platform compiled (real Accelerate on macOS, the shim on
// Linux) and asserts they match the fixture. So:
// - on macOS it is a fixture-freshness check (Accelerate == fixture), and
// - on Linux it proves the shim reproduces Accelerate's numeric semantics
//   (packing, scaling, window constants) within tolerance.
//
// Element-wise exact-shape pinning happens at small sizes (n = 16 / 64);
// a 4096-point probe covers accumulated-rounding behavior at the sizes the
// verifier and spectrum analyzer actually use.

private struct GoldenFixture: Codable {
    var hannDenorm16: [Float]
    var hannNorm16: [Float]
    var hannNorm4096ProbeIndices: [Int]
    var hannNorm4096ProbeValues: [Float]
    var hannNorm4096Sum: Float
    var fft64ImpulseRe: [Float]
    var fft64ImpulseIm: [Float]
    var fft64SineRe: [Float]
    var fft64SineIm: [Float]
    var fft64RandRe: [Float]
    var fft64RandIm: [Float]
    var fft4096ProbeBins: [Int]
    var fft4096ProbeMag2: [Float]
    var fft4096Energy: Float
    var convOutput: [Float]
    var dotprValue: Float
}

private func fixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Support/accelerate_golden.json")
}

/// Deterministic LCG (same sequence on every platform) for random-vector
/// probes without storing inputs in the fixture.
private struct LCG {
    var state: UInt32 = 0x1234_5678
    mutating func nextFloat() -> Float {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Float(state >> 8) / Float(1 << 24) * 2.0 - 1.0
    }
}

/// Forward packed real FFT of `input` (length must be a power of two) using
/// whichever vDSP implementation this platform compiled. Returns the packed
/// split-complex result (realp[0] = 2*DC, imagp[0] = 2*Nyquist, bins = 2*Xk).
private func packedRealFFT(_ input: [Float]) -> (re: [Float], im: [Float]) {
    let n = input.count
    let half = n / 2
    let log2n = vDSP_Length(Int(log2(Double(n)).rounded()))
    var re = [Float](repeating: 0, count: half)
    var im = [Float](repeating: 0, count: half)
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
        fatalError("fftsetup failed")
    }
    defer { vDSP_destroy_fftsetup(setup) }
    re.withUnsafeMutableBufferPointer { reBuf in
        im.withUnsafeMutableBufferPointer { imBuf in
            var split = DSPSplitComplex(
                realp: reBuf.baseAddress!, imagp: imBuf.baseAddress!)
            input.withUnsafeBufferPointer { inBuf in
                inBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        }
    }
    return (re, im)
}

private func computeCurrent() -> GoldenFixture {
    // Hann windows.
    var hd16 = [Float](repeating: 0, count: 16)
    vDSP_hann_window(&hd16, 16, Int32(vDSP_HANN_DENORM))
    var hn16 = [Float](repeating: 0, count: 16)
    vDSP_hann_window(&hn16, 16, Int32(vDSP_HANN_NORM))
    var hn4096 = [Float](repeating: 0, count: 4096)
    vDSP_hann_window(&hn4096, 4096, Int32(vDSP_HANN_NORM))
    let probeIdx = [0, 1, 2, 1000, 2048, 4095]
    var hnSum: Float = 0
    vDSP_sve(hn4096, 1, &hnSum, 4096)

    // FFT n = 64: impulse, bin-centered sine, seeded random.
    var impulse = [Float](repeating: 0, count: 64)
    impulse[3] = 1.0
    let fftImpulse = packedRealFFT(impulse)
    var sine = [Float](repeating: 0, count: 64)
    for i in 0..<64 {
        sine[i] = sinf(2.0 * Float.pi * 5.0 * Float(i) / 64.0)
    }
    let fftSine = packedRealFFT(sine)
    var lcg = LCG()
    var rand64 = [Float](repeating: 0, count: 64)
    for i in 0..<64 { rand64[i] = lcg.nextFloat() }
    let fftRand = packedRealFFT(rand64)

    // FFT n = 4096 random probe: a few |X|^2 bins + total spectral energy.
    var rand4096 = [Float](repeating: 0, count: 4096)
    for i in 0..<4096 { rand4096[i] = lcg.nextFloat() }
    let big = packedRealFFT(rand4096)
    var mag2 = [Float](repeating: 0, count: 2048)
    var bigRe = big.re
    var bigIm = big.im
    bigRe.withUnsafeMutableBufferPointer { reBuf in
        bigIm.withUnsafeMutableBufferPointer { imBuf in
            var split = DSPSplitComplex(
                realp: reBuf.baseAddress!, imagp: imBuf.baseAddress!)
            vDSP_zvmags(&split, 1, &mag2, 1, 2048)
        }
    }
    let probeBins = [1, 7, 100, 999, 2047]
    var energy: Float = 0
    vDSP_sve(mag2, 1, &energy, 2048)

    // Correlation (vDSP_conv semantics) and dot product.
    var convIn = [Float](repeating: 0, count: 20)   // n + p - 1 = 16 + 5 - 1
    for i in 0..<20 { convIn[i] = lcg.nextFloat() }
    let taps: [Float] = [0.1, -0.25, 0.5, -0.25, 0.1]
    var convOut = [Float](repeating: 0, count: 16)
    vDSP_conv(convIn, 1, taps, 1, &convOut, 1, 16, 5)
    var dotA = [Float](repeating: 0, count: 33)
    var dotB = [Float](repeating: 0, count: 33)
    for i in 0..<33 { dotA[i] = lcg.nextFloat() }
    for i in 0..<33 { dotB[i] = lcg.nextFloat() }
    var dot: Float = 0
    vDSP_dotpr(dotA, 1, dotB, 1, &dot, 33)

    return GoldenFixture(
        hannDenorm16: hd16,
        hannNorm16: hn16,
        hannNorm4096ProbeIndices: probeIdx,
        hannNorm4096ProbeValues: probeIdx.map { hn4096[$0] },
        hannNorm4096Sum: hnSum,
        fft64ImpulseRe: fftImpulse.re,
        fft64ImpulseIm: fftImpulse.im,
        fft64SineRe: fftSine.re,
        fft64SineIm: fftSine.im,
        fft64RandRe: fftRand.re,
        fft64RandIm: fftRand.im,
        fft4096ProbeBins: probeBins,
        fft4096ProbeMag2: probeBins.map { mag2[$0] },
        fft4096Energy: energy,
        convOutput: convOut,
        dotprValue: dot
    )
}

/// abs-relative match: |a-b| <= tol * max(1, |b|) -- absolute near zero,
/// relative for large values (FFT bins at n = 4096 reach O(1000)).
private func matches(_ a: Float, _ b: Float, tol: Float) -> Bool {
    abs(a - b) <= tol * max(1.0, abs(b))
}

private func expectClose(
    _ a: [Float], _ b: [Float], tol: Float, _ label: String
) {
    #expect(a.count == b.count, "\(label): count \(a.count) != \(b.count)")
    for i in 0..<min(a.count, b.count) where !matches(a[i], b[i], tol: tol) {
        Issue.record("\(label)[\(i)]: \(a[i]) vs fixture \(b[i])")
        return
    }
}

@Suite("Accelerate shim golden fixture")
struct AccelerateShimTests {
    #if !canImport(Accelerate)
    // SIMD tanh accuracy: the shim's vectorized approximation must stay
    // within ~1e-7 of libm across the full useful range (the clipper's
    // distortion cancellation assumes tanh's exact shape; the Linux strict
    // baseline is captured with THIS implementation).
    @Test func tanhApproximationMatchesLibm() {
        var maxErr: Float = 0
        var worstX: Float = 0
        var x: Float = -10.0
        while x <= 10.0 {
            var input = [Float](repeating: x, count: 8)
            var output = [Float](repeating: 0, count: 8)
            var n: Int32 = 8
            vvtanhf(&output, &input, &n)
            let err = abs(output[0] - tanhf(x))
            if err > maxErr {
                maxErr = err
                worstX = x
            }
            x += 0.001
        }
        #expect(maxErr < 3e-7, "max |shim - libm| = \(maxErr) at x = \(worstX)")
    }

    // Batch-size independence: the padded tail lane must produce the same
    // values as the full-lane path (results must not depend on n % 8).
    @Test func tanhBatchSizeIndependent() {
        let values: [Float] = [-3.2, -1.1, -0.02, 0.0, 0.4, 0.9, 2.5, 7.7, 9.6, -12.0, 0.13]
        var full = [Float](repeating: 0, count: values.count)
        var n = Int32(values.count)
        values.withUnsafeBufferPointer { vvtanhf(&full, $0.baseAddress!, &n) }
        for (i, v) in values.enumerated() {
            var one = [Float](repeating: 0, count: 1)
            var single: Int32 = 1
            withUnsafePointer(to: v) { vvtanhf(&one, $0, &single) }
            #expect(one[0] == full[i], "element \(i) differs between batch sizes")
        }
    }

    // SIMD dot: only summation-order rounding may differ from scalar.
    @Test func simdDotMatchesScalarReference() {
        var lcg = LCG()
        for count in [1, 7, 8, 9, 31, 32, 33, 129, 511] {
            let a = (0..<count).map { _ in lcg.nextFloat() }
            let b = (0..<count).map { _ in lcg.nextFloat() }
            var out: Float = 0
            a.withUnsafeBufferPointer { pa in
                b.withUnsafeBufferPointer { pb in
                    vDSP_dotpr(pa.baseAddress!, 1, pb.baseAddress!, 1, &out, vDSP_Length(count))
                }
            }
            let reference = zip(a, b).reduce(Double(0)) { $0 + Double($1.0) * Double($1.1) }
            #expect(abs(Double(out) - reference) < 1e-4 * max(1.0, abs(reference)),
                    "count \(count): \(out) vs \(reference)")
        }
    }
    #endif

    @Test func matchesGoldenFixture() throws {
        let current = computeCurrent()

        if ProcessInfo.processInfo.environment["MPXPRIME_CAPTURE_GOLDEN"] == "1" {
            #if canImport(Accelerate)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(current).write(to: fixtureURL())
            print("accelerate_golden.json captured from real Accelerate")
            return
            #else
            Issue.record("golden fixture must be captured on macOS (real Accelerate)")
            return
            #endif
        }

        let golden = try JSONDecoder().decode(
            GoldenFixture.self, from: Data(contentsOf: fixtureURL()))

        // Small-size element-wise pins: tight tolerance (identical formula,
        // only libm ulp differences allowed).
        let tight: Float = 2e-6
        expectClose(current.hannDenorm16, golden.hannDenorm16, tol: tight, "hannDenorm16")
        expectClose(current.hannNorm16, golden.hannNorm16, tol: tight, "hannNorm16")
        #expect(current.hannNorm4096ProbeIndices == golden.hannNorm4096ProbeIndices)
        expectClose(
            current.hannNorm4096ProbeValues, golden.hannNorm4096ProbeValues,
            tol: tight, "hannNorm4096Probe")
        #expect(matches(current.hannNorm4096Sum, golden.hannNorm4096Sum, tol: 1e-5))

        expectClose(current.fft64ImpulseRe, golden.fft64ImpulseRe, tol: 1e-5, "fft64ImpulseRe")
        expectClose(current.fft64ImpulseIm, golden.fft64ImpulseIm, tol: 1e-5, "fft64ImpulseIm")
        expectClose(current.fft64SineRe, golden.fft64SineRe, tol: 1e-4, "fft64SineRe")
        expectClose(current.fft64SineIm, golden.fft64SineIm, tol: 1e-4, "fft64SineIm")
        expectClose(current.fft64RandRe, golden.fft64RandRe, tol: 1e-4, "fft64RandRe")
        expectClose(current.fft64RandIm, golden.fft64RandIm, tol: 1e-4, "fft64RandIm")

        // 4096-point accumulated-rounding probe: looser tolerance.
        #expect(current.fft4096ProbeBins == golden.fft4096ProbeBins)
        expectClose(
            current.fft4096ProbeMag2, golden.fft4096ProbeMag2,
            tol: 5e-4, "fft4096ProbeMag2")
        #expect(matches(current.fft4096Energy, golden.fft4096Energy, tol: 5e-4))

        expectClose(current.convOutput, golden.convOutput, tol: tight, "convOutput")
        #expect(matches(current.dotprValue, golden.dotprValue, tol: 1e-5))
    }
}
