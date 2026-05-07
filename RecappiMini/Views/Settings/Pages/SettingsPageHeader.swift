import SwiftUI

/// Hero block that opens every Settings detail page: large rounded icon tile,
/// title in `.title2`, then a one-line subtitle in `.caption`. Matches the
/// System Settings cadence so each pane has the same visual rhythm.
struct SettingsPageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            GlassDetailIcon(color: color, systemImage: systemImage)

            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.labelPrimary)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Palette.labelSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
