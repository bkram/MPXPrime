import AppKit
import SwiftUI

// A pop-up menu (NSPopUpButton) whose selection also steps on mouse-wheel /
// trackpad scroll while the pointer is over it -- the menu equivalent of
// ScrollableNumericField. Because it IS the native control (not an overlay),
// clicking still opens the menu normally. Used for the SDR IF-bandwidth
// selector so it can be dialled without opening the menu.
//
// `options` is ordered (label, tag); `selection` binds to the chosen tag.
struct ScrollableMenuPicker: NSViewRepresentable {
    let options: [(label: String, tag: Int)]
    @Binding var selection: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ScrollNSPopUpButton {
        let pop = ScrollNSPopUpButton(frame: .zero, pullsDown: false)
        pop.bezelStyle = .rounded
        pop.controlSize = .regular
        pop.font = .systemFont(ofSize: NSFont.systemFontSize)
        pop.target = context.coordinator
        pop.action = #selector(Coordinator.selectionChanged(_:))
        pop.onScroll = { [weak c = context.coordinator] dir in c?.scroll(dir) }
        context.coordinator.rebuild(pop)
        return pop
    }

    func updateNSView(_ pop: ScrollNSPopUpButton, context: Context) {
        context.coordinator.parent = self
        context.coordinator.rebuild(pop)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ScrollableMenuPicker
        init(_ parent: ScrollableMenuPicker) { self.parent = parent }

        /// Rebuild the menu items if the option set changed, then sync selection.
        func rebuild(_ pop: ScrollNSPopUpButton) {
            let titles = parent.options.map(\.label)
            if pop.itemTitles != titles {
                pop.removeAllItems()
                for opt in parent.options {
                    pop.addItem(withTitle: opt.label)
                    pop.lastItem?.tag = opt.tag
                }
            }
            if pop.selectedTag() != parent.selection {
                pop.selectItem(withTag: parent.selection)
            }
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            parent.selection = sender.selectedTag()
        }

        /// Scroll up = next option in the list, down = previous.
        func scroll(_ direction: Int) {
            let tags = parent.options.map(\.tag)
            guard let idx = tags.firstIndex(of: parent.selection) else { return }
            let next = idx - direction   // wheel-up (positive) moves toward the top item
            guard next >= 0, next < tags.count else { return }
            parent.selection = tags[next]
        }
    }
}

// NSPopUpButton that converts scroll over it into step commands.
final class ScrollNSPopUpButton: NSPopUpButton {
    var onScroll: ((Int) -> Void)?
    private var accum: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            accum += event.scrollingDeltaY
            let threshold: CGFloat = 6
            while accum >= threshold { onScroll?(1); accum -= threshold }
            while accum <= -threshold { onScroll?(-1); accum += threshold }
        } else if event.scrollingDeltaY > 0 {
            onScroll?(1)
        } else if event.scrollingDeltaY < 0 {
            onScroll?(-1)
        }
    }
}
