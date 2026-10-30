import Foundation

/// The arithmetic and decisions behind the macOS device-volume layer, kept
/// platform-independent so they are testable on Linux (the `ALSAMixerMath`
/// pattern). The HAL binding itself is `CoreAudioDeviceVolume`, macOS-only,
/// below.
///
/// Why this exists: on macOS the device's own output volume sits between the
/// composite and the exciter exactly as the ALSA mixer does on Linux. The
/// station's DX3 Pro+ ran at -5.00 dB in CoreAudio (volume scalar 0.9228 on
/// element 0, dB range -127..0) while the app also applied -5 dBFS line
/// output, and nothing in the app could see it: the manual sent the operator
/// to Audio MIDI Setup instead. Nothing here is on the render thread.
enum CoreAudioDeviceVolumeMath {

    /// Below this the output device is reported as "not at unity".
    static let unityToleranceDB = 0.1
    /// A configured level is re-asserted only once the device has drifted by
    /// more than this (the same tolerance as the ALSA assert).
    static let assertToleranceDB = 0.25
    /// Where the dB estimate bottoms out for a device without a dB scale.
    static let estimateFloorDB = -127.0
    /// How many per-channel elements the fallback probe looks at.
    static let maxChannelElements: UInt32 = 32

    enum Side: String, Codable, Sendable {
        case playback
        case capture
    }

    /// What the HAL reports for one scope of one device, gathered by the
    /// platform wrap and interpreted here.
    struct Probe: Equatable, Sendable {
        /// Element 0 carries a volume (the virtual main volume or a plain
        /// main-element scalar).
        var mainHasVolume = false
        /// Elements 1..N that carry `kAudioDevicePropertyVolumeScalar`.
        var channelElements: [UInt32] = []
        /// 0...1, the position of the system's own slider.
        var scalar: Double?
        /// The device's own dB reading, when it has a dB scale.
        var decibels: Double?
        var rangeDB: ControlDBRange?
        var muted: Bool?
        var settable = false

        var hasVolume: Bool { mainHasVolume || !channelElements.isEmpty }
    }

    /// Which element(s) the wrap reads and writes: the main element when the
    /// device has one (one write moves every channel together), otherwise
    /// every channel element alike, never a mix of the two.
    enum ElementChoice: Equatable {
        case main
        case channels([UInt32])
        case none
    }

    static func elementChoice(mainHasVolume: Bool, channelElements: [UInt32]) -> ElementChoice {
        if mainHasVolume { return .main }
        if channelElements.isEmpty { return .none }
        return .channels(channelElements)
    }

    /// The dashboard's 0...100 slider from the HAL's 0...1 scalar.
    static func percent(fromScalar scalar: Double) -> Double {
        Swift.max(0.0, Swift.min(1.0, scalar)) * 100.0
    }

    static func scalar(fromPercent percent: Double) -> Double {
        Swift.max(0.0, Swift.min(100.0, percent)) / 100.0
    }

    /// Only for a device that offers neither `VolumeDecibels` nor the
    /// scalar-to-dB translation: CoreAudio's scalar is a slider position, not
    /// an amplitude (the DX3 reads 0.9228 for -5 dB), so this is an estimate
    /// and is labelled as one wherever it is shown.
    static func estimatedDecibels(fromScalar scalar: Double, range: ControlDBRange?) -> Double {
        let floor = range?.minDB ?? estimateFloorDB
        guard scalar > 0 else { return floor }
        let dB = 20.0 * log10(Swift.min(1.0, scalar))
        return clampedDecibels(Swift.max(floor, dB), range: range)
    }

    static func estimatedScalar(fromDecibels dB: Double) -> Double {
        Swift.max(0.0, Swift.min(1.0, pow(10.0, Swift.min(0.0, dB) / 20.0)))
    }

    static func clampedDecibels(_ dB: Double, range: ControlDBRange?) -> Double {
        guard let range, range.maxDB >= range.minDB else { return dB }
        return Swift.max(range.minDB, Swift.min(range.maxDB, dB))
    }

