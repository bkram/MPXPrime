import Foundation

/// What a ladder meter draws: the falling sample peak, the held peak, and a
/// latched clip flag. dBFS, -infinity for silence.
public struct LadderMeterReading: Equatable, Sendable {
    public var peakDBFS: Float
    public var heldPeakDBFS: Float
    public var clipped: Bool

    public init(peakDBFS: Float = -.infinity, heldPeakDBFS: Float = -.infinity, clipped: Bool = false) {
        self.peakDBFS = peakDBFS
        self.heldPeakDBFS = heldPeakDBFS
        self.clipped = clipped
    }

    public static let silent = LadderMeterReading()
}

/// Ladder-meter ballistics, ported from Prime Mixer's `MeterBallistics`:
/// instant attack, 24 dB/s peak fall-back, a 1.5 s peak hold and a 2 s clip
/// latch at full scale. Feed it the linear peak of each metering interval.
/// Control-thread state; pure, so it is unit-tested without a GUI.
public struct LadderMeterBallistics: Sendable {
    public static let holdSeconds: Double = 1.5
    public static let clipLatchSeconds: Double = 2.0
    public static let peakFallDBPerSecond: Double = 24.0
    /// Below -120 dBFS is silence for display; stops decays running into denormals.
    private static let floor: Float = 1e-6

    /// Linear level that latches the clip flag: full scale for a dBFS meter;
    /// a deviation meter fed `kHz / limit` sets this a little over 1 so the
    /// composite clipper holding exactly at the limit does not light it.
    public let clipThreshold: Float

    public private(set) var reading = LadderMeterReading()
    private var displayedPeak: Float = 0
    private var heldPeak: Float = 0
    private var heldUntil: Double = 0
    private var clipUntil: Double = 0

    public init(clipThreshold: Float = 1) {
        self.clipThreshold = clipThreshold
    }

    /// `peak` is the linear sample peak since the previous call, `now` a
    /// monotonic time in seconds, `interval` the time since the previous call.
    @discardableResult
    public mutating func update(peak rawPeak: Float, now: Double, interval: Double) -> LadderMeterReading {
        let peak = rawPeak.isFinite ? max(0, rawPeak) : 0
        let fall = Float(pow(10.0, -Self.peakFallDBPerSecond * max(0, interval) / 20.0))
        displayedPeak = max(peak, displayedPeak * fall)
        if peak >= heldPeak || now >= heldUntil {
            heldPeak = peak
            heldUntil = now + Self.holdSeconds
        }
        if peak >= clipThreshold { clipUntil = now + Self.clipLatchSeconds }
        if displayedPeak < Self.floor { displayedPeak = 0 }
        if heldPeak < Self.floor { heldPeak = 0 }
        reading = LadderMeterReading(
            peakDBFS: Self.decibels(displayedPeak),
            heldPeakDBFS: Self.decibels(heldPeak),
            clipped: now < clipUntil)
        return reading
    }

    public mutating func reset() { self = LadderMeterBallistics(clipThreshold: clipThreshold) }

    static func decibels(_ amplitude: Float) -> Float {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }
}
