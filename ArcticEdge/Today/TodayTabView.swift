// TodayTabView.swift
// ArcticEdge
//
// Today tab root. Shows ContentView when no session is active.
// When isDayActive, fullScreenCover presents LiveTelemetryView for the duration
// of the session. LiveTelemetryView internally handles the post-run sheet.
// The fullScreenCover is dismissed automatically when isDayActive → false
// (triggered by the End Day button inside LiveTelemetryView calling appModel.endDay()).

import SwiftUI

struct TodayTabView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ContentView()
            .fullScreenCover(isPresented: Binding(
                get: { appModel.isDayActive },
                set: { _ in }   // read-only; dismissed by endDay() setting isDayActive = false
            )) {
                LiveTelemetryView()
                    .environment(appModel)
            }
    }
}
