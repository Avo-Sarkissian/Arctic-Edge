// Theme.swift
// ArcticEdge
//
// The single source for Arctic Dark: colour, type, spacing, and surfaces.
//
// These values were previously re-declared literal-by-literal across six view
// files, so the palette drifted and no change could be made in one place. Every
// view now reads from here.
//
// Direction: a precision instrument, not a dashboard. Deep slate that recedes,
// hairline structure, and one bright accent spent sparingly. The score band ramp
// deliberately avoids red-to-green: a skier working on their technique is not a
// failure state, and traffic lights belong to a different product. The ramp runs
// cold instead, from deep slate through arctic blue to glacier cyan to lit snow,
// so a better run reads as brighter and colder rather than as "passing".

import SwiftUI

// MARK: - Theme

nonisolated enum Theme {

    // MARK: Colour

    enum Palette {
        /// Background, top of the slate gradient.
        static let abyss = Color(red: 0.051, green: 0.067, blue: 0.090)
        /// Background, bottom of the slate gradient.
        static let deep = Color(red: 0.024, green: 0.039, blue: 0.059)

        /// Primary accent. Used for state, focus, and the app's identity.
        static let arctic = Color(red: 0.12, green: 0.56, blue: 1.0)
        /// Secondary accent for load and effort channels.
        static let mint = Color(red: 0.15, green: 0.85, blue: 0.55)
        /// Tertiary accent for speed.
        static let amber = Color(red: 1.0, green: 0.62, blue: 0.10)
        /// Destructive and error states only.
        static let alarm = Color(red: 1.0, green: 0.28, blue: 0.28)
        /// Advisory, non-blocking warnings.
        static let caution = Color(red: 1.0, green: 0.75, blue: 0.0)

        // Score band ramp: cold and increasingly lit, never red-to-green.
        static let bandDeveloping = Color(red: 0.24, green: 0.35, blue: 0.47)
        static let bandSolid = arctic
        static let bandStrong = Color(red: 0.27, green: 0.85, blue: 1.0)
        static let bandExpert = Color(red: 0.91, green: 0.96, blue: 1.0)

        // Foreground tiers. Text sits on a dark field, so hierarchy is carried
        // by opacity rather than by hue.
        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.55)
        static let textTertiary = Color.white.opacity(0.38)
        static let textFaint = Color.white.opacity(0.25)

        /// Hairline used for every divider and card edge.
        static let hairline = Color.white.opacity(0.08)
        static let cardFill = Color.white.opacity(0.03)
    }

    // MARK: Gradients

    enum Gradients {
        /// The app-wide background. Every full-screen surface uses this one.
        static let slate = LinearGradient(
            stops: [
                .init(color: Palette.abyss, location: 0),
                .init(color: Palette.deep, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )

        static let primaryAction = LinearGradient(
            colors: [
                Color(red: 0.118, green: 0.565, blue: 1.0),
                Color(red: 0.0, green: 0.40, blue: 0.80)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Type
    //
    // SF Pro throughout, per the project's aesthetic rules. Personality comes
    // from weight contrast rather than from a second family: the wordmark is
    // black, the score numeral is hairline. A heavy score numeral is the obvious
    // move and reads as a sports badge; a hairline one at size reads as a
    // measuring instrument, which is what this is.

    enum Typography {
        /// The score numeral. Hairline weight, tight tracking, monospaced digits
        /// so the number does not jitter as it animates.
        static func hero(_ size: CGFloat = 92) -> Font {
            .system(size: size, weight: .ultraLight, design: .default)
        }

        static let display = Font.system(size: 28, weight: .bold)
        static let title = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 14, weight: .regular)
        static let caption = Font.system(size: 12, weight: .regular)

        /// Section eyebrows and metric labels. Always uppercase, always tracked.
        static let label = Font.system(size: 10, weight: .medium)
        static let microLabel = Font.system(size: 8, weight: .medium)

        /// Live and summary numbers.
        static let metric = Font.system(size: 20, weight: .light)
        static let metricSmall = Font.system(size: 15, weight: .medium)
    }

    enum Tracking {
        static let label: CGFloat = 2.5
        static let microLabel: CGFloat = 1.5
        static let wordmark: CGFloat = 4.2
        static let hero: CGFloat = -4
    }

    // MARK: Layout

    enum Spacing {
        static let xs: CGFloat = 6
        static let s: CGFloat = 10
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 40
    }

    enum Radius {
        static let small: CGFloat = 10
        static let card: CGFloat = 14
        static let action: CGFloat = 16
    }

    static let hairlineWidth: CGFloat = 0.5
}

// MARK: - Surfaces

extension View {
    /// The frosted card used for every grouped surface.
    func arcticCard(radius: CGFloat = Theme.Radius.card, borderTint: Color? = nil) -> some View {
        self
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderTint ?? Theme.Palette.hairline, lineWidth: Theme.hairlineWidth)
            )
    }

    /// Section eyebrow styling: uppercase, tracked, quiet.
    func arcticLabel(_ tint: Color = Theme.Palette.textTertiary) -> some View {
        self
            .font(Theme.Typography.label)
            .tracking(Theme.Tracking.label)
            .foregroundStyle(tint)
    }

    /// Full-bleed Arctic Dark background.
    func arcticBackground() -> some View {
        background(Theme.Gradients.slate.ignoresSafeArea())
    }
}

// MARK: - Score bands

/// Qualitative band for a carving score.
///
/// Explicitly provisional: the thresholds are placeholders until the model
/// anchors are recalibrated from labelled runs, and the UI says so rather than
/// presenting them as an authoritative grading scale.
nonisolated enum ScoreBand: String, Sendable, CaseIterable {
    case developing
    case solid
    case strong
    case expert

    init(score: Double) {
        switch score {
        case ..<40:  self = .developing
        case ..<60:  self = .solid
        case ..<80:  self = .strong
        default:     self = .expert
        }
    }

    var label: String {
        switch self {
        case .developing: return "Developing"
        case .solid:      return "Solid"
        case .strong:     return "Strong"
        case .expert:     return "Expert"
        }
    }

    var color: Color {
        switch self {
        case .developing: return Theme.Palette.bandDeveloping
        case .solid:      return Theme.Palette.bandSolid
        case .strong:     return Theme.Palette.bandStrong
        case .expert:     return Theme.Palette.bandExpert
        }
    }

    /// Colour for an optional score, so callers do not have to branch.
    static func color(for score: Double?) -> Color {
        guard let score else { return Theme.Palette.textFaint }
        return ScoreBand(score: score).color
    }
}
