// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import Foundation
import MPXPrimeCore
import MPXPrimeUI
import SwiftUI

// The RDS pages. Page titles, subtitles and help come from `Stage`; the
// scaffold in `StageContentView` adds the reset button and the help box.
// Every setting is bound through `model.setting(...)` with the disposition
// the engine derives (RDS data keys apply live through the RDS runtime
// config; only the subcarrier injection needs a restart), so the restart
// badge is never hand-placed. RDS group codes (0A, 1A, 2A, 4A, 15A) belong
// in tooltips, never on labels.

/// Bindings the RDS pages need beyond a plain `setting()`.
extension MPXPrimeViewModel {
    /// A setting whose binding sanitises its input (PI, ECC, LIC, PTY).
    /// Recorded for the layout audit like `setting()`.
    func rdsSetting<T>(
        _ keyPath: WritableKeyPath<AppConfig, T>, binding: Binding<T>
    ) -> ConfigSetting<T> {
        SettingAudit.record(keyPath, .liveRDS)
        return ConfigSetting(binding: binding, disposition: .liveRDS)
    }
}

/// Values and labels the RDS pages show, kept testable.
enum RDSPageFormat {
    /// Time-zone choices: -12 to +14 hours in quarter hours.
    static let timeZoneChoices: [Double] = stride(from: -48, through: 56, by: 1).map { Double($0) / 4.0 }

    /// "UTC+01:00", "UTC-03:30", "UTC+05:45", "UTC+00:00".
    static func timeZoneLabel(_ hours: Double) -> String {
        let quarters = Int((hours * 4.0).rounded())
        let sign = quarters < 0 ? "-" : "+"
        let minutes = abs(quarters) * 15
        return String(format: "UTC%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }

    /// The menu's choices, plus the stored value if it is off the grid
    /// (an INI edited by hand), so the picker always shows the real value.
    static func timeZoneMenu(including current: Double) -> [Double] {
        timeZoneChoices.contains(current) ? timeZoneChoices : (timeZoneChoices + [current]).sorted()
    }

    /// RDS injection as the operator reads it: kHz, with the share of the
    /// 75 kHz reference deviation, e.g. "2.0 kHz (2.7%)".
    static func injectionReadout(kHz: Double) -> String {
        String(format: "%.1f kHz (%.1f%%)", kHz, kHz / 75.0 * 100.0)
    }

    static let injectionRangeKHz: ClosedRange<Double> = 0.0...7.5
    static let psFrameRange: ClosedRange<Double> = 0.5...30.0
    static let cycleTimeRange: ClosedRange<Double> = 1.0...60.0
}

// MARK: - Status

/// The landing page: the master switch and the switches an operator flips
/// during the day (TA, TP, MS), then what is on air now.
struct RDSStatusTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Switches") {
            RDSStatusSwitches(model: model)
        }
        Card(title: "On Air Now", style: .meter) {
            RDSLivePreviewPlate(model: model)
        }
    }
}

struct RDSStatusSwitches: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        SettingToggle("Enable RDS", setting: model.setting(\.enRDS, .liveRDS),
                      tooltip: "Turns the 57 kHz RDS subcarrier on or off.")
            .toggleStyle(.switch)
        LazyVGrid(columns: [
            GridItem(.flexible(minimum: 120)),
            GridItem(.flexible(minimum: 120)),
            GridItem(.flexible(minimum: 120))
        ], alignment: .leading, spacing: 8) {
            SettingToggle("Traffic Programme (TP)", setting: model.setting(\.rdsTP, .liveRDS),
                          tooltip: "This station carries traffic announcements from time to time.")
            SettingToggle("Traffic Announcement (TA)", setting: model.setting(\.rdsTA, .liveRDS),
                          tooltip: "Switch on for the length of a traffic bulletin so receivers set to traffic switch to it, then off again.")
            SettingToggle("Music (MS)", setting: model.setting(\.rdsMS, .liveRDS),
                          tooltip: "Music/speech switch: on while music plays, off for speech.")
        }
        .toggleStyle(.switch)
        .disabled(!model.config.enRDS)
    }
}

// MARK: - Identity

/// Who the station is: the codes a receiver identifies it by, the station
/// names, then the set-once fields under Advanced.
struct RDSProgramTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Station") {
            RDSStationCodes(model: model)
        }
        Card(title: "Station Name (PS)") {
            RDSStationNames(model: model)
        }
        Card(title: "Long PS") {
            RDSLongPSFields(model: model)
        }
        Card {
            RDSIdentityAdvanced(model: model)
        }
    }
}

