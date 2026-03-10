// ClassifierDebugHUD.swift
// ArcticEdge
//
// #if DEBUG persistent HUD showing live classifier state.
// Compiled out of release builds — no gesture unlock needed.

#if DEBUG
import SwiftUI

struct ClassifierDebugHUD: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("STATE: \(appModel.classifierStateLabel)")
                .foregroundStyle(stateColor)
                .fontWeight(.semibold)
            Text(String(format: "GPS: %.1f m/s", appModel.lastGPSSpeed))
            Text(String(format: "VAR: %.4f g\u{00B2}", appModel.lastGForceVariance))
            Text("ACT: \(appModel.lastActivityLabel)")
            ProgressView(value: appModel.hysteresisProgress)
                .tint(stateColor)
                .frame(width: 120)
            Text(String(format: "%.0f%%", appModel.hysteresisProgress * 100))
                .font(.caption2)
        }
        .font(.caption.monospacedDigit())
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var stateColor: Color {
        switch appModel.classifierStateLabel {
        case "SKIING":    return .green
        case "CHAIRLIFT": return .orange
        default:          return .secondary
        }
    }
}
#endif
