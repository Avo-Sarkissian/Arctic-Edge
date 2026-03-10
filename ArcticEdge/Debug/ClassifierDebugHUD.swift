// ClassifierDebugHUD.swift
// ArcticEdge
//
// #if DEBUG persistent HUD showing live classifier diagnostics.
// Compiled out of release builds — no gesture unlock needed.
// Design: Arctic Dark — dark blur background, monospace digits, state-keyed accent color.

#if DEBUG
import SwiftUI

struct ClassifierDebugHUD: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // State label — most prominent field
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 5, height: 5)
                Text(appModel.classifierStateLabel)
                    .foregroundStyle(stateColor)
                    .fontWeight(.semibold)
            }

            Divider()
                .overlay(Color.white.opacity(0.12))

            // Diagnostic values — monospace for alignment stability
            Group {
                hudRow(label: "GPS", value: String(format: "%.1f m/s", appModel.lastGPSSpeed))
                hudRow(label: "VAR", value: String(format: "%.4f g\u{00B2}", appModel.lastGForceVariance))
                hudRow(label: "ACT", value: appModel.lastActivityLabel)
            }

            // Hysteresis progress bar
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.08))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(stateColor.opacity(0.75))
                            .frame(width: geo.size.width * appModel.hysteresisProgress)
                    }
                }
                .frame(height: 3)
                Text(String(format: "%.0f%%", appModel.hysteresisProgress * 100))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.75))
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .frame(width: 148)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Helpers

    private func hudRow(label: String, value: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .foregroundStyle(Color.white.opacity(0.4))
                .frame(width: 30, alignment: .leading)
            Text(value)
                .foregroundStyle(Color.white.opacity(0.8))
        }
    }

    private var stateColor: Color {
        switch appModel.classifierStateLabel {
        case "SKIING":    return Color(red: 0.20, green: 0.90, blue: 0.50)
        case "CHAIRLIFT": return Color(red: 1.0,  green: 0.62, blue: 0.0)
        default:          return Color.white.opacity(0.35)
        }
    }
}
#endif