struct RDSStationCodes: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        LabeledContent {
            HexCodeField(text: model.rdsSetting(\.rdsPI, binding: model.piBinding()).binding,
                         placeholder: "0000", width: 72)
        } label: {
            Text("PI Code")
        }
        .help("Programme Identification: the 16-bit hex code a receiver recognises the station by and follows across alternative frequencies. Assigned by your broadcasting authority; in RBDS it is derived from the call sign.")
        LabeledContent {
            HexCodeField(text: model.rdsSetting(\.rdsECC, binding: model.hexByteBinding(\.rdsECC)).binding,
                         placeholder: "E0", width: 54)
        } label: {
            Text("Extended Country Code (ECC)")
        }
        .help("One hex byte that, with the first digit of the PI code, identifies the country. Use the value your broadcasting authority assigns (IEC 62106 annex D).")
        SettingPicker("Programme Type (PTY)", setting: model.rdsSetting(\.rdsPTY, binding: model.ptyBinding())) {
            ForEach(model.ptyChoices, id: \.0) { pty in
                Text("\(pty.0) - \(pty.1)").tag(pty.0)
            }
        }
        .pickerStyle(.menu)
        SettingPicker("PTY Names", setting: model.setting(\.rdsPtyRBDS, .none),
                      tooltip: "Which table names the PTY codes above. The transmitted code is the same either way: Europe (RDS) and North America (RBDS) name the same number differently, and receivers pick the table by region.") {
            Text("Europe (RDS)").tag(false)
            Text("North America (RBDS)").tag(true)
        }
        .pickerStyle(.segmented)
    }
}

struct RDSStationNames: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        PSBankRow(letter: "A", model: model, path: \.rdsPSA)
        PSBankRow(letter: "B", model: model, path: \.rdsPSB)
        PSBankRow(letter: "C", model: model, path: \.rdsPSC)
        PSBankRow(letter: "D", model: model, path: \.rdsPSD)
        SettingToggle("Centre PS", setting: model.setting(\.rdsPSCentered, .liveRDS),
                      tooltip: "Centres a name shorter than 8 characters in the display.")
        DoubleSliderRow(
            title: "PS Frame Time",
            setting: model.setting(\.rdsPSFrameSeconds, .liveRDS),
            range: RDSPageFormat.psFrameRange,
            format: "%.1f s",
            tooltip: "How long each 8-character chunk of a longer name stays on screen, unless the text sets its own time with a marker such as 4s:NEWS. 3 s is typical.",
            defaultValue: model.resetValue(\.rdsPSFrameSeconds))
        Text("Click the circle to choose which name goes on air.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct RDSLongPSFields: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        SettingToggle("Enable Long PS", setting: model.setting(\.rdsEnableLPS, .liveRDS),
                      tooltip: "Sends a station name of up to 32 characters (group 15A). Receivers that decode it show the full name; others keep showing the 8-character name.")
        RDSCountedField(placeholder: "Long station name",
                        text: model.setting(\.rdsLongPS32, .liveRDS).binding, maxChars: 32)
            .disabled(!model.config.rdsEnableLPS)
        SettingToggle("Centre Long PS", setting: model.setting(\.rdsLPSCentered, .liveRDS))
            .disabled(!model.config.rdsEnableLPS)
        SettingToggle("Append Carriage Return", setting: model.setting(\.rdsLPSCR, .liveRDS),
                      tooltip: "Ends the name with a carriage return so receivers know where it stops.")
            .disabled(!model.config.rdsEnableLPS)
    }
}

