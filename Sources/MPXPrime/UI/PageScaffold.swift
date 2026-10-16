// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import MPXPrimeUI
import SwiftUI

// The building blocks every page is made of, in one place so the pages look
// alike (style guide in docs/ui-style-guide.md):
//
//   - `Card`      a settings group (`.standard`) or a live readout (`.meter`)
//   - `InsetTile` a tile inside a card
//   - `Chip`      a small status pill
//   - `TabHelpBox` the one help block at the bottom of every page
//
// Do not hand-build `RoundedRectangle` backgrounds in a page: use these.

enum CardStyle {
    /// Settings group: parameter controls, status blocks, RDS fields.
    case standard
    /// Live readouts: a slightly darker plate so meters and LEDs stand out.
    case meter
}

/// A titled group of controls. The title names a part of the page and never
/// repeats the page title; a page with a single card passes an empty title
/// and the card draws without one.
struct Card<Content: View>: View {
    let title: String
    let style: CardStyle
    @ViewBuilder var content: Content

    init(title: String = "", style: CardStyle = .standard, @ViewBuilder content: () -> Content) {
        self.title = title
        self.style = style
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(surface)
            .overlay(
                RoundedRectangle(cornerRadius: BroadcastStyle.panelCornerRadius)
                    .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelCornerRadius))
        }
    }

    private var surface: Color {
        switch style {
        case .standard: return BroadcastStyle.panelSurface
        case .meter: return BroadcastStyle.meterSurface
        }
    }

    private var padding: CGFloat {
        switch style {
        case .standard: return BroadcastStyle.cardPadding
        case .meter: return BroadcastStyle.meterCardPadding
        }
    }

    private var spacing: CGFloat {
        switch style {
        case .standard: return BroadcastStyle.cardSpacing
        case .meter: return BroadcastStyle.meterCardSpacing
        }
    }
}

/// A tile inside a card (a meter group, a readout block, an Overview stage
/// card): 8 pt radius, 10 pt padding, the meter surface.
struct InsetTile<Content: View>: View {
    var highlighted: Bool = false
    @ViewBuilder var content: Content

    init(highlighted: Bool = false, @ViewBuilder content: () -> Content) {
        self.highlighted = highlighted
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BroadcastStyle.meterCardSpacing) {
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .fill(BroadcastStyle.meterSurface.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(highlighted ? BroadcastStyle.accent.opacity(0.40) : BroadcastStyle.panelBorder,
                        lineWidth: 0.75)
        )
    }
}

/// A small status pill (status bar, flow strip, readout tags): 4 pt radius.
struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.caption.monospaced().weight(filled ? .semibold : .regular))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(filled ? Color.white : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(filled ? AnyShapeStyle(tint) : BroadcastStyle.stagePillFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(BroadcastStyle.panelBorder, lineWidth: filled ? 0 : 0.5)
            )
    }
}

/// The page's help block, at the bottom of every page, fed by
/// `Stage.helpText`. One per page; never restate it in a card caption.
struct TabHelpBox: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Decorative: the text beside it carries the content.
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelCornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelCornerRadius, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }
}

/// Page layout constants: every page uses them, so no page invents its own.
enum PageLayout {
    static let padding: CGFloat = 20
    static let maxWidth: CGFloat = 1120
    static let cardSpacing: CGFloat = 16
}

#endif  // os(macOS)
