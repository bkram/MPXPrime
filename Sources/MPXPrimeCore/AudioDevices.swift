// macOS-only (CoreAudio device enumeration): the Linux CLI build excludes this file.
#if os(macOS)

import CoreAudio
import Foundation

/// A snapshot of one Core Audio device, read in one pass by `AudioDevices.list()`.
/// `id` is the transient `AudioDeviceID`; `uid` is what the INI stores, because
/// it survives relaunches and hot-plugs.
public struct AudioDevice: Identifiable, Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    /// Current nominal rate (Hz); 0 when the device does not report one.
    public let nominalSampleRate: Double
    /// Supported nominal rates (Hz), continuous ranges expanded.
    public let availableSampleRates: [Double]
    /// Current HAL buffer size in frames; 0 when not reported.
    public let bufferFrameSize: Int
    /// "USB", "Built-in", "Virtual", "Aggregate", ... (`AudioDevices.transportName`).
    public let transport: String
    public let isDefaultInput: Bool
    public let isDefaultOutput: Bool
    /// Sample size the hardware actually moves on that scope, from the physical
    /// stream format: "24-bit", "32-bit float", or "" when the scope has no streams.
    public let inputPhysicalFormat: String
    public let outputPhysicalFormat: String

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }

    public init(
        id: AudioDeviceID, uid: String, name: String,
        inputChannels: Int, outputChannels: Int,
        nominalSampleRate: Double = 0,
        availableSampleRates: [Double] = [],
        bufferFrameSize: Int = 0,
        transport: String = "",
        isDefaultInput: Bool = false,
        isDefaultOutput: Bool = false,
        inputPhysicalFormat: String = "",
        outputPhysicalFormat: String = ""
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.nominalSampleRate = nominalSampleRate
        self.availableSampleRates = availableSampleRates
        self.bufferFrameSize = bufferFrameSize
        self.transport = transport
        self.isDefaultInput = isDefaultInput
        self.isDefaultOutput = isDefaultOutput
        self.inputPhysicalFormat = inputPhysicalFormat
        self.outputPhysicalFormat = outputPhysicalFormat
    }
}

public enum AudioDeviceError: Error {
    case propertyQueryFailed(OSStatus)
}

/// A live subscription to the HAL's device-list and default-device changes,
/// from `AudioDevices.startObserving`. `cancel()` removes the listeners; so
/// does deinit, so dropping the last reference is enough. Never created by a
/// test (it registers with the real HAL).
public final class AudioDeviceObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var block: AudioObjectPropertyListenerBlock?

    fileprivate init(block: @escaping AudioObjectPropertyListenerBlock) {
        self.block = block
    }

    public func cancel() {
        lock.lock()
        let active = block
        block = nil
        lock.unlock()
        guard let active else { return }
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        for selector in AudioDevices.observedSelectors {
            var addr = AudioDevices.address(selector)
            AudioObjectRemovePropertyListenerBlock(sysObj, &addr, DispatchQueue.main, active)
        }
    }

    deinit {
        cancel()
    }
}

