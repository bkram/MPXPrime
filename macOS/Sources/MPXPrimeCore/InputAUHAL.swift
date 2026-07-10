// macOS-only (AUHAL input capture): the Linux CLI build excludes this file.
#if os(macOS)

import AudioToolbox
import CoreAudio
import Foundation
import MPXPrimeNative
import os

/// Direct AUHAL (`kAudioUnitSubType_HALOutput`) input-capture wrapper.
///
/// Exists to escape AVAudioEngine's first-start failure on non-default
/// input devices: AVAudioEngine's input-node binding intermittently
/// fails to deliver tap callbacks even when every API call returns
/// success. The two-AUHAL pattern (separate input AU + output AU +
/// ring buffer) is the documented escape hatch from TN2091 and what
/// Stereotool / CAPlayThrough / AudioKit's non-default-device path
/// use on macOS.
///
/// Setup follows TN2091 verbatim and the property order matters. The
/// sequence has not changed since macOS 10.4 and is encoded inline in
/// `start()` with explicit step numbers.
///
/// RT-safety: the input render callback runs on the AU's real-time
/// HAL I/O thread. The frame-sink closure is invoked synchronously
/// from that thread — callers must keep the closure body
/// allocation-free and lock-free. Refcon uses `passUnretained`; the
/// lifetime invariant is that `stop()` always runs before `deinit`,
/// so `self` stays alive while the unit is initialized.
public final class InputAUHAL {
    /// Frame sink invoked from the AUHAL render thread after each
    /// successful `AudioUnitRender`. Pointers point into the
    /// pre-allocated buffer list and are valid only for the duration
    /// of the call — sinks must copy or push to a ring before
    /// returning.
    public typealias FrameSink = (
        _ left: UnsafePointer<Float>,
        _ right: UnsafePointer<Float>,
        _ frameCount: Int
    ) -> Void

    public struct Format {
        public let deviceSampleRate: Double
        public let deviceChannelCount: Int

        public init(deviceSampleRate: Double, deviceChannelCount: Int) {
            self.deviceSampleRate = deviceSampleRate
            self.deviceChannelCount = deviceChannelCount
        }
    }

    public enum InputAUHALError: Error, CustomStringConvertible {
        case componentNotFound
        case osStatus(name: String, status: OSStatus)
        case invalidChannelCount(Int)

        public var description: String {
            switch self {
            case .componentNotFound:
                return "AUHAL component not found"
            case .osStatus(let name, let status):
                return "\(name) failed (OSStatus \(status))"
            case .invalidChannelCount(let n):
                return "device reports \(n) channels"
            }
        }
    }

    private static let log = Logger(subsystem: "com.mpxprime.app", category: "input-auhal")

    private var unit: AudioUnit?
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private var maxFramesPerSlice: Int = 4096
    private var running: Bool = false

    /// Set this before calling `start()`. Once start succeeds the AU
    /// can fire callbacks at any time, so changing the sink afterward
    /// is racy — replace by stop+restart instead.
    public var frameSink: FrameSink?

    public var isRunning: Bool { running }

    public init() {}

    /// Open and start an AUHAL pinned to `deviceID`. Returns the
    /// device's native format (sample rate + channel count) so the
    /// caller can wire up rate-conversion machinery.
    @discardableResult
    public func start(deviceID: AudioDeviceID, maxFramesPerSlice: Int = 4096) throws -> Format {
        precondition(unit == nil, "InputAUHAL.start called twice without stop()")
        self.maxFramesPerSlice = max(1024, maxFramesPerSlice)

        // 1. Find + instantiate the AUHAL component.
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw InputAUHALError.componentNotFound
        }
        var newUnit: AudioUnit?
        try check("AudioComponentInstanceNew",
            AudioComponentInstanceNew(component, &newUnit))
        guard let unit = newUnit else {
            throw InputAUHALError.componentNotFound
        }
        self.unit = unit

        // From here on, any failure must dispose the unit before
        // throwing so we don't leak it.
        do {
            try configure(unit: unit, deviceID: deviceID)
        } catch {
            AudioComponentInstanceDispose(unit)
            self.unit = nil
            throw error
        }

