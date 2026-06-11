import AudioToolbox
import CoreAudio
import MPXPrimeCore

/// Abstraction over a source of MPX composite samples. The AUHAL audio backend
/// conforms today; a future SDR backend (rtl-sdr -> composite samples) conforms
/// later with zero change to the analysis/engine layers. This is the seam the
/// plan calls for so SDR input is purely additive.
protocol MPXInputSource: AnyObject {
    /// Invoked from the capture thread with planar L/R frames. The composite is
    /// a single real signal, normally patched to the left channel. Pointers are
    /// valid only for the duration of the call.
    var frameSink: ((_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ frames: Int) -> Void)? { get set }
    var isRunning: Bool { get }

    /// Start capture pinned to `deviceID`. Returns the device's native rate and
    /// channel count.
    @discardableResult
    func start(deviceID: AudioDeviceID, maxFramesPerSlice: Int) throws -> (sampleRate: Double, channels: Int)
    func stop()
}

/// Core Audio AUHAL backend (TN2091), wrapping the shared `InputAUHAL`.
final class AUHALInputSource: MPXInputSource {
    private let au = InputAUHAL()

    var frameSink: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)? {
        get { au.frameSink }
        set { au.frameSink = newValue }
    }

    var isRunning: Bool { au.isRunning }

    @discardableResult
    func start(deviceID: AudioDeviceID, maxFramesPerSlice: Int) throws -> (sampleRate: Double, channels: Int) {
        let fmt = try au.start(deviceID: deviceID, maxFramesPerSlice: maxFramesPerSlice)
        return (fmt.deviceSampleRate, fmt.deviceChannelCount)
    }

    func stop() { au.stop() }
}
