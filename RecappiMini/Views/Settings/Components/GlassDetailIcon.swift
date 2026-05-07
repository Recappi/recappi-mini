import SwiftUI

/// Hero icon used at the top of each Settings detail page. The brand color
/// fills the rounded outer tile; the glyph sits on a frosted-glass chip with
/// a top-down highlight so it picks up the same liquid-glass look as the
/// floating recorder pill.
struct GlassDetailIcon: View {
    let color: Color
    var systemImage: String? = nil
    var asset: String? = nil
    var tileSize: CGFloat = 72
    var iconSize: CGFloat = 26
    var outerCornerRadius: CGFloat = 20
    var innerCornerRadius: CGFloat = 14

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous)

        ZStack {
            outer.fill(color.gradient)
                .frame(width: tileSize, height: tileSize)
            inner
                .fill(color.gradient)
                .overlay(inner.strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                .overlay {
                    glyph
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                }
                .frame(width: tileSize, height: tileSize)
        }
        .frame(width: tileSize, height: tileSize)
        .overlay(
            LinearGradient(
                colors: [.white.opacity(0.5), .white.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .blendMode(.plusLighter)
            .mask(outer.stroke(lineWidth: 1.5))
        )
        .clipShape(outer)
    }

    @ViewBuilder
    private var glyph: some View {
        if let asset {
            Image(asset)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .frame(width: iconSize + 32, height: iconSize + 32)
        }
    }
}