        // 11. AudioOutputUnitStart.
        do {
            try check("AudioOutputUnitStart", AudioOutputUnitStart(unit))
        } catch {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
            if let bl = bufferList {
                Self.freePlanarBuffers(bl)
                bufferList = nil
            }
            throw error
        }
        running = true

        // Read back the actual device format so the caller gets the
        // ground-truth rate / channel count it should use to size the
        // ring and compute resample ratios.
        let actual = try readDeviceFormat(unit: unit)
        Self.log.info(
            "AUHAL input started deviceID=\(deviceID, privacy: .public) deviceRate=\(actual.deviceSampleRate, privacy: .public) deviceChannels=\(actual.deviceChannelCount, privacy: .public)"
        )
        return actual
    }

    private func configure(unit: AudioUnit, deviceID: AudioDeviceID) throws {
        // 2. EnableIO on input bus 1.
        var enableInput: UInt32 = 1
        try check("EnableIO input", AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        ))

        // 3. DisableIO on output bus 0.
        var disableOutput: UInt32 = 0
        try check("DisableIO output", AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        ))

        // 4. CurrentDevice. Must come AFTER EnableIO — TN2091:
        //    "devices can only be set to the AUHAL after enabling IO".
        //    Reversing this order silently misroutes input.
        var device = deviceID
        try check("SetCurrentDevice", AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ))

        // 5. Read the device's native format off input scope element 1
        //    so we know what rate / channel count to set on our client
        //    format. This is read-only on input scope.
        var deviceFormat = AudioStreamBasicDescription()
        var deviceFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check("GetStreamFormat input", AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &deviceFormat,
            &deviceFormatSize
        ))
        let deviceChannels = Int(deviceFormat.mChannelsPerFrame)
        guard deviceChannels >= 1 else {
            throw InputAUHALError.invalidChannelCount(deviceChannels)
        }

        // 6. Set client format on output scope element 1: Float32,
        //    planar (non-interleaved), 2 channels (stereo), at the
        //    DEVICE'S sample rate. AUHAL's built-in converter does
        //    packing / format only — NOT sample-rate conversion.
        //    Asking for 192k from a 48k device fails with
        //    kAudioUnitErr_FormatNotSupported (-10868) at Initialize.
        //    External SRC happens downstream in the consumer.
        var clientFormat = Self.makePlanarFloat32(
            sampleRate: deviceFormat.mSampleRate, channels: 2)
        try check("SetStreamFormat client", AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &clientFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ))

        // 7. MaxFramesPerSlice — pre-size internal buffers for the
        //    worst case. Display-sleep wake can deliver a single
        //    larger slice than steady state.
        var mfps = UInt32(self.maxFramesPerSlice)
        try check("SetMaxFramesPerSlice", AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &mfps,
            UInt32(MemoryLayout<UInt32>.size)
        ))

        // 8. ChannelMap — only when the device differs from our
        //    target stereo layout. -1 = silence; n = device channel
        //    index. Stereo devices use the implicit 1:1 mapping.
        if deviceChannels == 1 {
            // Mono device → duplicate into both client channels.
            var map: [Int32] = [0, 0]
            let mapBytes = UInt32(MemoryLayout<Int32>.size * map.count)
            try map.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                try check("SetChannelMap mono->stereo", AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_ChannelMap,
                    kAudioUnitScope_Output,
                    1,
                    base,
                    mapBytes
                ))
            }
        } else if deviceChannels > 2 {
            // Multichannel device → take the first two channels.
            var map: [Int32] = [0, 1]
            let mapBytes = UInt32(MemoryLayout<Int32>.size * map.count)
            try map.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                try check("SetChannelMap downselect", AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_ChannelMap,
                    kAudioUnitScope_Output,
                    1,
                    base,
                    mapBytes
                ))
            }
        }

        // 9. SetInputCallback — refCon points at self via
        //    passUnretained. Lifetime invariant: stop() runs before
        //    deinit, so self stays alive while the unit is active.
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var cb = AURenderCallbackStruct(
            inputProc: auhalInputProc,
            inputProcRefCon: refCon
        )
        try check("SetInputCallback", AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &cb,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ))

        // 10. AudioUnitInitialize — consume all the properties we
        //     just set, allocate the AU's internal buffers.
        try check("AudioUnitInitialize", AudioUnitInitialize(unit))

        // Allocate our planar bufferList for AudioUnitRender to fill.
        bufferList = Self.allocatePlanarBufferList(
            channels: 2, frames: maxFramesPerSlice
        )
    }

    private func readDeviceFormat(unit: AudioUnit) throws -> Format {
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check("GetStreamFormat input (post-init)", AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &fmt,
            &size
        ))
        return Format(
            deviceSampleRate: fmt.mSampleRate,
            deviceChannelCount: Int(fmt.mChannelsPerFrame)
        )
    }

    public func stop() {
        guard let unit else { return }
        if running {
            AudioOutputUnitStop(unit)
            running = false
        }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        if let bl = bufferList {
            Self.freePlanarBuffers(bl)
            bufferList = nil
        }
    }

    deinit {
        stop()
    }

    // MARK: - Render callback body

    fileprivate func handleInput(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard let unit, let bufferList else { return noErr }
        let frames = Int(frameCount)
        guard frames > 0, bufferList.count >= 2 else { return noErr }

        // mDataByteSize must be reset on every callback. The AU
        // treats it as both an input (capacity available) and an
        // output (actual filled). Leaving it at the worst-case
        // capacity occasionally short-fills in release builds.
        let bytesPerFrame = MemoryLayout<Float>.size
        let neededBytes = UInt32(frames * bytesPerFrame)
        bufferList[0].mDataByteSize = neededBytes
        bufferList[1].mDataByteSize = neededBytes

        let render = AudioUnitRender(
            unit,
            actionFlags,
            timeStamp,
            1,                 // bus 1 — input AUHAL renders to bus 1
            frameCount,
            bufferList.unsafeMutablePointer
        )
        if render != noErr {
            // -10874 = TooManyFramesToProcess (would need a larger
            // MaxFramesPerSlice). Other transient errors recover on
            // the next callback.
            return render
        }

        guard let leftRaw = bufferList[0].mData,
              let rightRaw = bufferList[1].mData
        else {
            return noErr
        }
        let left = leftRaw.assumingMemoryBound(to: Float.self)
        let right = rightRaw.assumingMemoryBound(to: Float.self)
        frameSink?(left, right, frames)
        return noErr
    }

    // MARK: - Helpers

    private static func makePlanarFloat32(
        sampleRate: Double, channels: UInt32
    ) -> AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytesPerSample,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private static func allocatePlanarBufferList(
        channels: Int, frames: Int
    ) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        let bytesPerSample = MemoryLayout<Float>.size
        let bufferBytes = max(1, frames * bytesPerSample)
        for i in 0..<channels {
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: bufferBytes,
                alignment: MemoryLayout<Float>.alignment
            )
            memset(raw, 0, bufferBytes)
            list[i] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bufferBytes),
                mData: raw
            )
        }
        return list
    }

    private static func freePlanarBuffers(
        _ list: UnsafeMutableAudioBufferListPointer
    ) {
        for i in 0..<list.count {
            if let p = list[i].mData {
                p.deallocate()
            }
        }
        free(UnsafeMutableRawPointer(list.unsafeMutablePointer))
    }

    private func check(_ name: String, _ status: OSStatus) throws {
        if status != noErr {
            Self.log.error(
                "\(name, privacy: .public) failed status=\(status, privacy: .public)"
            )
            throw InputAUHALError.osStatus(name: name, status: status)
        }
    }
}

// MARK: - Top-level @convention(c) trampoline

private let auhalInputProc: AURenderCallback = {
    inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
    // Mirror the FTZ/DAZ setting from AudioOutputEngine's source-node
    // callback. CoreAudio's input thread is a separate high-priority
    // thread; MXCSR / FPCR are per-thread, so we set them here too.
    // See MPXPrimeNative.h for the rationale (denormal accumulation
    // → x86 slow path → audio dropout → "white noise after a couple
    // of songs" on Intel).
    mpx_enable_flush_to_zero()
    let state = Unmanaged<InputAUHAL>.fromOpaque(inRefCon)
        .takeUnretainedValue()
    return state.handleInput(
        actionFlags: ioActionFlags,
        timeStamp: inTimeStamp,
        frameCount: inNumberFrames
    )
}

#endif  // os(macOS)
