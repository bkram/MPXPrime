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
        // Reflect the model value unless the user is *actively typing* (a focused
        // or text-selected field is NOT enough -- otherwise scroll / stepper /
        // live-retune changes never reach the display while the box has focus).
        // Only write when the text actually differs, so background re-renders
        // (RDS/status updates) don't deselect a field the user just clicked.
        if !context.coordinator.isUserTyping {
            let s = context.coordinator.formatted(value)
            if tf.stringValue != s { tf.stringValue = s }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ScrollableNumericField
        // True only between the first keystroke and commit/blur -- the window in
        // which updateNSView must not overwrite what the user is typing.
        var isUserTyping = false
        init(_ parent: ScrollableNumericField) { self.parent = parent }

        func formatted(_ v: Double) -> String { String(format: "%.\(parent.decimals)f", v) }

        // Clamp only -- do NOT snap to the step grid. `step` is the scroll/
        // stepper increment, not a value raster: typed values keep their full
        // precision (864.540 must not round to 864.5 -- audio links sit off
        // the broadcast raster), and scrolling from an off-raster value
        // increments it without destroying the fine offset.
        private func apply(_ raw: Double) {
            parent.value = min(parent.range.upperBound, max(parent.range.lowerBound, raw))
        }

        private func commit(_ sender: NSTextField) {
            let norm = sender.stringValue.replacingOccurrences(of: ",", with: ".")
            if let d = Double(norm) { apply(d) }
            isUserTyping = false
            sender.stringValue = formatted(parent.value)
        }

        @objc func commitAction(_ sender: NSTextField) {
            commit(sender)
            // Resign first responder on Enter so the box returns to display-sync
            // mode (a lingering selection otherwise looks "stuck" on the typed
            // value even though tuning works).
            sender.window?.makeFirstResponder(nil)
        }

        // Focused (text auto-selected) but nothing typed yet -- still allow the
        // display to track the model (scroll/stepper/retune).
        func controlTextDidBeginEditing(_ obj: Notification) { isUserTyping = false }

        // First keystroke: now protect the in-progress text until commit/blur.
        func controlTextDidChange(_ obj: Notification) { isUserTyping = true }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let tf = obj.object as? NSTextField { commit(tf) }
        }

        func scroll(_ direction: Int) {
            isUserTyping = false   // scrolling means the user is done typing
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
