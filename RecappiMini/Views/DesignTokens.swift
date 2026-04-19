import SwiftUI

/// Design tokens mirroring `Recappi Mini - Design Refresh.html`.
/// Source file: /tmp/recappi-design-refresh/recappi-mini/project/Recappi Mini - Design Refresh.html
/// Keep this central so state views stay readable and tokens match the
/// AppKit / SwiftUI opacity and radius conventions the design established.
enum DT {
    // MARK: - Opacity tiers over black (design's "label" scale)

    enum Label {
        static let primary: Double = 0.847
        static let secondary: Double = 0.498
        static let tertiary: Double = 0.259
        static let quaternary: Double = 0.098
    }

    // MARK: - System accents

    static let systemRed = Color(red: 255/255, green: 59/255, blue: 48/255)
    static let systemRedDeep = Color(red: 220/255, green: 36/255, blue: 30/255)
    static let systemRedLight = Color(red: 255/255, green: 120/255, blue: 110/255)
    static let systemBlue = Color(red: 0/255, green: 122/255, blue: 255/255)
    static let systemBluePress = Color(red: 0/255, green: 101/255, blue: 212/255)
    static let systemGreen = Color(red: 52/255, green: 199/255, blue: 89/255)
    static let systemOrange = Color(red: 255/255, green: 159/255, blue: 10/255)

    // MARK: - Radii (pt)

    enum R {
        static let panel: CGFloat = 14
        static let card: CGFloat = 10
        static let control: CGFloat = 6
    }

    // MARK: - Panel geometry

    static let panelWidth: CGFloat = 280
    static let panelPadding: CGFloat = 8

    // MARK: - Motion — cubic-bezier(0.22, 1, 0.36, 1) / spring variants

    /// Design's `--ease` (cubic-bezier(0.22, 1, 0.36, 1)) — easeOutExpo-ish.
    /// SwiftUI `.timingCurve(0.22, 1, 0.36, 1, duration:)` matches.
    static func ease(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    /// Design's `--ease-spring` (cubic-bezier(0.2, 0.9, 0.2, 1)).
    static func easeSpring(_ duration: Double) -> Animation {
        .timingCurve(0.2, 0.9, 0.2, 1, duration: duration)
    }

    // MARK: - Per-transition timings (from the design's motion table)

    enum Motion {
        /// idle ▸ recording: resize first, then content
        static let idleToRecording: Double = 0.20
        /// recording ▸ processing: cross-fade
        static let recordingToProcessing: Double = 0.20
        /// processing ▸ done: spring up
        static let processingToDone: Double = 0.26
        /// any ▸ error: horizontal nudge
        static let toError: Double = 0.18
        /// done ▸ idle: fade + shrink
        static let doneToIdle: Double = 0.24
    }
}

// MARK: - Color helpers

extension Color {
    /// Black with the design's tiered opacity scale — use instead of
    /// SwiftUI's .primary/.secondary/.tertiary when we need to match the
    /// exact opacity the design establishes (and stay light-mode-only for
    /// now, since the panel is on a glass material with its own contrast).
    static let dtLabel = Color.black.opacity(DT.Label.primary)
    static let dtLabelSecondary = Color.black.opacity(DT.Label.secondary)
    static let dtLabelTertiary = Color.black.opacity(DT.Label.tertiary)
    static let dtLabelQuaternary = Color.black.opacity(DT.Label.quaternary)
}

// MARK: - Shared shapes / controls

/// 28pt square icon button with hover fill — panel chrome (settings gear,
/// trash, folder, copy, etc.).
struct PanelIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        Chrome(isPressed: configuration.isPressed, size: size) {
            configuration.label
        }
    }

    private struct Chrome<Content: View>: View {
        let isPressed: Bool
        let size: CGFloat
        @ViewBuilder let content: () -> Content
        @State private var hovered = false

        var body: some View {
            content()
                .frame(width: size, height: size)
                .foregroundStyle(hovered || isPressed ? Color.dtLabel : Color.dtLabelSecondary)
                .background(
                    RoundedRectangle(cornerRadius: DT.R.control)
                        .fill(Color.black.opacity(isPressed ? 0.10 : (hovered ? 0.06 : 0)))
                )
                .contentShape(RoundedRectangle(cornerRadius: DT.R.control))
                .onHover { hovered = $0 }
                .animation(DT.ease(0.12), value: hovered)
                .animation(DT.ease(0.08), value: isPressed)
        }
    }
}

/// Radial-gradient red button used for Record/Stop. 28pt circle with a
/// white inner core; swap shape (circle vs rounded-square) for record vs stop.
struct PrimaryRecordButton: View {
    enum Kind { case record, stop }

    let kind: Kind
    let action: () -> Void

    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [DT.systemRedLight, DT.systemRed, DT.systemRedDeep],
                            center: UnitPoint(x: 0.35, y: 0.30),
                            startRadius: 0,
                            endRadius: 20
                        )
                    )
                    .overlay(
                        Circle().stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                    )
                    .overlay(alignment: .top) {
                        // Inset top highlight — the "liquid" giveaway for the button
                        Circle()
                            .trim(from: 0, to: 0.5)
                            .stroke(Color.white.opacity(0.55), lineWidth: 0.5)
                            .rotationEffect(.degrees(-90))
                            .padding(0.5)
                    }
                    .shadow(color: Color.black.opacity(0.15), radius: 1, y: 1)
                    .shadow(color: DT.systemRed.opacity(0.45), radius: 4, y: 2)

                switch kind {
                case .record:
                    Circle()
                        .fill(Color.white.opacity(0.96))
                        .frame(width: 10, height: 10)
                case .stop:
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.white.opacity(0.96))
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 28, height: 28)
            .scaleEffect(pressed ? 0.96 : (hovered ? 1.04 : 1.0))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .animation(DT.ease(0.12), value: hovered)
        .animation(DT.ease(0.08), value: pressed)
    }
}

/// macOS-style push button (bordered gradient). Matches `.btn` + `.btn.primary`
/// from the design.
struct PanelPushButtonStyle: ButtonStyle {
    var primary: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: primary ? .regular : .regular))
            .foregroundStyle(primary ? Color.white : Color.dtLabel)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control)
                    .fill(
                        primary
                        ? LinearGradient(
                            colors: [Color(red: 60/255, green: 140/255, blue: 255/255), DT.systemBlue],
                            startPoint: .top, endPoint: .bottom
                        )
                        : LinearGradient(
                            colors: [Color.white.opacity(0.95), Color(red: 248/255, green: 248/255, blue: 252/255).opacity(0.9)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control)
                    .stroke(primary ? Color(red: 0, green: 0.35, blue: 0.78).opacity(0.55) : Color.black.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 0.5, y: 0.5)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
    }
}
