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

    /// Mint green used in the recording-state logo tile. Matches the tint
    /// in the Figma design's dark-pill mockup — bright enough to pop on
    /// our light Liquid Glass shell, not so saturated it clashes with the
    /// record button's red.
    static let accentGreenLight = Color(red: 72/255, green: 230/255, blue: 178/255)
    static let accentGreenDeep = Color(red: 18/255, green: 184/255, blue: 130/255)

    /// Charcoal shell for the recording-state pill (from image #39's
    /// iOS copy: UIColor(red: 0.179, green: 0.179, blue: 0.179)).
    static let recordingShell = Color(red: 0.179, green: 0.179, blue: 0.179)
    /// Slightly lighter charcoal for inset controls (stop/share buttons)
    /// so they read as chips on the recording pill.
    static let recordingChip = Color(red: 0.26, green: 0.26, blue: 0.26)

    /// Waveform dot colors from the Figma spec (node 94:32916).
    /// Lit: `#1DF8B3`. Unlit: `#000000` — pure black against the
    /// charcoal shell reads as dim "off" dots.
    static let waveformLit = Color(red: 29/255, green: 248/255, blue: 179/255)
    static let waveformUnlit = Color.black

    // MARK: - Radii (pt)

    enum R {
        static let panel: CGFloat = 14
        static let card: CGFloat = 10
        static let control: CGFloat = 6
    }

    // MARK: - Panel geometry

    static let panelWidth: CGFloat = 320
    /// Outer panel padding. Design spec is 8pt but at that value the
    /// speaker icon sits 17pt from the glass edge which reads as too much
    /// inset on the left; 6pt brings it to 15pt — still inside the panel's
    /// 14pt corner radius, visually tighter.
    static let panelPadding: CGFloat = 6

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

/// Dark-mode text tokens — the panel is always on DT.recordingShell so
/// every label tier is white with tuned opacity. Kept behind the `dtLabel*`
/// names so existing call sites don't need to change.
extension Color {
    static let dtLabel = Color.white.opacity(0.92)
    static let dtLabelSecondary = Color.white.opacity(0.62)
    static let dtLabelTertiary = Color.white.opacity(0.38)
    static let dtLabelQuaternary = Color.white.opacity(0.16)
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
                        .fill(Color.white.opacity(isPressed ? 0.12 : (hovered ? 0.08 : 0)))
                )
                .contentShape(RoundedRectangle(cornerRadius: DT.R.control))
                .onHover { hovered = $0 }
                .animation(DT.ease(0.12), value: hovered)
                .animation(DT.ease(0.08), value: isPressed)
        }
    }
}

/// Flat red Record/Stop button. Solid fill + thin rim + inner mark —
/// no gradients or glow so it sits flush on the charcoal pill.
struct PrimaryRecordButton: View {
    enum Kind { case record, stop, loading }

    let kind: Kind
    var size: CGFloat = 28
    let action: () -> Void

    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(hovered ? DT.systemRedLight : DT.systemRed)
                    .overlay(
                        Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5)
                    )

                switch kind {
                case .record:
                    Circle()
                        .fill(Color.white)
                        .frame(width: size * 0.36, height: size * 0.36)
                case .stop:
                    RoundedRectangle(cornerRadius: size * 0.08)
                        .fill(Color.white)
                        .frame(width: size * 0.30, height: size * 0.30)
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .scaleEffect(0.85)
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(pressed ? 0.96 : 1.0)
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

/// Green-gradient tile with the headset logo — brand chip shared by
/// the recording pill (48pt) and the Settings header (56pt). Size scales
/// padding + corner radius proportionally. Logo PNG loaded from
/// Bundle.main (copied to Contents/Resources by scripts/build-app.sh).
struct LogoTile: View {
    var size: CGFloat = 48

    var body: some View {
        let radius = size * 0.25
        Image(nsImage: logoImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(.black.opacity(0.85))
            .padding(size * 0.083)
            .frame(width: size, height: size)
            .background(
                // Figma: linear-gradient 0→20% white overlay on #1DF8B3
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(DT.waveformLit)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.white.opacity(0), Color.white.opacity(0.2)],
                                startPoint: .top, endPoint: .bottom))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            // Figma: box-shadow: 0px 1px 2px rgba(0,0,0,0.25), 0px 4px 18.8px #4CB191
            .shadow(color: Color(red: 76/255, green: 177/255, blue: 145/255).opacity(0.65), radius: 9, y: 4)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
    }

    private var logoImage: NSImage {
        let img = NSImage(named: "Logo") ?? NSImage()
        img.isTemplate = true
        return img
    }
}

