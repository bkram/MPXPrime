import Foundation

/// The arithmetic and string handling behind the ALSA mixer controls, kept
/// platform-independent so it is testable on the machine this is developed on.
/// The libasound binding itself is `ALSAMixer`, Linux-only, below.
enum ALSAMixerMath {

    /// One simple-mixer control, as the dashboard shows it.
    struct Control: Codable, Sendable, Equatable {
        var name: String
        var index: UInt32
        /// Percent of the control's own range, 0...100, or nil when the
        /// control has no volume on that side.
        var playbackPercent: Double?
        var capturePercent: Double?
        /// The card's own dB reading, when it reports one.
        var playbackDB: Double?
        var captureDB: Double?
        var playbackMuted: Bool?
        var captureMuted: Bool?
    }

    /// The card name inside a `hw:CARD=Name,DEV=0` device string, which is
    /// what the mixer wants (`default:Name`). Returns nil for a plain
    /// `default` or an unparseable string.
    static func cardName(fromDeviceUID uid: String) -> String? {
        guard let range = uid.range(of: "CARD=") else { return nil }
        let rest = uid[range.upperBound...]
        let name = rest.prefix { $0 != "," }
        return name.isEmpty ? nil : String(name)
    }

    /// Percent from a raw value inside its range, matching `amixer`'s own
    /// rounding so the dashboard and the command line agree.
    static func percent(value: Int, min: Int, max: Int) -> Double {
        guard max > min else { return 0 }
        return (Double(value - min) / Double(max - min)) * 100.0
    }

    /// The raw value a percent asks for, clamped into the control's range.
    static func rawValue(percent: Double, min: Int, max: Int) -> Int {
        guard max > min else { return min }
        let clamped = Swift.max(0.0, Swift.min(100.0, percent))
        let scaled = Double(min) + (clamped / 100.0) * Double(max - min)
        return Int(scaled.rounded())
    }
}

#if os(Linux)
import CAlsa

/// The sound card's own volume controls, read and written through libasound's
/// simple mixer API.
///
/// Why the encoder exposes these at all: on Linux the card's mixer sits
/// BETWEEN the encoder and the exciter, so a slider at 96% quietly costs 2 dB
/// of composite that no meter in the app can see -- and the operator has no
/// GUI on that box, only the dashboard. It has bitten this project twice: a
/// mixer at zero was half of the "stereo lamp but no RDS" hunt, and a stored
/// level came back 2 dB down after a reboot. Calibration still belongs in the
/// encoder (`output_gain_db` / `mpx_line_output_dbfs`); this is here so the
/// operator can SEE the hardware path is at unity and put it back when it is
/// not.
///
/// Deliberately not part of the INI: these are hardware state, owned by ALSA
/// and shared with anything else on the box, so they are read live and never
/// persisted by us. `alsactl store` is what makes them survive a reboot.
enum ALSAMixer {

    private static func withMixer<T>(
        card: String, _ body: (OpaquePointer) throws -> T
    ) rethrows -> T? {
        var handle: OpaquePointer?
        guard snd_mixer_open(&handle, 0) >= 0, let mixer = handle else { return nil }
        defer { snd_mixer_close(mixer) }
        guard snd_mixer_attach(mixer, "default:" + card) >= 0,
              snd_mixer_selem_register(mixer, nil, nil) >= 0,
              snd_mixer_load(mixer) >= 0
        else { return nil }
        return try body(mixer)
    }

    /// Every simple control on `card` that carries a volume.
    static func controls(card: String) -> [ALSAMixerMath.Control] {
        withMixer(card: card) { mixer -> [ALSAMixerMath.Control] in
            var out: [ALSAMixerMath.Control] = []
            var element = snd_mixer_first_elem(mixer)
            while let elem = element {
                var control = ALSAMixerMath.Control(
                    name: String(cString: snd_mixer_selem_get_name(elem)),
                    index: snd_mixer_selem_get_index(elem))
                var lo: Int = 0
                var hi: Int = 0
                var raw: Int = 0

                if snd_mixer_selem_has_playback_volume(elem) == 1,
                   snd_mixer_selem_get_playback_volume_range(elem, &lo, &hi) >= 0,
                   snd_mixer_selem_get_playback_volume(elem, SND_MIXER_SCHN_FRONT_LEFT, &raw) >= 0 {
                    control.playbackPercent = ALSAMixerMath.percent(value: raw, min: lo, max: hi)
                    var dB: Int = 0
                    if snd_mixer_selem_get_playback_dB(elem, SND_MIXER_SCHN_FRONT_LEFT, &dB) >= 0 {
                        control.playbackDB = Double(dB) / 100.0
                    }
                }
                if snd_mixer_selem_has_capture_volume(elem) == 1,
                   snd_mixer_selem_get_capture_volume_range(elem, &lo, &hi) >= 0,
                   snd_mixer_selem_get_capture_volume(elem, SND_MIXER_SCHN_FRONT_LEFT, &raw) >= 0 {
                    control.capturePercent = ALSAMixerMath.percent(value: raw, min: lo, max: hi)
                    var dB: Int = 0
                    if snd_mixer_selem_get_capture_dB(elem, SND_MIXER_SCHN_FRONT_LEFT, &dB) >= 0 {
                        control.captureDB = Double(dB) / 100.0
                    }
                }
                var switchValue: Int32 = 0
                if snd_mixer_selem_has_playback_switch(elem) == 1,
                   snd_mixer_selem_get_playback_switch(elem, SND_MIXER_SCHN_FRONT_LEFT, &switchValue) >= 0 {
                    control.playbackMuted = switchValue == 0
                }
                if snd_mixer_selem_has_capture_switch(elem) == 1,
                   snd_mixer_selem_get_capture_switch(elem, SND_MIXER_SCHN_FRONT_LEFT, &switchValue) >= 0 {
                    control.captureMuted = switchValue == 0
                }

                if control.playbackPercent != nil || control.capturePercent != nil {
                    out.append(control)
                }
                element = snd_mixer_elem_next(elem)
            }
            return out
        } ?? []
    }

