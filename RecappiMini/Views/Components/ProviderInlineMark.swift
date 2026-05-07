import AppKit
import SwiftUI

struct ProviderInlineMark: View {
    let provider: OAuthProvider
    let size: CGFloat

    var body: some View {
        Image(nsImage: provider.logoImage)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
