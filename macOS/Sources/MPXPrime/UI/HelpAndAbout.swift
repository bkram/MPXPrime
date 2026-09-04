// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import Accelerate
import AppKit
import AVFoundation
import Combine
import CoreAudio
import Darwin
import Foundation
import MPXPrimeCore
import MPXPrimeUI
import SwiftUI
import UniformTypeIdentifiers

enum HelpTopic: String, CaseIterable, Identifiable {
    case inputLevels = "Input Levels"
    case rdsText = "RDS Text Format"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .inputLevels: return "waveform.path.ecg"
        case .rdsText: return "dot.radiowaves.left.and.right"
        }
    }
}

struct HelpWindowView: View {
    @State private var selection: HelpTopic = .inputLevels

    var body: some View {
        HSplitView {
            List(HelpTopic.allCases, selection: $selection) { topic in
                Label(topic.rawValue, systemImage: topic.icon)
                    .symbolRenderingMode(.hierarchical)
                    .tag(topic)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(selection.rawValue)
                        .font(.title3.weight(.semibold))
                    switch selection {
                    case .inputLevels:
                        HelpInputLevelsView()
                    case .rdsText:
                        HelpRDSTextView()
                    }
                }
                .padding(20)
                .frame(maxWidth: 860, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

func CodeBlock(_ text: String) -> some View {
    Text(text)
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
}

struct InlineRestartRequiredNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Restart Required")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }
}

struct HelpInputLevelsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended operating targets for the current MPX Prime FM chain. Feed it clean, consistent program audio and let the processor create the final density.")
                .foregroundStyle(.secondary)
                .font(.callout)

            GroupBox {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Normal Peaks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("-12 to -6 dBFS")
                            .font(.body.weight(.semibold))
                    }
                    Divider().frame(height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Occasional Peaks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("up to -3 dBFS")
                            .font(.body.weight(.semibold))
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Text("Notes")
                .font(.headline)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("• US nominal input alignment: around -20 dBFS")
                Text("• Europe (EBU R68) style alignment: around -18 dBFS")
                Text("• Do not hold the source at -2 dBFS all the time")
                Text("• If the input already looks slammed, back it down and let the chain work")
                Text("• Wideband AGC is a platform leveler, not the final loudness stage")
                Text("• Final Drive is the main loudness control before the composite clipper")
                Text("• MPX Output Level is for final exciter or interface calibration")
                Text("• Levels are peak safety meters — judge loudness on a real receiver, not on the screen")
                Text("If you hit 0 dBFS, reduce input gain or Final Drive and re-check pre-emphasis behavior.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            Text("Restart-Required Settings")
                .font(.headline)
                .padding(.top, 4)

            InlineRestartRequiredNote(text: kRestartRequiredSettingsListText)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 860, alignment: .leading)
    }
}

struct HelpRDSTextView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stereotool-compatible RDS text grammar for PS, Radiotext, PTYN, and Long PS. Existing Stereotool presets should load without modification.")
                .foregroundStyle(.secondary)
                .font(.callout)

            Text("Quick start")
                .font(.headline)
                .padding(.top, 4)

            CodeBlock("10s:First/10s:Second")

            Text("Shows \"First\" for 10 seconds, then \"Second\" for 10 seconds, repeating.")
                .foregroundStyle(.secondary)
                .font(.callout)

            // MARK: Timing

            Text("Timing prefixes")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("• `Ns:Text` — show `Text` for `N` seconds. Fractional accepted: `1.5s:Text`")
                Text("• `Nt:Text` — transmit-count. Show `Text` for `N` full transmissions of the field, then advance. Useful when you want the receiver to see the message a known number of times rather than for a fixed wall-clock duration.")
                Text("• Untimed text that fits in one chunk holds for 10 s before repeating.")
                Text("• Untimed text that splits into multiple chunks rotates at a default per-chunk duration. For PS, the default is the **PS Frame** slider in the RDS tab (default 3 s); for Radiotext / PTYN / Long PS, the default is 2.5 s.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            CodeBlock("""
1.5s:Short segment
3t:Transmit me three times/5s:Then this for 5 seconds
""")

            // MARK: Separators

            Text("Segment separators")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("• `/` separates segments at the top level. Escape as `\\/` to transmit a literal slash.")
                Text("• Inline whitespace-separated timed tokens also work: `1s:A 2s:B 3s:C` reads as three segments.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            // MARK: Scroll

            Text("Scrolling (PS only)")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("• `<Text` scrolls left, `>Text` scrolls right. Each marker advances by one character per full PS transmission.")
                Text("• Repeat the marker for faster scroll: `<<Text` moves two chars per tick, `<<<Text` three.")
                Text("• Scroll markers are parser-level only on Radiotext — RT transmits too slowly (~5.8 s per cycle) for scrolling to be useful.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            CodeBlock("<<MPX PRIME - FM BROADCAST ENCODER")

            // MARK: Escapes

            Text("Escaping special characters")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("• `\\<`  `\\>`  `\\|`  `\\:`  `\\/`  `\\\\` — transmit the special char literally instead of treating it as a marker.")
                Text("• `||` is accepted for Stereotool compatibility but is a no-op: word-wrap is always on.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            CodeBlock("Visit us\\: https\\://example.com/10s:Alt text")

            // MARK: External content

            Text("External content")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("• `\\R\"path\"` — load file, force uppercase.")
                Text("• `\\r\"path\"` — load file, preserve case.")
                Text("• `\\F\"path\"` / `\\f\"path\"` — Stereotool-compatible aliases for `\\R` / `\\r`.")
                Text("• `\\w\"url\"` — fetch text from a URL. MPX Prime extension, not in Stereotool.")
                Text("File content re-enters the parser, so timing markers inside a loaded file are honored.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            // MARK: Now Playing

            Text("Now Playing macros (Radiotext)")
                .font(.headline)
                .padding(.top, 8)

            CodeBlock("""
Now: {now_playing}
{artist} - {title}
{title}
{date} {time}
""")

            VStack(alignment: .leading, spacing: 6) {
                Text("• `{now_playing}` and `{display}` use the script display text")
                Text("• `{artist}` and `{title}` are preferred for RT+ tagging")
                Text("• When the now-playing script is enabled, RT+ tags are derived from structured script output automatically")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            // MARK: Field limits

            Text("Field widths and transmission cadence")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("• PS is 8 chars wide. One full PS transmission = 4 group-0 blocks.")
                Text("• Radiotext 2A is 64 chars wide (16 segments); 2B is 32 chars (16 segments).")
                Text("• PTYN is 8 chars wide (2 segments).")
                Text("• Long PS is 32 chars wide (8 segments).")
                Text("• Overlong text is word-wrapped and cycled; chunks inherit their segment's timing.")
                Text("• In Mono Mode pilot and RDS are suppressed — transmitted RDS text is disabled until Mono Mode is turned off.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            // MARK: Examples

            Text("More examples")
                .font(.headline)
                .padding(.top, 8)

            CodeBlock("""
5s:MPX Prime - 5s:FM Coder
20s:Station Name/10s:Now Playing
8s:Tune to 88.5/8s:My Frequency
1.5s:Short/2t:Repeat Twice
<<MARQUEE TEXT
10s:Now\\: {artist} - {title}
\\R"~/Documents/station_name.txt"/10s:Static segment
""")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 860, alignment: .leading)
    }
}

/// macOS-style About panel (cf. Music.app / Final Cut): app icon, name,
/// a confident one-line description, version, then a compact highlight of
/// what the processor actually does — it ships a patent-grade chain, full
/// RDS, and a verification harness, so the About should say so rather than
/// undersell it. The full disclaimer is NOT restated here: README.md
/// (intended-use / not-certified) and LICENSE (GPL-3.0, no warranty) are
/// the single source of truth; the panel shows README's canonical key
/// phrase plus links to both.
struct AboutSectionView: View {
    private var appIcon: NSImage? {
        if let icon = NSApp?.applicationIconImage, icon.size.width > 0 {
            return icon
        }
        return NSImage(named: NSImage.applicationIconName)
    }

    private struct Capability: Identifiable {
        let symbol: String
        let text: String
        var id: String { symbol }
    }

    private let capabilities: [Capability] = [
        Capability(
            symbol: "dot.radiowaves.right",
            text: "True FM stereo encoding — constant-amplitude pilot with post-clipper subcarrier injection"),
        Capability(
            symbol: "slider.horizontal.3",
            text: "Linear-phase multiband, look-ahead limiting, PrimeBass enhancement, pre-emphasis-aware HF clipping"),
        Capability(
            symbol: "waveform",
            text: "Differential composite clipper with cross-domain IM cancellation and BS.412 MPX-power control"),
        Capability(
            symbol: "antenna.radiowaves.left.and.right",
            text: "Full RDS encoder — PS, RadioText, RT+, AF, CT, PTY and Long PS, all live-apply"),
        Capability(
            symbol: "chart.bar.xaxis",
            text: "Real-time meters, scope and spectrum, plus offline receiver-model verification")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 12) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 4) {
                    Text("MPX Prime Studio")
                        .font(.title.weight(.semibold))
                    Text("Professional FM stereo processing and RDS encoding — free and open source")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Version \(AppConfig.appVersion) · GPL-3.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(capabilities) { cap in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: cap.symbol)
                                .font(.callout)
                                .foregroundStyle(.tint)
                                .frame(width: 20, alignment: .center)
                                .accessibilityHidden(true)
                            Text(cap.text)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)

                HStack(spacing: 18) {
                    Link("View on GitHub", destination: kProjectURL)
                    Link("User Manual", destination: kManualURL)
                    Link("License", destination: kLicenseURL)
                }
                .font(.callout)

                // Single source of truth for the full disclaimer is README.md
                // (intended-use / not-certified) + LICENSE (GPL-3.0, no
                // warranty). The About only carries README's canonical key
                // phrase plus pointers — do not restate the full text here.
                Text("Experimental and not certified — no conformity or compliance is promised. See the README for intended use and the GPL-3.0 license for terms (provided without warranty).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                Text("Copyright © 2026 Bkram Developments")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct PendingApplyCard: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // Empty view — never shown
        EmptyView()

        // Or completely remove the if and Card, leaving just:
        // EmptyView()
    }
    //     if model.runtimeApplyPending {
    //         Card(title: "Apply Pending") {
    //             HStack {
    //                 Text("Changes were saved. Restart runtime to apply them to audio output.")
    //                     .foregroundStyle(.secondary)
    //                 Spacer()
    //                 Button("Apply Now") {
    //                     model.applyPendingRuntimeChanges()
    //                 }
    //                 .buttonStyle(.borderedProminent)
    //             }
    //         }
    //         .hidden()
    //     }
}

// Conditional `.help()` so an empty/nil tooltip does not clear tooltips set
// elsewhere in the subtree — SwiftUI interprets `.help("")` as "remove help".
struct TooltipIfPresent: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text = text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}

#endif  // os(macOS)
