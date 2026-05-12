import SwiftUI

extension View {
    /// Keep controls interactive and keyboard-reachable while hiding the
    /// default SwiftUI focus ring. Recappi's compact panels are pointer-first,
    /// and the ring reads as visual noise when controls are clicked.
    func recappiSuppressFocusRing() -> some View {
        focusEffectDisabled()
    }
}
