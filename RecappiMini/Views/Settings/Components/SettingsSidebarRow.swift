import SwiftUI

/// Sidebar row for the Settings split view — small SF-symbol gradient tile +
/// title, with an optional 8pt status dot at the trailing edge so categories
/// like Account / Permissions can surface their connected/needs-attention
/// state without requiring the user to drill in.
struct SettingsSidebarRow: View {
    let title: String
    let systemImage: String
    let color: Color
    var size: CGFloat = 28
    var iconSize: CGFloat? = nil
    var cornerRadius: CGFloat? = nil
    var statusDot: Color? = nil

    var body: some View {
        let radius = cornerRadius ?? size * 0.28
        let innerSize = iconSize ?? size * 0.55
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: innerSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color.gradient)
                .overlay(
                    LinearGradient(
                        colors: [.white.opacity(0.5), .white.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.plusLighter)
                    .mask(shape.stroke(lineWidth: 1.5))
                )
                .clipShape(shape)
            Text(title)
                .font(.body)
            Spacer()
            if let statusDot {
                Circle()
                    .fill(statusDot)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 2)
    }
}