/// Set-once identity fields: language, PTYN, PIN, decoder information, ID.
struct RDSIdentityAdvanced: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        AdvancedGroup {
            LabeledContent {
                HexCodeField(text: model.rdsSetting(\.rdsLIC, binding: model.hexByteBinding(\.rdsLIC)).binding,
                             placeholder: "09", width: 54)
            } label: {
                Text("Language Code (LIC)")
            }
            .help("One hex byte naming the programme language (group 1A), independent of the country. For example 09 English, 08 German, 0F French, 15 Italian, 0A Spanish.")
            SettingToggle("Enable PTYN", setting: model.setting(\.rdsEnablePTYN, .liveRDS),
                          tooltip: "Programme Type Name (group 10A): an 8-character text that refines the PTY genre, such as FOOTBALL under Sport.")
            RDSCountedField(placeholder: "PTYN", text: model.setting(\.rdsPTYN, .liveRDS).binding, maxChars: 8)
                .disabled(!model.config.rdsEnablePTYN)
            SettingToggle("Centre PTYN", setting: model.setting(\.rdsPTYNCentered, .liveRDS))
                .disabled(!model.config.rdsEnablePTYN)
            SettingToggle("Enable PIN", setting: model.setting(\.rdsEnablePIN, .liveRDS),
                          tooltip: "Programme Item Number (group 1A): the scheduled start of the current programme item. Rarely decoded by modern receivers; off sends 0.")
            if model.config.rdsEnablePIN {
                HStack(spacing: 14) {
                    Stepper("Day \(model.config.rdsPINDay)",
                            value: model.setting(\.rdsPINDay, .liveRDS).binding, in: 1...31)
                    Stepper("Hour \(model.config.rdsPINHour)",
                            value: model.setting(\.rdsPINHour, .liveRDS).binding, in: 0...23)
                    Stepper("Minute \(model.config.rdsPINMinute)",
                            value: model.setting(\.rdsPINMinute, .liveRDS).binding, in: 0...59)
                }
                .font(.callout)
            }
            SettingToggle("Enable ID", setting: model.setting(\.rdsEnableID, .liveRDS),
                          tooltip: "Sends the language and country identification (group 1A).")
            SettingToggle("Stereo (DI)", setting: model.setting(\.rdsDI_STEREO, .liveRDS),
                          tooltip: "Decoder information: the programme is stereo (off: mono). Match the actual programme.")
            SettingToggle("Artificial Head (DI)", setting: model.setting(\.rdsDI_HEAD, .liveRDS),
                          tooltip: "Decoder information: binaural (artificial-head) recording. Leave off for normal stereo.")
            SettingToggle("Compressed (DI)", setting: model.setting(\.rdsDI_COMP, .liveRDS),
                          tooltip: "Decoder information: the audio is companded (an obsolete noise-reduction scheme). Leave off.")
            SettingToggle("Dynamic PTY (DI)", setting: model.setting(\.rdsDI_DYN, .liveRDS),
                          tooltip: "Decoder information: the programme type changes during the broadcast rather than being fixed for the station.")
        }
    }
}

struct PSBankRow: View {
    let letter: String
    @ObservedObject var model: MPXPrimeViewModel
    let path: WritableKeyPath<AppConfig, String>

    var body: some View {
        let isActive = model.config.rdsPSActiveBank.uppercased() == letter
        HStack(spacing: 10) {
            Button {
                model.setConfigValue(\.rdsPSActiveBank, letter, runtimeDisposition: .liveRDS)
            } label: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isActive ? "PS \(letter) on air" : "Put PS \(letter) on air")
            .help("Put PS \(letter) on air")

            Text("PS \(letter)")
                .frame(width: 40, alignment: .leading)
                .font(.callout.monospaced())
                .foregroundStyle(isActive ? Color.primary : Color.secondary)

            RDSCountedField(placeholder: "", text: model.setting(path, .liveRDS).binding, maxChars: 8)
        }
    }
}

/// RDS text entry with a live character counter. RDS fields have hard
/// length limits (PS 8, PTYN 8, Long PS 32, Radiotext 64); past the limit
/// the encoder silently truncates. The trailing `n/max` counter turns amber
/// once the field reaches the limit so the operator sees it before air.
struct RDSCountedField: View {
    let placeholder: String
    let text: Binding<String>
    let maxChars: Int

    var body: some View {
        let count = text.wrappedValue.count
        let atLimit = count >= maxChars
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
            Text("\(count)/\(maxChars)")
                .font(BroadcastStyle.scaleLabel)
                .monospacedDigit()
                .foregroundStyle(atLimit ? BroadcastStyle.tightAmber : .secondary)
                .accessibilityLabel("\(count) of \(maxChars) characters")
        }
    }
}

struct HexCodeField: View {
    let text: Binding<String>
    let placeholder: String
    let width: CGFloat

    var body: some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(.tertiary))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced).weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(width: width)
            .textSelection(.enabled)
    }
}

// MARK: - Radiotext

struct RDSRadiotextTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Text") {
            RDSRadiotextText(model: model)
        }
        Card(title: "Messages") {
            RDSRadiotextMessages(model: model)
        }
        Card(title: "RT+") {
            RDSRadiotextPlus(model: model)
        }
        Card(title: "Now Playing") {
            RDSNowPlaying(model: model)
        }
    }
}