    /// What asserting a configured level has to do: move the level when the
    /// device reports a dB reading that is off by more than the tolerance
    /// (no reading = nothing to compare, like the ALSA path), and unmute a
    /// managed output -- a configured level means the operator wants that
    /// level on the exciter, and a mute silently delivers none of it.
    struct AssertActions: Equatable {
        var setLevel: Bool
        var unmute: Bool
    }

    static func assertActions(have: Double?, muted: Bool?, want: Double) -> AssertActions {
        let drifted: Bool
        if let have {
            drifted = abs(have - want) > assertToleranceDB
        } else {
            drifted = false
        }
        return AssertActions(setLevel: drifted, unmute: muted == true)
    }

    /// The level used for "is it at unity" and for the dB readout: the
    /// device's own dB when it has one, the estimate otherwise.
    static func effectiveDecibels(_ probe: Probe) -> Double? {
        if let dB = probe.decibels { return dB }
        guard let scalar = probe.scalar else { return nil }
        return estimatedDecibels(fromScalar: scalar, range: probe.rangeDB)
    }

    static func isAtUnity(decibels: Double?, muted: Bool?) -> Bool {
        guard muted != true, let dB = decibels else { return muted != true && decibels == nil }
        return dB >= -unityToleranceDB
    }

    /// The routing note for an output below unity or muted; nil when there is
    /// nothing to say. British English, operator-facing.
    static func lowOutputNote(deviceName: String, probe: Probe) -> String? {
        guard probe.hasVolume else { return nil }
        if probe.muted == true {
            return "\(deviceName) output is muted in CoreAudio; nothing reaches the exciter. "
                + "Unmute it here or in Audio MIDI Setup."
        }
        guard let dB = effectiveDecibels(probe), dB < -unityToleranceDB else { return nil }
        let shortfall = compactDB(-dB)
        return "\(deviceName) output volume is \(formatDB(dB)) dB in CoreAudio; "
            + "the composite reaches the exciter \(shortfall) dB low. "
            + "Set it to 0 dB here or in Audio MIDI Setup."
    }

    /// "-5.0", "0.0": one decimal, like the dashboard's readouts.
    static func formatDB(_ dB: Double) -> String {
        String(format: "%.1f", dB)
    }

