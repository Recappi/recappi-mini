import SwiftUI

/// Readonly label/value pair used inside grouped Forms — version, distribution,
/// last-checked timestamps, etc. Pads vertically so consecutive rows breathe
/// like System Settings' info rows rather than crammed-together LabeledContent.
struct SettingsReadonlyRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(Palette.labelPrimary)
            Spacer()
            Text(value)
                .foregroundStyle(Palette.labelSecondary)
        }
        .padding(.vertical, 4)
    }
}
