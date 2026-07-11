// macOS-only (CoreAudio device enumeration): the Linux CLI build excludes this file.
#if os(macOS)

import CoreAudio
import Foundation

public struct AudioDevice: Identifiable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }

    public init(
        id: AudioDeviceID, uid: String, name: String,
        inputChannels: Int, outputChannels: Int
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
    }
}

public enum AudioDeviceError: Error {
    case propertyQueryFailed(OSStatus)
}

public enum AudioDevices {
    public static func list() throws -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var status = AudioObjectGetPropertyDataSize(sysObj, &addr, 0, nil, &dataSize)
        guard status == noErr else {
            throw AudioDeviceError.propertyQueryFailed(status)
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        status = AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &dataSize, &ids)
        guard status == noErr else {
            throw AudioDeviceError.propertyQueryFailed(status)
        }
        return ids.compactMap { id in
            let name =
                readCFString(
                    objectID: id,
                    selector: kAudioObjectPropertyName,
                    scope: kAudioObjectPropertyScopeGlobal
                ) ?? "AudioDevice \(id)"
            let uid =
                readCFString(
                    objectID: id,
                    selector: kAudioDevicePropertyDeviceUID,
                    scope: kAudioObjectPropertyScopeGlobal
                ) ?? "\(id)"
            let inputChannels = readChannelCount(
                deviceID: id, scope: kAudioDevicePropertyScopeInput)
            let outputChannels = readChannelCount(
                deviceID: id, scope: kAudioDevicePropertyScopeOutput)
            if inputChannels <= 0 && outputChannels <= 0 {
                return nil
            }
            return AudioDevice(
                id: id,
                uid: uid,
                name: name,
                inputChannels: inputChannels,
                outputChannels: outputChannels
            )
        }
    }

    public static func inputDevices() throws -> [AudioDevice] {
        try list().filter { $0.hasInput }
    }

    public static func outputDevices() throws -> [AudioDevice] {
        try list().filter { $0.hasOutput }
    }

    /// System default input device per the Core Audio HAL. Used when
    /// the operator has not selected an explicit input — AUHAL needs
    /// an explicit `AudioDeviceID`, unlike AVAudioEngine which infers
    /// "default" implicitly.
    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectGetPropertyData(
            sysObj, &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func readCFString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &addr,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr, let value else {
            return nil
        }
        return value.takeUnretainedValue() as String
    }

    private static func readChannelCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope)
        -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let statusSize = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize)
        if statusSize != noErr || dataSize == 0 {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        var mutableSize = dataSize
        let statusData = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &mutableSize, raw)
        if statusData != noErr {
            return 0
        }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        var channels = 0
        for buffer in buffers {
            channels += Int(buffer.mNumberChannels)
        }
        return channels
    }

    /// Reads the device's allowed `kAudioDevicePropertyBufferFrameSize`
    /// range. Returns `nil` if the property isn't available (some virtual
    /// devices). Used to clamp our requested HAL buffer size before setting.
    public static func bufferFrameSizeRange(deviceID: AudioDeviceID) -> (min: UInt32, max: UInt32)? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &range)
        guard status == noErr else { return nil }
        return (UInt32(range.mMinimum), UInt32(range.mMaximum))
    }

    /// Reads the current `kAudioDevicePropertyBufferFrameSize`. Returns
    /// `nil` on error.
    public static func currentBufferFrameSize(deviceID: AudioDeviceID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &frames)
        guard status == noErr else { return nil }
        return frames
    }

    /// Set the device's HAL buffer frame size, clamped to the device's
    /// reported allowed range. Returns the value the device ended up at
    /// (which may differ from `requested` if the device clamped or
    /// rejected). Returns `nil` if neither the range query nor the set
    /// succeeded — caller should treat that as "device kept its default".
    @discardableResult
    public static func setBufferFrameSize(deviceID: AudioDeviceID, requested: UInt32) -> UInt32? {
        let clamped: UInt32
        if let range = bufferFrameSizeRange(deviceID: deviceID) {
            clamped = max(range.min, min(range.max, requested))
        } else {
            clamped = requested
        }
        var value = clamped
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &value)
        guard status == noErr else {
            return currentBufferFrameSize(deviceID: deviceID)
        }
        return currentBufferFrameSize(deviceID: deviceID) ?? clamped
    }

    /// The device's supported nominal sample rates (Hz). A range with
    /// min == max is a discrete rate; ranges (rare on real hardware) are
    /// reported by their max. Empty on error.
    public static func availableNominalSampleRates(deviceID: AudioDeviceID) -> [Double] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioValueRange>.size
        var ranges = Array(repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &dataSize, &ranges) == noErr
        else { return [] }
        return ranges.map { $0.mMaximum }
    }

    /// Reads the device's current nominal sample rate (Hz), or nil on error.
    public static func currentNominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return nil }
        return rate
    }

    /// Set the device's nominal sample rate (Hz). The HAL applies the change
    /// asynchronously, so this polls the current rate until it matches (within
    /// 1 Hz) or `timeout` elapses. Returns the rate the device ended up at, or
    /// nil if the set call itself failed.
    @discardableResult
    public static func setNominalSampleRate(
        deviceID: AudioDeviceID, _ rate: Double, timeout: TimeInterval = 1.5
    ) -> Double? {
        if let current = currentNominalSampleRate(deviceID: deviceID),
           abs(current - rate) < 1.0 {
            return current
        }
        var value = Float64(rate)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &value) == noErr
        else { return nil }
        // Poll until the asynchronous switch lands.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current = currentNominalSampleRate(deviceID: deviceID),
               abs(current - rate) < 1.0 {
                return current
            }
            usleep(20_000)
        }
        return currentNominalSampleRate(deviceID: deviceID)
    }
}

#endif  // os(macOS)