    /// "5" for a whole number of dB, "2.5" otherwise.
    static func compactDB(_ dB: Double) -> String {
        let rounded = (dB * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.05 {
            return String(Int(rounded.rounded()))
        }
        return String(format: "%.1f", rounded)
    }

    /// The dashboard's control shape for one side, or nil when the device
    /// has no volume on that side (BlackHole's input, for one).
    static func control(deviceName: String, side: Side, probe: Probe) -> ALSAMixerMath.Control? {
        guard probe.hasVolume, let scalar = probe.scalar else { return nil }
        var control = ALSAMixerMath.Control(name: deviceName, index: 0)
        let percent = percent(fromScalar: scalar)
        let dB = effectiveDecibels(probe)
        switch side {
        case .playback:
            control.playbackPercent = percent
            control.playbackDB = dB
            control.playbackMuted = probe.muted
        case .capture:
            control.capturePercent = percent
            control.captureDB = dB
            control.captureMuted = probe.muted
        }
        return control
    }

    /// A PATCH names the control it moves; on macOS that is the device. An
    /// empty name is accepted (the GUI's own buttons), a different name is a
    /// stale page talking about another device and is refused.
    static func patchNamesDevice(_ name: String, deviceName: String) -> Bool {
        name.isEmpty || name == deviceName
    }

    /// What the GUI's Audio I/O rows show for one side.
    struct Display: Equatable, Sendable {
        var deviceName: String
        var decibels: Double?
        var percent: Double
        var muted: Bool
        /// The dB figure is estimated from the slider position.
        var estimated: Bool
        var settable: Bool

        var atUnity: Bool { CoreAudioDeviceVolumeMath.isAtUnity(decibels: decibels, muted: muted) }

        var text: String {
            var parts: [String] = []
            if muted { parts.append("muted") }
            if let dB = decibels {
                parts.append((estimated ? "approx. " : "") + CoreAudioDeviceVolumeMath.formatDB(dB) + " dB")
            }
            return parts.joined(separator: ", ") + " (\(Int(percent.rounded())) %)"
        }
    }

    static func display(deviceName: String, probe: Probe) -> Display? {
        guard probe.hasVolume, let scalar = probe.scalar else { return nil }
        return Display(
            deviceName: deviceName,
            decibels: effectiveDecibels(probe),
            percent: percent(fromScalar: scalar),
            muted: probe.muted == true,
            estimated: probe.decibels == nil,
            settable: probe.settable)
    }

    /// The same display from a `GET /api/mixer` payload (the GUI reads the
    /// mixer through the backend service, like the dashboard does).
    static func display(from mixer: ControlMixer, side: Side) -> Display? {
        switch side {
        case .playback:
            guard let control = mixer.controls.first(where: { $0.playbackPercent != nil }),
                  let percent = control.playbackPercent
            else { return nil }
            return Display(
                deviceName: mixer.playbackDeviceName ?? control.name,
                decibels: control.playbackDB, percent: percent,
                muted: control.playbackMuted == true,
                estimated: mixer.playbackDBEstimated ?? false,
                settable: mixer.playbackSettable ?? true)
        case .capture:
            guard let control = mixer.controls.first(where: { $0.capturePercent != nil }),
                  let percent = control.capturePercent
            else { return nil }
            return Display(
                deviceName: mixer.captureDeviceName ?? control.name,
                decibels: control.captureDB, percent: percent,
                muted: control.captureMuted == true,
                estimated: mixer.captureDBEstimated ?? false,
                settable: mixer.captureSettable ?? true)
        }
    }

    /// The PATCH the GUI's "Set to 0 dB" button sends for one side.
    static func unityPatch(deviceName: String, side: Side) -> ControlMixerPatch {
        var patch = ControlMixerPatch(name: deviceName)
        switch side {
        case .playback:
            patch.playbackDB = 0
            patch.playbackMuted = false
        case .capture:
            patch.captureDB = 0
            patch.captureMuted = false
        }
        return patch
    }
}

/// What a `PATCH /api/mixer` left on the devices: the dB each side now reads
/// (nil = that side was not moved, or the device has no dB scale to record).
struct DeviceVolumeApplyResult: Sendable, Equatable {
    var playbackDB: Double?
    var captureDB: Double?
}

/// The device-volume layer as the control backends see it, platform-free so
/// the Linux build compiles against it and a test can inject a stub instead
/// of the HAL (the `deviceLister` rule). Every call reads the hardware live;
/// callers run it on the control actor or the main thread, never the render
/// thread.
struct DeviceVolumeService: Sendable {
    /// `GET /api/mixer`: the output device's playback control and the input
    /// device's capture control.
    var read: @Sendable (_ outputUID: String?, _ inputUID: String?) -> ControlMixer
    /// `PATCH /api/mixer`; nil when nothing could be applied.
    var apply: @Sendable (_ patch: ControlMixerPatch, _ outputUID: String?, _ inputUID: String?)
        -> DeviceVolumeApplyResult?
    /// Put the configured levels on the devices; returns the log lines of
    /// what it corrected.
    var assertLevels: @Sendable (
        _ playbackDB: Double?, _ captureDB: Double?, _ outputUID: String?, _ inputUID: String?
    ) -> [String]
    /// The routing note for an output below unity or muted; nil when fine.
    var outputNote: @Sendable (_ outputUID: String?) -> String?

    /// A platform without a device-volume layer (the Linux build reads ALSA
    /// directly instead).
    static let unavailable = DeviceVolumeService(
        read: { _, _ in
            ControlMixer(
                available: false, card: nil, controls: [],
                note: "No device volume layer on this platform.")
        },
        apply: { _, _, _ in nil },
        assertLevels: { _, _, _, _ in [] },
        outputNote: { _ in nil })

