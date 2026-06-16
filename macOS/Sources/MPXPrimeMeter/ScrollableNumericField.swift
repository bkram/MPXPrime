import AppKit
import SwiftUI

// A right-aligned numeric text field that (1) always displays a "." decimal and
// accepts a typed "," (converted to "."), independent of the system locale, and
// (2) adjusts on mouse-wheel / trackpad scroll while the pointer is over it.
// Used for the SDR Frequency and Gain fields; it writes the bound value, and an
// existing onChange(of:) on the value drives the live retune/gain apply.
struct ScrollableNumericField: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let decimals: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ScrollNSTextField {
        let tf = ScrollNSTextField()
        tf.alignment = .right
        // Default control font (system), matching the other input-bar fields;
        // don't force a monospaced face here.
        tf.font = .systemFont(ofSize: NSFont.systemFontSize)
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.delegate = context.coordinator
        tf.target = context.coordinator
        tf.action = #selector(Coordinator.commitAction(_:))
        tf.onScroll = { [weak c = context.coordinator] dir in c?.scroll(dir) }
        tf.stringValue = context.coordinator.formatted(value)
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateNSView(_ tf: ScrollNSTextField, context: Context) {
        context.coordinator.parent = self
        // Don't clobber the user's in-progress text while the field is editing.
        if tf.currentEditor() == nil {
            tf.stringValue = context.coordinator.formatted(value)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ScrollableNumericField
        init(_ parent: ScrollableNumericField) { self.parent = parent }

        func formatted(_ v: Double) -> String { String(format: "%.\(parent.decimals)f", v) }

        private func apply(_ raw: Double) {
            let stepped = (raw / parent.step).rounded() * parent.step
            parent.value = min(parent.range.upperBound, max(parent.range.lowerBound, stepped))
        }

        @objc func commitAction(_ sender: NSTextField) {
            let norm = sender.stringValue.replacingOccurrences(of: ",", with: ".")
            if let d = Double(norm) { apply(d) }
            sender.stringValue = formatted(parent.value)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let tf = obj.object as? NSTextField { commitAction(tf) }
        }

        func scroll(_ direction: Int) {
            apply(parent.value + Double(direction) * parent.step)
        }
    }
}

// NSTextField that turns scroll events over it into step commands. Works
// whether or not the field is focused (scrollWheel is delivered to the view
// under the pointer).
final class ScrollNSTextField: NSTextField {
    var onScroll: ((Int) -> Void)?
    private var accum: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            // Trackpad: accumulate; ~one step per several points of travel.
            accum += event.scrollingDeltaY
            let threshold: CGFloat = 6
            while accum >= threshold { onScroll?(1); accum -= threshold }
            while accum <= -threshold { onScroll?(-1); accum += threshold }
        } else {
            // Mouse wheel: one detent per step.
            if event.scrollingDeltaY > 0 { onScroll?(1) } else if event.scrollingDeltaY < 0 { onScroll?(-1) }
        }
    }
}