struct RDSRadiotextText: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        RDSCountedField(placeholder: "Default Radiotext",
                        text: model.setting(\.rdsRTText, .liveRDS).binding, maxChars: 64)
        SettingPicker("Radiotext Length", setting: model.setting(\.rdsRTMode, .liveRDS),
                      tooltip: "64 characters (group 2A) suits almost every receiver; 32 characters (group 2B) only for very old ones.") {
            Text("64 Characters").tag("2A")
            Text("32 Characters").tag("2B")
        }
        .pickerStyle(.segmented)
        SettingToggle("Centre Radiotext", setting: model.setting(\.rdsRTCentered, .liveRDS))
        SettingToggle("Append Carriage Return", setting: model.setting(\.rdsRTCR, .liveRDS),
                      tooltip: "Ends each message with a carriage return so receivers know where it stops.")
        Text("The Default Radiotext goes on air while no message below is ticked.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct RDSRadiotextMessages: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        ForEach(0..<4, id: \.self) { index in
            HStack(spacing: 12) {
                Toggle("Message \(model.rtBufferLabel(index))", isOn: model.rtBufferEnabledBinding(index))
                    .toggleStyle(.checkbox)
                    .frame(width: 96, alignment: .leading)
                TextField("Message \(model.rtBufferLabel(index))", text: model.rtBufferTextBinding(index))
                    .textFieldStyle(.roundedBorder)
            }
        }
        DoubleSliderRow(
            title: "Cycle Time",
            setting: model.setting(\.rdsRTCycleTime, .liveRDS),
            range: RDSPageFormat.cycleTimeRange,
            format: "%.1f s",
            tooltip: "How long each ticked message stays on air before the next one.",
            defaultValue: model.resetValue(\.rdsRTCycleTime))
        Text(model.enabledRTBufferIndices.isEmpty
             ? "No message is ticked, so the Default Radiotext is on air."
             : "Ticked messages rotate in order, one per cycle.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct RDSRadiotextPlus: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        SettingToggle("Enable RT+", setting: model.setting(\.rdsEnableRTPlus, .liveRDS),
                      tooltip: "Tags artist and title inside the Radiotext (groups 3A and 11A) so RT+ receivers show them in their own fields. RT+ can only tag text that is actually in a message.")
        if !model.config.rdsNowPlayingEnabled {
            TextField("RT+ Format A", text: model.setting(\.rdsRTPlusFormatA, .liveRDS).binding)
                .textFieldStyle(.roundedBorder)
            TextField("RT+ Format B", text: model.setting(\.rdsRTPlusFormatB, .liveRDS).binding)
                .textFieldStyle(.roundedBorder)
        }
        Text("To show artist and title, turn on the now-playing script and put \"{artist} - {title}\" in the Default Radiotext or a message.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct RDSNowPlaying: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        SettingToggle("Enable Now Playing Script", setting: model.setting(\.rdsNowPlayingEnabled, .liveRDS),
                      tooltip: "Runs a script that prints the current artist and title; its output fills the {artist}, {title} and {now_playing} macros.")
        LabeledContent("Script Path") {
            HStack(spacing: 8) {
                TextField("", text: model.setting(\.rdsNowPlayingScript, .none).binding)
                    .textFieldStyle(.roundedBorder)
                Button("Choose\u{2026}") {
                    model.chooseNowPlayingScript()
                }
                .buttonStyle(.bordered)
            }
        }
        DoubleSliderRow(
            title: "Poll Interval",
            setting: model.setting(\.rdsNowPlayingPollSeconds, .none),
            range: 1...60,
            format: "%.1f s",
            tooltip: "How often the script runs.",
            defaultValue: model.resetValue(\.rdsNowPlayingPollSeconds))
        DoubleSliderRow(
            title: "Script Timeout",
            setting: model.setting(\.rdsNowPlayingTimeoutSeconds, .none),
            range: 0.2...10,
            format: "%.1f s",
            tooltip: "A script that runs longer than this is stopped and its output ignored.",
            defaultValue: model.resetValue(\.rdsNowPlayingTimeoutSeconds))
        LiveObservationView(telemetry: model.telemetry) { t in
            Text(t.rdsNowPlayingStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help("Macros: {now_playing}, {artist}, {title}, {display}, {date}, {time}")
    }
}

