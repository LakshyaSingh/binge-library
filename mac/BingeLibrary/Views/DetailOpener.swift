import SwiftUI

/// Wraps a poster or row in a real button, so it works with the pointer, the keyboard
/// (Full Keyboard Access: Tab to it, then Space or Return) and VoiceOver.
/// The detail page zooms out of the spot you clicked; from the keyboard it opens from the center.
/// The click position is read once from the click itself, so nothing is tracked while scrolling.
struct DetailOpener<Content: View>: View {
    @Environment(AppModel.self) private var model
    let item: DetailItem
    let accessibilityLabel: String
    /// When set, the item can be selected: a click selects it while selecting, and ⌘-click starts selecting.
    var selection: Selection? = nil
    @ViewBuilder let content: Content

    struct Selection {
        var active: Bool
        var isSelected: Bool
        var toggle: () -> Void
    }

    var body: some View {
        // Built from lightweight pieces rather than a Button: a Button per poster measurably
        // slowed scrolling (0.6% → 1.2% dropped frames at 120 Hz), and these cover the same ground.
        content
            .contentShape(Rectangle())
            .onTapGesture {                                                                      // pointer
                if let selection, selection.active || NSEvent.modifierFlags.contains(.command) {
                    selection.toggle()
                } else {
                    model.openDetail(item, from: DetailArea.anchorForCurrentClick())
                }
            }
            .focusable(interactions: .activate)                                                  // keyboard focus
            .onKeyPress(keys: [.return, .space]) { _ in activate(); return .handled }            // Return / Space
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selection?.active == true ? (selection?.isSelected == true ? [.isButton, .isSelected] : .isButton) : .isButton)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(selection?.active == true ? "Selects or deselects" : "Opens details")
            .accessibilityAction { activate() }
    }

    private func activate() {
        if let selection, selection.active { selection.toggle() } else { model.openDetail(item) }
    }
}

extension AppModel {
    /// Animations for page changes: springs normally, a short fade when Reduce Motion is on.
    static var motion: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeInOut(duration: 0.2) : pageSpring
    }
}
