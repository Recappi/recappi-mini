import SwiftUI

struct AccountAvatar: View {
    let session: UserSession?
    let size: CGFloat

    var body: some View {
        Group {
            if let url = avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: size, height: size)
                    case .failure:
                        fallback
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Palette.borderHairline, lineWidth: 0.5)
        )
    }

    private var avatarURL: URL? {
        guard let raw = session?.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    private var fallback: some View {
        ZStack {
            Circle()
                .fill(Palette.controlFillPress)

            if let initials, !initials.isEmpty {
                Text(initials)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.dtLabelSecondary)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: size, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.dtLabelSecondary)
            }
        }
    }

    private var initials: String? {
        guard let session else { return nil }
        let display = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = display.isEmpty ? session.email : display
        let parts = source
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }
        return letters.joined()
    }
}