    static var platformDefault: DeviceVolumeService {
        #if os(macOS)
        return .coreAudio
        #else
        return .unavailable
        #endif
    }
}

#if os(macOS)
import CoreAudio
import MPXPrimeCore

/// The device's own volume in CoreAudio, read and written through the HAL's
/// AudioObject property API. Prefers the virtual main volume (one write moves
/// every channel), falls back to the per-channel scalars set alike, reads the
/// device's dB scale for the readout and estimates it only when the device
/// has none. HAL calls block on the device driver, so this is called from the
/// control actor or the main thread -- never from a render callback.
enum CoreAudioDeviceVolume {
    typealias Math = CoreAudioDeviceVolumeMath

    enum Scope {
        case output
        case input

        var hal: AudioObjectPropertyScope {
            switch self {
            case .output: return kAudioObjectPropertyScopeOutput
            case .input: return kAudioObjectPropertyScopeInput
            }
        }
    }

    struct Reading: Sendable, Equatable {
        var deviceID: AudioDeviceID
        var deviceName: String
        var probe: Math.Probe
    }

    /// 'vmvc', `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`: the
    /// HAL serves it on the device object; spelt out so this file needs only
    /// CoreAudio.
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    // MARK: - Device lookup

    /// The configured device by UID, or the system default for the scope when
    /// the operator left the selection on "System Default".
    static func deviceID(forUID uid: String?, scope: Scope) -> AudioDeviceID? {
        if let uid, !uid.isEmpty {
            return (try? AudioDevices.list())?.first(where: { $0.uid == uid })?.id
        }
        return scope == .output ? AudioDevices.defaultOutputDeviceID() : AudioDevices.defaultInputDeviceID()
    }

    static func read(deviceUID: String?, scope: Scope) -> Reading? {
        guard let id = deviceID(forUID: deviceUID, scope: scope) else { return nil }
        return Reading(deviceID: id, deviceName: deviceName(id), probe: probe(id, scope: scope.hal))
    }

    // MARK: - Probe