// MARK: - Subcarrier

struct RDSCarrierTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // One card: the page title already says Subcarrier.
        Card {
            RDSInjectionControls(model: model)
        }
    }
}

struct RDSInjectionControls: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        DoubleSliderRow(
            title: "Injection",
            setting: model.setting(\.rdsLevel, .restart),
            range: RDSPageFormat.injectionRangeKHz,
            format: "%.1f kHz",
            tooltip: "Deviation taken by the 57 kHz RDS subcarrier. 2.0 kHz (2.7% of 75 kHz) is typical; ITU-R BS.450 allows about 1 to 7.5 kHz. The subcarrier is locked to three times the pilot.",
            defaultValue: model.resetValue(\.rdsLevel))
        Text("On air: \(RDSPageFormat.injectionReadout(kHz: model.config.rdsLevel)) of the 75 kHz reference deviation.")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Schedule

/// Group scheduling and clock time.
struct RDSScheduleTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Groups") {
            RDSGroupSchedule(model: model)
        }
        Card(title: "Clock Time") {
            RDSClockTime(model: model)
        }
    }
}

struct RDSGroupSchedule: View {
    @ObservedObject var model: MPXPrimeViewModel

    // Automatic (recommended) vs Custom. Automatic uses the standard
    // IEC 62106 schedule, auto-derived from the enabled RDS features; Custom
    // uses the manual group sequence. Mapped onto the existing scheduler
    // flags so existing INIs keep working unchanged -- the manual sequence is
    // active only when both Standard and Auto are off.
    private var useCustomSequence: Binding<Bool> {
        Binding(
            get: { !model.config.rdsSchedulerStandard && !model.config.rdsSchedulerAuto },
            set: { custom in
                model.setConfigValue(\.rdsSchedulerStandard, !custom, runtimeDisposition: .liveRDS)
                model.setConfigValue(\.rdsSchedulerAuto, !custom, runtimeDisposition: .liveRDS)
            }
        )
    }

    var body: some View {
        Toggle("Custom Group Sequence", isOn: useCustomSequence)
            .help("Off (recommended): groups are scheduled automatically at the IEC 62106 rates for the features you enable. On: exactly the group list you type is sent.")
        if useCustomSequence.wrappedValue {
            TextField("Group Sequence", text: model.setting(\.rdsGroupSequence, .liveRDS).binding)
                .textFieldStyle(.roundedBorder)
            Text("Space-separated groups, for example 0A 0A 2A 3A 11A. Include every group your enabled features need.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Automatic: the group mix follows the standard rates and updates as you enable RDS features.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct RDSClockTime: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        SettingToggle("Enable Clock Time", setting: model.setting(\.rdsEnableCT, .liveRDS),
                      tooltip: "Sends the date and time once a minute (group 4A) so receivers can set their clocks.")
        SettingPicker("Time Zone", setting: model.setting(\.rdsTZOffset, .liveRDS),
                      tooltip: "Local time offset from UTC sent with the clock time. Adjust it for daylight saving time.") {
            ForEach(RDSPageFormat.timeZoneMenu(including: model.config.rdsTZOffset), id: \.self) { hours in
                Text(RDSPageFormat.timeZoneLabel(hours)).tag(hours)
            }
        }
        .pickerStyle(.menu)
        .disabled(!model.config.rdsEnableCT)
    }
}

// MARK: - Alternative Frequencies

struct RDSAFTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // One card: the page title already says Alt. Frequencies.
        Card {
            RDSAFFields(model: model)
        }
    }
}

struct RDSAFFields: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        SettingToggle("Enable AF", setting: model.setting(\.rdsEnableAF, .liveRDS),
                      tooltip: "Sends the alternative-frequency list (group 0A).")
        SettingPicker("Method", setting: model.setting(\.rdsAFMethod, .liveRDS),
                      tooltip: "Method A: one list of every frequency in the network. Method B: each alternative paired with the tuned frequency, for regional variants.") {
            Text("Method A").tag("A")
            Text("Method B").tag("B")
        }
        .pickerStyle(.segmented)
        .fixedSize()
        TextField("Frequencies", text: model.setting(\.rdsAFList, .liveRDS).binding,
                  prompt: Text("88.1, 98.8, 106.6"))
            .textFieldStyle(.roundedBorder)
        Text("Frequencies in MHz, separated by commas (87.6 to 107.9). With Method B, put the tuned frequency first.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

#endif  // os(macOS)
