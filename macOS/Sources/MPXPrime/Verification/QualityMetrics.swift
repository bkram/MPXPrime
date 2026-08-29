#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

func computeStereoSignalMetrics(
    left: [Float],
    right: [Float]
) -> StereoSignalMetrics {
    let frameCount = min(left.count, right.count)
    guard frameCount > 0 else { return StereoSignalMetrics() }

    var sumL: Double = 0.0
    var sumR: Double = 0.0
    var dotLR: Double = 0.0
    var midEnergy: Double = 0.0
    var sideEnergy: Double = 0.0
    var peak: Float = 0.0

    for i in 0..<frameCount {
        let l = left[i]
        let r = right[i]
        peak = max(peak, max(fabsf(l), fabsf(r)))

        let ld = Double(l)
        let rd = Double(r)
        sumL += ld * ld
        sumR += rd * rd
        dotLR += ld * rd

        let mid = 0.5 * (ld + rd)
        let side = 0.5 * (ld - rd)
        midEnergy += mid * mid
        sideEnergy += side * side
    }

    let rmsL = sqrt(sumL / Double(frameCount))
    let rmsR = sqrt(sumR / Double(frameCount))
    let rms = Float(sqrt((rmsL * rmsL + rmsR * rmsR) * 0.5))
    let correlation = Float(dotLR / max(1e-12, sqrt(sumL * sumR)))
    let sideToMidRatio = Float(sqrt(sideEnergy / max(1e-12, midEnergy)))

    return StereoSignalMetrics(
        rms: rms,
        peak: peak,
        correlation: correlation.isFinite ? correlation : 0.0,
        sideToMidRatio: sideToMidRatio.isFinite ? sideToMidRatio : 0.0
    )
}

func computeAudioBandRMSMetrics(
    left: [Float],
    right: [Float],
    sampleRate: Float
) -> AudioBandRMSMetrics {
    let frameCount = min(left.count, right.count)
    guard frameCount > 0 else { return AudioBandRMSMetrics() }

    var lowL = Biquad()
    var lowR = Biquad()
    var lowMidL = Biquad()
    var lowMidR = Biquad()
    lowL.configureLowpass(cutoffHz: 180.0, sampleRate: sampleRate)
    lowR.configureLowpass(cutoffHz: 180.0, sampleRate: sampleRate)
    lowMidL.configureLowpass(cutoffHz: 4_200.0, sampleRate: sampleRate)
    lowMidR.configureLowpass(cutoffHz: 4_200.0, sampleRate: sampleRate)

    var lowPower: Double = 0.0
    var midPower: Double = 0.0
    var highPower: Double = 0.0
    for i in 0..<frameCount {
        let l = left[i]
        let r = right[i]
        let lLow = lowL.process(l)
        let rLow = lowR.process(r)
        let lLowMid = lowMidL.process(l)
        let rLowMid = lowMidR.process(r)
        let lMid = lLowMid - lLow
        let rMid = rLowMid - rLow
        let lHigh = l - lLowMid
        let rHigh = r - rLowMid

        lowPower += Double((lLow * lLow) + (rLow * rLow)) * 0.5
        midPower += Double((lMid * lMid) + (rMid * rMid)) * 0.5
        highPower += Double((lHigh * lHigh) + (rHigh * rHigh)) * 0.5
    }

    func db(_ power: Double) -> Float {
        Float(10.0 * log10(max(power / Double(frameCount), 1e-16)))
    }
    return AudioBandRMSMetrics(
        lowDBFS: db(lowPower),
        midDBFS: db(midPower),
        highDBFS: db(highPower)
    )
}