    private static func probe(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Math.Probe {
        var probe = Math.Probe()
        let mainVirtual = has(id, virtualMainVolume, scope, 0)
        let mainScalar = has(id, kAudioDevicePropertyVolumeScalar, scope, 0)
        probe.mainHasVolume = mainVirtual || mainScalar
        probe.channelElements = (1...Math.maxChannelElements).filter {
            has(id, kAudioDevicePropertyVolumeScalar, scope, $0)
        }
        let elements: [UInt32]
        let scalarSelector: AudioObjectPropertySelector
        switch Math.elementChoice(mainHasVolume: probe.mainHasVolume, channelElements: probe.channelElements) {
        case .none:
            return probe
        case .main:
            elements = [0] + probe.channelElements
            scalarSelector = mainVirtual ? virtualMainVolume : kAudioDevicePropertyVolumeScalar
        case .channels(let channels):
            elements = channels
            scalarSelector = kAudioDevicePropertyVolumeScalar
        }
        let first = elements[0]
        probe.scalar = readFloat(id, scalarSelector, scope, first).map(Double.init)
        probe.settable = isSettable(id, scalarSelector, scope, first)
        probe.decibels = firstValue(elements) { readFloat(id, kAudioDevicePropertyVolumeDecibels, scope, $0) }
            .map(Double.init)
        if probe.decibels == nil, let scalar = probe.scalar {
            probe.decibels = firstValue(elements) {
                translate(id, kAudioDevicePropertyVolumeScalarToDecibels, scope, $0, Float32(scalar))
            }.map(Double.init)
        }
        probe.rangeDB = firstValue(elements) { readRange(id, kAudioDevicePropertyVolumeRangeDecibels, scope, $0) }
        probe.muted = firstValue(elements) { readUInt32(id, kAudioDevicePropertyMute, scope, $0) }.map { $0 != 0 }
        return probe
    }

    // MARK: - Set

    /// Move the slider position (0...1) on the main element, or on every
    /// channel element alike.
    static func setScalar(deviceID id: AudioDeviceID, scope: Scope, scalar: Double) -> Bool {
        let probe = probe(id, scope: scope.hal)
        let value = Float32(Swift.max(0.0, Swift.min(1.0, scalar)))
        switch Math.elementChoice(mainHasVolume: probe.mainHasVolume, channelElements: probe.channelElements) {
        case .none:
            return false
        case .main:
            let selector = has(id, virtualMainVolume, scope.hal, 0)
                ? virtualMainVolume : kAudioDevicePropertyVolumeScalar
            return writeFloat(id, selector, scope.hal, 0, value)
        case .channels(let channels):
            var ok = true
            for element in channels {
                ok = writeFloat(id, kAudioDevicePropertyVolumeScalar, scope.hal, element, value) && ok
            }
            return ok
        }
    }

    /// Set a level in dB, the unit the operator reasons in: through the
    /// device's dB property where it is settable, through its dB-to-scalar
    /// translation otherwise, and by estimate only when it has neither.
    static func setDecibels(deviceID id: AudioDeviceID, scope: Scope, decibels: Double) -> Bool {
        let probe = probe(id, scope: scope.hal)
        guard probe.hasVolume else { return false }
        let target = Float32(Math.clampedDecibels(decibels, range: probe.rangeDB))
        let elements: [UInt32] = probe.mainHasVolume ? [0] + probe.channelElements : probe.channelElements
        if probe.mainHasVolume, isSettable(id, kAudioDevicePropertyVolumeDecibels, scope.hal, 0) {
            return writeFloat(id, kAudioDevicePropertyVolumeDecibels, scope.hal, 0, target)
        }
        if !probe.mainHasVolume,
           probe.channelElements.allSatisfy({ isSettable(id, kAudioDevicePropertyVolumeDecibels, scope.hal, $0) }) {
            var ok = true
            for element in probe.channelElements {
                ok = writeFloat(id, kAudioDevicePropertyVolumeDecibels, scope.hal, element, target) && ok
            }
            return ok
        }
        let translated = firstValue(elements) {
            translate(id, kAudioDevicePropertyVolumeDecibelsToScalar, scope.hal, $0, target)
        }
        let scalar = translated.map(Double.init) ?? Math.estimatedScalar(fromDecibels: Double(target))
        return setScalar(deviceID: id, scope: scope, scalar: scalar)
    }

    static func setMuted(deviceID id: AudioDeviceID, scope: Scope, muted: Bool) -> Bool {
        let value: UInt32 = muted ? 1 : 0
        if has(id, kAudioDevicePropertyMute, scope.hal, 0) {
            return writeUInt32(id, kAudioDevicePropertyMute, scope.hal, 0, value)
        }
        let channels = (1...Math.maxChannelElements).filter { has(id, kAudioDevicePropertyMute, scope.hal, $0) }
        guard !channels.isEmpty else { return false }
        var ok = true
        for element in channels {
            ok = writeUInt32(id, kAudioDevicePropertyMute, scope.hal, element, value) && ok
        }
        return ok
    }

    // MARK: - The mixer API served from CoreAudio

    /// `GET /api/mixer` on macOS: the output device's playback control and the
    /// input device's capture control, plus a note for anything that has no
    /// control ("no control" is a fact, not an error) and for an output below
    /// unity.
    static func mixer(outputUID: String?, inputUID: String?) -> ControlMixer {
        var mixer = ControlMixer(available: false, card: nil, controls: [], note: nil)
        var notes: [String] = []
        if let out = read(deviceUID: outputUID, scope: .output) {
            if let control = Math.control(deviceName: out.deviceName, side: .playback, probe: out.probe) {
                mixer.controls.append(control)
                mixer.playbackDeviceName = out.deviceName
                mixer.playbackRangeDB = out.probe.rangeDB
                mixer.playbackSettable = out.probe.settable
                mixer.playbackDBEstimated = out.probe.decibels == nil
                if out.probe.decibels == nil {
                    notes.append("\(out.deviceName) reports no dB scale; its output level in dB is estimated from the slider position.")
                }
                if let note = Math.lowOutputNote(deviceName: out.deviceName, probe: out.probe) {
                    notes.append(note)
                }
            } else {
                notes.append("Output device \(out.deviceName) has no volume control in CoreAudio.")
            }
        } else {
            notes.append("The output device was not found; its volume cannot be read.")
        }
        if let input = read(deviceUID: inputUID, scope: .input) {
            if let control = Math.control(deviceName: input.deviceName, side: .capture, probe: input.probe) {
                mixer.controls.append(control)
                mixer.captureDeviceName = input.deviceName
                mixer.captureRangeDB = input.probe.rangeDB
                mixer.captureSettable = input.probe.settable
                mixer.captureDBEstimated = input.probe.decibels == nil
            } else {
                notes.append("Input device \(input.deviceName) has no input level control in CoreAudio.")
            }
        }
        mixer.available = !mixer.controls.isEmpty
        mixer.note = notes.isEmpty ? nil : notes.joined(separator: " ")
        return mixer
    }

    /// `PATCH /api/mixer` on macOS. The side is implied by the fields present
    /// (playback = output device, capture = input device), as on Linux.
    static func apply(_ patch: ControlMixerPatch, outputUID: String?, inputUID: String?) -> DeviceVolumeApplyResult? {
        var result = DeviceVolumeApplyResult()
        var touched = false
        var ok = true
        if patch.playbackPercent != nil || patch.playbackDB != nil || patch.playbackMuted != nil {
            guard let out = read(deviceUID: outputUID, scope: .output), out.probe.hasVolume,
                  Math.patchNamesDevice(patch.name, deviceName: out.deviceName)
            else { return nil }
            if let dB = patch.playbackDB {
                ok = setDecibels(deviceID: out.deviceID, scope: .output, decibels: dB) && ok
            } else if let percent = patch.playbackPercent {
                ok = setScalar(deviceID: out.deviceID, scope: .output, scalar: Math.scalar(fromPercent: percent)) && ok
            }
            if let muted = patch.playbackMuted {
                ok = setMuted(deviceID: out.deviceID, scope: .output, muted: muted) && ok
            }
            if patch.playbackDB != nil || patch.playbackPercent != nil {
                result.playbackDB = probe(out.deviceID, scope: Scope.output.hal).decibels
            }
            touched = true
        }
        if patch.capturePercent != nil || patch.captureDB != nil || patch.captureMuted != nil {
            guard let input = read(deviceUID: inputUID, scope: .input), input.probe.hasVolume,
                  Math.patchNamesDevice(patch.name, deviceName: input.deviceName)
            else { return nil }
            if let dB = patch.captureDB {
                ok = setDecibels(deviceID: input.deviceID, scope: .input, decibels: dB) && ok
            } else if let percent = patch.capturePercent {
                ok = setScalar(deviceID: input.deviceID, scope: .input, scalar: Math.scalar(fromPercent: percent)) && ok
            }
            if let muted = patch.captureMuted {
                ok = setMuted(deviceID: input.deviceID, scope: .input, muted: muted) && ok
            }
            if patch.captureDB != nil || patch.capturePercent != nil {
                result.captureDB = probe(input.deviceID, scope: Scope.input.hal).decibels
            }
            touched = true
        }
        return touched && ok ? result : nil
    }

    /// Put the configured levels where the config says, when it says: at
    /// engine start and on the reconcile tick, like the ALSA assert.
    static func assertLevels(
        playbackDB: Double?, captureDB: Double?, outputUID: String?, inputUID: String?
    ) -> [String] {
        var lines: [String] = []
        if let want = playbackDB, let out = read(deviceUID: outputUID, scope: .output), out.probe.hasVolume {
            lines += assertReading(out, scope: .output, want: want, what: "output volume")
        }
        if let want = captureDB, let input = read(deviceUID: inputUID, scope: .input), input.probe.hasVolume {
            lines += assertReading(input, scope: .input, want: want, what: "input level")
        }
        return lines
    }

    private static func assertReading(_ reading: Reading, scope: Scope, want: Double, what: String) -> [String] {
        var lines: [String] = []
        let actions = Math.assertActions(have: reading.probe.decibels, muted: reading.probe.muted, want: want)
        if actions.setLevel, let have = reading.probe.decibels {
            let target = Math.clampedDecibels(want, range: reading.probe.rangeDB)
            if setDecibels(deviceID: reading.deviceID, scope: scope, decibels: target) {
                lines.append(
                    "[CoreAudio] \(reading.deviceName) \(what) was \(Math.formatDB(have)) dB, "
                    + "re-asserted \(Math.formatDB(target)) dB")
            }
        }
        if actions.unmute, setMuted(deviceID: reading.deviceID, scope: scope, muted: false) {
            lines.append("[CoreAudio] \(reading.deviceName) \(what) was muted, unmuted")
        }
        return lines
    }

    static func outputNote(outputUID: String?) -> String? {
        guard let out = read(deviceUID: outputUID, scope: .output) else { return nil }
        return Math.lowOutputNote(deviceName: out.deviceName, probe: out.probe)
    }

    // MARK: - HAL plumbing

    /// The first element that answers the query (element 0 first, then the
    /// channels), so a reading never mixes two elements.
    private static func firstValue<T>(_ elements: [UInt32], _ read: (UInt32) -> T?) -> T? {
        for element in elements {
            guard let value = read(element) else { continue }
            return value
        }
        return nil
    }

    private static func address(
        _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ element: UInt32
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func has(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope, _ element: UInt32
    ) -> Bool {
        var addr = address(selector, scope, element)
        return AudioObjectHasProperty(id, &addr)
    }

    private static func isSettable(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope, _ element: UInt32
    ) -> Bool {
        var addr = address(selector, scope, element)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectIsPropertySettable(id, &addr, &settable) == noErr
        else { return false }
        return settable.boolValue
    }

    private static func readFloat(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope, _ element: UInt32
    ) -> Float32? {
        var addr = address(selector, scope, element)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func writeFloat(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope, _ element: UInt32, _ value: Float32
    ) -> Bool {
        var addr = address(selector, scope, element)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var copy = value
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &copy) == noErr
    }

    private static func readUInt32(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope, _ element: UInt32
    ) -> UInt32? {
        var addr = address(selector, scope, element)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func writeUInt32(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope, _ element: UInt32, _ value: UInt32
    ) -> Bool {
        var addr = address(selector, scope, element)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var copy = value
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &copy) == noErr
    }

    private static func readRange(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope, _ element: UInt32
    ) -> ControlDBRange? {
        var addr = address(selector, scope, element)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &range) == noErr else { return nil }
        return ControlDBRange(minDB: range.mMinimum, maxDB: range.mMaximum)
    }

    /// The HAL's in-place translations (`VolumeScalarToDecibels` and back):
    /// the value goes in and comes out converted.
    private static func translate(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope, _ element: UInt32, _ value: Float32
    ) -> Float32? {
        var addr = address(selector, scope, element)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var inOut = value
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &inOut) == noErr else { return nil }
        return inOut
    }

    private static func deviceName(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, 0)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else {
            return "AudioDevice \(id)"
        }
        return value.takeUnretainedValue() as String
    }
}

extension DeviceVolumeService {
    /// The real HAL layer, the production default on macOS.
    static let coreAudio = DeviceVolumeService(
        read: { outputUID, inputUID in
            CoreAudioDeviceVolume.mixer(outputUID: outputUID, inputUID: inputUID)
        },
        apply: { patch, outputUID, inputUID in
            CoreAudioDeviceVolume.apply(patch, outputUID: outputUID, inputUID: inputUID)
        },
        assertLevels: { playbackDB, captureDB, outputUID, inputUID in
            CoreAudioDeviceVolume.assertLevels(
                playbackDB: playbackDB, captureDB: captureDB, outputUID: outputUID, inputUID: inputUID)
        },
        outputNote: { outputUID in
            CoreAudioDeviceVolume.outputNote(outputUID: outputUID)
        })
}
#endif