/// Dark circle action button used on the recording pill (stop, and
/// eventually share). Matches Figma CSS 1:1:
///   - bg: #1D1D1D with a 180° linear-gradient rgba(0,0,0,0.02)→rgba(0,0,0,0.2)
///   - inset shadows: 0.5px 1px 1px rgba(255,255,255,0.25) (top highlight)
///                    0px 2px 2px rgba(0,0,0,0.25)           (bottom shade)
///   - outer drop: 0px 1px 2px rgba(0,0,0,0.25)
struct DarkCircleButton: View {
    enum Kind { case stop, record }

    let kind: Kind
    var size: CGFloat = 40
    let action: () -> Void

    @State private var hovered = false
    @State private var pressed = false

    private var base: Color { Color(red: 29/255, green: 29/255, blue: 29/255) }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(base)
                    .overlay(
                        Circle().fill(LinearGradient(
                            colors: [.black.opacity(0.02), .black.opacity(0.2)],
                            startPoint: .top, endPoint: .bottom))
                    )
                    // Inset top highlight (fake inner-shadow via arc stroke).
                    .overlay(alignment: .top) {
                        Circle()
                            .trim(from: 0, to: 0.5)
                            .stroke(Color.white.opacity(0.28), lineWidth: 1)
                            .rotationEffect(.degrees(-90))
                            .padding(0.5)
                    }
                    // Inset bottom shade.
                    .overlay(alignment: .bottom) {
                        Circle()
                            .trim(from: 0, to: 0.5)
                            .stroke(Color.black.opacity(0.35), lineWidth: 1)
                            .rotationEffect(.degrees(90))
                            .padding(0.5)
                    }
                    .shadow(color: .black.opacity(0.30), radius: 2, y: 1)

                switch kind {
                case .stop:
                    RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                        .fill(Color.white)
                        .frame(width: size * 0.32, height: size * 0.32)
                case .record:
                    Circle()
                        .fill(DT.systemRed)
                        .frame(width: size * 0.38, height: size * 0.38)
                }
            }
            .frame(width: size, height: size)
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

/// Dark-theme icon chip used in the recording pill (trash + any future
/// share/action icons). Matches image #39: lighter-charcoal rounded square
/// with a subtle bright-on-hover highlight.
struct DarkChipButtonStyle: ButtonStyle {
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
                .foregroundStyle(Color.white.opacity(hovered || isPressed ? 0.95 : 0.72))
                .background(
                    RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                        .fill(DT.recordingChip.opacity(isPressed ? 1.0 : (hovered ? 0.9 : 0.7)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: DT.R.control))
                .onHover { hovered = $0 }
                .animation(DT.ease(0.12), value: hovered)
                .animation(DT.ease(0.08), value: isPressed)
        }
    }
}

/// Dark-theme push button. Primary uses the app accent (#1DF8B3) on a
/// dark chip so it reads as the affirmative action without leaving the
/// charcoal palette; secondary is a flat dark chip matching the rest of
/// the panel.
struct PanelPushButtonStyle: ButtonStyle {
    var primary: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(primary ? Color.black.opacity(0.88) : Color.dtLabel)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .fill(
                        primary
                        ? LinearGradient(
                            colors: [DT.waveformLit, Color(red: 14/255, green: 210/255, blue: 152/255)],
                            startPoint: .top, endPoint: .bottom
                        )
                        : LinearGradient(
                            colors: [DT.recordingChip.opacity(0.9), DT.recordingChip],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .stroke(primary ? Color.white.opacity(0.18) : Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}