    /// The first control carrying a playback volume and the first carrying a
    /// capture volume: on a USB card these are the output and input paths the
    /// encoder actually uses ("Headphone" / "Mic" on the rig's C-Media card,
    /// "PCM" / "Capture" on others). The asserted dB keys apply to these.
    static func primaryControls(card: String) -> (playback: ALSAMixerMath.Control?, capture: ALSAMixerMath.Control?) {
        let all = controls(card: card)
        return (all.first { $0.playbackPercent != nil }, all.first { $0.capturePercent != nil })
    }

    /// Set a control by dB, the unit the operator reasons in and the card
    /// reports. ALSA rounds to the nearest step the control has; the caller
    /// reads back what it took. Returns false when the control is missing or
    /// has no dB scale.
    static func setDB(card: String, name: String, index: UInt32, playbackDB: Double?, captureDB: Double?) -> Bool {
        withMixer(card: card) { mixer -> Bool in
            var sid: OpaquePointer?
            snd_mixer_selem_id_malloc(&sid)
            guard let selemID = sid else { return false }
            defer { snd_mixer_selem_id_free(selemID) }
            snd_mixer_selem_id_set_index(selemID, index)
            snd_mixer_selem_id_set_name(selemID, name)
            guard let elem = snd_mixer_find_selem(mixer, selemID) else { return false }
            var ok = true
            if let dB = playbackDB, snd_mixer_selem_has_playback_volume(elem) == 1 {
                ok = snd_mixer_selem_set_playback_dB_all(elem, Int(lround(dB * 100.0)), 0) >= 0 && ok
            }
            if let dB = captureDB, snd_mixer_selem_has_capture_volume(elem) == 1 {
                ok = snd_mixer_selem_set_capture_dB_all(elem, Int(lround(dB * 100.0)), 0) >= 0 && ok
            }
            return ok
        } ?? false
    }

    /// Set one control. Every field is optional: only what is supplied moves.
    /// Returns false when the card or the control could not be opened.
    static func set(
        card: String,
        name: String,
        index: UInt32,
        playbackPercent: Double?,
        capturePercent: Double?,
        playbackMuted: Bool?,
        captureMuted: Bool?
    ) -> Bool {
        withMixer(card: card) { mixer -> Bool in
            var sid: OpaquePointer?
            snd_mixer_selem_id_malloc(&sid)
            guard let selemID = sid else { return false }
            defer { snd_mixer_selem_id_free(selemID) }
            snd_mixer_selem_id_set_index(selemID, index)
            snd_mixer_selem_id_set_name(selemID, name)
            guard let elem = snd_mixer_find_selem(mixer, selemID) else { return false }

            var lo: Int = 0
            var hi: Int = 0
            if let pct = playbackPercent,
               snd_mixer_selem_has_playback_volume(elem) == 1,
               snd_mixer_selem_get_playback_volume_range(elem, &lo, &hi) >= 0 {
                _ = snd_mixer_selem_set_playback_volume_all(elem, ALSAMixerMath.rawValue(percent: pct, min: lo, max: hi))
            }
            if let pct = capturePercent,
               snd_mixer_selem_has_capture_volume(elem) == 1,
               snd_mixer_selem_get_capture_volume_range(elem, &lo, &hi) >= 0 {
                _ = snd_mixer_selem_set_capture_volume_all(elem, ALSAMixerMath.rawValue(percent: pct, min: lo, max: hi))
            }
            if let muted = playbackMuted, snd_mixer_selem_has_playback_switch(elem) == 1 {
                _ = snd_mixer_selem_set_playback_switch_all(elem, muted ? 0 : 1)
            }
            if let muted = captureMuted, snd_mixer_selem_has_capture_switch(elem) == 1 {
                _ = snd_mixer_selem_set_capture_switch_all(elem, muted ? 0 : 1)
            }
            return true
        } ?? false
    }
}
#endif