public enum AudioDevices {
    public static func list() throws -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
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
        let defaultInput = defaultInputDeviceID()
        let defaultOutput = defaultOutputDeviceID()
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
            let transportType: UInt32 = readValue(
                objectID: id, selector: kAudioDevicePropertyTransportType, default: 0)
            return AudioDevice(
                id: id,
                uid: uid,
                name: name,
                inputChannels: inputChannels,
                outputChannels: outputChannels,
                nominalSampleRate: currentNominalSampleRate(deviceID: id) ?? 0,
                availableSampleRates: availableNominalSampleRates(deviceID: id),
                bufferFrameSize: Int(currentBufferFrameSize(deviceID: id) ?? 0),
                transport: transportName(transportType),
                isDefaultInput: id == defaultInput,
                isDefaultOutput: id == defaultOutput,
                inputPhysicalFormat: physicalFormatName(
                    deviceID: id, scope: kAudioDevicePropertyScopeInput),
                outputPhysicalFormat: physicalFormatName(
                    deviceID: id, scope: kAudioDevicePropertyScopeOutput)
            )
        }
    }

    public static func inputDevices() throws -> [AudioDevice] {
        try list().filter { $0.hasInput }
    }

    public static func outputDevices() throws -> [AudioDevice] {
        try list().filter { $0.hasOutput }
    }

    /// System default output device per the Core Audio HAL (the device
    /// whose buffer-frame-size range the block-size benchmark reports).
    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectGetPropertyData(
            sysObj, &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// System default input device per the Core Audio HAL. Used when
    /// the operator has not selected an explicit input -- AUHAL needs
    /// an explicit `AudioDeviceID`, unlike AVAudioEngine which infers
    /// "default" implicitly.
    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectGetPropertyData(
            sysObj, &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // MARK: - Hot-plug

    /// The system-object properties a device observation listens to: the
    /// device list itself and both default devices.
    static let observedSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice
    ]

    /// Calls `handler` on the main queue whenever a device appears or
    /// disappears, or a default device changes. The handler sees no detail;
    /// it re-lists. Keep the returned observation alive for as long as the
    /// subscription should last; `cancel()` (or letting it go) ends it.
    public static func startObserving(_ handler: @escaping @Sendable () -> Void)
        -> AudioDeviceObservation {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        for selector in observedSelectors {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(sysObj, &addr, DispatchQueue.main, block)
        }
        return AudioDeviceObservation(block: block)
    }

    // MARK: - Property helpers (non-real-time only)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// One fixed-size property value, or `fallback` when the query fails.
    private static func readValue<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default fallback: T
    ) -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = fallback
        let status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, UnsafeMutableRawPointer(pointer))
        }
        return status == noErr ? result : fallback
    }

    /// A variable-length array property; empty when the query fails.
    private static func readArray<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: max(1, count))
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, buffer) == noErr
        else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    private static func readCFString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var addr = address(selector, scope: scope)
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
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
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

    /// The widest physical sample the device's streams carry in a scope, named
    /// like "24-bit" or "32-bit float"; "" when the scope has no streams.
    public static func physicalFormatName(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope)
        -> String {
        let streams: [AudioStreamID] = readArray(
            objectID: deviceID, selector: kAudioDevicePropertyStreams, scope: scope)
        let formats = streams.map { stream -> AudioStreamBasicDescription in
            readValue(
                objectID: stream, selector: kAudioStreamPropertyPhysicalFormat,
                default: AudioStreamBasicDescription())
        }
        guard let widest = formats.max(by: { $0.mBitsPerChannel < $1.mBitsPerChannel }),
              widest.mBitsPerChannel > 0 else { return "" }
        let isFloat = widest.mFormatFlags & kAudioFormatFlagIsFloat != 0
        return "\(widest.mBitsPerChannel)-bit\(isFloat ? " float" : "")"
    }

    /// Human name for a `kAudioDevicePropertyTransportType` value.
    public static func transportName(_ type: UInt32) -> String {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity"
        case 0: return "Unknown"
        default: return "Other"
        }
    }

    /// Reads the device's allowed `kAudioDevicePropertyBufferFrameSize`
    /// range. Returns `nil` if the property isn't available (some virtual
    /// devices). Used to clamp our requested HAL buffer size before setting.
    public static func bufferFrameSizeRange(deviceID: AudioDeviceID) -> (min: UInt32, max: UInt32)? {
        var addr = address(kAudioDevicePropertyBufferFrameSizeRange)
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &range)
        guard status == noErr else { return nil }
        return (UInt32(range.mMinimum), UInt32(range.mMaximum))
    }

    /// Reads the current `kAudioDevicePropertyBufferFrameSize`. Returns
    /// `nil` on error.
    public static func currentBufferFrameSize(deviceID: AudioDeviceID) -> UInt32? {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
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
    /// succeeded -- caller should treat that as "device kept its default".
    @discardableResult
    public static func setBufferFrameSize(deviceID: AudioDeviceID, requested: UInt32) -> UInt32? {
        let clamped: UInt32
        if let range = bufferFrameSizeRange(deviceID: deviceID) {
            clamped = max(range.min, min(range.max, requested))
        } else {
            clamped = requested
        }
        var value = clamped
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &value)
        guard status == noErr else {
            return currentBufferFrameSize(deviceID: deviceID)
        }
        return currentBufferFrameSize(deviceID: deviceID) ?? clamped
    }

    /// Expand CoreAudio rate ranges into concrete rates: a range with
    /// min == max is a discrete rate; a continuous range contributes its
    /// endpoints plus every standard rate inside it. Reporting only mMaximum
    /// (pre-0.45) made a device advertising (44100...384000) look like it
    /// supported only 384 kHz, so the Meter's exact-match test for 192 kHz
    /// failed and it captured at 384 kHz instead of the preferred rate.
    public static func expandRateRanges(_ ranges: [(min: Double, max: Double)]) -> [Double] {
        let standard: [Double] = [
            8_000, 11_025, 16_000, 22_050, 32_000, 44_100, 48_000,
            88_200, 96_000, 176_400, 192_000, 352_800, 384_000
        ]
        var rates = Set<Double>()
        for r in ranges {
            if abs(r.max - r.min) < 0.5 {
                rates.insert(r.min)
            } else {
                rates.insert(r.min)
                rates.insert(r.max)
                for s in standard where s >= r.min && s <= r.max { rates.insert(s) }
            }
        }
        return rates.sorted()
    }

    /// The device's supported nominal sample rates (Hz), with continuous
    /// ranges expanded via `expandRateRanges`. Empty on error.
    public static func availableNominalSampleRates(deviceID: AudioDeviceID) -> [Double] {
        let ranges: [AudioValueRange] = readArray(
            objectID: deviceID, selector: kAudioDevicePropertyAvailableNominalSampleRates)
        return expandRateRanges(ranges.map { (min: $0.mMinimum, max: $0.mMaximum) })
    }

    /// Reads the device's current nominal sample rate (Hz), or nil on error.
    public static func currentNominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
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
        var addr = address(kAudioDevicePropertyNominalSampleRate)
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