func computeMPXBandwidthMetrics(
    samples: [Float],
    sampleRate: Double
) -> MPXBandwidthMetrics {
    let maxFFTSize = min(samples.count, 131_072)
    let log2n = Int(floor(log2(Double(maxFFTSize))))
    let fftSize = 1 << max(10, log2n)
    guard fftSize >= 1024, fftSize <= samples.count else {
        return MPXBandwidthMetrics()
    }

    var window = [Float](repeating: 0.0, count: fftSize)
    vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

    let signal = Array(samples.prefix(fftSize))
    var windowed = [Float](repeating: 0.0, count: fftSize)
    vDSP_vmul(signal, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

    let halfSize = fftSize / 2
    var real = [Float](repeating: 0.0, count: halfSize)
    var imag = [Float](repeating: 0.0, count: halfSize)

    real.withUnsafeMutableBufferPointer { realPtr in
        imag.withUnsafeMutableBufferPointer { imagPtr in
            guard let realBase = realPtr.baseAddress,
                let imagBase = imagPtr.baseAddress
            else { return }
            var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
            windowed.withUnsafeBufferPointer { windowedPtr in
                guard let windowedBase = windowedPtr.baseAddress else { return }
                windowedBase.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfSize))
                }
            }
            guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2))
            else { return }
            vDSP_fft_zrip(
                fftSetup,
                &split,
                1,
                vDSP_Length(log2(Double(fftSize))),
                FFTDirection(FFT_FORWARD)
            )
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    var mags = [Float](repeating: 0.0, count: halfSize)
    mags.withUnsafeMutableBufferPointer { magsPtr in
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                guard let magsBase = magsPtr.baseAddress,
                    let realBase = realPtr.baseAddress,
                    let imagBase = imagPtr.baseAddress
                else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_zvmags(&split, 1, magsBase, 1, vDSP_Length(halfSize))
            }
        }
    }

    let binHz = Float(sampleRate) / Float(fftSize)
    var totalPower: Double = 0.0
    var inBandPower: Double = 0.0
    var above60Power: Double = 0.0
    var above67Power: Double = 0.0
    var cumulativePower: Double = 0.0
    var occupied999Hz: Float = 0.0

    for bin in 1..<halfSize {
        let freq = Float(bin) * binHz
        let power = Double(mags[bin])
        totalPower += power
        if freq <= 60_000.0 {
            inBandPower += power
        } else {
            above60Power += power
        }
        if freq > 67_000.0 {
            above67Power += power
        }
    }

    let targetPower = totalPower * 0.999
    if targetPower > 0.0 {
        for bin in 1..<halfSize {
            cumulativePower += Double(mags[bin])
            if cumulativePower >= targetPower {
                occupied999Hz = Float(bin) * binHz
                break
            }
        }
    }

    func ratioDB(_ num: Double, _ den: Double) -> Float {
        guard num > 1e-18, den > 1e-18 else { return -160.0 }
        return Float(10.0 * log10(num / den))
    }

    return MPXBandwidthMetrics(
        occupied999Hz: occupied999Hz,
        above60kRatioDB: ratioDB(above60Power, inBandPower),
        above67kRatioDB: ratioDB(above67Power, inBandPower)
    )
}

func qualityFindings(
    scenario: VerificationScenario,
    metrics: VerificationMetrics,
    expectationsOverride: QualityExpectations? = nil
) -> [String] {
    let tolerance: Float = 0.005
    var findings: [String] = []
    let expectations = expectationsOverride ?? scenario.quality

    if let maxCorrelationDelta = expectations.maxCorrelationDelta {
        let delta = fabsf(metrics.outputSignal.correlation - metrics.inputSignal.correlation)
        if delta > (maxCorrelationDelta + tolerance) {
            findings.append(
                "corr delta \(String(format: "%.2f", delta)) > \(String(format: "%.2f", maxCorrelationDelta))"
            )
        }
    }

    if let maxOutputCorrelation = expectations.maxOutputCorrelation {
        let outputCorrelation = fabsf(metrics.outputSignal.correlation)
        if outputCorrelation > (maxOutputCorrelation + tolerance) {
            findings.append(
                "out corr \(String(format: "%.2f", outputCorrelation)) > \(String(format: "%.2f", maxOutputCorrelation))"
            )
        }
    }

    if let minSideRetention = expectations.minSideRetention,
        metrics.inputSignal.sideToMidRatio > 0.05 {
        let retention = metrics.outputSignal.sideToMidRatio / max(0.001, metrics.inputSignal.sideToMidRatio)
        if retention < (minSideRetention - tolerance) {
            findings.append(
                "side retention \(String(format: "%.2f", retention)) < \(String(format: "%.2f", minSideRetention))"
            )
        }
    }

    if let maxAbsRMSDeltaDB = expectations.maxAbsRMSDeltaDB {
        let delta = fabsf(metrics.rmsDeltaDB)
        if delta > (maxAbsRMSDeltaDB + tolerance) {
            findings.append(
                "rms drift \(String(format: "%.1f", delta)) dB > \(String(format: "%.1f", maxAbsRMSDeltaDB)) dB"
            )
        }
    }

    if let maxOccupied999Hz = expectations.maxOccupied999Hz {
        let occupied = metrics.bandwidth.occupied999Hz
        if occupied > (maxOccupied999Hz + 150.0) {
            findings.append(
                "occ999 \(String(format: "%.0f", occupied)) Hz > \(String(format: "%.0f", maxOccupied999Hz)) Hz"
            )
        }
    }

    if let maxAbove60kRatioDB = expectations.maxAbove60kRatioDB {
        let ratio = metrics.bandwidth.above60kRatioDB
        if ratio > (maxAbove60kRatioDB + 0.75) {
            findings.append(
                ">60k/in \(String(format: "%.1f", ratio)) dB > \(String(format: "%.1f", maxAbove60kRatioDB)) dB"
            )
        }
    }

    if let maxAbove67kRatioDB = expectations.maxAbove67kRatioDB {
        let ratio = metrics.bandwidth.above67kRatioDB
        if ratio > (maxAbove67kRatioDB + 0.75) {
            findings.append(
                ">67k/in \(String(format: "%.1f", ratio)) dB > \(String(format: "%.1f", maxAbove67kRatioDB)) dB"
            )
        }
    }

    return findings
}

